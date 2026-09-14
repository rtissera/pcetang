-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- END-OF-COMMAND phase walk, driven through cd.vhd's REGISTER interface.
--
-- This is tb_cd_endcmd.vhd's more faithful sibling. That one drives the SCSI bus signals
-- directly, which skips cd.vhd entirely -- and cd.vhd is where AUTO_ACK, the CD_DTR /
-- CD_DTD status flags and the "any write to $1800 asserts SEL" phantom-selection
-- behaviour all live. It is also more permissive than the real machine in one way that
-- matters: it drains DATA IN "until the phase changes", whereas the system card reads
-- EXACTLY 2048 bytes per sector and then polls. A target offering the wrong number of
-- bytes would desync the real CPU and pass that test.
--
-- So this testbench models the CPU the way an instrumented mednafen boot of Rondo shows
-- the system card really behaving, register access by register access:
--
--   SELECT      W $1801 = 0x81 (target id on the data bus), then W $1800 (asserts SEL)
--   per CDB byte    poll $1800 until 0xd0 (BSY|REQ|CD = COMMAND, byte requested)
--                   W $1801 = byte
--                   W $1802 = 0x80   -- ACK, bit 7
--                   poll $1800 until 0x90 (REQ dropped)
--                   W $1802 = 0x00   -- release ACK
--   DATA IN     poll $1800 until 0xc8 (BSY|REQ|IO), read $1808 (AUTO_ACK does the
--               handshake), exactly 2048 times per sector
--   END         0xd8 STATUS + REQ -> read $1801 (status, expect 00 GOOD) -> ACK pulse
--               0xf8 MESSAGE IN + REQ -> read $1801 (message, expect 00) -> ACK pulse
--               0x00 BUS FREE
--
-- A hang anywhere in that walk is the hardware symptom: the system card waits, times
-- out, resets the SCSI bus and returns to "push run".
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cd_regwalk is
	generic (
		-- Number of commands from the golden Rondo boot to replay, in order. The board
		-- completes 12 and stops, so a single-command test cannot see whatever accumulates
		-- across them (FIFO residue, DATAIN_CNT, STAT_PEND). 0 = use SECTORS as a single
		-- READ(6), which is the original single-command behaviour.
		COMMANDS      : integer := 0;
		SECTORS       : integer := 8;
		SECTOR_LAT_US : integer := 10000;
		FEED_CYCLES   : integer := 214;
		CPU_CYCLES    : integer := 43;
		HUNK_EVERY    : integer := 0;
		HUNK_EXTRA_US : integer := 0;
		-- VBlank interruption. On real hardware IRQ1 fires every ~16.7 ms while a single
		-- sector takes ~10 ms to arrive over the 2 Mbaud link, so the system card's read
		-- loop IS interrupted mid-DATA-IN, repeatedly, and the target sits with REQ
		-- asserted and no ACK for the duration of the ISR. An initiator that polls without
		-- ever being interrupted -- which is every testbench here until now -- cannot see
		-- a target that mishandles that pause. 0 = no interruption.
		VBLANK_EVERY_US : integer := 0;
		VBLANK_LEN_US   : integer := 0
	);
end entity;

