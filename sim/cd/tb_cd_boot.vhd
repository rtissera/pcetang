-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Real-ROM boot testbench for pce_top, built to answer ONE question that several rounds
-- of on-hardware probing could not: when a plain HuCard is loaded on Console 60K, does
-- the HuC6280 ever get as far as programming the VDC, and if not, where does it stop?
--
-- Mirrors src/pcetang_console60k_cd.vhd's own instantiation exactly -- same generics
-- (LITE=0, EXT_VRAM0=0, NO_CD=0, everything else default), same SGX/AC_EN/BG_EN/SPR_EN
-- port values, same 42.857 MHz clk_pce -- with two deliberate differences, both stated
-- here so no result gets over-read:
--
--   1. CD_EN is '0' (the board now drives cd_mounted_i, which is 0 for a .pce).
--   2. The ROM is an IDEAL zero-wait memory (ROM_RDY tied '1'), not the board's SDRAM
--      bridge. So this run says nothing at all about the SDRAM ROM path -- that is the
--      point: it splits "core never programs the VDC" from "SDRAM bridge starves it".
--
-- See sim_stubs.vhd for the four stubbed-out modules and the same caveat about what a
-- passing run does and does not prove.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cd_boot is
	generic (
		ROM_FILE   : string  := "rom.bin";
		-- pce_top's ROM_SZ bucket. X"080" = 512K, matching a 524288-byte HuCard --
		-- the same value the board's own rom_sz_r traced as on real hardware.
		ROM_SZ_G   : std_logic_vector(11 downto 0) := X"080";
		SGX_G      : std_logic := '1';
		CD_EN_G    : std_logic := '0';
		-- Simulated wall-clock to run for, in microseconds. One PCE frame is ~16.7 ms.
		RUN_US     : integer := 120000;
		-- Print every VDC/VCE register write (verbose) or just the summary.
		VERBOSE    : integer := 1;
		-- Dump the first N raw CPU bus cycles (every CPU_CE with RD or WR active).
		TRACE_N    : integer := 0;
		-- Skip this many CPU bus cycles before TRACE_N starts printing.
		TRACE_SKIP : integer := 0;
		-- Start dumping raw CPU bus cycles once this many VDC0 writes have happened.
		DUMP_AFTER_VDC : integer := 0;
		AC_BUILD_G : integer := 1;
		NO_CD_G : integer := 0;
		-- ROM read latency in clk_pce cycles. 0 = ideal zero-wait memory (ROM_RDY tied
		-- '1'). Nonzero mimics the SHAPE of pcetang_console60k_cd.vhd's read bridge:
		-- ROM_RDY drops while ROM_RD is asserted, the data is registered, and ROM_RDY
		-- rises ROM_LAT cycles later. This does NOT model sdram.sv -- it only tests
		-- whether the handshake protocol itself can stall the HuC6280, independently of
		-- whether the returned data is correct.
		ROM_LAT    : integer := 0;
		-- Flat sector slice produced by scripts/cd_slice.py from a chdman-extracted .bin:
		-- one line per sector, 4096 hex chars of USER data (2048 bytes, Mode 1 offset 16).
		SECTOR_FILE : string := "de2_sectors.hex";
		SECTOR_BASE : integer := 3584;
		SECTOR_CNT  : integer := 160;
		-- TOC the bridge is told about, matching the real disc (Dungeon Explorer II):
		-- track 1 audio at LBA 0, track 2 DATA at 3590, lead-out at 316011.
		TOC_T2_LBA  : integer := 3590;
		TOC_LEADOUT : integer := 316011;
		-- The system card sits in a "PUSH RUN BUTTON" loop until a pad reports RUN, so a
		-- CD boot simulation that never presses it observes nothing at all -- the first
		-- run of this testbench sat in that loop for its entire duration (CPU pinned at
		-- $03C2/$03C6, zero SCSI commands).
		RUN_PRESS_US : integer := 30000;
		-- clk_pce cycles between served bytes. 214 is the real 2Mbaud UART pace (a sector
		-- then takes ~10ms of simulated time); lower it when the question under test is
		-- not the pacing itself, to finish a run in minutes rather than an hour.
		SECTOR_BYTE_CYCLES : integer := 214
	);
end entity;

