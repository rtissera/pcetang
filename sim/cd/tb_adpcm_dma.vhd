-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand
--
-- tb_adpcm_dma.vhd -- ADPCM DMA load from CD, against a beetle-pce-fast golden trace.
--
-- Run: sim/cd/run_adpcm_dma.sh
--
-- Rondo loads ALL of its ADPCM data this way: a READ(6), then $180B <= 02, and cd.vhd copies
-- the DATA IN bytes straight off the SCSI bus into ADPCM RAM (DMA_WRITE_PEND on REQ, then
-- SCSI_ACK_N/AUTO_ACK) with no CPU $1808 reads at all. The playback tests preload the RAM and
-- never exercise this path.
--
-- Golden case sim/cd/golden/adpcm_rondo_dma1 = Rondo's first DMA load (beetle frame 12291):
--   $180D<=00  $1808/9<=0000  $180D<=03 $180D<=02 $180D<=00     write address <- 0
--   SELECT; CDB 08 00 10 1f 20 00                              READ(6) LBA 4127, 32 sectors
--   $180B<=02 ... STATUS ... $180B<=00; STATUS/MESSAGE acks
-- sectors.hex = user data of LBA 4127..4158 taken from the CHD; dma_writes.hex = beetle's
-- 65536 ADPCM RAM writes for that load. The two were checked equal (0 mismatches), so the
-- golden is independent of beetle's CD path.
--
-- DUT: the REAL cd.vhd + REAL cd_bridge.vhd, the port-C arbiter copy (sim/cd/cosim/
-- portc_arbiter.vhd, drift-checked against the boards) and an SDRAM model with WAIT latency.
-- The sector server feeds the real bytes at the 2 Mbaud byte pace. SECTORS may be lowered for
-- a faster run: the CDB count and the comparison range follow it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_adpcm_dma is
	generic (
		DIR           : string  := "sim/cd/golden/adpcm_rondo_dma1";
		SECTORS       : integer := 4;
		SECTOR_LAT_US : integer := 10000;   -- MCU decode latency before a sector's first byte
		FEED_CYCLES   : integer := 214      -- real 2 Mbaud byte pace in clk_pce cycles
	);
end entity;

architecture sim of tb_adpcm_dma is
	constant CLK_PERIOD : time := 23.3 ns;
	constant LBA0       : integer := 4127;
	signal clk     : std_logic := '0';
	signal rst_n   : std_logic := '0';
	signal cpu_ce  : std_logic := '0';
	signal running : boolean := true;

	signal ext_a    : std_logic_vector(20 downto 0) := (others => '0');
	signal ext_di   : std_logic_vector(7 downto 0) := (others => '0');
	signal ext_do   : std_logic_vector(7 downto 0);
	signal ext_wr_n : std_logic := '1';
	signal ext_rd_n : std_logic := '1';

	-- cd <-> cd_bridge
	signal cd_stat, cd_msg : std_logic_vector(7 downto 0);
	signal cd_stat_get     : std_logic;
	signal cd_comm         : std_logic_vector(95 downto 0);
	signal cd_comm_send    : std_logic;
	signal cd_data         : std_logic_vector(7 downto 0);
	signal cd_data_wr, cd_data_end, cd_audio_wr, cd_dm : std_logic;
	signal cd_datain_sectors : unsigned(8 downto 0);
	signal disc_mounted    : std_logic := '0';
	signal toc_wr          : std_logic := '0';
	signal toc_track, toc_control : std_logic_vector(7 downto 0) := (others => '0');
	signal toc_lba         : std_logic_vector(23 downto 0) := (others => '0');
	signal sector_req, sector_is_audio : std_logic;
	signal sector_lba      : std_logic_vector(23 downto 0);
	signal sector_data     : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_data_valid, sector_data_last : std_logic := '0';
	signal dbg_state       : std_logic_vector(4 downto 0);
	signal dbg_dend        : std_logic_vector(31 downto 0);
	signal fifo_space      : unsigned(12 downto 0);
	signal dbg_sp          : std_logic_vector(3 downto 0);
	signal last_1800       : std_logic_vector(7 downto 0) := (others => '0');
	signal cpu_step        : integer := 0;

	-- ADPCM RAM
	signal a_a    : std_logic_vector(16 downto 0);
	signal a_do   : std_logic_vector(3 downto 0);
	signal a_we, a_req : std_logic;
	signal a_slot : std_logic_vector(1 downto 0);
	signal a_di   : std_logic_vector(3 downto 0);
	signal a_rdy  : std_logic;
	signal c_addr : std_logic_vector(24 downto 0);
	signal c_req, c_rd_n : std_logic;
	signal c_di, c_do : std_logic_vector(7 downto 0) := (others => '0');
	signal c_wait : std_logic := '0';

	type mem_t is array (0 to 2**17 - 1) of integer range -1 to 15;
	shared variable mem : mem_t := (others => -1);
	type bytes_t is array (0 to 65535) of integer range 0 to 255;
	shared variable sect_bytes : bytes_t;
	shared variable gold_val   : bytes_t;
	shared variable gold_addr  : bytes_t;

	signal req_pending : integer := 0;
	signal req_lba     : integer := 0;
	signal req_taken   : std_logic := '0';
	signal nibble_writes : integer := 0;

	function reg_addr(r : integer) return std_logic_vector is
	begin
		return "11111111" & "11000" & std_logic_vector(to_unsigned(r, 8));
	end function;