architecture sim of tb_cd_regwalk is
	constant CLK_PERIOD : time := 23.3 ns;

	signal clk     : std_logic := '0';
	signal rst_n   : std_logic := '0';
	signal done    : boolean   := false;

	signal ext_a   : std_logic_vector(20 downto 0) := (others => '0');
	signal ext_di  : std_logic_vector(7 downto 0)  := (others => '0');
	signal ext_do  : std_logic_vector(7 downto 0);
	signal ext_wr_n, ext_rd_n : std_logic := '1';
	signal cpu_ce  : std_logic := '0';

	signal cd_stat, cd_msg : std_logic_vector(7 downto 0);
	signal cd_stat_get     : std_logic;
	signal cd_comm         : std_logic_vector(95 downto 0);
	signal cd_comm_send    : std_logic;
	signal cd_data         : std_logic_vector(7 downto 0);
	signal cd_data_wr      : std_logic;
	signal cd_data_end     : std_logic;
	signal cd_dout_req     : std_logic := '0';
	signal cd_dout         : std_logic_vector(79 downto 0);
	signal cd_dout_send    : std_logic;
	signal cd_audio_wr, cd_dm : std_logic;

	signal sector_req        : std_logic;
	signal sector_lba        : std_logic_vector(23 downto 0);
	signal sector_data       : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_data_valid : std_logic := '0';
	signal sector_data_last  : std_logic := '0';
	signal sector_is_audio   : std_logic;
	-- SECTOR_REQ latch (see the mcu process): pulses counted, never polled for.
	signal req_pending : integer := 0;
	signal req_lba     : integer := 0;
	signal req_taken   : std_logic := '0';

	signal toc_wr      : std_logic := '0';
	signal toc_track   : std_logic_vector(7 downto 0)  := (others => '0');
	signal toc_control : std_logic_vector(7 downto 0)  := (others => '0');
	signal toc_lba     : std_logic_vector(23 downto 0) := (others => '0');
	signal disc_mounted : std_logic := '0';

	signal dbg_state : std_logic_vector(4 downto 0);
	signal dbg_dend  : std_logic_vector(31 downto 0);
	signal cd_datain_sectors : unsigned(8 downto 0);
	signal sel_n_o, irq_n_o, ram_cs_n_o, bram_en_o, cd_reset_o : std_logic;
	signal dbg_datain_cnt : unsigned(15 downto 0);
	signal dbg_first8 : std_logic_vector(63 downto 0);
	signal dbg_sp : std_logic_vector(3 downto 0);
	signal dbg_adpcm : std_logic_vector(2 downto 0);
	signal dbg_comm_pos : unsigned(3 downto 0);
	signal dbg_comm0, dbg_comm1 : std_logic_vector(7 downto 0);
	signal dbg_sel_cnt : unsigned(15 downto 0);
	signal dbg_fifo_space : unsigned(12 downto 0);
	signal dbg_fifo_drops : unsigned(15 downto 0);
	signal dbg_gdi : std_logic_vector(127 downto 0);
	signal dbg_rd_total, dbg_underruns : unsigned(15 downto 0);
	signal cd_sl, cd_sr, ad_s : signed(15 downto 0);

	signal bytes_read : integer := 0;
	signal vbl_count  : integer := 0;
	signal polls      : integer := 0;

	-- Golden Rondo boot, commands 1..13, exactly as an instrumented beetle-pce-fast run
	-- dispatches them (all from the system card ROM, PC $E95E-$EA3A, bank 00).
	-- 10 bytes wide, because CDB LENGTH DEPENDS ON THE OPCODE GROUP. SCSI takes it from
	-- the top nibble: 0x08 >> 4 = 0 -> 6 bytes, 0xDE >> 4 = 0xD -> 10 bytes. The reference
	-- shows both plainly -- "08 00 0f 32 02 00" is six, "de 00 ca 00 00 00 00 00 00 00" is
	-- ten. Sending six for everything leaves the target still in COMMAND phase asking for
	-- more ($1800 reads 0xd0 forever), which is exactly how the first version of this
	-- table hung on command 2.
	type cdb_t is array (0 to 12) of std_logic_vector(79 downto 0);
	constant GOLDEN : cdb_t := (
		x"00000000000000000000",    --  1  TEST UNIT READY              (6)
		x"de00ca00000000000000",    --  2  GETDIRINFO mode 0            (10)
		x"de01ca00000000000000",    --  3  GETDIRINFO mode 1 (lead-out) (10)
		x"de020100000000000000",    --  4  GETDIRINFO mode 2 track 1    (10)
		x"de020200000000000000",    --  5  GETDIRINFO mode 2 track 2    (10)
		x"08000f3202000000_0000",   --  6  READ(6) LBA 3890 x2 (boot header)
		x"08000f3401000000_0000",   --  7  READ(6) LBA 3892 x1
		x"de020200000000000000",    --  8  GETDIRINFO mode 2 track 2 again (reference does this)
		x"de022200000000000000",    --  9  GETDIRINFO mode 2 track 0x22 (last track)
		x"08000f750a000000_0000",   -- 10  READ(6) LBA 3957 x10
		x"08000f7f0c000000_0000",   -- 11  READ(6) LBA 3967 x12
		x"08000f8b08000000_0000",   -- 12  READ(6) LBA 3979 x8  <-- board completes, then stops
		x"08000ff308000000_0000"    -- 13  READ(6) LBA 4083 x8  <-- board never issues this
	);

	-- Same rule SCSI.vhd's RequiredCDBLen uses: length from the opcode's top nibble.
	function cdb_len(cdb : std_logic_vector(79 downto 0)) return integer is
	begin
		case cdb(79 downto 76) is
			when x"0"   => return 6;
			when x"d"   => return 10;
			when others => return 6;
		end case;
	end function;

	function sectors_of(cdb : std_logic_vector(79 downto 0)) return integer is
	begin
		if cdb(79 downto 72) = x"08" then
			return to_integer(unsigned(cdb(47 downto 40)));
		else
			return 0;    -- not a READ(6); reply is short and ends on FIFO empty
		end if;
	end function;

	function reg_addr(r : integer) return std_logic_vector is
	begin
		-- REG_SEL is EXT_A(20..13)=0xFF and EXT_A(12..8)="11000"; low byte is the register
		return x"FF" & "11000" & std_logic_vector(to_unsigned(r, 8));
	end function;