architecture sim of tb_cd_boot is

	constant CLK_PERIOD : time := 23.333 ns;   -- 42.857 MHz clk_pce

	signal clk       : std_logic := '0';
	signal reset     : std_logic := '1';
	signal running   : boolean   := true;

	-- pce_top ROM interface
	signal rom_rd    : std_logic;
	signal rom_a     : std_logic_vector(21 downto 0);
	signal rom_do    : std_logic_vector(7 downto 0) := (others => '1');
	signal rom_q     : std_logic_vector(7 downto 0) := (others => '1');
	signal rom_rdy   : std_logic := '1';

	-- Board-side ports that pcetang_console60k_cd.vhd routes to the shared port-C
	-- arbiter (which drives cd_ram_rdy_i, the OTHER term of pce_top's WAIT_N). Probed
	-- here rather than left open: if the CD/ADPCM side requests DRAM during a plain
	-- HuCard boot, that arbiter can stall the CPU exactly the way ROM_RDY can.
	signal cd_ram_rd_s, cd_ram_wr_s : std_logic;
	signal adpcm_req_s              : std_logic;
	signal adpcm_we_s               : std_logic;

	signal dbg_cpu_a_s  : std_logic_vector(20 downto 0);
	signal dbg_vdc_wr_s : std_logic;

	-- video
	signal video_vs, video_hs, video_vbl, video_hbl, video_ce : std_logic;
	signal video_r, video_g, video_b : std_logic_vector(2 downto 0);

	signal brm_a  : std_logic_vector(10 downto 0);
	signal brm_di : std_logic_vector(7 downto 0);
	signal brm_we : std_logic;

	signal joy_out : std_logic_vector(1 downto 0);

	signal cdda_sl, cdda_sr, adpcm_s, psg_sl, psg_sr : signed(15 downto 0);

	-- ROM image
	constant ROM_WORDS : integer := 2**22;
	type rom_t is array (0 to ROM_WORDS-1) of std_logic_vector(7 downto 0);

	type charfile is file of character;

	impure function load_rom(fn : string) return rom_t is
		file     f   : charfile;
		variable st  : file_open_status;
		variable c   : character;
		variable m   : rom_t := (others => x"FF");
		variable i   : integer := 0;
		variable l   : line;
	begin
		file_open(st, f, fn, read_mode);
		if st /= open_ok then
			write(l, string'("FATAL: cannot open ROM file "));
			write(l, fn);
			writeline(output, l);
			return m;
		end if;
		while not endfile(f) and i < ROM_WORDS loop
			read(f, c);
			m(i) := std_logic_vector(to_unsigned(character'pos(c), 8));
			i := i + 1;
		end loop;
		file_close(f);
		write(l, string'("ROM loaded: "));
		write(l, fn);
		write(l, string'("  bytes="));
		write(l, i);
		writeline(output, l);
		return m;
	end function;

	shared variable rom_img : rom_t := load_rom(ROM_FILE);

	-- ------------------------------------------------------------ CD plumbing
	-- Pad model. PCE pad nibbles are ACTIVE LOW: with SEL low the nibble reads
	-- (bit3=RUN, bit2=SELECT, bit1=II, bit0=I); with SEL high it is the d-pad.
	signal joy_in_s      : std_logic_vector(3 downto 0) := "1111";
	signal run_pressed   : std_logic := '0';

	signal cd_stat_s     : std_logic_vector(7 downto 0);
	signal cd_msg_s      : std_logic_vector(7 downto 0);
	signal cd_stat_get_s : std_logic;
	signal cd_comm_s     : std_logic_vector(95 downto 0);
	signal cd_comm_send_s: std_logic;
	signal cd_data_s     : std_logic_vector(7 downto 0);
	signal cd_data_wr_s  : std_logic;
	signal cd_audio_wr_s : std_logic;
	signal cd_dm_s       : std_logic;
	signal cd_data_end_s : std_logic;
	signal cd_reset_s    : std_logic;
	signal sector_req_s  : std_logic;
	signal sector_lba_s  : std_logic_vector(23 downto 0);
	signal sector_audio_s: std_logic;
	signal sector_data_s : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_dv_s   : std_logic := '0';
	signal sector_last_s : std_logic := '0';
	signal disc_mounted_s: std_logic := '0';
	signal toc_wr_s      : std_logic := '0';
	signal toc_track_s   : std_logic_vector(7 downto 0) := (others => '0');
	signal toc_ctl_s     : std_logic_vector(7 downto 0) := (others => '0');
	signal toc_lba_s     : std_logic_vector(23 downto 0) := (others => '0');

	-- CD-RAM model. The boot program is LOADED INTO THIS, so tying CD_RAM_DI to x"FF"
	-- (as the HuCard testbench does) would make any CD boot impossible by construction.
	type cdram_t is array (0 to 262143) of std_logic_vector(7 downto 0);
	shared variable cdram : cdram_t := (others => x"00");
	signal cd_ram_a_s    : std_logic_vector(21 downto 0);
	signal cd_ram_do_s   : std_logic_vector(7 downto 0);
	signal cd_ram_di_s   : std_logic_vector(7 downto 0) := x"00";

	-- Sector slice, read once at elaboration.
	type sec_t is array (0 to SECTOR_CNT*2048 - 1) of std_logic_vector(7 downto 0);
	impure function load_sectors(fn : string) return sec_t is
		file f      : text;
		variable st : file_open_status;
		variable ln : line;
		variable m  : sec_t := (others => x"00");
		variable idx, nsec : integer := 0;
		variable c  : character;
		variable nyb, hi : integer;
		variable l2 : line;
	begin
		file_open(st, f, fn, read_mode);
		if st /= open_ok then
			write(l2, string'("SECTOR FILE NOT FOUND: ")); write(l2, fn);
			writeline(output, l2);
			return m;
		end if;
		while not endfile(f) and nsec < SECTOR_CNT loop
			readline(f, ln);
			if ln'length >= 4096 then
				for b in 0 to 2047 loop
					hi := 0;
					for half in 0 to 1 loop
						c := ln.all(b*2 + half + 1);
						case c is
							when '0' to '9' => nyb := character'pos(c) - character'pos('0');
							when 'a' to 'f' => nyb := character'pos(c) - character'pos('a') + 10;
							when 'A' to 'F' => nyb := character'pos(c) - character'pos('A') + 10;
							when others     => nyb := 0;
						end case;
						if half = 0 then hi := nyb * 16; else hi := hi + nyb; end if;
					end loop;
					m(nsec*2048 + b) := std_logic_vector(to_unsigned(hi, 8));
				end loop;
				nsec := nsec + 1;
			end if;
		end loop;
		file_close(f);
		write(l2, string'("sectors loaded: ")); write(l2, nsec);
		write(l2, string'(" from ")); write(l2, fn);
		writeline(output, l2);
		return m;
	end function;
	shared variable sec_img : sec_t := load_sectors(SECTOR_FILE);

	-- ---------------------------------------------------------------- helpers
	function hex(v : std_logic_vector) return string is
		constant N : integer := (v'length + 3) / 4;
		variable p : std_logic_vector(N*4-1 downto 0) := (others => '0');
		variable s : string(1 to N);
		variable d : integer;
	begin
		p(v'length-1 downto 0) := v;
		for i in 0 to N-1 loop
			d := to_integer(unsigned(p(i*4+3 downto i*4)));
			if d < 10 then
				s(N-i) := character'val(character'pos('0') + d);
			else
				s(N-i) := character'val(character'pos('A') + d - 10);
			end if;
		end loop;
		return s;
	end function;

	function hex(v : integer; n : integer) return string is
		variable u : unsigned(31 downto 0) := to_unsigned(v, 32);
	begin
		return hex(std_logic_vector(u(n*4-1 downto 0)));
	end function;

begin

	-- ------------------------------------------------------------------ clock
	clk <= not clk after CLK_PERIOD/2 when running else '0';

	-- ------------------------------------------------------------------ reset
	-- Board holds core_resetn low well past PLL lock; 200 raw clocks is ample and the
	-- exact length is not load-bearing (HuC6280 latches its own reset internally).
	reset_proc : process
	begin
		reset <= '1';
		wait for CLK_PERIOD * 200;
		wait until rising_edge(clk);
		reset <= '0';
		wait;
	end process;

	-- -------------------------------------------------------------- ROM model
	rom_q <= rom_img(to_integer(unsigned(rom_a)));

	gen_rom_ideal : if ROM_LAT = 0 generate
		rom_do  <= rom_q;
		rom_rdy <= '1';
	end generate;

	-- Latency model. Mirrors the board bridge's own structure: ROM_RD is a LEVEL held
	-- for the whole CPU memory cycle, so the FSM must re-arm from idle (it will
	-- immediately restart while ROM_RD is still high, exactly as the board's RB_IDLE
	-- does) rather than edge-detect.
	gen_rom_lat : if ROM_LAT /= 0 generate
		process (clk)
			variable cnt   : integer := 0;
			variable busy  : boolean := false;
		begin
			if rising_edge(clk) then
				if reset = '1' then
					busy    := false;
					cnt     := 0;
					rom_rdy <= '1';
				elsif not busy then
					rom_rdy <= '1';
					if rom_rd = '1' then
						busy    := true;
						cnt     := ROM_LAT;
						rom_rdy <= '0';
					end if;
				else
					if cnt <= 1 then
						busy    := false;
						rom_do  <= rom_q;
						rom_rdy <= '1';
					else
						cnt := cnt - 1;
					end if;
				end if;
			end if;
		end process;
	end generate;

	-- ------------------------------------------------------------------- DUT
	dut : entity work.pce_top
	generic map (LITE => 0, EXT_VRAM0 => 0, NO_CD => NO_CD_G, AC_BUILD => AC_BUILD_G)
	port map (
		RESET      => reset,
		COLD_RESET => reset,
		CLK        => clk,

		VRAM0_RAM_A_ADDR => open, VRAM0_RAM_A_REQ => open, VRAM0_RAM_A_RD_N => open,
		VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0'),
		VRAM0_RAM_A_WAIT => '0',
		DBG_DEADLINE_MISS => open, DBG_FIFO_OVERFLOW => open,
		VRAM0_RAM_A_LINE_REFILL => open, VRAM0_RAM_A_LINE_DO => (others => '0'),

		VRAM1_RAM_A_ADDR => open, VRAM1_RAM_A_REQ => open, VRAM1_RAM_A_RD_N => open,
		VRAM1_RAM_A_DI => open, VRAM1_RAM_A_DO => (others => '0'),
		VRAM1_RAM_A_WAIT => '0',
		VRAM1_RAM_A_LINE_REFILL => open, VRAM1_RAM_A_LINE_DO => (others => '0'),
		DBG_DEADLINE_MISS_1 => open, DBG_FIFO_OVERFLOW_1 => open,

		-- Mapped, not left open, so the summary can cross-check the exact signal the
		-- board's hardware trace reports (DBG_VDC_WR) against this testbench's own
		-- independent count via CPU_VDC0_SEL_N. If those two ever disagree, the
		-- hardware number would be meaningless.
		DBG_CPU_A => dbg_cpu_a_s, DBG_VDC_WR => dbg_vdc_wr_s,

		ROM_RD    => rom_rd,
		ROM_RDY   => rom_rdy,
		ROM_A     => rom_a,
		ROM_DO    => rom_do,
		ROM_SZ    => ROM_SZ_G,
		ROM_POP   => '0',
		ROM_CLKEN => open,

		BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => x"FF", BRM_WE => brm_we,

		GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

		SP64 => '0', SGX => SGX_G,

		JOY_OUT => joy_out, JOY_IN => joy_in_s,

		CD_EN => disc_mounted_s, CD_RAM_A => cd_ram_a_s, CD_RAM_DO => cd_ram_do_s,
		CD_RAM_DI => cd_ram_di_s, CD_RAM_RD => cd_ram_rd_s, CD_RAM_WR => cd_ram_wr_s,
		CD_RAM_RDY => '1',

		ADPCM_RAM_A => open, ADPCM_RAM_DO => open,
		ADPCM_RAM_WE => adpcm_we_s, ADPCM_RAM_REQ => adpcm_req_s,
		ADPCM_RAM_SLOT_CNT => open,
		ADPCM_RAM_DI => "0000", ADPCM_RAM_READY => '1',

		AC_EN => '1',

		CD_STAT => cd_stat_s, CD_MSG => cd_msg_s, CD_STAT_GET => cd_stat_get_s,
		CD_COMM => cd_comm_s, CD_COMM_SEND => cd_comm_send_s,
		CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
		CD_REGION => '0', CD_RESET => cd_reset_s,
		CD_DATA => cd_data_s, CD_DATA_WR => cd_data_wr_s, CD_AUDIO_WR => cd_audio_wr_s,
		CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end_s, CD_DM => cd_dm_s,

		CDDA_SL => cdda_sl, CDDA_SR => cdda_sr, ADPCM_S => adpcm_s,
		PSG_SL => psg_sl, PSG_SR => psg_sr,

		BG_EN => '1', SPR_EN => '1', GRID_EN => "00", CPU_PAUSE_EN => '0',

		BORDER_EN => '0', ReducedVBL => '0',
		VIDEO_R => video_r, VIDEO_G => video_g, VIDEO_B => video_b,
		VIDEO_BW => open, VIDEO_CE => video_ce, VIDEO_CE_FS => open,
		VIDEO_VS => video_vs, VIDEO_HS => video_hs,
		VIDEO_HBL => video_hbl, VIDEO_VBL => video_vbl
	);

	-- RUN button, held from RUN_PRESS_US onward.
	joy_in_s <= "0111" when (run_pressed = '1' and joy_out(0) = '0') else "1111";
	runbtn : process
	begin
		wait for RUN_PRESS_US * 1 us;
		run_pressed <= '1';
		report "RUN button pressed" severity note;
		wait;
	end process;

	-- ------------------------------------------------------------- CD subsystem
	-- The whole point of this testbench: the real cd_bridge, driven by the real syscard
	-- running on the real pce_top, fed by real sectors off a real disc image. The HuCard
	-- boot harness ties all of this off, so it can never reproduce a CD fault.
	cd_bridge_inst : entity work.cd_bridge
		port map (
			CLK => clk, RST_N => not reset,
			CD_STAT => cd_stat_s, CD_MSG => cd_msg_s, CD_STAT_GET => cd_stat_get_s,
			CD_COMM => cd_comm_s, CD_COMM_SEND => cd_comm_send_s,
			CD_DATA => cd_data_s, CD_DATA_WR => cd_data_wr_s,
			CD_DATA_END => cd_data_end_s,
			DISC_MOUNTED => disc_mounted_s,
			TOC_WR => toc_wr_s, TOC_TRACK => toc_track_s,
			TOC_CONTROL => toc_ctl_s, TOC_LBA => toc_lba_s,
			CD_AUDIO_WR => cd_audio_wr_s, CD_DM => cd_dm_s,
			SECTOR_REQ => sector_req_s, SECTOR_LBA => sector_lba_s,
			SECTOR_IS_AUDIO => sector_audio_s,
			SECTOR_DATA => sector_data_s, SECTOR_DATA_VALID => sector_dv_s,
			SECTOR_DATA_LAST => sector_last_s,
			DBG_STATE => open
		);

	-- CD-RAM behavioural model, one cycle, matching the board's CD_RAM_RDY => '1' path.
	cdram_proc : process (clk)
	begin
		if rising_edge(clk) then
			if cd_ram_wr_s = '1' then
				cdram(to_integer(unsigned(cd_ram_a_s(17 downto 0)))) := cd_ram_do_s;
			end if;
			cd_ram_di_s <= cdram(to_integer(unsigned(cd_ram_a_s(17 downto 0))));
		end if;
	end process;

	-- TOC + mount, the same order the real MCU uses (TOC first, then mount).
	toc_proc : process
	begin
		wait until reset = '0';
		wait for CLK_PERIOD * 20;
		-- track 1: audio at LBA 0
		toc_track_s <= x"01"; toc_ctl_s <= x"00"; toc_lba_s <= x"000000";
		wait until rising_edge(clk); toc_wr_s <= '1';
		wait until rising_edge(clk); toc_wr_s <= '0';
		wait until rising_edge(clk);
		-- track 2: DATA
		toc_track_s <= x"02"; toc_ctl_s <= x"04";
		toc_lba_s <= std_logic_vector(to_unsigned(TOC_T2_LBA, 24));
		wait until rising_edge(clk); toc_wr_s <= '1';
		wait until rising_edge(clk); toc_wr_s <= '0';
		wait until rising_edge(clk);
		-- lead-out
		toc_track_s <= x"64"; toc_ctl_s <= x"00";
		toc_lba_s <= std_logic_vector(to_unsigned(TOC_LEADOUT, 24));
		wait until rising_edge(clk); toc_wr_s <= '1';
		wait until rising_edge(clk); toc_wr_s <= '0';
		wait for CLK_PERIOD * 4;
		disc_mounted_s <= '1';
		wait;
	end process;

	-- Sector server. Models the MCU's real cadence (a decode stall, then bytes at UART
	-- pace) rather than an instant memory, because the bridge's pacing is part of what is
	-- under test -- an infinitely fast source would hide exactly the class of bug that
	-- back-pressure and the request watchdog exist to handle.
	sector_proc : process
		variable lba, off : integer;
		variable l : line;
	begin
		sector_dv_s   <= '0';
		sector_last_s <= '0';
		wait until rising_edge(clk) and sector_req_s = '1';
		lba := to_integer(unsigned(sector_lba_s));
		write(l, string'("[sector] req LBA ")); write(l, lba);
		if lba < SECTOR_BASE or lba >= SECTOR_BASE + SECTOR_CNT then
			write(l, string'("  *** OUTSIDE THE SLICE -- not served"));
			writeline(output, l);
		else
			writeline(output, l);
			off := (lba - SECTOR_BASE) * 2048;
			wait for 100 us;                       -- decode stall, as the MCU has
			for i in 0 to 2047 loop
				for g in 0 to SECTOR_BYTE_CYCLES - 2 loop
					wait until rising_edge(clk);
				end loop;
				sector_data_s <= sec_img(off + i);
				sector_dv_s   <= '1';
				if i = 2047 then sector_last_s <= '1'; end if;
				wait until rising_edge(clk);
				sector_dv_s   <= '0';
				sector_last_s <= '0';
			end loop;
		end if;
	end process;

	-- CD command + interrupt monitor. The open question this testbench exists to answer:
	-- the data path is verified byte-for-byte and CD-RAM is verified across all 256KB,
	-- yet games load and then stop. If the CD never interrupts the CPU, the BIOS's
	-- transfer-complete wait never returns, which looks exactly like this from outside.
	cdmon : process
		alias cd_irq_n is << signal dut.CD_IRQ_N : std_logic >>;
		variable l : line;
		variable ncmd, nirq : integer := 0;
		variable irq_r : std_logic := '1';
	begin
		wait until rising_edge(clk);
		if cd_comm_send_s = '1' then
			ncmd := ncmd + 1;
			write(l, string'("[scsi] cmd #")); write(l, ncmd);
			write(l, string'("  op=")); write(l, hex(cd_comm_s(7 downto 0)));
			write(l, string'("  cdb=")); write(l, hex(cd_comm_s(39 downto 0)));
			writeline(output, l);
		end if;
		if cd_stat_get_s = '1' then
			write(l, string'("[scsi] status=")); write(l, hex(cd_stat_s));
			writeline(output, l);
		end if;
		if cd_irq_n = '0' and irq_r = '1' then
			nirq := nirq + 1;
			if nirq <= 20 then
				write(l, string'("[cd-irq] assertion #")); write(l, nirq);
				writeline(output, l);
			end if;
		end if;
		irq_r := cd_irq_n;
	end process;

	-- ------------------------------------------------------- internal probes
	-- VHDL-2008 external names. Everything below is a read-only tap on a signal that
	-- already exists in pce_top's architecture -- no RTL change, nothing to revert.
	probe : process
		alias cpu_a       is << signal dut.CPU_A          : std_logic_vector(20 downto 0) >>;
		alias cpu_do      is << signal dut.CPU_DO         : std_logic_vector(7 downto 0) >>;
		alias cpu_di      is << signal dut.CPU_DI         : std_logic_vector(7 downto 0) >>;
		alias cpu_wr_n    is << signal dut.CPU_WR_N       : std_logic >>;
		alias cpu_rd_n    is << signal dut.CPU_RD_N       : std_logic >>;
		alias cpu_ce      is << signal dut.CPU_CE         : std_logic >>;
		alias vdc0_sel_n  is << signal dut.CPU_VDC0_SEL_N : std_logic >>;
		alias vdc1_sel_n  is << signal dut.CPU_VDC1_SEL_N : std_logic >>;
		alias vpc_sel_n   is << signal dut.CPU_VPC_SEL_N  : std_logic >>;
		alias vce_sel_n   is << signal dut.CPU_VCE_SEL_N  : std_logic >>;
		alias vdc0_irq_n  is << signal dut.VDC0_IRQ_N     : std_logic >>;
		alias vdc1_irq_n  is << signal dut.VDC1_IRQ_N     : std_logic >>;
		alias cd_irq_n    is << signal dut.CD_IRQ_N       : std_logic >>;
		-- Same two probes the hardware trace carries (tags 0xE3/0xE4), so the sim and
		-- the board are answering the identical question with the identical wiring.
		alias mpr_dbg     is << signal dut.CPU.CORE.MPR_DBG : std_logic_vector(63 downto 0) >>;
		alias tam_dbg     is << signal dut.CPU.CORE.TAM_DBG : std_logic_vector(31 downto 0) >>;
		-- Same probe the board freezes at the trap. Sampled here at the 7th TAM, the
		-- equivalent moment, so sim and hardware can be compared field by field. This is
		-- what says whether hardware's "ADDR=operand, DI=opcode" is a real fault or just
		-- the normal address/data pipelining that a healthy CPU also shows.
		alias tload_dbg   is << signal dut.CPU.CORE.TLOAD_DBG : std_logic_vector(191 downto 0) >>;

		variable l : line;

		variable n_vdc0_wr : integer := 0;
		variable n_vdc1_wr : integer := 0;
		variable n_vpc_wr  : integer := 0;
		variable n_vce_wr  : integer := 0;
		variable n_vdc0_rd : integer := 0;

		variable n_vdc0_irq : integer := 0;
		variable n_vdc1_irq : integer := 0;
		variable n_cd_irq   : integer := 0;

		variable printed   : integer := 0;
		variable n_bus     : integer := 0;
		variable n_dbg_vdc : integer := 0;
		variable traced    : integer := 0;
		variable vdc_reg   : std_logic_vector(4 downto 0) := (others => '0');

		-- MPR/TAM evidence, mirroring the board's derailment trap. `bad_bank` is the
		-- hardware failure signature: CPU_A entering physical bank $E8-$EF, none of
		-- which exist. If the sim never sets it, the sim does not reproduce the fault.
		variable tam_max   : integer := 0;
		variable bad_bank  : boolean := false;
		variable mpr_at_7  : std_logic_vector(63 downto 0) := (others => '0');
		variable tload_at_7 : std_logic_vector(191 downto 0) := (others => '0');
		variable mpr_final : std_logic_vector(63 downto 0) := (others => '0');
		variable mpr_bad   : std_logic_vector(63 downto 0) := (others => '0');
		variable tam_bad   : std_logic_vector(31 downto 0) := (others => '0');
		variable bad_addr  : std_logic_vector(20 downto 0) := (others => '0');

		-- bank coverage of ROM reads, one bit per 8K physical bank 0..127
		type bankhit_t is array (0 to 127) of boolean;
		variable bankhit : bankhit_t := (others => false);
		variable nbanks  : integer := 0;

		variable vbl_edges : integer := 0;
		variable vs_edges  : integer := 0;

		variable prev_vbl : std_logic := '0';
		variable prev_vs  : std_logic := '0';
		variable prev_v0i : std_logic := '1';
		variable prev_v1i : std_logic := '1';
		variable prev_cdi : std_logic := '1';

		-- port-C requesters (see the signal declarations above for why these matter)
		variable n_cdram_rd  : integer := 0;
		variable n_cdram_wr  : integer := 0;
		variable n_adpcm_req : integer := 0;
		variable cyc_cdram   : integer := 0;
		variable cyc_adpcm   : integer := 0;
		variable prev_crd : std_logic := '0';
		variable prev_cwr : std_logic := '0';
		variable prev_areq: std_logic := '0';

		variable b : integer;

		-- Progress heartbeat: the RAM-clear TAI alone is ~8192 iterations, so a run
		-- long enough to reach the VDC covers tens of ms. Printing where the CPU is
		-- every HB_US shows forward progress (or a loop) without a full bus dump.
		constant HB_US    : integer := 1000;
		variable hb_next  : time := 0 ns;
		variable first_vdc : time := 0 ns;
	begin
		wait until reset = '0';
		hb_next := now;

		while running loop
			-- Must also wake on `running` going false: the clock generator stops
			-- toggling at that point, so a plain `wait until rising_edge(clk)` would
			-- park here forever and the summary below would never print.
			wait until rising_edge(clk) or not running;
			exit when not running;

			-- MPR/TAM evidence. Sampled every clock, not on cpu_ce, so a TAM that
			-- fires and is immediately overwritten still raises the count.
			if to_integer(unsigned(tam_dbg(31 downto 24))) > tam_max then
				tam_max := to_integer(unsigned(tam_dbg(31 downto 24)));
				if tam_max = 7 then
					mpr_at_7 := mpr_dbg;
					tload_at_7 := tload_dbg;
				end if;
			end if;
			mpr_final := mpr_dbg;
			if not bad_bank and cpu_a(20 downto 16) = "11101" then
				bad_bank := true;
				bad_addr := cpu_a;
				mpr_bad  := mpr_dbg;
				tam_bad  := tam_dbg;
			end if;

			-- IRQ edges (falling = asserted)
			if vdc0_irq_n = '0' and prev_v0i = '1' then n_vdc0_irq := n_vdc0_irq + 1; end if;
			if vdc1_irq_n = '0' and prev_v1i = '1' then n_vdc1_irq := n_vdc1_irq + 1; end if;
			if cd_irq_n   = '0' and prev_cdi = '1' then n_cd_irq   := n_cd_irq   + 1; end if;
			prev_v0i := vdc0_irq_n;
			prev_v1i := vdc1_irq_n;
			prev_cdi := cd_irq_n;

			-- Independent count of the port the board's hardware trace reports.
			if dbg_vdc_wr_s = '1' then
				n_dbg_vdc := n_dbg_vdc + 1;
			end if;

			-- port-C requesters: rising edges, and total cycles held asserted (the
			-- board's arbiter drops cd_ram_rdy_i for as long as it is servicing one,
			-- so the held-cycle count is what actually bounds a CPU stall).
			if cd_ram_rd_s  = '1' and prev_crd  = '0' then n_cdram_rd  := n_cdram_rd  + 1; end if;
			if cd_ram_wr_s  = '1' and prev_cwr  = '0' then n_cdram_wr  := n_cdram_wr  + 1; end if;
			if adpcm_req_s  = '1' and prev_areq = '0' then n_adpcm_req := n_adpcm_req + 1; end if;
			if cd_ram_rd_s = '1' or cd_ram_wr_s = '1' then cyc_cdram := cyc_cdram + 1; end if;
			if adpcm_req_s = '1' then cyc_adpcm := cyc_adpcm + 1; end if;
			prev_crd  := cd_ram_rd_s;
			prev_cwr  := cd_ram_wr_s;
			prev_areq := adpcm_req_s;

			-- video activity
			if video_vbl = '1' and prev_vbl = '0' then vbl_edges := vbl_edges + 1; end if;
			if video_vs  = '1' and prev_vs  = '0' then vs_edges  := vs_edges  + 1; end if;
			prev_vbl := video_vbl;
			prev_vs  := video_vs;

			if now >= hb_next then
				hb_next := now + (HB_US * 1 us);
				write(l, string'("HB "));
				write(l, now);
				write(l, string'("  cpu_a="));
				write(l, hex(cpu_a));
				write(l, string'("  bus="));
				write(l, n_bus);
				write(l, string'("  vdc0wr="));
				write(l, n_vdc0_wr);
				write(l, string'("  vbl="));
				write(l, vbl_edges);
				writeline(output, l);
			end if;

			if cpu_ce = '1' then
				if cpu_rd_n = '0' or cpu_wr_n = '0' then
					n_bus := n_bus + 1;
					-- Dump every bus cycle once the VDC write count reaches DUMP_AFTER_VDC.
					-- Hardware stops at exactly 10 VDC writes and then runs off into
					-- physical bank $ED, so this shows what the WORKING core does at the
					-- same instant -- the one comparison that can name the divergence.
					if DUMP_AFTER_VDC > 0 and n_vdc0_wr >= DUMP_AFTER_VDC
					   and traced < TRACE_N then
						traced := traced + 1;
						write(l, string'("BUS "));
						write(l, n_bus);
						if cpu_wr_n = '0' then
							write(l, string'(" WR "));
						else
							write(l, string'(" RD "));
						end if;
						write(l, hex(cpu_a));
						write(l, string'(" = "));
						if cpu_wr_n = '0' then
							write(l, hex(cpu_do));
						else
							write(l, hex(cpu_di));
						end if;
						writeline(output, l);
					end if;
				end if;

				-- ROM read bank coverage
				if cpu_a(20) = '0' and cpu_rd_n = '0' then
					b := to_integer(unsigned(cpu_a(19 downto 13)));
					if not bankhit(b) then
						bankhit(b) := true;
						nbanks := nbanks + 1;
					end if;
				end if;

				if cpu_wr_n = '0' then
					if vdc0_sel_n = '0' then
						n_vdc0_wr := n_vdc0_wr + 1;
						if first_vdc = 0 ns then
							first_vdc := now;
						end if;
						if VERBOSE /= 0 and printed < 400 then
							printed := printed + 1;
							write(l, now);
							write(l, string'("  VDC0 WR #"));
							write(l, n_vdc0_wr);
							write(l, string'(" reg="));
							write(l, hex(cpu_a(4 downto 0)));
							write(l, string'(" d="));
							write(l, hex(cpu_do));
							write(l, string'("  pc_a="));
							write(l, hex(cpu_a));
							writeline(output, l);
						end if;
					elsif vdc1_sel_n = '0' then
						n_vdc1_wr := n_vdc1_wr + 1;
					elsif vpc_sel_n = '0' then
						n_vpc_wr := n_vpc_wr + 1;
					elsif vce_sel_n = '0' then
						n_vce_wr := n_vce_wr + 1;
					end if;
				elsif cpu_rd_n = '0' and vdc0_sel_n = '0' then
					n_vdc0_rd := n_vdc0_rd + 1;
				end if;
			end if;
		end loop;

		write(l, string'("")); writeline(output, l);
		write(l, string'("================ tb_pce_boot summary ================"));
		writeline(output, l);
		write(l, string'("  sim time            : ")); write(l, now); writeline(output, l);
		write(l, string'("  VDC0 writes         : ")); write(l, n_vdc0_wr); writeline(output, l);
		write(l, string'("  first VDC0 write at : ")); write(l, first_vdc); writeline(output, l);
		write(l, string'("  DBG_VDC_WR count    : ")); write(l, n_dbg_vdc);
		if n_dbg_vdc = n_vdc0_wr then
			write(l, string'("   (matches, tap is sound)"));
		else
			write(l, string'("   *** DISAGREES with VDC0 writes -- tap is WRONG ***"));
		end if;
		writeline(output, l);
		write(l, string'("  VDC0 reads          : ")); write(l, n_vdc0_rd); writeline(output, l);
		write(l, string'("  VDC1 writes         : ")); write(l, n_vdc1_wr); writeline(output, l);
		write(l, string'("  VPC  writes         : ")); write(l, n_vpc_wr);  writeline(output, l);
		write(l, string'("  VCE  writes         : ")); write(l, n_vce_wr);  writeline(output, l);
		write(l, string'("  VDC0 IRQ assertions : ")); write(l, n_vdc0_irq); writeline(output, l);
		write(l, string'("  VDC1 IRQ assertions : ")); write(l, n_vdc1_irq); writeline(output, l);
		write(l, string'("  CD   IRQ assertions : ")); write(l, n_cd_irq);   writeline(output, l);
		write(l, string'("  VBLANK edges        : ")); write(l, vbl_edges);  writeline(output, l);
		write(l, string'("  VSYNC edges         : ")); write(l, vs_edges);   writeline(output, l);
		write(l, string'("  CPU bus cycles      : ")); write(l, n_bus);      writeline(output, l);
		-- The two lines that matter for the black screen. Hardware sees TAM writes land
		-- masked and the CPU enter bank $ED; this says whether the sim does the same.
		write(l, string'("  TAM writes executed : ")); write(l, tam_max);
		if tam_max = 7 then
			write(l, string'("   (matches the boot path's expected 7)"));
		else
			write(l, string'("   *** expected 7 ***"));
		end if;
		writeline(output, l);
		write(l, string'("  MPR at 7th TAM      : "));
		for i in 0 to 7 loop
			write(l, hex(mpr_at_7((i*8+7) downto (i*8)))); write(l, string'(" "));
		end loop;
		write(l, string'(" (MPR0..MPR7)")); writeline(output, l);
		write(l, string'("  T-LOADS at 7th TAM (newest first): IR DI ADDR ALU STATE LOADT"));
		writeline(output, l);
		for i in 0 to 3 loop
			write(l, string'("    ["));
			write(l, i);
			write(l, string'("] "));
			write(l, hex(tload_at_7((i*48+47) downto (i*48+40))));  -- IR
			write(l, string'(" "));
			write(l, hex(tload_at_7((i*48+39) downto (i*48+32))));  -- DI
			write(l, string'(" "));
			write(l, hex(tload_at_7((i*48+31) downto (i*48+16))));  -- ADDR_BUS
			write(l, string'(" "));
			write(l, hex(tload_at_7((i*48+15) downto (i*48+8))));   -- ALU_OUT
			write(l, string'(" "));
			write(l, hex(tload_at_7((i*48+7) downto (i*48+3))));    -- STATE
			write(l, string'(" "));
			write(l, hex(tload_at_7((i*48+2) downto (i*48+0))));    -- LOAD_T
			writeline(output, l);
		end loop;
		write(l, string'("  MPR at end of run   : "));
		for i in 0 to 7 loop
			write(l, hex(mpr_final((i*8+7) downto (i*8)))); write(l, string'(" "));
		end loop;
		writeline(output, l);
		if bad_bank then
			write(l, string'("  *** REPRODUCED the hardware fault: CPU entered bank $E8-$EF at "));
			write(l, hex(bad_addr)); writeline(output, l);
			write(l, string'("      MPR there : "));
			for i in 0 to 7 loop
				write(l, hex(mpr_bad((i*8+7) downto (i*8)))); write(l, string'(" "));
			end loop;
			writeline(output, l);
			write(l, string'("      TAM_CNT/IR/T/A : ")); write(l, hex(tam_bad)); writeline(output, l);
		else
			write(l, string'("  bank $E8-$EF entry  : never (sim does NOT reproduce the hardware fault)"));
			writeline(output, l);
		end if;
		write(l, string'("  CD_RAM_RD pulses    : ")); write(l, n_cdram_rd);  writeline(output, l);
		write(l, string'("  CD_RAM_WR pulses    : ")); write(l, n_cdram_wr);  writeline(output, l);
		write(l, string'("  ADPCM_RAM_REQ pulses: ")); write(l, n_adpcm_req); writeline(output, l);
		write(l, string'("  CD_RAM held cycles  : ")); write(l, cyc_cdram);   writeline(output, l);
		write(l, string'("  ADPCM held cycles   : ")); write(l, cyc_adpcm);   writeline(output, l);
		write(l, string'("  distinct ROM banks  : ")); write(l, nbanks);     writeline(output, l);
		write(l, string'("  ROM banks touched   : "));
		for i in 0 to 127 loop
			if bankhit(i) then
				write(l, string'(" "));
				write(l, hex(i, 2));
			end if;
		end loop;
		writeline(output, l);
		write(l, string'("====================================================="));
		writeline(output, l);
		wait;
	end process;

	-- ------------------------------------------------------------- stop clock
	stopper : process
	begin
		wait for RUN_US * 1 us;
		running <= false;
		wait for CLK_PERIOD * 4;
		wait;
	end process;

end architecture;