begin
	clk <= not clk after CLK_PERIOD / 2 when running;

	ce_gen : process (clk)
		variable d : integer := 0;
	begin
		if rising_edge(clk) then
			if d = 5 then d := 0; cpu_ce <= '1'; else d := d + 1; cpu_ce <= '0'; end if;
		end if;
	end process;

	cd_inst : entity work.cd
	port map (
		RST_N => rst_n, CLK => clk, EN => '1',
		EXT_A => ext_a, EXT_DI => ext_di, EXT_DO => ext_do,
		EXT_WR_N => ext_wr_n, EXT_RD_N => ext_rd_n, CPU_CE => cpu_ce,
		SEL_N => open, IRQ_N => open, RAM_CS_N => open, BRAM_EN => open,
		CD_STAT => cd_stat, CD_MSG => cd_msg, CD_STAT_GET => cd_stat_get,
		CD_COMM => cd_comm, CD_COMM_SEND => cd_comm_send,
		CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
		CD_REGION => '0', CD_RESET => open,
		CD_DATA => cd_data, CD_DATA_WR => cd_data_wr,
		CD_AUDIO_WR => cd_audio_wr, CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end,
		CD_DATAIN_SECTORS => cd_datain_sectors,
		DBG_DATAIN_CNT => open, DBG_FIRST8 => open, DBG_SP => dbg_sp, DBG_ADPCM => open,
		DBG_COMM_POS => open, DBG_COMM0 => open, DBG_COMM1 => open, DBG_SEL_CNT => open,
		DBG_FIFO_SPACE => fifo_space, DBG_FIFO_DROPS => open, DBG_GDI => open,
		DBG_RD_TOTAL => open, DBG_CDDA_SPACE => open, DBG_UNDERRUNS => open,
		DM => cd_dm, CD_SL => open, CD_SR => open, AD_S => open,
		ADPCM_RAM_A => a_a, ADPCM_RAM_DO => a_do, ADPCM_RAM_WE => a_we,
		ADPCM_RAM_REQ => a_req, ADPCM_RAM_SLOT_CNT => a_slot,
		ADPCM_RAM_DI => a_di, ADPCM_RAM_READY => a_rdy
	);

	bridge_inst : entity work.cd_bridge
	port map (
		CLK => clk, RST_N => rst_n,
		CD_STAT => cd_stat, CD_MSG => cd_msg, CD_STAT_GET => cd_stat_get,
		CD_COMM => cd_comm, CD_COMM_SEND => cd_comm_send,
		CD_DATA => cd_data, CD_DATA_WR => cd_data_wr, CD_DATA_END => cd_data_end,
		DISC_MOUNTED => disc_mounted,
		TOC_WR => toc_wr, TOC_TRACK => toc_track, TOC_CONTROL => toc_control,
		TOC_LBA => toc_lba,
		SECTOR_REQ => sector_req, SECTOR_LBA => sector_lba,
		SECTOR_DATA => sector_data, SECTOR_DATA_VALID => sector_data_valid,
		SECTOR_DATA_LAST => sector_data_last,
		CD_AUDIO_WR => cd_audio_wr, CD_DM => cd_dm, SECTOR_IS_AUDIO => sector_is_audio,
		DBG_STATE => dbg_state, DBG_DEND => dbg_dend,
		DATAIN_SECTORS => cd_datain_sectors,
		-- MUST be wired as on the board: the port default (all ones) disables back-pressure
		-- in simulation only, which once manufactured a fake stall.
		FIFO_SPACE => fifo_space
	);

	arb_inst : entity work.portc_arbiter
	port map (
		clk_pce => clk,
		cd_ram_a => (others => '0'), cd_ram_do => (others => '0'), cd_ram_rd => '0', cd_ram_wr => '0',
		cd_ram_di => open, cd_ram_rdy => open,
		adpcm_ram_a => a_a, adpcm_ram_do => a_do, adpcm_ram_we => a_we, adpcm_ram_req => a_req,
		adpcm_ram_slot_cnt => a_slot, adpcm_ram_di => a_di, adpcm_ram_ready => a_rdy,
		ram_c_addr => c_addr, ram_c_req => c_req, ram_c_rd_n => c_rd_n, ram_c_di => c_di,
		ram_c_do => c_do, ram_c_wait => c_wait
	);

	-- SDRAM port C model: ADPCM window only, one nibble per SDRAM byte. RD_n='1' means WRITE
	-- (sdram.sv's own convention, `we <= RAM_C_RD_n`).
	sdram_c : process (clk)
		variable n    : integer := 0;
		variable busy : boolean := false;
		variable rq_r : std_logic := '0';
		variable ad   : integer;
	begin
		if rising_edge(clk) then
			if not busy and c_req = '1' and rq_r = '0' then busy := true; n := 0; end if;
			if busy then
				n := n + 1;
				if n = 2 then
					c_wait <= '1';
				elsif n = 6 then
					ad := to_integer(unsigned(c_addr)) - 16#080000#;
					if c_rd_n = '1' then
						if ad >= 0 and ad < 2**17 then
							mem(ad) := to_integer(unsigned(c_di(3 downto 0)));
							nibble_writes <= nibble_writes + 1;
						end if;
					else
						if ad >= 0 and ad < 2**17 and mem(ad) >= 0 then
							c_do <= std_logic_vector(to_unsigned(mem(ad), 8));
						end if;
					end if;
					c_wait <= '0'; busy := false;
				end if;
			end if;
			rq_r := c_req;
		end if;
	end process;

	req_latch : process (clk)
	begin
		if rising_edge(clk) then
			if sector_req = '1' then
				req_pending <= req_pending + 1;
				req_lba     <= to_integer(unsigned(sector_lba));
			elsif req_taken = '1' and req_pending > 0 then
				req_pending <= req_pending - 1;
			end if;
		end if;
	end process;

	mcu : process
		variable s : integer;
	begin
		sector_data_valid <= '0'; sector_data_last <= '0';
		wait until rst_n = '1';
		loop
			while req_pending = 0 loop wait until rising_edge(clk); end loop;
			s := req_lba - LBA0;
			req_taken <= '1';
			wait until rising_edge(clk);
			req_taken <= '0';
			wait for SECTOR_LAT_US * 1 us;
			for i in 0 to 2047 loop
				for c in 1 to FEED_CYCLES loop wait until rising_edge(clk); end loop;
				if s >= 0 and s < 32 then
					sector_data <= std_logic_vector(to_unsigned(sect_bytes(s * 2048 + i), 8));
				else
					sector_data <= x"EE";   -- a sector the golden case never asked for
				end if;
				sector_data_valid <= '1';
				if i = 2047 then sector_data_last <= '1'; end if;
				wait until rising_edge(clk);
				sector_data_valid <= '0'; sector_data_last <= '0';
			end loop;
		end loop;
	end process;

	cpu : process
		file f     : text;
		variable l : line;
		variable b8 : std_logic_vector(7 downto 0);
		variable a16: std_logic_vector(15 downto 0);
		variable good : boolean;
		variable k, ok, bad, never, first_bad : integer;
		variable v  : std_logic_vector(7 downto 0);
		variable g  : integer;

		procedure tick(n : integer) is
		begin
			for i in 1 to n loop wait until rising_edge(clk); end loop;
		end procedure;
		procedure wr_reg(r : integer; val : std_logic_vector(7 downto 0)) is
		begin
			ext_a <= reg_addr(r); ext_di <= val; ext_wr_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			wait until rising_edge(clk);
			ext_wr_n <= '1';
			tick(40);
		end procedure;
		procedure rd_reg(r : integer; res : out std_logic_vector(7 downto 0)) is
		begin
			ext_a <= reg_addr(r); ext_rd_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			res := ext_do;
			wait until rising_edge(clk);
			ext_rd_n <= '1';
			tick(40);
		end procedure;
		procedure wait_phase(want : std_logic_vector(7 downto 0); what : string) is
			variable pv : std_logic_vector(7 downto 0);
			variable pg : integer := 0;
		begin
			loop
				rd_reg(0, pv);
				last_1800 <= pv;
				exit when pv = want;
				pg := pg + 1;
				assert pg < 3_000_000
					report "TIMEOUT waiting for " & what & " last $1800="
					     & integer'image(to_integer(unsigned(pv))) severity failure;
			end loop;
		end procedure;
		procedure ack_pulse is
			variable av : std_logic_vector(7 downto 0);
		begin
			rd_reg(2, av); wr_reg(2, x"80"); rd_reg(2, av); wr_reg(2, x"00");
		end procedure;
	begin
		-- golden data
		file_open(f, DIR & "/sectors.hex", read_mode);
		k := 0;
		while not endfile(f) and k < 65536 loop
			readline(f, l); hread(l, b8, good);
			if good then sect_bytes(k) := to_integer(unsigned(b8)); k := k + 1; end if;
		end loop;
		file_close(f);
		file_open(f, DIR & "/dma_writes.hex", read_mode);
		k := 0;
		while not endfile(f) and k < 65536 loop
			readline(f, l); hread(l, a16, good); hread(l, b8, good);
			if good then
				gold_addr(k) := to_integer(unsigned(a16)) mod 256;   -- only used as a sequence check
				gold_val(k)  := to_integer(unsigned(b8));
				k := k + 1;
			end if;
		end loop;
		file_close(f);

		rst_n <= '0'; tick(20); rst_n <= '1'; tick(20);
		disc_mounted <= '1';
		toc_track <= x"01"; toc_control <= x"04"; toc_lba <= x"000000";
		toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(2);
		toc_track <= x"64"; toc_control <= x"00"; toc_lba <= x"010000";
		toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(4);

		-- the game's ADPCM write-address setup, verbatim from the trace
		wr_reg(16#D#, x"00"); wr_reg(16#8#, x"00"); wr_reg(16#9#, x"00");
		wr_reg(16#D#, x"03"); wr_reg(16#D#, x"02"); wr_reg(16#D#, x"00");

		-- READ(6) LBA 4127 (0x00101F), SECTORS sectors -- the game asks for 32
		wr_reg(1, x"81");
		wr_reg(0, x"81");
		for b in 0 to 5 loop
			wait_phase(x"d0", "COMMAND REQ byte " & integer'image(b));
			case b is
				when 0 => v := x"08";
				when 1 => v := x"00";
				when 2 => v := x"10";
				when 3 => v := x"1F";
				when 4 => v := std_logic_vector(to_unsigned(SECTORS, 8));
				when others => v := x"00";
			end case;
			wr_reg(1, v);
			ack_pulse;
		end loop;

		cpu_step <= 1;   -- CDB sent
		-- DMA on: cd.vhd consumes DATA IN itself; the CPU only watches for STATUS
		wr_reg(16#B#, x"02");
		cpu_step <= 2;   -- DMA enabled
		wait_phase(x"d8", "STATUS after DMA load");
		wr_reg(16#B#, x"00");
		rd_reg(1, v);
		assert v = x"00" report "STATUS not GOOD" severity error;
		ack_pulse;
		wait_phase(x"f8", "MESSAGE IN");
		rd_reg(1, v);
		ack_pulse;
		wait_phase(x"00", "BUS FREE");
		tick(20000);

		-- compare ADPCM RAM (nibbles) with beetle's writes for the same bytes
		ok := 0; bad := 0; never := 0; first_bad := -1;
		for i in 0 to SECTORS * 2048 - 1 loop
			if mem(2*i) < 0 or mem(2*i + 1) < 0 then
				never := never + 1;
				if first_bad < 0 then first_bad := i; end if;
			elsif mem(2*i) * 16 + mem(2*i + 1) = gold_val(i) then
				ok := ok + 1;
			else
				bad := bad + 1;
				if first_bad < 0 then first_bad := i; end if;
			end if;
		end loop;
		-- anything written past the requested bytes would be a duplicated or stray write
		g := 0;
		for i in SECTORS * 2048 to 2**16 - 1 loop
			if mem(2*i) >= 0 or mem(2*i + 1) >= 0 then g := g + 1; end if;
		end loop;
		write(l, string'("RESULT sectors=")); write(l, SECTORS);
		write(l, string'(" bytes=")); write(l, SECTORS * 2048);
		write(l, string'(" ok=")); write(l, ok);
		write(l, string'(" wrong=")); write(l, bad);
		write(l, string'(" never_written=")); write(l, never);
		write(l, string'(" first_bad_byte=")); write(l, first_bad);
		write(l, string'(" stray_bytes_past_end=")); write(l, g);
		write(l, string'(" nibble_writes=")); write(l, nibble_writes);
		writeline(output, l);
		if ok = SECTORS * 2048 and g = 0 then
			write(l, string'("PASS: DMA load matches beetle byte for byte"));
		else
			write(l, string'("FAIL"));
		end if;
		writeline(output, l);
		running <= false;
		wait;
	end process;
	-- heartbeat: DMA progress and what the SCSI side is doing, every 20 ms of sim time
	heartbeat : process
		variable l : line;
	begin
		loop
			wait for 20 ms;
			exit when not running;
			write(l, string'("HB t=")); write(l, now / 1 ms); write(l, string'("ms"));
			write(l, string'(" nibble_writes=")); write(l, nibble_writes);
			write(l, string'(" sector_req_pending=")); write(l, req_pending);
			write(l, string'(" bridge_state=")); write(l, to_integer(unsigned(dbg_state)));
			write(l, string'(" fifo_space=")); write(l, to_integer(fifo_space));
			write(l, string'(" a_req=")); write(l, a_req);
			write(l, string'(" a_slot=")); write(l, to_integer(unsigned(a_slot)));
			write(l, string'(" scsi_sp=")); write(l, to_integer(unsigned(dbg_sp)));
			write(l, string'(" last_1800=0x")); hwrite(l, last_1800);
			write(l, string'(" cpu_step=")); write(l, cpu_step);
			writeline(output, l);
		end loop;
		wait;
	end process;
end architecture;