begin
	clk <= not clk after CLK_PERIOD/2 when not done else '0';

	-- CPU_CE at roughly the HuC6280's rate relative to this 42.9 MHz clock.
	ce_gen : process(clk)
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
		SEL_N => sel_n_o, IRQ_N => irq_n_o,
		RAM_CS_N => ram_cs_n_o, BRAM_EN => bram_en_o,
		CD_STAT => cd_stat, CD_MSG => cd_msg, CD_STAT_GET => cd_stat_get,
		CD_COMM => cd_comm, CD_COMM_SEND => cd_comm_send,
		CD_DOUT_REQ => cd_dout_req, CD_DOUT => cd_dout, CD_DOUT_SEND => cd_dout_send,
		CD_REGION => '0', CD_RESET => cd_reset_o,
		CD_DATA => cd_data, CD_DATA_WR => cd_data_wr,
		CD_AUDIO_WR => cd_audio_wr, CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end,
		CD_DATAIN_SECTORS => cd_datain_sectors,
		DBG_DATAIN_CNT => dbg_datain_cnt, DBG_FIRST8 => dbg_first8, DBG_SP => dbg_sp,
		DBG_ADPCM => dbg_adpcm, DBG_COMM_POS => dbg_comm_pos,
		DBG_COMM0 => dbg_comm0, DBG_COMM1 => dbg_comm1, DBG_SEL_CNT => dbg_sel_cnt,
		DBG_FIFO_SPACE => dbg_fifo_space, DBG_FIFO_DROPS => dbg_fifo_drops,
		DBG_GDI => dbg_gdi, DBG_RD_TOTAL => dbg_rd_total, DBG_UNDERRUNS => dbg_underruns,
		DM => cd_dm, CD_SL => cd_sl, CD_SR => cd_sr, AD_S => ad_s
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
		DATAIN_SECTORS => cd_datain_sectors
	);

	-- Request latch: counts SECTOR_REQ pulses so none can be missed, and holds the LBA
	-- that came with the most recent one.
	req_latch : process(clk)
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
		variable sect  : integer := 0;
		variable nsect : integer := 0;
	begin
		sector_data_valid <= '0'; sector_data_last <= '0';
		wait until rst_n = '1';
		loop
			-- LATCH the request, do not poll for it. SECTOR_REQ is a ONE-CYCLE PULSE and
			-- cd_bridge issues the next one ~2 cycles after the previous sector's last
			-- byte -- while this process is still returning from its feed loop. A model
			-- that only listens at a `wait until sector_req='1'` statement MISSES it, and
			-- cd_bridge then sits in SCSI_READ_WAIT_BYTE forever. That looks exactly like
			-- an RTL hang and is not one; the real firmware queues requests. Cost one
			-- false "reproduced hang" on 2026-09-14.
			while req_pending = 0 loop wait until rising_edge(clk); end loop;
			sect := req_lba;
			req_taken <= '1';
			wait until rising_edge(clk);
			req_taken <= '0';
			nsect := nsect + 1;
			if HUNK_EVERY > 0 and (nsect mod HUNK_EVERY) = 0 then
				wait for (SECTOR_LAT_US + HUNK_EXTRA_US) * 1 us;
			else
				wait for SECTOR_LAT_US * 1 us;
			end if;
			for i in 0 to 2047 loop
				for c in 1 to FEED_CYCLES loop wait until rising_edge(clk); end loop;
				sector_data <= std_logic_vector(to_unsigned((sect + i) mod 256, 8));
				sector_data_valid <= '1';
				if i = 2047 then sector_data_last <= '1'; end if;
				wait until rising_edge(clk);
				sector_data_valid <= '0'; sector_data_last <= '0';
			end loop;
		end loop;
	end process;

	cpu : process
		procedure tick(n : integer) is
		begin
			for i in 1 to n loop wait until rising_edge(clk); end loop;
		end procedure;

		-- cd.vhd samples EXT_WR_N/EXT_RD_N ON the CPU_CE edge (it clears SCSI_SEL_N at
		-- the top of `if CPU_CE = '1'` and re-asserts it inside the same block), so the
		-- strobe must ALREADY be low when that edge arrives. Driving it after the edge
		-- makes every access invisible -- which is exactly how the first version of this
		-- testbench failed: SELECT never took and $1800 stayed at 0x00 forever.
		procedure wr_reg(r : integer; v : std_logic_vector(7 downto 0)) is
		begin
			ext_a <= reg_addr(r); ext_di <= v; ext_wr_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			wait until rising_edge(clk);
			ext_wr_n <= '1';
			tick(2);
		end procedure;

		procedure rd_reg(r : integer; res : out std_logic_vector(7 downto 0)) is
		begin
			ext_a <= reg_addr(r); ext_rd_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			res := ext_do;            -- EXT_DO is combinational from REG_SEL/EXT_A
			wait until rising_edge(clk);
			ext_rd_n <= '1';
			tick(2);
		end procedure;

		-- poll $1800 until it matches, exactly as the system card busy-waits
		procedure wait_phase(want : std_logic_vector(7 downto 0); what : string) is
			variable v : std_logic_vector(7 downto 0);
			variable g : integer := 0;
		begin
			loop
				rd_reg(0, v);
				polls <= polls + 1;
				exit when v = want;
				g := g + 1;
				-- 20M polls ~= 2.8 s of simulated time. The old 2M bound was ~280 ms, which
				-- is SHORTER than some modelled MCU delays -- a 400 ms hunk stall tripped
				-- the guard and looked exactly like an RTL hang. A guard must outlast every
				-- delay the testbench itself injects.
				assert g < 20_000_000
					report "TIMEOUT waiting for " & what & " (want "
					     & integer'image(to_integer(unsigned(want))) & ", last saw "
					     & integer'image(to_integer(unsigned(v))) & ", bridge_state="
					     & integer'image(to_integer(unsigned(dbg_state)))
					     & ", dend_consumed="
					     & integer'image(to_integer(unsigned(dbg_dend(31 downto 16))))
					     & ", dend_LOST="
					     & integer'image(to_integer(unsigned(dbg_dend(15 downto 0))))
					severity failure;
			end loop;
		end procedure;

		procedure ack_pulse is
			variable v : std_logic_vector(7 downto 0);
		begin
			rd_reg(2, v);
			wr_reg(2, x"80");
			rd_reg(2, v);
			wr_reg(2, x"00");
		end procedure;

		variable v    : std_logic_vector(7 downto 0);
		variable cdb  : std_logic_vector(79 downto 0);
		variable nlen : integer := 6;
		variable nsec : integer := 0;
		variable gshort : integer := 0;
		variable last_vbl : time := 0 ns;
		variable ncmd : integer := 1;
	begin
		if COMMANDS > 0 then ncmd := COMMANDS; end if;
		wait until rst_n = '1';
		tick(20);

		disc_mounted <= '1';
		toc_track <= x"01"; toc_control <= x"00"; toc_lba <= x"000000";
		toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(2);
		toc_track <= x"64"; toc_control <= x"00"; toc_lba <= x"010000";
		toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(4);

		for c in 0 to ncmd - 1 loop
			if COMMANDS = 0 then
				cdb := x"08" & x"00" & x"10" & x"00"
				     & std_logic_vector(to_unsigned(SECTORS, 8)) & x"00" & x"00000000";
				nsec := SECTORS;
			else
				cdb  := GOLDEN(c);
				nsec := sectors_of(cdb);
			end if;
			nlen := cdb_len(cdb);

			-- SELECT: target id on the data bus, then any write to $1800 asserts SEL
			wr_reg(1, x"81");
			wr_reg(0, x"00");

			for b in 0 to nlen - 1 loop
				wait_phase(x"d0", "cmd " & integer'image(c + 1) & " COMMAND REQ byte "
				                  & integer'image(b));
				wr_reg(1, cdb(79 - b*8 downto 72 - b*8));
				ack_pulse;
			end loop;

			if nsec > 0 then
				-- READ(6): exactly 2048 bytes per sector, like the real system card
				for s in 1 to nsec loop
					for i in 1 to 2048 loop
						wait_phase(x"c8", "cmd " & integer'image(c + 1) & " DATA IN sector "
						                  & integer'image(s) & " byte " & integer'image(i));
						rd_reg(8, v);            -- $1808; cd.vhd AUTO_ACKs this read
						bytes_read <= bytes_read + 1;
						tick(CPU_CYCLES);
						-- VBlank: stop servicing the bus entirely for the ISR duration,
						-- leaving the target mid-burst with REQ up and no ACK coming.
						if VBLANK_EVERY_US > 0 then
							if now - last_vbl >= VBLANK_EVERY_US * 1 us then
								last_vbl := now;
								vbl_count <= vbl_count + 1;
								wait for VBLANK_LEN_US * 1 us;
							end if;
						end if;
					end loop;
				end loop;
			else
				-- short reply (GETDIRINFO / TEST UNIT READY): drain until the target
				-- leaves DATA IN, since the length is not known to the initiator up front
				-- GUARDED. Every other wait in this testbench has a bound; this one did
				-- not, and a short reply that never reaches STATUS spins here forever with
				-- no diagnostic -- which is indistinguishable from "the sim is just slow".
				gshort := 0;
				loop
					rd_reg(0, v);
					exit when v = x"d8";                       -- STATUS reached
					if v = x"c8" then
						rd_reg(8, v);
						bytes_read <= bytes_read + 1;
					end if;
					gshort := gshort + 1;
					assert gshort < 400_000
						report "TIMEOUT draining short reply for cmd "
						     & integer'image(c + 1) & " (last $1800 = "
						     & integer'image(to_integer(unsigned(v)))
						     & ", bytes so far " & integer'image(bytes_read)
						     & ", bridge_state="
						     & integer'image(to_integer(unsigned(dbg_state))) & ")"
						severity failure;
				end loop;
			end if;

			-- STATUS -> MESSAGE IN -> BUS FREE, every command, every time
			wait_phase(x"d8", "cmd " & integer'image(c + 1) & " STATUS + REQ");
			rd_reg(1, v);
			assert v = x"00"
				report "cmd " & integer'image(c + 1) & " STATUS not GOOD" severity error;
			ack_pulse;
			wait_phase(x"f8", "cmd " & integer'image(c + 1) & " MESSAGE IN + REQ");
			rd_reg(1, v);
			ack_pulse;
			wait_phase(x"00", "cmd " & integer'image(c + 1) & " BUS FREE");
			report "cmd " & integer'image(c + 1) & " OK, bytes so far="
			     & integer'image(bytes_read)
			     & " dend_consumed="
			     & integer'image(to_integer(unsigned(dbg_dend(31 downto 16))))
			     & " dend_LOST="
			     & integer'image(to_integer(unsigned(dbg_dend(15 downto 0))));
		end loop;

		report "RESULT SECTORS=" & integer'image(SECTORS)
		     & " bytes_read=" & integer'image(bytes_read)
		     & " polls=" & integer'image(polls)
		     & " dend_consumed=" & integer'image(to_integer(unsigned(dbg_dend(31 downto 16))))
		     & " dend_LOST=" & integer'image(to_integer(unsigned(dbg_dend(15 downto 0))))
		     & " underruns=" & integer'image(to_integer(dbg_underruns))
		     & " vblanks=" & integer'image(vbl_count);
		if COMMANDS = 0 then
			assert bytes_read = SECTORS * 2048 report "WRONG BYTE COUNT" severity error;
		end if;
		report "PASS: register-level end-of-command walk completed";
		done <= true;
		wait;
	end process;

	rst : process
	begin
		rst_n <= '0'; wait for 2 us; rst_n <= '1'; wait;
	end process;
end architecture;
