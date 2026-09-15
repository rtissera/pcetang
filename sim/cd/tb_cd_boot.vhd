-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand
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
		-- CD-appropriate defaults (2026-09-12). A COMPILED ghdl backend (gcc/llvm) cannot
		-- override std_logic or std_logic_vector generics at run time -- it rejects them
		-- with "unhandled type for generic override" -- while mcode's -r can. Strings and
		-- integers override fine on both. Since this testbench only ever runs a CD boot,
		-- these three now default to what that needs, and neither runner has to pass them.
		ROM_SZ_G   : std_logic_vector(11 downto 0) := X"040";
		SGX_G      : std_logic := '0';
		CD_EN_G    : std_logic := '1';
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
		-- Two accepted forms, and which one a line is in is decided per line:
		--   "<4096 hex chars>"        the Nth such line is LBA SECTOR_BASE+N
		--   "<lba> <4096 hex chars>"  the sector is at exactly that LBA
		-- The sparse form exists because a real boot's reads are not contiguous: Dungeon
		-- Explorer II touches 31 sectors spread from LBA 3590 to 11967, which as one run
		-- would be 8378 sectors of hex for GHDL to load at elaboration.
		SECTOR_FILE : string := "de2_sectors.hex";
		SECTOR_BASE : integer := 3584;
		SECTOR_CNT  : integer := 160;
		-- Real TOC, one "<track> <control> <lba>" line per track (track 100 = lead-out),
		-- as produced by scripts/cd_toc.py straight from the .chd. Leave it empty to fall
		-- back to the 2-track stand-in below.
		--
		-- A stand-in TOC cannot reproduce a real boot, and that is not a detail: this
		-- testbench used to report only tracks 1, 2 and the lead-out, so GETDIRINFO mode
		-- 0 answered "last track = 2" and the system card never issued the `de 02 34`
		-- (mode 2, track 34) that an instrumented mednafen run shows it asks for right
		-- after the third READ(6) -- exactly the point real hardware stops. The sim was
		-- structurally incapable of reaching the failure.
		TOC_FILE    : string := "";
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
		SECTOR_BYTE_CYCLES : integer := 214;
		-- The `probe` process is 16 VHDL-2008 external names deep into the DUT, including
		-- CPU.CORE.MPR_DBG. Those work under GHDL's mcode backend and abort with "NULL
		-- access dereferenced" at time 0 under both compiled backends, so a run that wants
		-- the ~1.3x speed of ghdl-llvm sets PROBE_EN=0 and gives up the MPR/bad-bank
		-- diagnostics. An integer, not a boolean, because compiled backends can only
		-- override integer and string generics.
		PROBE_EN : integer := 1;
		-- Dump the CD-RAM region the system card has written, once this many sectors have
		-- been served. 0 = off. This is the reference for comparing against a dump taken
		-- on real hardware, where CD-RAM is SDRAM rather than an ideal array.
		-- CD-RAM wait states, in clk_pce cycles. 0 keeps the original zero-latency model.
		--
		-- This is the single biggest sim/hardware gap found (2026-09-14): the board's
		-- CD-RAM lives in SDRAM behind the cdr_owner arbiter and drops cd_ram_rdy_i on
		-- EVERY access, stalling the CPU through `CPU_WAIT_N_I <= ROM_RDY and CD_RAM_RDY`
		-- (pce_top.vhd:1379) for the whole SDRAM round trip -- the arbiter's settle window
		-- alone is 16 clk_pce cycles. This testbench tied CD_RAM_RDY to '1', so the CPU was
		-- never stalled once, and the model therefore CANNOT reproduce any fault that
		-- depends on CD-RAM latency. The syscard reads $1808 in 2048-byte bursts with no
		-- handshake and stores into CD-RAM, so on hardware every store in that burst
		-- stalls the CPU and in simulation none of them do.
		CDRAM_WAIT       : integer := 0;
		-- Jitter around CDRAM_WAIT, and an extra stall every 64th access, to approximate an
		-- SDRAM arbiter instead of an ideal fixed-latency array. 0 = the old behaviour.
		CDRAM_JITTER     : integer := 0;
		CDRAM_REFRESH    : integer := 0;
		-- 1 = model the PRE-2026-09-15 broken CD-RAM bridge (edge-only launch, so
		-- back-to-back accesses re-present the previous byte). Default 0 = the fixed
		-- bridge. Exists so the defect that stopped every CD game stays reproducible.
		CDRAM_STALE_BUG  : integer := 0;
		CDRAM_DUMP_AFTER : integer := 0;
		CDRAM_DUMP_BYTES : integer := 512;
		-- Write one PPM per output frame, starting at this frame number. 0 = off.
		-- The point: every other check in this testbench proves the CD TRANSACTIONS are
		-- right -- commands matching the reference, sectors byte-identical. None of them
		-- prove the machine is running the GAME. The system card can load perfect data,
		-- jump into it and execute rubbish, and the SCSI log would look exactly the same.
		-- A picture is the only thing that distinguishes "loaded the disc" from "booted".
		FRAME_DUMP_FROM : integer := 0;
		FRAME_DUMP_N    : integer := 0;
		FRAME_DIR       : string  := ""
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
	-- The CPU bus, taken from pce_top's REAL debug ports rather than VHDL-2008 external
	-- names. cdregmon used `alias cpu_a is << signal dut.CPU_A >>` and friends, which
	-- work under GHDL's mcode backend and fail with "NULL access dereferenced" at time 0
	-- under both compiled backends (gcc and llvm). Since pce_top already exports exactly
	-- these signals, the external names bought nothing and cost the faster backends.
	signal dbg_cpu_wr_n_s : std_logic;
	signal dbg_cpu_rd_n_s : std_logic;
	signal dbg_cpu_do_s   : std_logic_vector(7 downto 0);
	signal dbg_cpu_di_s   : std_logic_vector(7 downto 0);
	signal dbg_cpu_ce_s   : std_logic;
	signal dbg_irq2_n_s   : std_logic;
	-- VCE write tap (2026-09-14). Hardware tag 0xB3 showed the VCE control register
	-- ending at 0xFF after exactly one write from game code -- DOTCLOCK=512, BW=1. No
	-- real game writes 0xFF to $0400, so this prints every VCE write with the value and
	-- the physical address, to see whether the same write happens here.
	signal dbg_vce_wr_s   : std_logic;
	signal dbg_vce_do_s   : std_logic_vector(7 downto 0);
	-- VDC0's live BAT-size field (MWR bits 6:4). The reference emulator has the system
	-- card set MWR = 0x0070 (128 cols x 64 rows) within the first frames; hardware tag
	-- 0xB3 reported this stuck at "000" with ZERO changes for a whole run.
	signal dbg_vdc_screen_s : std_logic_vector(2 downto 0);
	-- SCSI target internals, already exported by pce_top but never wired here. The
	-- stall is a mutual wait between SCSI.vhd's SP_FREE (needs FIFO_LEVEL >= 2048) and
	-- cd_bridge's SCSI_READ_WAIT_END (needs CD_DATA_END), so the numbers that name it
	-- are the SCSI phase state, the DATA-IN byte counter and the FIFO occupancy.
	signal dbg_sp_s         : std_logic_vector(3 downto 0);
	signal dbg_datain_cnt_s : unsigned(15 downto 0);
	signal dbg_comm0_s      : std_logic_vector(7 downto 0);
	-- Byte accounting across the two hand-offs on the producer side, because the stall
	-- shows 8192 bytes handed to cd_bridge, 6144 delivered to the CPU and only 234 left
	-- in the FIFO -- 1814 unaccounted, with drops=0 and underrun=0. dv counts bytes the
	-- testbench hands cd_bridge; wr counts bytes cd_bridge pushes into SCSI.vhd's FIFO.
	-- If wr < dv the loss is inside cd_bridge; if they agree it is inside the FIFO.
	-- SCSI.vhd's own count of FIFO_RD_REQ pulses, i.e. bytes actually POPPED from the
	-- DATA IN FIFO. With fifowr (bytes pushed in) and DATAIN_CNT (bytes handed to the
	-- CPU) this closes the accounting: writes - pops must equal the level, and pops must
	-- equal deliveries. 1814 bytes go missing and only these three numbers say where.
	signal dbg_rd_total_s   : unsigned(15 downto 0);
	signal cdb_state_s      : std_logic_vector(4 downto 0);
	signal cdb_wr_cnt_s     : integer := 0;
	signal cdb_dv_cnt_s     : integer := 0;
	signal cdram_chk_s    : integer := 0;
	signal cdram_mis_s    : integer := 0;
	signal rom_chk_s      : integer := 0;
	signal rom_mis_s      : integer := 0;
	signal dbg_irq1_n_s   : std_logic;
	signal irq1_cnt_s     : integer := 0;
	signal irq2_cnt_s     : integer := 0;
	signal fifo_drops_s   : unsigned(15 downto 0);
	signal underruns_s    : unsigned(15 downto 0);
	signal fifo_space_s   : unsigned(12 downto 0);
	-- Bytes the producer has pulsed SECTOR_DATA_VALID for, visible every heartbeat so
	-- 'the producer stalled' and 'the consumer missed pulses' can be told apart.
	signal served_sig     : integer := 0;
	signal sector_served_cnt : integer := 0;

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
	signal cd_datain_sectors_s : unsigned(8 downto 0);
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
	-- One-cycle strobe from cdram_wait_model: an access was accepted this cycle. Gates
	-- the array read above so the model republishes data only on a real launch.
	signal cdram_launch_s : std_logic := '0';
	signal cd_ram_rdy_s  : std_logic := '1';

	-- Sector slice, read once at elaboration.
	type sec_t is array (0 to SECTOR_CNT*2048 - 1) of std_logic_vector(7 downto 0);
	-- LBA of each loaded slot, -1 = empty. Filled by load_sectors below, searched by
	-- sector_proc, so a slice needs no fixed base and no contiguity.
	type sec_lba_t is array (0 to SECTOR_CNT - 1) of integer;
	shared variable sec_lba : sec_lba_t := (others => -1);
	impure function load_sectors(fn : string) return sec_t is
		file f      : text;
		variable st : file_open_status;
		variable ln : line;
		variable m  : sec_t := (others => x"00");
		variable idx, nsec : integer := 0;
		variable c  : character;
		variable nyb, hi : integer;
		variable base_off, lba_v : integer := 0;
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
			-- Decide the line's form from its length: exactly the hex payload is the
			-- contiguous form, anything longer carries a decimal LBA in front.
			base_off := 0;
			if ln'length > 4096 then
				lba_v := 0;
				while base_off < ln'length and ln.all(base_off + 1) /= ' ' loop
					c := ln.all(base_off + 1);
					if c >= '0' and c <= '9' then
						lba_v := lba_v * 10 + (character'pos(c) - character'pos('0'));
					end if;
					base_off := base_off + 1;
				end loop;
				base_off := base_off + 1;          -- step over the separating space
				sec_lba(nsec) := lba_v;
			else
				sec_lba(nsec) := SECTOR_BASE + nsec;
			end if;
			if ln'length - base_off >= 4096 then
				for b in 0 to 2047 loop
					hi := 0;
					for half in 0 to 1 loop
						c := ln.all(base_off + b*2 + half + 1);
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
		DBG_CPU_WR_N => dbg_cpu_wr_n_s, DBG_CPU_RD_N => dbg_cpu_rd_n_s,
		DBG_CPU_DO   => dbg_cpu_do_s,   DBG_CPU_DI   => dbg_cpu_di_s,
		DBG_CPU_CE   => dbg_cpu_ce_s,   DBG_IRQ2_N => dbg_irq2_n_s,
		DBG_VCE_WR   => dbg_vce_wr_s,    DBG_VCE_DO => dbg_vce_do_s,
		DBG_VDC_SCREEN => dbg_vdc_screen_s,
		CD_DBG_SP => dbg_sp_s, CD_DBG_DATAIN_CNT => dbg_datain_cnt_s,
		CD_DBG_RD_TOTAL => dbg_rd_total_s,
		CD_DBG_COMM0 => dbg_comm0_s,
		DBG_IRQ1_N => dbg_irq1_n_s,
		CD_DBG_FIFO_DROPS => fifo_drops_s, CD_DBG_UNDERRUNS => underruns_s,
		CD_DBG_FIFO_SPACE => fifo_space_s,

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
		CD_RAM_RDY => cd_ram_rdy_s,

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
		CD_DATAIN_SECTORS => cd_datain_sectors_s,
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
	-- All four buttons (I, II, SELECT, RUN) rather than the single bit I guessed as RUN:
	-- the first attempt pressed only bit 3 and the system card never left its wait loop,
	-- and this removes the guess from the experiment. Directions stay released.
	-- RUN ONLY. This used to drive "0000", i.e. all four buttons at once, and that is
	-- SELECT+RUN -- the PC Engine's soft-reset combination -- held for 120 ms and repeated
	-- every 200 ms forever. The system card duly left its "PUSH RUN BUTTON" loop and then
	-- never got anywhere: it sat in a display loop at $00296A-$00297B for over a second of
	-- simulated time, drawing every frame and never touching the CD again after the
	-- $18C5/C6/C7 signature read.
	--
	-- Mapping is the one the real board uses (pcetang_console60k_cd.vhd), active LOW:
	--    SEL = 1 -> D0 UP, D1 RIGHT, D2 DOWN,   D3 LEFT
	--    SEL = 0 -> D0 I,  D1 II,    D2 SELECT, D3 RUN
	-- so RUN alone is "0111". An earlier attempt at bit 3 alone is recorded as having
	-- failed, which is presumably why it was widened to all four; with the mapping above
	-- confirmed against the shipping board, the narrow press is the correct one.
	joy_in_s <= "0111" when (run_pressed = '1' and joy_out(0) = '0') else "1111";
	-- PULSED, not held. Holding RUN from a fixed time onward means there is never a
	-- press EDGE after the system card puts its prompt up -- a real person presses after
	-- seeing it, and a card that debounces or edge-detects would ignore a button already
	-- down at boot. The held version reached CD-BIOS init and no further.
	runbtn : process
	begin
		wait for RUN_PRESS_US * 1 us;
		loop
			run_pressed <= '1';
			report "RUN pressed" severity note;
			wait for 120 us * 1000;     -- 120 ms held
			run_pressed <= '0';
			wait for 80 us * 1000;      -- 80 ms released, so the next press is an edge
		end loop;
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
			DATAIN_SECTORS => cd_datain_sectors_s,
			-- MUST be wired, exactly as the board does it (pcetang_console60k_cd.vhd wires
			-- FIFO_SPACE => scsi_fifo_space_i from CD_DBG_FIFO_SPACE). The port defaults to
			-- (others => '1') = 8191 = "plenty of room", which DISABLES cd_bridge's
			-- back-pressure entirely: it then streams every sector of a multi-sector READ(6)
			-- without pausing, the 4096-byte FIFO overflows, and SCSI.vhd's
			-- `if FULL = '0' then FIFO_WR_REQ <= '1'` silently discards the excess -- which
			-- cd_fifos' drops counter CANNOT see, because it only counts a wrreq it was
			-- actually offered. Leaving this open reproduced a convincing FAKE stall:
			-- 1814 bytes lost on command 7, $1800 stuck at 0x88, identical to hardware.
			FIFO_SPACE => fifo_space_s,
			CD_DATA_END => cd_data_end_s,
			DISC_MOUNTED => disc_mounted_s,
			TOC_WR => toc_wr_s, TOC_TRACK => toc_track_s,
			TOC_CONTROL => toc_ctl_s, TOC_LBA => toc_lba_s,
			CD_AUDIO_WR => cd_audio_wr_s, CD_DM => cd_dm_s,
			SECTOR_REQ => sector_req_s, SECTOR_LBA => sector_lba_s,
			SECTOR_IS_AUDIO => sector_audio_s,
			SECTOR_DATA => sector_data_s, SECTOR_DATA_VALID => sector_dv_s,
			SECTOR_DATA_LAST => sector_last_s,
			DBG_STATE => cdb_state_s
		);

	-- CD-RAM behavioural model, one cycle, matching the board's CD_RAM_RDY => '1' path.
	-- is_x() guards are NOT cosmetic here. Before the CPU drives this bus the address is
	-- 'U', and numeric_std's to_integer then emits a metavalue warning EVERY clock -- the
	-- first run of this testbench wrote a 19.4 GB log and filled the disk.
	cdram_proc : process (clk)
		variable lo, hi, nw : integer := -1;
		variable l : line;
		variable dumped : boolean := false;
		variable cd_ram_rd_prev : std_logic := '0';
		variable cdrd_n : integer := 0;
	begin
		if rising_edge(clk) then
			-- CD-RAM write-extent tracking. The point of comparison for a hardware dump is
			-- "what did the system card put in CD-RAM, and where", so record the address
			-- range it touches and print the region once a chosen number of sectors has
			-- been delivered. Simulation models CD-RAM as this plain array, so it CANNOT
			-- reproduce an SDRAM fault -- which is exactly why this is the reference side
			-- of the comparison and the board is the side under test.
			if CDRAM_DUMP_AFTER > 0 and not dumped
			   and sector_served_cnt >= CDRAM_DUMP_AFTER then
				dumped := true;
				write(l, string'("[cdram] after ")); write(l, sector_served_cnt);
				write(l, string'(" sectors: writes=")); write(l, nw);
				if lo >= 0 then
					write(l, string'("  range=0x")); write(l, to_hstring(to_unsigned(lo,24)));
					write(l, string'("..0x")); write(l, to_hstring(to_unsigned(hi,24)));
				end if;
				writeline(output, l);
				if lo >= 0 then
					for a in lo to minimum(hi, lo + CDRAM_DUMP_BYTES - 1) loop
						if (a - lo) mod 32 = 0 then
							if a > lo then writeline(output, l); end if;
							write(l, string'("[cdram] "));
							write(l, to_hstring(to_unsigned(a, 24)));
							write(l, string'(": "));
						end if;
						write(l, to_hstring(cdram(a)));
					end loop;
					writeline(output, l);
				end if;
			end if;
			-- CD-RAM READ LOG (2026-09-13). Mirrors the board's 0xC0-0xC8 snoop so the
			-- two can be diffed directly. The board, after the boot's 8th command, reads
			-- bank $68 correctly (0x10003 -> 0x4C, matching this model) and then reads
			-- bank $83 (CPU_A(17:0) = 0x06xxx, the base CD-ROM2 64K RAM) getting mostly
			-- 0x55 -- and restarts instead of issuing command 9. This says whether the
			-- known-good model reads that same region, and what it finds there.
			if cd_ram_rd_s = '1' and cd_ram_rd_prev = '0'
			   and not is_x(cd_ram_a_s(17 downto 0)) and cdrd_n < 40 then
				cdrd_n := cdrd_n + 1;
				write(l, string'("[cdrd] a=0x"));
				write(l, to_hstring(to_unsigned(to_integer(unsigned(cd_ram_a_s(17 downto 0))), 24)));
				write(l, string'(" d=0x"));
				write(l, to_hstring(cdram(to_integer(unsigned(cd_ram_a_s(17 downto 0))))));
				writeline(output, l);
			end if;
			cd_ram_rd_prev := cd_ram_rd_s;

			if not is_x(cd_ram_a_s(17 downto 0)) then
				if cd_ram_wr_s = '1' then
					cdram(to_integer(unsigned(cd_ram_a_s(17 downto 0)))) := cd_ram_do_s;
					nw := nw + 1;
					if lo < 0 or to_integer(unsigned(cd_ram_a_s(17 downto 0))) < lo then
						lo := to_integer(unsigned(cd_ram_a_s(17 downto 0)));
					end if;
					if to_integer(unsigned(cd_ram_a_s(17 downto 0))) > hi then
						hi := to_integer(unsigned(cd_ram_a_s(17 downto 0)));
					end if;
				end if;
				-- PCE PORT (2026-09-15). THIS LINE USED TO BE UNCONDITIONAL, and that is
				-- the second false conclusion this testbench has manufactured (the first
				-- was the unwired FIFO_SPACE). Driving the data from the CURRENT address
				-- every clock means the model ALWAYS presents the correct byte, no matter
				-- what the request handshake does -- so a bridge that launches no access
				-- and leaves the previous byte on the bus is INVISIBLE here. That is
				-- exactly the defect that stopped every CD game on hardware, and it is why
				-- Dracula X reached its title screen in this testbench while the board
				-- stalled. Republish only when an access is actually launched, the way the
				-- board publishes cd_ram_di_i at completion, so the model can be wrong in
				-- the same way the hardware can.
				if CDRAM_WAIT = 0 or cdram_launch_s = '1' then
					cd_ram_di_s <= cdram(to_integer(unsigned(cd_ram_a_s(17 downto 0))));
				end if;
			end if;
		end if;
	end process;

	-- CD-RAM wait-state model (see CDRAM_WAIT's own comment). Mirrors the board's
	-- arbiter handshake shape rather than its internals: ready drops on the cycle an
	-- access is accepted and comes back CDRAM_WAIT cycles later. cd_ram_di_s is already
	-- driven combinationally from the array by the process above, so the data is valid
	-- when ready returns, exactly as the board publishes cd_ram_di_i at completion.
	-- CD-RAM wait-state model. CDRAM_WAIT is the MEAN; when CDRAM_JITTER /= 0 the actual
	-- latency varies pseudo-randomly in [CDRAM_WAIT-CDRAM_JITTER, CDRAM_WAIT+CDRAM_JITTER]
	-- and every 64th access takes an extra CDRAM_REFRESH cycles.
	--
	-- WHY: a fixed-latency ideal array cannot express what the board actually has, which
	-- is SDRAM behind an arbiter -- variable ordering, contention with the ROM path, and
	-- refresh stalls. A sweep of FIXED latencies 20/40/80 changed nothing (all reached
	-- command 8 with the byte identity exact), so mean latency is NOT the differentiator.
	-- Jitter and ordering are what remain untested.
	cdram_wait_model : process(clk)
		variable cnt      : integer := 0;
		variable busy     : boolean := false;
		variable rd_prev  : std_logic := '0';
		variable wr_prev  : std_logic := '0';
		variable acc      : integer := 0;
		variable lfsr     : unsigned(15 downto 0) := x"ACE1";
		variable extra    : integer := 0;
		variable a_prev   : std_logic_vector(21 downto 0) := (others => '0');
	begin
		if rising_edge(clk) then
			cdram_launch_s <= '0';
			if CDRAM_WAIT = 0 then
				cd_ram_rdy_s <= '1';
			else
				if not busy then
					cd_ram_rdy_s <= '1';
					-- PCE PORT (2026-09-15): the address-change term, matching the boards'
					-- fixed arbiters (cd_new_comb). CD_RAM_RD is a LEVEL held across
					-- consecutive CPU memory cycles, so an edge-only launch silently drops
					-- every back-to-back access -- which, together with the now-gated
					-- republish of cd_ram_di_s, is precisely the hardware defect. Set the
					-- CDRAM_STALE_BUG generic to 1 to model the OLD, broken bridge and
					-- watch the boot die the way the board did.
					if (cd_ram_rd_s = '1' and rd_prev = '0')
					   or (cd_ram_wr_s = '1' and wr_prev = '0')
					   or (CDRAM_STALE_BUG = 0
					       and (cd_ram_rd_s = '1' or cd_ram_wr_s = '1')
					       and not is_x(cd_ram_a_s) and cd_ram_a_s /= a_prev) then
						a_prev := cd_ram_a_s;
						busy := true;
						-- galois LFSR, cheap and repeatable
						if lfsr(0) = '1' then
							lfsr := ('0' & lfsr(15 downto 1)) xor x"B400";
						else
							lfsr := '0' & lfsr(15 downto 1);
						end if;
						extra := 0;
						if CDRAM_JITTER /= 0 then
							extra := (to_integer(lfsr(7 downto 0)) mod (2*CDRAM_JITTER+1))
							         - CDRAM_JITTER;
						end if;
						acc := acc + 1;
						if CDRAM_REFRESH /= 0 and (acc mod 64) = 0 then
							extra := extra + CDRAM_REFRESH;
						end if;
						cnt := CDRAM_WAIT + extra;
						if cnt < 1 then cnt := 1; end if;
						cd_ram_rdy_s <= '0';
						cdram_launch_s <= '1';
					end if;
				else
					if cnt > 0 then
						cnt := cnt - 1;
					else
						busy := false;
						cd_ram_rdy_s <= '1';
					end if;
				end if;
			end if;
			rd_prev := cd_ram_rd_s;
			wr_prev := cd_ram_wr_s;
		end if;
	end process;

	-- ---------------------------------------------------------------------------
	-- CD-RAM SHADOW CHECKER (2026-09-14).
	--
	-- Every CD game gets as far as loading code into CD-RAM and then diverges the moment
	-- the CPU EXECUTES from it: DD2 writes 0xFF to the VCE and parks, Rondo hangs
	-- mid-READ, the rest hit the reset vector. Bomberman '93 (HuCard, no CD-RAM) is fine.
	-- The 16/16 byte-identical CD-RAM readback done on hardware proved the ARRAY holds
	-- the right bytes; it was taken by the MCU at rest and says nothing about what the
	-- CPU receives on a WAIT-STATED fetch. That is the untested seam, and the HuCard ROM
	-- bridge bug was exactly this class -- the CPU was handed byte N-1 for every fetch.
	--
	-- HUC6280.vhd only raises CPU_CE when WAIT_N = '1' (see its clock-divider process),
	-- and pce_top ties WAIT_N to `ROM_RDY and CD_RAM_RDY`, so a CE pulse CANNOT occur
	-- while a CD-RAM access is still outstanding. That makes the check exact: latch the
	-- address of any in-flight CD-RAM read together with what this model holds there,
	-- and on the next CPU_CE compare it against DBG_CPU_DI -- the byte the CPU core
	-- actually takes off the bus. A mismatch is the bug, with no theory in between.
	cdram_shadow : process
		variable pend  : boolean := false;
		variable paddr : integer := 0;
		variable pexp  : std_logic_vector(7 downto 0) := (others => '0');
		variable nchk  : integer := 0;
		variable nmis  : integer := 0;
		variable lastrep : integer := -1;
		variable l     : line;
	begin
		wait until rising_edge(clk);
			if cd_ram_rd_s = '1' and not is_x(cd_ram_a_s(21 downto 0))
			   and cd_ram_a_s(21 downto 18) = "1000" then
				pend  := true;
				paddr := to_integer(unsigned(cd_ram_a_s(17 downto 0)));
				pexp  := cdram(paddr);
			end if;
			if dbg_cpu_ce_s = '1' then
				if pend and not is_x(dbg_cpu_di_s) then
					nchk := nchk + 1;
					if dbg_cpu_di_s /= pexp then
						nmis := nmis + 1;
						if nmis <= 20 then
							write(l, string'("[cdshadow] MISMATCH #")); write(l, nmis);
							write(l, string'(" t=")); write(l, now);
							write(l, string'(" a=0x"));
							write(l, to_hstring(to_unsigned(paddr, 24)));
							write(l, string'(" expected=0x")); write(l, to_hstring(pexp));
							write(l, string'(" cpu_got=0x")); write(l, to_hstring(dbg_cpu_di_s));
							write(l, string'("  cpu_a=0x"));
							write(l, to_hstring(dbg_cpu_a_s));
							write(l, string'(" sectors_served=")); write(l, sector_served_cnt);
							writeline(output, l);
						end if;
					end if;
				end if;
				pend := false;
			if nchk > 0 and nchk mod 20000 = 0 and nchk /= lastrep then
				lastrep := nchk;
				write(l, string'("[cdshadow] alive: ")); write(l, nchk);
				write(l, string'(" checks, ")); write(l, nmis);
				write(l, string'(" mismatches")); writeline(output, l);
			end if;
			end if;
			cdram_chk_s <= nchk;
			cdram_mis_s <= nmis;
	end process;

	-- Every CPU write that selects the VCE, with the value. Hardware saw the control
	-- register (A = "000") end at 0xFF: DOTCLOCK = "11" (512-wide), CR(2) artifact bit,
	-- CR(7) = BW. The syscard leaves it at 0x04. Printing these says whether the real
	-- reference does the same thing or whether the board invented that write.
	-- Every change of VDC0's BAT-size field, with a timestamp. The reference writes
	-- MWR = 0x0070 during system-card init; if this never leaves "000" here too, the
	-- register write path for VDC reg $09 is broken in RTL and is reproducible offline.
	vdc_screen_log : process (clk)
		variable prev : std_logic_vector(2 downto 0) := "XXX";
		variable n    : integer := 0;
		variable l    : line;
	begin
		if rising_edge(clk) then
			if not is_x(dbg_vdc_screen_s) and dbg_vdc_screen_s /= prev and n < 60 then
				n := n + 1;
				prev := dbg_vdc_screen_s;
				write(l, string'("[screen] t=")); write(l, now);
				write(l, string'(" SCREEN=")); write(l, to_integer(unsigned(dbg_vdc_screen_s)));
				writeline(output, l);
			end if;
		end if;
	end process;

	-- ROM SHADOW CHECKER (2026-09-14). Same construction as cdram_shadow above, on the
	-- other memory the CPU fetches from. Every sim here runs ROM_LAT=16, the code that
	-- diverges is the system card, and the system card executes from ROM -- yet only
	-- CD-RAM was being checked. The HuCard black-screen bug (777ba38) was precisely a ROM
	-- bridge handing the CPU byte N-1, so this seam has a track record. CPU_CE cannot
	-- fire while ROM_RDY is low, so a compare at CE is exact.
	rom_shadow : process
		variable pend  : boolean := false;
		variable paddr : integer := 0;
		variable pexp  : std_logic_vector(7 downto 0) := (others => '0');
		variable nchk  : integer := 0;
		variable nmis  : integer := 0;
		variable lastrep : integer := -1;
		variable l     : line;
	begin
		wait until rising_edge(clk);
			if rom_rd = '1' and not is_x(rom_a) then
				pend  := true;
				paddr := to_integer(unsigned(rom_a));
				if paddr < ROM_WORDS then pexp := rom_img(paddr); end if;
			end if;
			if dbg_cpu_ce_s = '1' then
				if pend and not is_x(dbg_cpu_di_s) and paddr < ROM_WORDS then
					nchk := nchk + 1;
					if dbg_cpu_di_s /= pexp then
						nmis := nmis + 1;
						if nmis <= 20 then
							write(l, string'("[romshadow] MISMATCH #")); write(l, nmis);
							write(l, string'(" t=")); write(l, now);
							write(l, string'(" rom_a=0x"));
							write(l, to_hstring(to_unsigned(paddr, 24)));
							write(l, string'(" expected=0x")); write(l, to_hstring(pexp));
							write(l, string'(" cpu_got=0x")); write(l, to_hstring(dbg_cpu_di_s));
							write(l, string'("  cpu_a=0x")); write(l, to_hstring(dbg_cpu_a_s));
							writeline(output, l);
						end if;
					end if;
				end if;
				pend := false;
			if nchk > 0 and nchk mod 20000 = 0 and nchk /= lastrep then
				lastrep := nchk;
				write(l, string'("[romshadow] alive: ")); write(l, nchk);
				write(l, string'(" checks, ")); write(l, nmis);
				write(l, string'(" mismatches")); writeline(output, l);
			end if;
			end if;
			rom_chk_s <= nchk;
			rom_mis_s <= nmis;
	end process;

	-- VDC REGISTER WRITE DECODER. pce_top exports DBG_VDC_WR plus the CPU bus, which is
	-- enough to reconstruct what the CPU programs: A="00" loads the address register,
	-- A="10"/"11" write the low/high byte of whatever register that selected. Register 2
	-- is the VRAM data port and would flood the log, so it is skipped. The reference
	-- emulator's fingerprint for this disc is MWR (reg $09) going 0x10 -> 0x00 at frame 1
	-- and 0x70 only at frame 5234, i.e. once the GAME takes over.
	vdc_wr_log : process (clk)
		variable ar : integer := 0;
		variable n  : integer := 0;
		variable l  : line;
	begin
		if rising_edge(clk) then
			if dbg_vdc_wr_s = '1' and not is_x(dbg_cpu_a_s) and not is_x(dbg_cpu_do_s) then
				if dbg_cpu_a_s(1) = '0' then
					ar := to_integer(unsigned(dbg_cpu_do_s(4 downto 0)));
				elsif ar /= 2 and n < 300 then
					n := n + 1;
					write(l, string'("[vdcreg] t=")); write(l, now);
					write(l, string'(" AR=")); write(l, ar);
					write(l, string'(" half=")); write(l, to_integer(unsigned(dbg_cpu_a_s(0 downto 0))));
					write(l, string'(" <= 0x")); write(l, to_hstring(dbg_cpu_do_s));
					writeline(output, l);
				end if;
			end if;
		end if;
	end process;

	vce_wr_log : process (clk)
		variable n : integer := 0;
		variable l : line;
	begin
		if rising_edge(clk) then
			if dbg_vce_wr_s = '1' and not is_x(dbg_vce_do_s) and n < 200 then
				n := n + 1;
				write(l, string'("[vce] t=")); write(l, now);
				write(l, string'(" a=0x")); write(l, to_hstring(dbg_cpu_a_s));
				write(l, string'(" reg=")); write(l, to_integer(unsigned(dbg_cpu_a_s(2 downto 0))));
				write(l, string'(" <= 0x")); write(l, to_hstring(dbg_vce_do_s));
				write(l, string'(" sectors_served=")); write(l, sector_served_cnt);
				writeline(output, l);
			end if;
		end if;
	end process;

	-- TOC + mount, the same order the real MCU uses (TOC first, then mount).
	toc_proc : process
		file tf       : text;
		variable st   : file_open_status;
		variable ln   : line;
		variable t, ctl, lba, ntoc : integer;
		variable good : boolean;
		variable l    : line;
	begin
		wait until reset = '0';
		wait for CLK_PERIOD * 20;
		ntoc := 0;
		if TOC_FILE /= "" then
			file_open(st, tf, TOC_FILE, read_mode);
			if st /= open_ok then
				write(l, string'("TOC FILE NOT FOUND: ")); write(l, TOC_FILE);
				writeline(output, l);
			else
				while not endfile(tf) loop
					readline(tf, ln);
					-- Skip blanks and the "# ..." comment scripts/cd_toc.py may emit.
					good := ln'length > 0;
					if good then good := ln.all(1) /= '#'; end if;
					if good then
						read(ln, t, good);
						if good then read(ln, ctl, good); end if;
						if good then read(ln, lba, good); end if;
					end if;
					if good then
						toc_track_s <= std_logic_vector(to_unsigned(t, 8));
						toc_ctl_s   <= std_logic_vector(to_unsigned(ctl, 8));
						toc_lba_s   <= std_logic_vector(to_unsigned(lba, 24));
						wait until rising_edge(clk); toc_wr_s <= '1';
						wait until rising_edge(clk); toc_wr_s <= '0';
						wait until rising_edge(clk);
						ntoc := ntoc + 1;
					end if;
				end loop;
				file_close(tf);
				write(l, string'("TOC entries sent: ")); write(l, ntoc);
				write(l, string'(" from ")); write(l, TOC_FILE);
				writeline(output, l);
			end if;
		end if;
		if ntoc = 0 then
			-- Stand-in TOC. Enough to make a READ(6) legal, NOT enough to reproduce a real
			-- boot -- see TOC_FILE's own comment in the generic clause.
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
		end if;
		wait for CLK_PERIOD * 4;
		disc_mounted_s <= '1';
		wait;
	end process;

	-- Sector server. Models the MCU's real cadence (a decode stall, then bytes at UART
	-- pace) rather than an instant memory, because the bridge's pacing is part of what is
	-- under test -- an infinitely fast source would hide exactly the class of bug that
	-- back-pressure and the request watchdog exist to handle.
	sector_proc : process
		variable lba, off, slot : integer;
		variable l : line;
		-- Bytes this process has handed to cd_bridge, cumulative. If the CPU is short of
		-- data but this number says everything was delivered, the loss is downstream of
		-- the producer -- which is the distinction the FIFO drop counter failed to make.
		variable served_total : integer := 0;
	begin
		sector_dv_s   <= '0';
		sector_last_s <= '0';
		wait until rising_edge(clk) and sector_req_s = '1';
		if is_x(sector_lba_s) then
			lba := -1;
		else
			lba := to_integer(unsigned(sector_lba_s));
		end if;
		sector_served_cnt <= sector_served_cnt + 1;
		write(l, string'("[sector] req LBA ")); write(l, lba);
		write(l, string'("  served_total=")); write(l, served_total);
		slot := -1;
		for i in 0 to SECTOR_CNT - 1 loop
			if sec_lba(i) = lba then slot := i; end if;
		end loop;
		if slot < 0 then
			write(l, string'("  *** OUTSIDE THE SLICE -- not served"));
			writeline(output, l);
		else
			writeline(output, l);
			off := slot * 2048;
			wait for 100 us;                       -- decode stall, as the MCU has
			for i in 0 to 2047 loop
				for g in 0 to SECTOR_BYTE_CYCLES - 2 loop
					wait until rising_edge(clk);
				end loop;
				sector_data_s <= sec_img(off + i);
				sector_dv_s   <= '1';
				served_total := served_total + 1;
				served_sig <= served_total + 1;
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
	-- IRQ edge counters. A display loop that never advances while VBlank interrupts are
	-- NOT arriving is a stuck wait; the same loop with interrupts arriving is just an
	-- animation. These two counters are what tells those apart.
	irqcnt : process (clk)
		variable p1, p2 : std_logic := '1';
	begin
		if rising_edge(clk) then
			if dbg_irq1_n_s = '0' and p1 = '1' then irq1_cnt_s <= irq1_cnt_s + 1; end if;
			if dbg_irq2_n_s = '0' and p2 = '1' then irq2_cnt_s <= irq2_cnt_s + 1; end if;
			p1 := dbg_irq1_n_s; p2 := dbg_irq2_n_s;
		end if;
	end process;

	-- Progress marker for PROBE_EN=0 runs, where the heartbeat inside `probe` is gone.
	-- Wakes once per simulated millisecond, not once per clock, so it costs nothing.
	hb_lite : process
		variable l : line;
	begin
		if PROBE_EN /= 0 then wait; end if;
		loop
			wait for 1 ms;
			write(l, string'("HB ")); write(l, now);
			-- Where is the CPU? dbg_cpu_a_s is a real pce_top port, so this costs one
			-- signal read per simulated millisecond and works on the compiled backends
			-- that the external-name version of this probe aborts.
			write(l, string'("  cpu_a=")); write(l, hex(dbg_cpu_a_s));
			write(l, string'("  irq1=")); write(l, irq1_cnt_s);
			write(l, string'("  irq2=")); write(l, irq2_cnt_s);
			-- Bytes the DATA IN FIFO threw away because it was full, and bursts that ran
			-- dry. Either being nonzero names the failure without further guessing.
			write(l, string'("  drops=")); write(l, integer'image(to_integer(fifo_drops_s)));
			write(l, string'("  underrun=")); write(l, integer'image(to_integer(underruns_s)));
			-- FIFO level. If a READ(6) stalls, this says whether the gate's 2048 threshold
			-- is simply never reached -- e.g. the producer delivered exactly 2048 but the
			-- level reads one short because the FIFO output is registered.
			write(l, string'("  lvl=")); write(l, integer'image(4096 - to_integer(fifo_space_s)));
			write(l, string'("  served=")); write(l, served_sig);
			write(l, string'("  dv=")); write(l, cdb_dv_cnt_s);
			write(l, string'("  fifowr=")); write(l, cdb_wr_cnt_s);
			write(l, string'("  cdbst=")); write(l, to_integer(unsigned(cdb_state_s)));
			write(l, string'("  pops=")); write(l, to_integer(dbg_rd_total_s));
			writeline(output, l);
		end loop;
	end process;

	cdmon : process
		alias cd_irq_n is dbg_irq2_n_s;   -- pce_top port, not an external name
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

	-- CD register + pad probe. The syscard talks to the drive through $1800-$180F and
	-- polls the pad at $1000; if it never issues a SCSI command, the reason is visible
	-- in what it reads back from those. Bounded print count -- an unbounded per-cycle
	-- print in this testbench once wrote a 19.4 GB log.
	-- SCSI PHASE POLL TAP (2026-09-14). cdregmon deliberately drops `RD $1800` because
	-- the system card polls it hundreds of thousands of times per boot. But the place
	-- both Rondo and Double Dragon 2 park is the system card's DATA-IN transfer loop,
	-- which is nothing BUT that poll:
	--
	--    EA79  LDA $1800 / AND #$F8 / STA $227A
	--    EA81  CMP #$C8   BEQ  -> take a byte  (BSY|REQ|IO      = DATA IN)
	--    EA85  CMP #$D8   BEQ  -> command done (BSY|REQ|CD|IO   = STATUS)
	--    EA89  BRA EA79                          <- spins here
	--
	-- So the one number that names the bug is what $1800 returns while it spins. Logging
	-- only CHANGES keeps it to a handful of lines instead of flooding the link the way
	-- CDREG_STREAM did on hardware.
	-- SCSI PHASE POLL + TARGET STATE TAP (2026-09-14, rewritten).
	--
	-- cdregmon deliberately drops `RD $1800` (the system card polls it hundreds of
	-- thousands of times a boot). But the place both Rondo and Double Dragon 2 park is
	-- the system card's DATA-IN loop, which is nothing but that poll:
	--
	--    EA79  LDA $1800 / AND #$F8 / STA $227A
	--    EA81  CMP #$C8   BEQ -> read a 2048-byte block BLIND (8 x 256, no handshake)
	--    EA85  CMP #$D8   BEQ -> command done
	--    EA89  BRA EA79                             <- spins here
	--
	-- MUST be a `wait until rising_edge(clk)` process, exactly like cdregmon. The first
	-- version of this tap was `process (clk)` and fired ZERO times in 173 ms of a run
	-- whose binary provably contained it, while cdregmon logged the same register all
	-- along -- the two styles do not sample CPU_CE/RD_N/A in the same delta.
	--
	-- Logs only CHANGES, with a repeat count, and carries the SCSI target's own state
	-- alongside: SP, DATAIN_CNT, COMM(0) and FIFO occupancy. That is the set that
	-- distinguishes "burst never started" from "burst started and ran dry".
	phasepoll : process
		variable prev : std_logic_vector(7 downto 0) := (others => 'X');
		variable n    : integer := 0;
		variable rep  : integer := 0;
		variable l    : line;
	begin
		wait until rising_edge(clk);
		if dbg_cpu_ce_s = '1' and not is_x(dbg_cpu_a_s)
		   and dbg_cpu_a_s(20 downto 10) = "11111111110"
		   and dbg_cpu_a_s(9 downto 0) = "0000000000"
		   and dbg_cpu_rd_n_s = '0' and not is_x(dbg_cpu_di_s) then
			if dbg_cpu_di_s /= prev then
				if rep > 0 and n < 300 then
					write(l, string'("[phase]   (x")); write(l, rep);
					write(l, string'(" repeats)")); writeline(output, l);
				end if;
				prev := dbg_cpu_di_s;
				rep  := 0;
				if n < 300 then
					n := n + 1;
					write(l, string'("[phase] t=")); write(l, now);
					write(l, string'(" $1800 => 0x")); write(l, to_hstring(dbg_cpu_di_s));
					write(l, string'("  SP=")); write(l, to_integer(unsigned(dbg_sp_s)));
					write(l, string'(" datain_cnt=")); write(l, to_integer(dbg_datain_cnt_s));
					write(l, string'(" comm0=0x")); write(l, to_hstring(dbg_comm0_s));
					write(l, string'(" fifo_level="));
					write(l, 4096 - to_integer(fifo_space_s));
					writeline(output, l);
				end if;
			else
				rep := rep + 1;
			end if;
		end if;
	end process;

	-- Every change of the SCSI target's phase state, with the FIFO occupancy at that
	-- moment. SP_FREE is 0. A burst that STARTS needs FIFO_LEVEL >= 2048 (BURST_RDY);
	-- printing the level at every entry to SP_FREE says directly whether a burst was
	-- ever dispatched with less than a full sector buffered.
	-- See cdb_wr_cnt_s' declaration. Counts both producer hand-offs, so the missing
	-- bytes can be attributed to one side of cd_bridge or the other.
	cdb_bytes : process
		variable wr, dv : integer := 0;
	begin
		wait until rising_edge(clk);
		if cd_data_wr_s = '1' then wr := wr + 1; end if;
		if sector_dv_s  = '1' then dv := dv + 1; end if;
		cdb_wr_cnt_s <= wr;
		cdb_dv_cnt_s <= dv;
	end process;

	spmon : process
		variable prev : std_logic_vector(3 downto 0) := (others => 'X');
		variable n    : integer := 0;
		variable l    : line;
	begin
		wait until rising_edge(clk);
		-- burst STARTS only (SP_FREE -> SP_DATAIN_START). Logging every SP change
		-- burned the cap in two lines per byte and lost the commands that matter.
		if not is_x(dbg_sp_s) and prev = x"0" and dbg_sp_s = x"A" and n < 400 then
			n := n + 1;
			write(l, string'("[sp] t=")); write(l, now);
			write(l, string'(" SP=")); write(l, to_integer(unsigned(dbg_sp_s)));
			write(l, string'(" datain_cnt=")); write(l, to_integer(dbg_datain_cnt_s));
			write(l, string'(" fifo_level="));
			write(l, 4096 - to_integer(fifo_space_s));
			writeline(output, l);
		end if;
		if not is_x(dbg_sp_s) then prev := dbg_sp_s; end if;
	end process;

	cdregmon : process
		-- Plain aliases onto pce_top's debug ports. NOT external names -- see the signal
		-- declarations above for why that matters.
		alias cpu_a    is dbg_cpu_a_s;
		alias cpu_do   is dbg_cpu_do_s;
		alias cpu_di   is dbg_cpu_di_s;
		alias cpu_wr_n is dbg_cpu_wr_n_s;
		alias cpu_rd_n is dbg_cpu_rd_n_s;
		alias cpu_ce   is dbg_cpu_ce_s;
		variable l : line;
		variable n : integer := 0;
		variable lo : std_logic_vector(11 downto 0);
	begin
		wait until rising_edge(clk);
		if cpu_ce = '1' and n < 200000 and not is_x(cpu_a) then
			lo := cpu_a(11 downto 0);
			-- PHYSICAL address, not logical. The PCE I/O page is bank $FF, i.e.
			-- 0x1FE000-0x1FFFFF, so the CD registers ($1800 in the page) are at
			-- 0x1FF800 and the pad ($1000) at 0x1FF000. Decoding the logical form is
			-- why the first version of this probe printed nothing at all.
			if cpu_a(20 downto 10) = "11111111110"            -- 0x1FF800: CD registers
			   and not (cpu_a(9 downto 0) = "0000000000"
			            and cpu_wr_n = '1') then              -- drop RD $1800 (busy poll)
				-- $1808 IS logged: the reference trace carries all 63488 sector bytes with
				-- their values, so the bytes the CPU actually loads can be diffed against a
				-- boot that works. That is the one comparison that says whether the code it
				-- jumps into is the right code.
				-- Exactly the filter sim/cd/golden/de2_boot_filtered.txt was built with, so
				-- scripts/cd_golden_diff.py can compare the two streams directly.
				if cpu_wr_n = '0' then
					n := n + 1;
					write(l, string'("[cdreg] WR $18")); write(l, hex(cpu_a(7 downto 0)));
					write(l, string'(" <= ")); write(l, hex(cpu_do));
					writeline(output, l);
				elsif cpu_rd_n = '0' then
					n := n + 1;
					write(l, string'("[cdreg] RD $18")); write(l, hex(cpu_a(7 downto 0)));
					write(l, string'(" => ")); write(l, hex(cpu_di));
					writeline(output, l);
				end if;
			-- NO cpu_rd_n gate. The pad is decoded INSIDE the HuC6280 (IOP_SEL, see
			-- HUC6280.vhd: CPU_A(20:13)=0xFF and CPU_A(12:10)="100"), so it never
			-- asserts the EXTERNAL bus read strobe -- gating on cpu_rd_n is why this
			-- probe printed nothing at all and made the pad model look broken.
			elsif cpu_a(20 downto 10) = "11111111100" then                   -- 0x1FF000: pad
				if n < 60 then
					n := n + 1;
					write(l, string'("[pad] acc joy_out=")); write(l, hex(joy_out));
					write(l, string'("  joy_in=")); write(l, hex(joy_in_s));
					write(l, string'("  run=")); write(l, std_logic'image(run_pressed));
					writeline(output, l);
				end if;
			end if;
		end if;
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
		if PROBE_EN = 0 then
			wait;   -- see PROBE_EN in the generic clause
		end if;

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
		write(l, string'("  CD-RAM shadow checks: ")); write(l, cdram_chk_s); writeline(output, l);
		write(l, string'("  CD-RAM MISMATCHES   : ")); write(l, cdram_mis_s); writeline(output, l);
		write(l, string'("  ROM shadow checks   : ")); write(l, rom_chk_s); writeline(output, l);
		write(l, string'("  ROM MISMATCHES      : ")); write(l, rom_mis_s); writeline(output, l);
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
	-- Frame grabber. VIDEO_CE is the dot-clock enable, VIDEO_HBL/VBL the blanking, so a
	-- frame is reconstructed by counting active dots between blanking edges. Output is
	-- binary PPM (P6), 8 bits per channel from the PCE's native 3.
	framedump : process
		file f          : text;
		variable st     : file_open_status;
		variable l      : line;
		variable x, y   : integer := 0;
		variable frame  : integer := 0;
		variable prev_vbl : std_logic := '1';
		variable written : integer := 0;
		type row_t is array (0 to 559) of std_logic_vector(8 downto 0);
		type img_t is array (0 to 279) of row_t;
		variable img    : img_t;
		variable px     : std_logic_vector(8 downto 0);
	begin
		if FRAME_DUMP_N = 0 then wait; end if;
		loop
			wait until rising_edge(clk);
			if video_ce = '1' then
				if video_hbl = '0' and video_vbl = '0' then
					if y <= 279 and x <= 559 then
						img(y)(x) := video_r & video_g & video_b;
					end if;
					x := x + 1;
				end if;
			end if;
			if video_hbl = '1' and x > 0 then
				x := 0; y := y + 1;
			end if;
			-- falling edge of VBL = start of a new visible frame
			if video_vbl = '0' and prev_vbl = '1' then
				if frame >= FRAME_DUMP_FROM and written < FRAME_DUMP_N and y > 8 then
					file_open(st, f, FRAME_DIR & "/frame_" &
					          integer'image(frame) & ".ppm", write_mode);
					if st = open_ok then
						write(l, string'("P3")); writeline(f, l);
						write(l, integer'image(512)); write(l, string'(" "));
						write(l, integer'image(240)); writeline(f, l);
						write(l, string'("255")); writeline(f, l);
						for yy in 0 to 239 loop
							for xx in 0 to 511 loop
								px := img(yy)(xx);
								-- 3 bits -> 8 bits, replicate so 7 maps to 255
								write(l, integer'image(to_integer(unsigned(px(8 downto 6))) * 36));
								write(l, string'(" "));
								write(l, integer'image(to_integer(unsigned(px(5 downto 3))) * 36));
								write(l, string'(" "));
								write(l, integer'image(to_integer(unsigned(px(2 downto 0))) * 36));
								write(l, string'(" "));
							end loop;
							writeline(f, l);
						end loop;
						file_close(f);
						written := written + 1;
						write(l, string'("[frame] wrote frame_"));
						write(l, frame); write(l, string'(".ppm  lines=")); write(l, y);
						writeline(output, l);
					end if;
				end if;
				frame := frame + 1;
				x := 0; y := 0;
			end if;
			prev_vbl := video_vbl;
		end loop;
	end process;

	-- `running <= false` only stops the CLOCK. Every process that paces itself with a
	-- plain `wait for` -- the heartbeat, the RUN-button presser -- keeps going, and with
	-- no clock edges left GHDL fast-forwards straight to TIME'HIGH firing them. A
	-- RUN_US=150000 run did exactly that on 2026-09-14: an 813 MB log, 9.27 million
	-- heartbeat lines at impossible timestamps (9223 s = TIME'HIGH with fs resolution),
	-- and a nearly full disk. std.env.finish ends the simulation outright instead.
	stopper : process
	begin
		wait for RUN_US * 1 us;
		running <= false;
		wait for CLK_PERIOD * 4;
		std.env.finish;
		wait;
	end process;

end architecture;
