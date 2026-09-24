-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- Real-trace measurement testbench for src/pce/common/mem/vram0_cache.vhd, driven by a
-- REAL src/pce/common/core/huc6270.vhd (the VDC, unmodified) and a real
-- src/pce/tg16-mister-rtl/huc6260.vhd (the VCE, unmodified, only source of DCK_CE/HSYNC/
-- VSYNC in this repo) -- NOT a synthetic address-pattern generator. Scratch/one-off
-- measurement tool, NOT part of the pcetang repo. See scratchpad report for the full
-- verification trail behind every register value below.
--
-- Register init table verified against a REAL, working PC Engine dev-kit source file:
-- the fpgapce project's soft/mkit251/INCLUDE/PCE/LIBRARY.ASM's
-- `init_vdc`/HSR/HDR macros for xres=256 (256x224, 64x32 BAT map, auto SATB DMA every
-- vblank) -- NOT recalled from training data. Field meanings cross-checked directly
-- against src/pce/common/core/huc6270.vhd's own HDISP_END_POS/VDISP_END_POS formulas and
-- BG_RAM_ADDR SCREEN-case logic (see report).
--
-- Internal cache hit/miss instrumentation uses GHDL VHDL-2008 external names against
-- vram0_cache.vhd's own REAL internal signals (hit/req_valid_d/req_wr_d/req_addr_d) --
-- the exact technique already proven working in this scratchpad's prior
-- tb_vram0_cache.vhd (see its own `<< signal ... >>` usage). No copy of vram0_cache.vhd
-- was made; the real, unmodified repo file is instantiated as-is.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

-- DEADLINE-MISS MEASUREMENT VARIANT (2026-08-28): forked from tb_top.vhd to run the SAME
-- real HuC6270-driven BG-only traffic against a mock SDRAM responder whose timing is
-- CALIBRATED to real measured numbers (not the arbitrary 5-mock-cycle stand-in tb_top.vhd
-- and tb_vram0_cache.vhd both use), and to count real dbg_deadline_miss pulses per stream.
-- See scratchpad/deadline_miss_rate_measurement.md for the full calibration derivation.
--
-- Calibration summary (Primer 25K profile; see report for the full cycle-by-cycle trace
-- this was derived from, and for the honest uncertainty band):
--   - clk_pce = 42.857142857 MHz (23.333ns/cycle); clk_sdram = 120.000MHz, exact 14:5 ratio.
--   - Real Verilator-measured "byte_seq round-trip cost" for a single-word refill:
--     186.67ns = 8 clk_pce cycles (vram0_deadline_implementation_plans.md). This
--     testbench's own byte_seq FSM (SEQ_IDLE->SEQ_REQ->SEQ_WAIT_RISE->SEQ_WAIT_FALL->
--     SEQ_DONE) contributes a fixed +4 clk_pce cycles of protocol overhead around
--     whatever the mock's busy-latency parameter is (traced by hand, cycle-by-cycle, from
--     this file's own mock process and vram0_cache.vhd's byte_seq -- see report), so
--     G_BUSY_LEGACY=4 reproduces the real 8-cycle/186.67ns round trip exactly.
--   - Real Verilator-measured (Stage 2, sdram_lr.sv, same-clock-domain SDRAM-side-only)
--     line-refill cost: 13 clk_sdram cycles (wait_cycles) / 14 (start-to-idle-again) vs.
--     9 for an ordinary single-word access -- a real, not assumed, +4/+5 clk_sdram-cycle
--     delta (line_refill_verification.md Stage 2). Modeling the clk_pce<->clk_sdram
--     crossing overhead as a roughly-fixed additive term (the dominant real cost per the
--     plan doc, not something that scales with burst length) gives a primary estimate of
--     G_BUSY_LR=5 (9 clk_pce cycles/210.0ns total) using the 13-cycle number, with 6
--     (10 cycles/233.3ns) as a documented conservative upper bound using the 14-cycle
--     "start-to-idle-again" number. This crossing-overhead-is-fixed assumption is a real
--     modeling uncertainty this file cannot resolve on its own (this testbench has no
--     clk_pce/clk_sdram crossing at all -- see report) -- both G_BUSY_LR values are run
--     and reported so the reader can see how much the deadline-miss numbers move across
--     that uncertainty band.
-- BAT PREFETCH VARIANT (2026-08-28): forked from tb_qa_check.vhd to insert the new,
-- scratch-only vram0_prefetch.vhd BETWEEN huc6270 (via the scratch huc6270_pf.vhd,
-- which adds OFS_Y_DBG/BYR_DBG -- otherwise byte-identical to the real repo file) and
-- vram0_cache (via the scratch vram0_cache_pf.vhd, which adds the G_PREFETCH pf_*
-- channel -- otherwise byte-identical when G_PREFETCH=false). ram_di (huc6270's real
-- RAM_DI) now comes from vram0_prefetch's own q_a output instead of vram0_cache's q_a
-- directly -- every existing check in this file (qa_check's QAREG/QAXTAB tables
-- especially) therefore automatically validates the COMBINED (buffer+cache) answer
-- with NO changes to that machinery -- it already reads `ram_di`, whatever is wired to
-- it. vram0_cache's OWN internal hit_e/reqvalid_e/refill_pending_e/dbg_deadline_miss
-- taps are UNCHANGED in meaning and timing (address_a/wren_a reach vram0_cache
-- unconditionally, pass-through -- see vram0_prefetch.vhd's own header) -- they still
-- reflect vram0_cache's OWN internal miss/give-up behavior, now decoupled from what
-- huc6270 actually receives. A case where vram0_cache's own state says "gave up" but
-- ram_di is nonetheless correct (QAXTAB's dm_right bucket, ALWAYS 0 in every prior
-- report in this series) is therefore the direct, positive signature of the buffer
-- successfully intercepting an access vram0_cache itself would have gotten wrong.
entity tb_top is
   generic (
      G_LINE_REFILL : boolean := true;   -- prefetch REQUIRES line-refill, see vram0_cache_pf/vram0_prefetch headers
      G_BUSY_LEGACY : integer := 4;   -- mock busy-cycles, single-word refill (see header)
      G_BUSY_LR     : integer := 5;   -- mock busy-cycles, line refill (see header)
      -- CG-EXTENSION VERIFICATION (2026-08-29): forked from tb_pf_check.vhd to validate
      -- vram0_prefetch.vhd's new G_CG_PREFETCH extension against the REAL, currently
      -- committed src/pce/common/core/huc6270.vhd and src/pce/common/mem/vram0_cache.vhd
      -- (not the scratch huc6270_pf.vhd/vram0_cache_pf.vhd pre-commit copies this file was
      -- originally forked against -- diffed byte-for-byte port-compatible before this fork
      -- was made). G_CG_PREFETCH here is this TESTBENCH's own generic, passed straight
      -- through to the `pf` instance's identically-named generic below -- false reproduces
      -- the exact pre-extension baseline (hit_checked=66739/hit_wrong=0/
      -- pf_hit_total=226807/pf_overrun_total=0) as a harness-fidelity check before any
      -- G_CG_PREFETCH=true result is trusted.
      G_CG_PREFETCH : boolean := false;
      -- When true, `drv` additionally issues a live BYR rewrite and a live MWR/SCREEN
      -- rewrite partway through the measurement window (see `drv`'s own comments at the
      -- STRESS markers) -- the two specific race conditions vram0_prefetch.vhd's own
      -- G_CG_PREFETCH header cites as what its per-entry cg_tag scheme is supposed to
      -- make safe (post-fix; the original design used a single global cg_row_valid_for
      -- register instead, since removed -- see that file's own header for the fix).
      -- False reproduces a plain steady-state run (no mid-run register rewrites beyond
      -- the original setup sequence).
      G_STRESS      : boolean := false
   );
end entity;

architecture sim of tb_top is

	constant CLK_PERIOD : time := 23.282 ns;  -- ~42.9545 MHz (2x PCE master clock)

	signal CLK   : std_logic := '0';
	signal RST_N : std_logic := '0';
	signal CLR_MEM : std_logic := '0';

	-- CPU register bus into the VDC (real 8-bit hardware protocol, BYTEWORD='1', matching
	-- src/pce/common/core/pce_top.vhd's own VDC0 instantiation)
	signal cpu_a     : std_logic_vector(1 downto 0) := "00";
	signal cpu_di    : std_logic_vector(7 downto 0) := x"00";
	signal cpu_do    : std_logic_vector(15 downto 0);
	signal cpu_cs_n  : std_logic := '1';
	signal cpu_wr_n  : std_logic := '1';
	signal cpu_rd_n  : std_logic := '1';
	signal vdc_busy_n: std_logic;

	-- VCE <-> VDC glue (real signals, real wiring, matching pce_top.vhd)
	signal vdc_clken, vdc_clken_f : std_logic;
	signal hsync_f, hsync_r, vsync_f, vsync_r : std_logic;
	signal vd       : std_logic_vector(8 downto 0);
	signal border_s : std_logic;
	signal grid_s   : std_logic_vector(1 downto 0);

	-- VRAM0 bus: VDC's RAM_A/RAM_DI/RAM_DO/RAM_WE <-> vram0_cache's address_a/q_a/data_a/
	-- wren_a, exactly as src/pce/common/core/pce_top.vhd's gen_vram0_ext wires them.
	signal ram_a   : std_logic_vector(15 downto 0);
	signal ram_di  : std_logic_vector(15 downto 0);   -- INTO the VDC (from cache's q_a)
	signal ram_do  : std_logic_vector(15 downto 0);   -- FROM the VDC (into cache's data_a)
	signal ram_we  : std_logic;

	-- vram0_cache <-> mock SDRAM port A
	signal sd_addr : std_logic_vector(20 downto 0);
	signal sd_req  : std_logic;
	signal sd_rd_n : std_logic;
	signal sd_di   : std_logic_vector(15 downto 0);
	signal sd_do   : std_logic_vector(15 downto 0) := (others => '0');
	signal sd_wait : std_logic := '0';
	-- New for the deadline-miss measurement variant: line-refill port A extension.
	signal sd_line_refill : std_logic;
	signal sd_line_do     : std_logic_vector(63 downto 0) := (others => '0');

	signal dbg_deadline_miss : std_logic;
	signal dbg_fifo_overflow : std_logic;

	-- BAT PREFETCH VARIANT: vram0_prefetch <-> vram0_cache pf_* channel, and the
	-- vram0_prefetch <-> vram0_cache pass-through bus (ds_*, distinct from ram_a/ram_di/
	-- ram_do/ram_we which are now huc6270 <-> vram0_prefetch's own upstream bus).
	signal ds_address_a : std_logic_vector(14 downto 0);
	signal ds_data_a    : std_logic_vector(15 downto 0);
	signal ds_wren_a    : std_logic;
	signal ds_q_a       : std_logic_vector(15 downto 0);
	signal pf_addr  : std_logic_vector(14 downto 0);
	signal pf_req   : std_logic;
	signal pf_rdata : std_logic_vector(63 downto 0);
	signal pf_done  : std_logic;
	signal dbg_pf_hit     : std_logic;
	signal dbg_pf_overrun : std_logic;
	signal dbg_cg_hit     : std_logic;
	signal dbg_cg_overrun : std_logic;
	signal dbg_cg_done_e  : std_logic;
	signal dbg_cur_cg_row_e       : unsigned(2 downto 0);
	signal dbg_pending_cg_row_e   : unsigned(2 downto 0);
	signal dbg_cg_i_e             : integer range 0 to 127;

	-- STRESS windows (G_STRESS only, see entity generic comment / drv process).
	signal stress_byr    : std_logic := '0';
	signal stress_screen : std_logic := '0';

	-- TEMP DEBUG probes (GHDL external names into vram0_prefetch's own internals).
	signal dbg_cur_supported : std_logic;
	signal dbg_pending_supported : std_logic;
	signal dbg_restart_req : std_logic;
	signal dbg_cur_total : integer;
	signal dbg_burst_i : integer;
	signal dbg_buf_valid : std_logic_vector(0 to 63);
	signal dbg_m_match_d1 : std_logic;
	signal dbg_m_addr_d1 : std_logic_vector(14 downto 0);
	signal dbg_cur_row : unsigned(5 downto 0);
	signal dbg_seq_is_pf : std_logic;

	-- Real huc6270 DBG taps the prefetch engine needs (see huc6270_pf.vhd).
	signal screen_dbg_s : std_logic_vector(2 downto 0);
	signal ofs_y_dbg_s  : std_logic_vector(8 downto 0);
	signal byr_dbg_s    : std_logic_vector(8 downto 0);

	-- vram0_cache's own real internal signals, observed via GHDL external names (see
	-- header) -- NOT inferred from outside behavior.
	signal hit_e      : std_logic;
	signal reqvalid_e : std_logic;
	signal reqwr_e    : std_logic;
	signal reqaddr_e  : std_logic_vector(14 downto 0);
	-- New: the address of the miss a dbg_deadline_miss pulse refers to (cache_ctrl's own
	-- refill_addr, held stable across the whole time a refill is outstanding -- see
	-- header calibration note and cache_ctrl's own race analysis in the report).
	signal refill_addr_e : std_logic_vector(14 downto 0);
	signal refill_pending_e : std_logic;

	-- Real mock-SDRAM write-commit tap (new, for the Q_A CORRECTNESS CHECK below): pulses
	-- dbg_wr_commit for one cycle with dbg_wr_addr/dbg_wr_data whenever `mock` actually
	-- commits a write into its own `mem` array -- i.e. ground truth for "what is really
	-- stored at this address", not a hand-derived re-statement of the drv process's upload
	-- formula. Needed because a real, empirically-confirmed drv/mock setup-time artifact
	-- (see report: the first ~21 BAT vwr_word writes collide on address 0 before the real
	-- auto-increment engages, shifting every later committed (address,data) pair by a
	-- constant -21 relative to the naive "address == loop index" assumption) makes
	-- re-deriving "expected" from the upload formula unreliable -- mirroring the mock's
	-- REAL committed content directly sidesteps that whole class of problem.
	signal dbg_wr_addr   : std_logic_vector(14 downto 0) := (others => '0');
	signal dbg_wr_data   : std_logic_vector(15 downto 0) := (others => '0');
	signal dbg_wr_commit : std_logic := '0';

	signal measuring : std_logic := '0';

	-- debug-only probes (diagnostic, not part of the measurement itself)
	signal dbg_rc_cnt   : unsigned(9 downto 0);
	signal dbg_disp_cnt : unsigned(9 downto 0);
	signal dbg_spr_find : std_logic;
	signal dbg_spr_fetch_en : std_logic;
	signal dbg_spr_eval_cnt : unsigned(6 downto 0);
	signal dbg_vdisp    : std_logic;
	signal dbg_dmas_exec : std_logic;
	signal dbg_bg_fetch  : std_logic;
	signal dbg_dot_cnt   : unsigned(2 downto 0);
	signal dbg_spr_eval  : std_logic;
	signal dbg_spr_y     : std_logic_vector(9 downto 0);
	signal dbg_dmas_sat_addr : std_logic_vector(7 downto 0);
	signal dbg_mock_writes : integer := 0;   -- real write commits into the mock SDRAM
	signal dbg_vrr, dbg_cpuvraddr : std_logic_vector(15 downto 0);
	signal dbg_cpubusy : std_logic;

	-------------------------------------------------------------- VRAM0 content layout
	-- BG-CG    : words     2048 .. 3071   (tiles 128..191, 16 words/tile, 64 tiles)
	-- BAT      : words     3072 .. 5119   (64x32 tiles, tile field points into BG-CG)
	-- SPR-CG   : words     5632 ..16255   (16 blocks of 64 words, base = 5632 + 704*k)
	-- SATB src : words    32512 ..32767   (0x7F00-0x7FFF, DVSSR points here)
	-- BG-CG's location is NOT freely choosable: huc6270.vhd computes its real fetch
	-- address as BG_BAT_CC*16 (BG_BAT_CC is BAT's own stored tile-number field), so it
	-- must sit at exactly tile_num*16 for whatever tile_num range BAT uses below --
	-- tile_num 128..191 hard-fixes BG-CG at 2048..3071.
	constant BGCG_BASE  : natural := 2048;
	-- BAT is likewise NOT freely choosable: huc6270.vhd computes BAT's real fetch
	-- address as BG_RAM_ADDR<="0000"&BG_OFS_Y(8:3)&BG_OFS_X(8:3) -- a hardcoded "0000"
	-- prefix, no base register at all (matches real PCE hardware: BAT always starts at
	-- VRAM word 0). An earlier attempt to relocate it to dodge a phantom-address-0
	-- miscount (see is_real's BAT arm below for the real fix) broke correctness --
	-- reverted.
	constant BAT_BASE   : natural := 0;
	constant SPRCG_BASE : natural := 4096;
	-- Spacing must stay a multiple of 64 (the real sprite pattern-fetch address is always
	-- PC(10:1)*64 + plane*16+line -- see report) but non-harmonic against 2048 (the
	-- cache's real aliasing distance): an earlier 1024 spacing was exactly half that
	-- distance, forcing every even/odd sprite pair onto the same two index ranges by
	-- construction -- a synthetic, not representative, aliasing pattern. 704 = 11*64
	-- divides neither 2048 nor 1024.
	constant SPRCG_SPACING : natural := 704;
	constant SATB_BASE  : natural := 32512;

	type nat16_arr_t is array (0 to 15) of natural;
	-- Screen Y (top row) per sprite -- group A (heavy overlap), gap, group B (light
	-- overlap), gap, group C (heavy overlap near the bottom) -- see report for why.
	constant SPR_Y : nat16_arr_t := (20,24,28,32,36, 110,122,134,146,158, 195,198,201,204,207,210);
	constant SPR_X : nat16_arr_t := (16,54,92,130,168,206,  8,70,132,194,  40,80,120,160,200,20);

	function classify(addr : integer) return integer is
		variable blk, sub : integer;
	begin
		if addr >= BAT_BASE and addr <= BAT_BASE+2047 then
			return 0;                                   -- BAT
		elsif addr >= BGCG_BASE and addr <= BGCG_BASE+1023 then
			if ((addr - BGCG_BASE) mod 16) < 8 then
				return 1;                                -- CG0 (plane pair 0/1)
			else
				return 2;                                -- CG1 (plane pair 2/3)
			end if;
		elsif addr >= SATB_BASE and addr <= SATB_BASE+255 then
			return 3;                                   -- SATB source (VRAM->SAT DMA)
		elsif addr >= SPRCG_BASE and addr <= SPRCG_BASE + 15*SPRCG_SPACING + 63 then
			blk := (addr - SPRCG_BASE) / SPRCG_SPACING;
			sub := (addr - SPRCG_BASE) mod SPRCG_SPACING;
			if sub <= 63 and blk <= 15 then
				return 4 + blk;                          -- SPR0..SPR15 pattern data
			else
				return 20;                               -- OTHER (shouldn't occur)
			end if;
		else
			return 20;                                  -- OTHER
		end if;
	end function;

	function region_name(r : integer) return string is
	begin
		case r is
			when 0 => return "BAT ";
			when 1 => return "CG0 ";
			when 2 => return "CG1 ";
			when 3 => return "SATB";
			when 20 => return "OTHR";
			when others => return "SPR" & integer'image(r-4);
		end case;
	end function;

	-- num/den scaled x1000 (guards den=0 -> 0). Used for both the same-line fraction
	-- (result = permille, i.e. percent*10) and the average-distinct-lines figure
	-- (result = average*1000) -- both reported as integers to avoid GHDL real-type
	-- formatting fuss; the report labels each field's exact scale.
	function pct1000(num, den : integer) return integer is
	begin
		if den = 0 then
			return 0;
		else
			return (num * 1000) / den;
		end if;
	end function;

	-- SUPERSEDED, kept only for documentation/record (no longer called from qa_check):
	-- originally meant to compute expected-correct data for a real BAT/CG0/CG1 address
	-- straight from the SAME formulas the `drv` process's upload loops below use (bi/ci ->
	-- bat_word/cg_word). Real GHDL evidence (see report, "Calibration surprise") showed
	-- this naive "address == loop index" assumption is WRONG in this exact testbench: the
	-- first ~21 real BAT vwr_word writes collide on address 0 before the real hardware
	-- auto-increment engages, shifting every later committed (address,data) pair by a
	-- constant -21 relative to what this function assumes. qa_check now builds a live
	-- shadow_mem reference model from the mock's own REAL write commits
	-- (dbg_wr_commit/dbg_wr_addr/dbg_wr_data) instead -- ground truth, immune to that
	-- artifact, whatever its exact cause. Left here, unused, only so a later reader can see
	-- what was tried first and why it was replaced, not as an actively wired code path.
	function expected_value(region, addr : integer) return std_logic_vector is
		variable x_tile, y_tile, tile_num, pal, ci : integer;
		variable w : std_logic_vector(15 downto 0);
	begin
		if region = 0 then                              -- BAT
			x_tile := addr mod 64;
			y_tile := addr / 64;
			tile_num := 128 + ((x_tile + y_tile) mod 64);
			pal := (x_tile * 3 + y_tile * 5) mod 16;
			w := std_logic_vector(to_unsigned(pal, 4)) & std_logic_vector(to_unsigned(tile_num, 12));
		else                                             -- CG0 (region=1) or CG1 (region=2)
			ci := addr - BGCG_BASE;
			w := std_logic_vector(to_unsigned((ci * 167 + 41) mod 65536, 16));
		end if;
		return w;
	end function;

	function popcount(v : std_logic_vector) return integer is
		variable c : integer := 0;
	begin
		for i in v'range loop
			if v(i) = '1' then c := c + 1; end if;
		end loop;
		return c;
	end function;

begin

	CLK <= not CLK after CLK_PERIOD/2;

	-------------------------------------------------------------------- DUT: VCE (huc6260)
	vce : entity work.huc6260
		port map (
			CLK      => CLK,
			RESET_N  => RST_N,
			A        => "000",
			CE_N     => '1',
			WR_N     => '1',
			RD_N     => '1',
			DI       => x"00",
			DO       => open,
			COLNO    => vd,
			CLKEN    => vdc_clken,
			CLKEN_F  => vdc_clken_f,
			HSYNC_F  => hsync_f,
			HSYNC_R  => hsync_r,
			VSYNC_F  => vsync_f,
			VSYNC_R  => vsync_r,
			CLKEN_FS => open,
			RVBL     => '1',
			GRID_EN  => "00",
			BORDER_EN=> '0',
			BORDER   => border_s,
			GRID     => grid_s,
			R        => open, G => open, B => open, BW => open,
			VS_N     => open, HS_N => open, HBL => open, VBL => open
		);

	-------------------------------------------------------------------- DUT: VDC (huc6270)
	vdc1 : entity work.HUC6270
		port map (
			CLK       => CLK,
			RST_N     => RST_N,
			CLR_MEM   => CLR_MEM,

			CPU_CE    => '1',
			BYTEWORD  => '1',
			A         => cpu_a,
			DI        => "00000000" & cpu_di,
			DO        => cpu_do,
			CS_N      => cpu_cs_n,
			WR_N      => cpu_wr_n,
			RD_N      => cpu_rd_n,
			BUSY_N    => vdc_busy_n,
			IRQ_N     => open,

			DCK_CE    => vdc_clken,
			DCK_CE_F  => vdc_clken_f,
			HSYNC_F   => hsync_f,
			HSYNC_R   => hsync_r,
			VSYNC_F   => vsync_f,
			VSYNC_R   => vsync_r,
			VD        => vd,
			BORDER    => border_s,
			GRID      => grid_s,
			SP64      => '0',

			RAM_A     => ram_a,
			RAM_DI    => ram_di,
			RAM_DO    => ram_do,
			RAM_WE    => ram_we,

			BG_EN     => '1',
			SPR_EN    => '1',

			IW_DBG => open, VM_DBG => open, CM_DBG => open, SCREEN_DBG => screen_dbg_s,
			SOUR_DBG => open, DESR_DBG => open, LENR_DBG => open,
			SPR_X_DBG => open, SPR_Y_DBG => open, SPR_PC_DBG => open,
			SPR_CG_DBG => open, SPR_PAL_DBG => open, SPR_PRIO_DBG => open,
			SPR_CGX_DBG => open, SPR_CGY_DBG => open, SPR_HF_DBG => open,
			SPR_VF_DBG => open,
			HSW_END_POS_DBG => open, HDS_END_POS_DBG => open, HDISP_END_POS_DBG => open,
			HSW_DBG => open, HDS_DBG => open, HDE_DBG => open,
			VDS_END_POS_DBG => open, VDISP_END_POS_DBG => open, VDE_END_POS_DBG => open,
			OFS_Y_DBG => ofs_y_dbg_s, BYR_DBG => byr_dbg_s
		);

	-------------------------------------------------------------------- DUT: vram0_prefetch
	-- Sits between vdc1's own RAM_A/RAM_DI/RAM_DO/RAM_WE (ram_a/ram_di/ram_do/ram_we,
	-- unchanged signal names/roles from the original file) and vram0_cache's own
	-- address_a/q_a/data_a/wren_a (now ds_address_a/ds_q_a/ds_data_a/ds_wren_a).
	pf : entity work.vram0_prefetch
		generic map (
			G_CG_PREFETCH => G_CG_PREFETCH
		)
		port map (
			clock      => CLK,
			hsync_f    => hsync_f,
			screen_dbg => screen_dbg_s,
			ofs_y_dbg  => ofs_y_dbg_s,
			byr_dbg    => byr_dbg_s,
			address_a  => ram_a(14 downto 0),
			data_a     => ram_do,
			wren_a     => ram_we,
			q_a        => ram_di,
			ds_address_a => ds_address_a,
			ds_data_a    => ds_data_a,
			ds_wren_a    => ds_wren_a,
			ds_q_a       => ds_q_a,
			pf_addr  => pf_addr,
			pf_req   => pf_req,
			pf_rdata => pf_rdata,
			pf_done  => pf_done,
			dbg_pf_hit     => dbg_pf_hit,
			dbg_pf_overrun => dbg_pf_overrun,
			dbg_cg_hit     => dbg_cg_hit,
			dbg_cg_overrun => dbg_cg_overrun
		);

	-------------------------------------------------------------------- DUT: vram0_cache
	cache : entity work.vram0_cache
		generic map (
			G_LINE_REFILL => G_LINE_REFILL,
			G_PREFETCH    => true
		)
		port map (
			clock      => CLK,
			dck_ce     => vdc_clken,
			address_a  => ds_address_a,
			data_a     => ds_data_a,
			wren_a     => ds_wren_a,
			q_a        => ds_q_a,
			ram_a_addr => sd_addr,
			ram_a_req  => sd_req,
			ram_a_rd_n => sd_rd_n,
			ram_a_di   => sd_di,
			ram_a_do   => sd_do,
			ram_a_wait => sd_wait,
			ram_a_line_refill => sd_line_refill,
			ram_a_line_do     => sd_line_do,
			dbg_deadline_miss => dbg_deadline_miss,
			dbg_fifo_overflow => dbg_fifo_overflow,
			pf_addr  => pf_addr,
			pf_req   => pf_req,
			pf_rdata => pf_rdata,
			pf_done  => pf_done
		);

	hit_e      <= << signal .tb_top.cache.hit         : std_logic >>;
	reqvalid_e <= << signal .tb_top.cache.req_valid_d : std_logic >>;
	reqwr_e    <= << signal .tb_top.cache.req_wr_d    : std_logic >>;
	reqaddr_e  <= << signal .tb_top.cache.req_addr_d  : std_logic_vector(14 downto 0) >>;
	refill_addr_e <= << signal .tb_top.cache.refill_addr : std_logic_vector(14 downto 0) >>;
	-- VALIDATION-ONLY probe (advisor-directed): refill_pending itself, to empirically
	-- measure its own rise-to-fall CLK-cycle count directly, instead of trusting only the
	-- hand-derived B+6 formula in the header.
	refill_pending_e <= << signal .tb_top.cache.refill_pending : std_logic >>;

	dbg_cur_supported     <= << signal .tb_top.pf.cur_supported     : std_logic >>;
	dbg_pending_supported <= << signal .tb_top.pf.pending_supported : std_logic >>;
	dbg_restart_req       <= << signal .tb_top.pf.restart_req       : std_logic >>;
	dbg_cur_total          <= << signal .tb_top.pf.cur_total : integer range 0 to 16 >>;
	dbg_burst_i            <= << signal .tb_top.pf.burst_i   : integer range 0 to 16 >>;
	dbg_buf_valid   <= << signal .tb_top.pf.buf_valid   : std_logic_vector(0 to 63) >>;
	dbg_m_match_d1  <= << signal .tb_top.pf.m_match_d1  : std_logic >>;
	dbg_m_addr_d1   <= << signal .tb_top.pf.m_addr_d1   : std_logic_vector(14 downto 0) >>;
	dbg_cur_row     <= << signal .tb_top.pf.cur_row     : unsigned(5 downto 0) >>;
	dbg_seq_is_pf   <= << signal .tb_top.cache.seq_is_pf : std_logic >>;

	-- CG-EXTENSION VERIFICATION: pf.cg_done, purely diagnostic -- lets cg_check below
	-- independently track "is a CG fill pass currently in flight" (cg_done='0') without
	-- re-deriving it from dbg_cg_overrun pulses alone, for the overrun-window
	-- cross-check in Step 3 (every overrun window really has zero wrong hits, not just
	-- the run as a whole).
	dbg_cg_done_e   <= << signal .tb_top.pf.cg_done : std_logic >>;
	dbg_cur_cg_row_e     <= << signal .tb_top.pf.cur_cg_row     : unsigned(2 downto 0) >>;
	-- NOTE (2026-08-29, post-fix verification): cg_row_valid_for no longer exists in
	-- vram0_prefetch.vhd -- the fix removed the single global "valid for row X" register
	-- entirely in favor of a per-entry {code,row} tag in cg_tag (see that file's own
	-- header). The dbg_cg_row_valid_for_e probe and its two report-string usages below
	-- were removed accordingly; cg_tag itself is not separately probed here since
	-- cg_match_comb's own pass/fail (dbg_cg_hit, checked directly by cg_check below) is
	-- the load-bearing observable, not the tag storage format.
	dbg_pending_cg_row_e <= << signal .tb_top.pf.pending_cg_row : unsigned(2 downto 0) >>;
	dbg_cg_i_e      <= << signal .tb_top.pf.cg_i      : integer range 0 to 127 >>;

	-- debug-only probes (diagnostic, not part of the measurement itself)
	dbg_rc_cnt   <= << signal .tb_top.vdc1.RC_CNT       : unsigned(9 downto 0) >>;
	dbg_disp_cnt <= << signal .tb_top.vdc1.DISP_CNT     : unsigned(9 downto 0) >>;
	dbg_spr_find <= << signal .tb_top.vdc1.SPR_FIND     : std_logic >>;
	dbg_spr_fetch_en <= << signal .tb_top.vdc1.SPR_FETCH_EN : std_logic >>;
	dbg_spr_eval_cnt <= << signal .tb_top.vdc1.SPR_EVAL_CNT : unsigned(6 downto 0) >>;
	dbg_vdisp    <= << signal .tb_top.vdc1.VDISP        : std_logic >>;
	dbg_dmas_exec <= << signal .tb_top.vdc1.DMAS_EXEC   : std_logic >>;
	dbg_bg_fetch  <= << signal .tb_top.vdc1.BG_FETCH    : std_logic >>;
	dbg_dot_cnt   <= << signal .tb_top.vdc1.DOT_CNT     : unsigned(2 downto 0) >>;
	dbg_spr_eval  <= << signal .tb_top.vdc1.SPR_EVAL    : std_logic >>;
	dbg_spr_y     <= << signal .tb_top.vdc1.SPR_Y       : std_logic_vector(9 downto 0) >>;
	dbg_dmas_sat_addr <= << signal .tb_top.vdc1.DMAS_SAT_ADDR : std_logic_vector(7 downto 0) >>;
	dbg_vrr     <= << signal .tb_top.vdc1.VRR     : std_logic_vector(15 downto 0) >>;
	dbg_cpubusy <= << signal .tb_top.vdc1.CPU_BUSY : std_logic >>;
	dbg_cpuvraddr <= << signal .tb_top.vdc1.CPU_VRAM_ADDR : std_logic_vector(15 downto 0) >>;

	------------------------------------------------------------- mock SDRAM port A
	-- Fixed-latency responder (5-cycle service time), same shape as this scratchpad's
	-- prior tb_vram0_cache.vhd mock. Pre-loaded with a non-degenerate varying pattern
	-- everywhere (real content only matters for cache HIT/MISS via ADDRESS, never DATA
	-- VALUE, for a direct-mapped tag/index cache) so any address the real RTL generates
	-- reads back something real and varying, whether or not this TB's CPU-write setup
	-- explicitly targeted it.
	-- DEADLINE-MISS VARIANT: mock responder rewritten to (a) use a CALIBRATED busy-cycle
	-- count instead of the original arbitrary 5, separately for legacy single-word
	-- (G_BUSY_LEGACY) vs line-refill (G_BUSY_LR) requests -- see file header for the
	-- derivation -- and (b) answer a ram_a_line_refill request with the real content of
	-- all 4 words of the requested line via sd_line_do, matching sdram.sv's real fixed
	-- word0,1,2,3 order (see vram0_cache.vhd's byte_seq SEQ_IDLE comment: seq_addr's low
	-- 2 bits are forced to "00" before launch when G_LINE_REFILL, so `a` below is already
	-- the line's own word0 whenever is_line='1' -- no extra masking needed here).
	mock : process (CLK)
		type mstate_t is (M_IDLE, M_BUSY, M_REC);
		variable mstate : mstate_t := M_IDLE;
		variable is_line : std_logic := '0';
		variable busy_target : integer := 4;
		type mem_t is array (0 to 32767) of std_logic_vector(15 downto 0);
		-- Zero-filled (not a varying hash): a real SATB DMA can and does run once from a
		-- register write before this TB's own CPU-driven BAT/SAT uploads land (DCR's
		-- DSR=1 auto-repeat fires at the next real vsync regardless of upload progress --
		-- see report). Zero content there reads back Y=0 for every sprite, which real
		-- huc6270.vhd's own SPR_FIND logic (RC_CNT is always >=64, SPR_H maxes at 63)
		-- guarantees never intersects any real scanline -- a harmless, inert early DMA.
		-- A varying/hash-filled default was tried first and is NOT safe here: it let an
		-- early transient SATB DMA load a garbage Y/H/X that (this session found via a
		-- real GHDL crash, not by inspection) drives SPR_TILE_X's real
		-- `unsigned(SPR.X) - 32` computation negative, wrapping to a huge unsigned value
		-- and blowing out SPR_TILE_FRAME's real fixed-size index in huc6270.vhd -- a
		-- genuine, narrow, real RTL bounds bug in the donor's sprite pixel-compositing
		-- path (unrelated to VRAM0 addressing), not something this TB should paper over
		-- with a defensive clamp. Real, intentional SAT content is uploaded later via the
		-- real CPU write path before display is enabled; this default only matters for
		-- the inert pre-setup transient.
		impure function init return mem_t is
			variable m : mem_t := (others => (others => '0'));
		begin
			return m;
		end function;
		variable mem : mem_t := init;
		variable cnt : integer := 0;
		variable a   : integer := 0;
		variable di  : std_logic_vector(15 downto 0);
		variable rdn : std_logic;
	begin
		if rising_edge(CLK) then
			dbg_wr_commit <= '0';
			case mstate is
				when M_IDLE =>
					sd_wait <= '0';
					if sd_req = '1' then
						a       := to_integer(unsigned(sd_addr(15 downto 1)));
						di      := sd_di;
						rdn     := sd_rd_n;
						is_line := sd_line_refill;
						cnt     := 0;
						if is_line = '1' then
							busy_target := G_BUSY_LR;
						else
							busy_target := G_BUSY_LEGACY;
						end if;
						mstate := M_BUSY;
					end if;
				when M_BUSY =>
					cnt := cnt + 1;
					if cnt = 1 then
						sd_wait <= '1';
					end if;
					if cnt = busy_target then
						if rdn = '0' then
							if is_line = '1' then
								-- Real fixed word0,1,2,3 order (see comment above) -- `a`
								-- is already the line's own word0.
								sd_line_do <= mem(a+3) & mem(a+2) & mem(a+1) & mem(a);
							else
								sd_do <= mem(a);
							end if;
						else
							mem(a) := di;
							dbg_mock_writes <= dbg_mock_writes + 1;
							-- Real write-commit tap for the Q_A CORRECTNESS CHECK's shadow
							-- reference model (see dbg_wr_* declaration-site comment above).
							dbg_wr_addr   <= std_logic_vector(to_unsigned(a, 15));
							dbg_wr_data   <= di;
							dbg_wr_commit <= '1';
						end if;
						sd_wait <= '0';
						mstate := M_REC;
					end if;
				when M_REC =>
					if sd_req = '0' then
						mstate := M_IDLE;
					end if;
			end case;
		end if;
	end process;

	------------------------------------------------------------- CPU register/VRAM driver
	drv : process
		procedure clk_n(n : integer) is
		begin
			for i in 1 to n loop
				wait until rising_edge(CLK);
			end loop;
		end procedure;

		-- Real, GHDL-confirmed finding: huc6270.vhd's BUSY_N output (line ~1552) is a
		-- bus-cycle-scoped wait-state pin -- its formula requires CS_N='0' and
		-- (RD_N='0' or WR_N='0') AT THAT SAME CYCLE to read busy at all; the instant this
		-- TB deselects the chip after a write pulse (as real 6280-style bus timing does),
		-- BUSY_N reads '1' (not busy) regardless of the REAL internal CPU_BUSY register's
		-- state. Polling it after deselecting (as an earlier version of this TB did) is
		-- therefore a no-op: it always "sees" not-busy on the very next cycle, letting the
		-- next register/VWR write race ahead of the still-internally-busy real one, which
		-- huc6270.vhd's own write-gate ("if CPU_BUSY='0' then ...") then silently drops --
		-- confirmed via a real GHDL readback (MARR/VRR path) showing CPU_BUSY stuck at
		-- '1' forever and every uploaded word reading back 0. Real PCE software polls the
		-- STATUS register's busy bit (A="00" read, bit 6) with CS_N held/re-asserted
		-- across each poll, or simply waits a fixed conservative delay -- this TB uses the
		-- latter, sized with real margin above the measured worst-case commit latency
		-- (CPUWR_PEND -> CPUWR_PEND2 -> CPUWR_EXEC needs up to ~4 DCK_CE edges, 8 CLK
		-- cycles apart in this repo's real default low-res dot clock, plus finding a real
		-- SLOT=CPU dot to commit).
		procedure wait_not_busy is
		begin
			clk_n(100);
		end procedure;

		procedure idx_write(v : std_logic_vector(4 downto 0)) is
		begin
			cpu_a <= "00";
			cpu_di <= "000" & v;
			cpu_cs_n <= '0';
			cpu_wr_n <= '0';
			wait until rising_edge(CLK);
			cpu_cs_n <= '1';
			cpu_wr_n <= '1';
			wait until rising_edge(CLK);
		end procedure;

		procedure data_write(a0 : std_logic; byte : std_logic_vector(7 downto 0)) is
		begin
			cpu_a <= "1" & a0;
			cpu_di <= byte;
			cpu_cs_n <= '0';
			cpu_wr_n <= '0';
			wait until rising_edge(CLK);
			cpu_cs_n <= '1';
			cpu_wr_n <= '1';
			wait until rising_edge(CLK);
		end procedure;

		procedure reg_write16(idx : natural; val : std_logic_vector(15 downto 0)) is
		begin
			idx_write(std_logic_vector(to_unsigned(idx, 5)));
			data_write('0', val(7 downto 0));
			data_write('1', val(15 downto 8));
			clk_n(8);
		end procedure;

		-- Assumes AR already = 2 (VWR) and MAWR already set; relies on real hardware's
		-- own auto-increment (CR_IW default "00" = +1 per 16-bit write) for sequential
		-- fills, exactly like a real game's VBlank VRAM upload loop.
		procedure vwr_word(val : std_logic_vector(15 downto 0)) is
		begin
			data_write('0', val(7 downto 0));
			data_write('1', val(15 downto 8));
			wait_not_busy;
		end procedure;

		-- Diagnostic-only readback via the real MARR/VRR CPU read path (not used for the
		-- measurement itself, only to verify the CPU-write upload actually landed).
		procedure read_word(addr : natural; result : out std_logic_vector(15 downto 0)) is
			variable av : std_logic_vector(15 downto 0);
			variable lo, hi : std_logic_vector(7 downto 0);
		begin
			av := std_logic_vector(to_unsigned(addr, 16));
			idx_write("00001");              -- MARR
			data_write('0', av(7 downto 0));
			data_write('1', av(15 downto 8));   -- triggers the real CPURD_PEND/CPU_BUSY
			wait_not_busy;
			cpu_a <= "10";
			wait until rising_edge(CLK);
			wait until rising_edge(CLK);
			lo := cpu_do(7 downto 0);
			cpu_a <= "11";
			wait until rising_edge(CLK);
			wait until rising_edge(CLK);
			hi := cpu_do(7 downto 0);
			idx_write("00010");              -- restore AR=VWR for any following upload
			result := hi & lo;
		end procedure;

		procedure set_mawr_vwr(addr : natural) is
			variable av : std_logic_vector(15 downto 0);
		begin
			av := std_logic_vector(to_unsigned(addr, 16));
			idx_write("00000");
			data_write('0', av(7 downto 0));
			data_write('1', av(15 downto 8));
			idx_write("00010");
		end procedure;

		variable x_tile, y_tile, tile_num, pal, bat_i : integer;
		variable bat_word : std_logic_vector(15 downto 0);
		variable cg_word  : std_logic_vector(15 downto 0);
		variable sat_w0, sat_w1, sat_w2, sat_w3 : std_logic_vector(15 downto 0);
		variable y_field, x_field, pc_field : integer;
		variable rb0, rb1, rb2, rb3 : std_logic_vector(15 downto 0);
	begin
		RST_N <= '0'; CLR_MEM <= '1';
		clk_n(20);
		RST_N <= '1';
		clk_n(300);            -- >256 cycles: guarantees one full CLR_A sweep of SAT
		CLR_MEM <= '0';
		clk_n(20);

		-- Real, verified register init (see file header + report): mkit251's real
		-- init_vdc table for 256x224, 64x32 BAT, auto SATB DMA every vblank.
		reg_write16(5,  x"0000");  -- CR: display+sprites OFF during setup
		reg_write16(6,  x"0000");  -- RCR
		reg_write16(7,  x"0000");  -- BXR
		reg_write16(8,  x"0000");  -- BYR
		reg_write16(9,  x"0010");  -- MWR: SCREEN=001 (64x32), VM=00, SM=00, CM=0
		reg_write16(10, x"0302");  -- HSR: HDS=3, HSW=2
		reg_write16(11, x"031F");  -- HDR: HDE=3, HDW=31 (32 tiles = 256px)
		reg_write16(12, x"1702");  -- VPR: VDS=23, VSW=2
		reg_write16(13, x"00DF");  -- VDR: VDW=223 (224 lines)
		reg_write16(14, x"000C");  -- VCR: VCE=12
		-- tb_top (this file) is the PRIMARY, full-multi-frame, crash-free BG-only
		-- measurement: DCR_DSR is left 0 and DVSSR (register 19) is deliberately never
		-- written, so no real SATB DMA ever fires and huc6270.vhd's internal SAT stays
		-- all-zero (Y=0 for every entry) for the whole run -- SPR_FIND can then never
		-- assert (RC_CNT is always >=64 during active display; a Y=0 sprite's window
		-- maxes out at Y+63) and SPR_TILE_SAVE's pixel-compositing path (in a DIFFERENT
		-- source file this session found a real, reachable GHDL bounds crash in --
		-- see docs/ARCHITECTURE-adjacent report) never fires. Real sprite-fetch cache
		-- traffic is measured separately, best-effort, in tb_spr.vhd (see its header
		-- for why that variant cannot safely run a full multi-frame window).
		reg_write16(15, x"0000");  -- DCR: DSR=0 (SATB DMA never auto-triggers)

		-- BAT: 64x32 tiles, tile field points into BG-CG (tiles 128..191), palette varies.
		report "TB: uploading BAT (2048 words)...";
		set_mawr_vwr(BAT_BASE);
		for bi in 0 to 2047 loop
			x_tile := bi mod 64;
			y_tile := bi / 64;
			tile_num := 128 + ((x_tile + y_tile) mod 64);
			pal := (x_tile * 3 + y_tile * 5) mod 16;
			bat_word := std_logic_vector(to_unsigned(pal, 4)) & std_logic_vector(to_unsigned(tile_num, 12));
			vwr_word(bat_word);
		end loop;

		-- BG-CG: 64 tiles x 16 words, non-degenerate varying content (values don't affect
		-- cache hit/miss -- only the ADDRESS matters for a tag/index direct-mapped cache).
		report "TB: uploading BG-CG (1024 words)...";
		set_mawr_vwr(BGCG_BASE);
		for ci in 0 to 1023 loop
			cg_word := std_logic_vector(to_unsigned((ci * 167 + 41) mod 65536, 16));
			vwr_word(cg_word);
		end loop;

		-- SPR-CG: 16 sprites x 64 words (16x16, 4bpp, standard SM="00" 4-plane fetch).
		report "TB: uploading SPR-CG (16 x 64 words)...";
		for k in 0 to 15 loop
			set_mawr_vwr(SPRCG_BASE + k*SPRCG_SPACING);
			for oi in 0 to 63 loop
				cg_word := std_logic_vector(to_unsigned((k*97 + oi*53 + 13) mod 65536, 16));
				vwr_word(cg_word);
			end loop;
		end loop;

		-- SATB source table: 16 real sprites (Y/X/PC/attr), spread and staggered so
		-- real per-scanline active-sprite count varies (0, few, many) -- see SPR_Y/SPR_X.
		-- Y field is +64 (HuC6270's own RC_CNT reset value, confirmed from this file's own
		-- RTL, not a generic spec), X field is +32 (from this file's own SPR_TILE_X calc).
		report "TB: uploading SATB source (16 real sprites)...";
		set_mawr_vwr(SATB_BASE);
		for si in 0 to 15 loop
			y_field := 64 + SPR_Y(si);
			x_field := 32 + SPR_X(si);
			pc_field := 128 + 22*si;  -- PC(10:1)*64 = SPRCG_BASE + si*SPRCG_SPACING (see report)
			sat_w0 := "000000" & std_logic_vector(to_unsigned(y_field, 10));
			sat_w1 := "000000" & std_logic_vector(to_unsigned(x_field, 10));
			sat_w2 := "00000" & std_logic_vector(to_unsigned(pc_field, 11));
			sat_w3 := (others => '0');
			sat_w3(3 downto 0) := std_logic_vector(to_unsigned(si mod 16, 4));  -- PAL
			vwr_word(sat_w0);
			vwr_word(sat_w1);
			vwr_word(sat_w2);
			vwr_word(sat_w3);
		end loop;

		-- NOTE: a CPU read-back verification pass was tried here and abandoned -- it hit
		-- vram0_cache.vhd's own documented, unfixed Bug 3 (see that file's header,
		-- "returns WRONG data on 17-34% of read dots ... even with ZERO cache
		-- conflicts"), which corrupts this exact MARR/VRR CPU-read path (it consumes
		-- q_a the same way a real VDC fetch does). A broken read-back cannot verify a
		-- write path; see report for the real verification actually used (the mock
		-- SDRAM's own write-commit counter, `mock`'s dbg_mock_writes).
		report "TB: real CPU-write commits so far (mock SDRAM write counter): " &
			integer'image(dbg_mock_writes);

		clk_n(50);
		report "TB: enabling display (CR: BB=1, SB=0 -- BG-only variant, see header)...";
		reg_write16(5, x"0080");

		-- Skip one transient frame (display just turned on mid-frame in real time), then
		-- measure for several full, real, steady-state frames.
		clk_n(750000);
		report "TB: === MEASUREMENT WINDOW START ===";
		measuring <= '1';

		-- Split into the SAME total (400000+500000+400000+500000+400000 = 2200000 clk_n
		-- cycles) as the original single clk_n(2200000) call, so a G_STRESS=false run
		-- (this TB's default) is cycle-for-cycle IDENTICAL to the pre-fork baseline --
		-- only when G_STRESS=true do the two STRESS blocks below insert real extra bus
		-- cycles (the reg_write16 calls themselves), on top of, not instead of, this
		-- 2200000-cycle skeleton.
		clk_n(400000);

		-- STRESS A (Check C race): REPEATED live BYR rewrites across a wide (500000-
		-- cycle, ~18 frames) span, alternating between two distinct row targets every
		-- 50000 cycles (10 pokes total) so the retarget race (predict's byr_changed
		-- branch, immediate re-target without waiting for the next hsync_f) is
		-- exercised many times, not just once -- a single isolated poke (this block's
		-- first version) only sampled a handful of real CG hits during its narrow
		-- window, too few to say anything statistically meaningful about cg_hit_wrong
		-- specifically inside the stress condition. stress_byr stays high for the
		-- WHOLE span, not just around one write.
		if G_STRESS then stress_byr <= '1'; end if;
		for i in 0 to 9 loop
			if G_STRESS then
				if (i mod 2) = 0 then
					report "TB: STRESS A -- live BYR rewrite mid-frame (row 48)...";
					reg_write16(8, x"0030");
				else
					report "TB: STRESS A -- live BYR rewrite mid-frame (row 96)...";
					reg_write16(8, x"0060");
				end if;
			end if;
			clk_n(50000);
		end loop;
		stress_byr <= '0';

		clk_n(400000);

		-- STRESS B (whole-buffer invalidate path): a live MWR rewrite that changes
		-- SCREEN(1:0) (64-wide "001" -> 32-wide "000", both within vram0_prefetch.vhd's
		-- supported set) held for a wide (500000-cycle, ~18 frame) span -- long enough
		-- to collect a statistically meaningful cg_hit_checked sample under the changed
		-- width, not just the handful of scanlines right at the transition -- then
		-- EXPLICITLY RESTORED to the original 64-wide value before stress_screen drops,
		-- so (a) the whole-buffer invalidate/cold-restart path is exercised TWICE (once
		-- on the way in, once on the way back) and (b) the remainder of the run after
		-- this block is genuinely back to steady-state, not silently left in a
		-- different width for the rest of the measurement window (an earlier version of
		-- this block never restored MWR, which both left most of the "STEADY" bucket
		-- after this point actually running 32-wide, and confounded cg_hit_total
		-- comparisons against the steady-only run).
		if G_STRESS then stress_screen <= '1'; end if;
		if G_STRESS then
			report "TB: STRESS B -- live MWR/SCREEN rewrite mid-run (SCREEN 001->000)...";
			reg_write16(9, x"0000");   -- MWR: SCREEN=000 (32x32), VM=00, SM=00, CM=0
		end if;
		clk_n(450000);
		if G_STRESS then
			report "TB: STRESS B -- restoring MWR/SCREEN (SCREEN 000->001)...";
			reg_write16(9, x"0010");   -- MWR: SCREEN=001 (64x32) -- back to original
		end if;
		clk_n(50000);
		stress_screen <= '0';

		clk_n(400000);
		measuring <= '0';
		clk_n(20);
		report "TB: === MEASUREMENT WINDOW END ===";
		wait for 200 ns;
		finish;
	end process;

	------------------------------------------------------------- per-scanline monitor
	mon : process (CLK)
		type touch_arr_t is array (0 to 511) of std_logic_vector(20 downto 0);
		variable touch : touch_arr_t := (others => (others => '0'));
		variable tot, hits, misses, wrs, alias_idx, idle : integer := 0;
		variable scanline : integer := 0;
		variable idxv, region : integer;
		variable is_real : boolean;

		-- grand totals across the whole measurement window
		variable g_tot, g_hits, g_misses, g_wrs, g_alias, g_lines, g_idle : integer := 0;
		type region_arr_t is array (0 to 20) of integer;
		variable g_rtot, g_rhit : region_arr_t := (others => 0);
		variable was_measuring : std_logic := '0';

		-- WITHIN-SCANLINE consecutive-fetch same-cache-line measurement (new). For each
		-- region/stream, pair_last(region) holds the idx (address(10:2), the exact
		-- vram0_cache.vhd idx_of() line-index bits) of the immediately-preceding REAL
		-- read fetch of that region WITHIN THE CURRENT SCANLINE ONLY -- reset to -1 at
		-- every hsync_f so no pair ever spans a scanline boundary (line-to-line reuse is
		-- a different, already-measured question, not this one). pairs_checked_sl/
		-- pairs_same_sl accumulate this scanline's count of consecutive-pair comparisons
		-- and how many of them landed in the same idx; folded into grand totals at each
		-- hsync_f then reset for the next line.
		variable pair_last        : region_arr_t := (others => -1);
		variable pairs_checked_sl : region_arr_t := (others => 0);
		variable pairs_same_sl    : region_arr_t := (others => 0);
		variable g_pairs_checked  : region_arr_t := (others => 0);
		variable g_pairs_same     : region_arr_t := (others => 0);
		-- Distinct cache-line (idx) count touched per region per scanline -- the second,
		-- independent view of the same within-scanline locality question. Computed from
		-- the existing `touch` bitmap (already indexed by idx x region) at each hsync_f,
		-- before it's cleared for the next line. g_active_lines(r) counts only scanlines
		-- where region r had >=1 real read (denominator for a meaningful average).
		variable region_distinct  : region_arr_t := (others => 0);
		variable g_distinct_sum   : region_arr_t := (others => 0);
		variable g_active_lines   : region_arr_t := (others => 0);

		-- DEADLINE-MISS VARIANT: per-stream dbg_deadline_miss pulse counting. Classified
		-- by refill_addr_e -- the address of the ACCESS WHOSE REFILL missed the deadline
		-- (cache_ctrl's own refill_addr, stable for the whole time that refill is
		-- outstanding -- see header calibration note for why this is race-free against
		-- the pulse itself). Same BAT phantom-address carve-out as is_real's BAT arm
		-- (addr<16 -> OTHR) applied here too, since refill_addr can itself be a stale
		-- idle-filler address if THAT access happened to also miss -- see report.
		variable dm_region        : integer;
		variable g_dmiss_region   : region_arr_t := (others => 0);
		variable g_dmiss_total    : integer := 0;
	begin
		if rising_edge(CLK) then
			if measuring = '1' and dbg_deadline_miss = '1' then
				dm_region := classify(to_integer(unsigned(refill_addr_e)));
				if dm_region = 0 and unsigned(refill_addr_e) < 16 then
					dm_region := 20;
				end if;
				g_dmiss_region(dm_region) := g_dmiss_region(dm_region) + 1;
				g_dmiss_total := g_dmiss_total + 1;
			end if;
			if measuring = '1' and reqvalid_e = '1' then
				idxv := to_integer(unsigned(reqaddr_e(10 downto 2)));
				region := classify(to_integer(unsigned(reqaddr_e)));
				-- Real fetch traffic only: exclude NOP dots and idle-CPU-slot filler
				-- (huc6270.vhd's SLOT mux replaces unused BAT/CG/sprite dots with
				-- repeated CPU/NOP reads of a stale address -- real bus traffic, but not
				-- a real BAT/CG/sprite fetch, and it would otherwise dominate the count:
				-- confirmed via a real GHDL run showing ~341 raw reads/scanline against
				-- an expected ~96 real BG fetches). BG_FETCH/SPR_FETCH_EN are huc6270's
				-- own real signals for exactly this distinction.
				-- Region-gated filter. A DOT_CNT-exact version (BAT=DOT_CNT 1, CG0=5,
				-- CG1=7 for VM="00") was tried and over-filtered to zero -- req_valid_d
				-- and DOT_CNT/BG_FETCH are not phase-aligned the way this TB sampled
				-- them, and chasing the exact relative latency wasn't worth more GHDL
				-- iterations here. BG_FETCH gates the whole BAT/CG0/CG1/CPU-filler
				-- window, not just the real fetch dots within it, so gating on it alone
				-- is coarser than ideal but safe FOR THIS VARIANT specifically: the one
				-- CPU_VRAM_ADDR left stale from setup sits at SATB_BASE+.. (>=32512),
				-- outside both the BAT (0..2047) and BG-CG (2048..3071) ranges, so a
				-- stale idle-CPU read can never masquerade as a BAT/CG0/CG1 access here.
				-- SATB is separately gated on DMAS_EXEC (a stale idle-CPU address CAN
				-- coincidentally fall inside the SATB range -- confirmed via a real GHDL
				-- run that miscounted ~135k such reads as "SATB" before this fix).
				-- BAT arm carve-out: huc6270.vhd's NOP filler dot re-presents a stale
				-- RAM_A that idles at exactly x"0000" every 8-dot tile loop (one NOP
				-- dot/tile), and word 0 is also BAT's own real hardware-fixed base
				-- (BG_RAM_ADDR's "0000" prefix -- no relocatable BAT base register
				-- exists, confirmed by RTL inspection, so BAT_BASE=0 above is correct
				-- and cannot be moved to dodge this). The two cases are
				-- indistinguishable by address alone at addr=0 specifically.
				--
				-- SECOND, LARGER carve-out found while building the within-scanline STRIDE
				-- measurement below (real GHDL trace, not guessed): classify()'s region
				-- split is a pure address-range test (BAT=0..2047, CG=2048..3071), which
				-- silently assumes a real CG fetch address (BG_BAT_CC*16 + row) always
				-- lands >=2048 -- true only because this TB's own BAT upload always uses
				-- tile_num in 128..191 (see the upload loop below), giving BG_BAT_CC*16 >=
				-- 2048 for every INTENDED tile. But vram0_cache.vhd's own documented,
				-- unfixed Bug 2 ("the cache never actually populates for pure reads" --
				-- see this scratchpad's report) means a real BAT tile-map read can come
				-- back stale/never-installed = 0 instead of the real uploaded value,
				-- which then drives a CG fetch computed from BG_BAT_CC=0 -- landing at
				-- address (0*16+row) or (0*16+8+row), i.e. some value in 0..15 -- squarely
				-- inside BAT's own address range and therefore misclassified as a BAT
				-- fetch by address alone. Confirmed via a real per-scanline GHDL dump
				-- (scanline 180): the real monotonic BAT run (e.g. addr 448,449,450,451,
				-- 452,453,...) had addr=5 and addr=13 (exactly row and row+8 for that
				-- scanline's BG_OFS_Y(2:0)=5) interleaved in TWICE per real fetch,
				-- corrupting the region's own within-scanline address sequence though
				-- NOT the CG0/CG1 regions (a real CG fetch from a corrupted-to-0 tile
				-- number can only ever land in 0..15, never inside CG0/CG1's own
				-- 2048..3071 range -- so CG0/CG1's numbers below are unaffected by this).
				-- Excluding addr<16 (not just addr=0) removes this whole phantom
				-- population; the only real cost is the pre-existing, already-disclosed
				-- ~1 real BAT fetch/scanline lost when a genuine x_tile in 0..15 of row 0
				-- of the map (address 0..15) is fetched (row 0 only, not every scanline --
				-- see BAT_BASE note above), same order of undercount as the original
				-- addr=0-only carve-out this replaces.
				is_real := (dbg_bg_fetch = '1' and region = 0 and unsigned(reqaddr_e) >= 16)
					or (dbg_bg_fetch = '1' and (region = 1 or region = 2))
					or (dbg_spr_fetch_en = '1' and region >= 4 and region <= 19)
					or (dbg_dmas_exec = '1' and region = 3);
				if is_real then
					touch(idxv)(region) := '1';
					if reqwr_e = '1' then
						wrs := wrs + 1;
					else
						tot := tot + 1;
						g_rtot(region) := g_rtot(region) + 1;
						if hit_e = '1' then
							hits := hits + 1;
							g_rhit(region) := g_rhit(region) + 1;
						else
							misses := misses + 1;
						end if;
						-- Within-scanline consecutive-fetch same-line tracking (new): compare
						-- this real read's idx against the immediately-preceding real read's
						-- idx FOR THIS SAME REGION, in real fetch order. pair_last(region)=-1
						-- means "no prior real read of this region yet this scanline" (either
						-- the very first one, or right after an hsync_f reset) -- correctly
						-- excluded from the pair count (a pair needs two fetches).
						if pair_last(region) /= -1 then
							pairs_checked_sl(region) := pairs_checked_sl(region) + 1;
							if pair_last(region) = idxv then
								pairs_same_sl(region) := pairs_same_sl(region) + 1;
							end if;
						end if;
						pair_last(region) := idxv;
					end if;
				else
					idle := idle + 1;
				end if;
			end if;

			if measuring = '1' and hsync_f = '1' then
				alias_idx := 0;
				region_distinct := (others => 0);
				for i in 0 to 511 loop
					if popcount(touch(i)) > 1 then
						alias_idx := alias_idx + 1;
					end if;
					for r in 0 to 20 loop
						if touch(i)(r) = '1' then
							region_distinct(r) := region_distinct(r) + 1;
						end if;
					end loop;
					touch(i) := (others => '0');
				end loop;
				-- fold this scanline's within-scanline consecutive-pair and distinct-line
				-- counts into the grand totals, then reset all per-scanline state so no
				-- pair/line-set ever spans a scanline boundary.
				for r in 0 to 20 loop
					g_pairs_checked(r) := g_pairs_checked(r) + pairs_checked_sl(r);
					g_pairs_same(r)    := g_pairs_same(r) + pairs_same_sl(r);
					if region_distinct(r) > 0 then
						g_distinct_sum(r)  := g_distinct_sum(r) + region_distinct(r);
						g_active_lines(r)  := g_active_lines(r) + 1;
					end if;
					pairs_checked_sl(r) := 0;
					pairs_same_sl(r)    := 0;
					pair_last(r)        := -1;
				end loop;
				report "SCANLINE " & integer'image(scanline) &
					" reads=" & integer'image(tot) &
					" hits=" & integer'image(hits) &
					" misses=" & integer'image(misses) &
					" writes=" & integer'image(wrs) &
					" idle=" & integer'image(idle) &
					" alias_idx=" & integer'image(alias_idx) &
					" | dbg rc=" & integer'image(to_integer(dbg_rc_cnt)) &
					" disp=" & integer'image(to_integer(dbg_disp_cnt)) &
					" vdisp=" & std_logic'image(dbg_vdisp) &
					" find=" & std_logic'image(dbg_spr_find) &
					" fen=" & std_logic'image(dbg_spr_fetch_en) &
					" evalcnt=" & integer'image(to_integer(dbg_spr_eval_cnt)) &
					" spry=" & integer'image(to_integer(unsigned(dbg_spr_y))) &
					" speval=" & std_logic'image(dbg_spr_eval);
				g_tot := g_tot + tot;
				g_hits := g_hits + hits;
				g_misses := g_misses + misses;
				g_wrs := g_wrs + wrs;
				g_alias := g_alias + alias_idx;
				g_idle := g_idle + idle;
				g_lines := g_lines + 1;
				scanline := scanline + 1;
				tot := 0; hits := 0; misses := 0; wrs := 0; idle := 0;

				-- Periodic STRIDE-CKPT checkpoint (every 20 scanlines): a crash-survival
				-- safety net for tb_spr.vhd's known reachable RTL bounds crash
				-- (huc6270.vhd:1082, see file header) -- GHDL aborts the WHOLE simulation
				-- on that error, so the final "=== WITHIN-SCANLINE STRIDE ===" block below
				-- (gated on measuring going back to '0', which never happens if the sim
				-- aborts mid-window) would otherwise be lost entirely. These checkpoints
				-- carry the real cumulative counts up to the last completed scanline, so
				-- even a crash mid-run leaves a usable, real (not estimated) result.
				if scanline mod 20 = 0 then
					for r in 0 to 20 loop
						if g_pairs_checked(r) > 0 or g_active_lines(r) > 0 then
							report "STRIDE-CKPT@" & integer'image(scanline) & " " &
								region_name(r) &
								" pairs_checked=" & integer'image(g_pairs_checked(r)) &
								" pairs_same_line=" & integer'image(g_pairs_same(r)) &
								" permille_same_line=" &
								integer'image(pct1000(g_pairs_same(r), g_pairs_checked(r))) &
								" active_scanlines=" & integer'image(g_active_lines(r)) &
								" distinct_lines_sum=" & integer'image(g_distinct_sum(r)) &
								" avg_distinct_lines_x1000=" &
								integer'image(pct1000(g_distinct_sum(r), g_active_lines(r)));
						end if;
					end loop;
				end if;
			end if;

			if was_measuring = '1' and measuring = '0' then
				report "=== GRAND TOTAL over " & integer'image(g_lines) & " scanlines ===";
				report "reads=" & integer'image(g_tot) &
					" hits=" & integer'image(g_hits) &
					" misses=" & integer'image(g_misses) &
					" writes=" & integer'image(g_wrs) &
					" idle_excluded=" & integer'image(g_idle) &
					" sum_alias_idx=" & integer'image(g_alias);
				for r in 0 to 20 loop
					if g_rtot(r) > 0 then
						report "REGION " & region_name(r) &
							" reads=" & integer'image(g_rtot(r)) &
							" hits=" & integer'image(g_rhit(r)) &
							" misses=" & integer'image(g_rtot(r) - g_rhit(r));
					end if;
				end loop;
				report "=== WITHIN-SCANLINE STRIDE/SAME-LINE MEASUREMENT ===";
				for r in 0 to 20 loop
					if g_pairs_checked(r) > 0 or g_active_lines(r) > 0 then
						report "STRIDE " & region_name(r) &
							" pairs_checked=" & integer'image(g_pairs_checked(r)) &
							" pairs_same_line=" & integer'image(g_pairs_same(r)) &
							" permille_same_line=" &
							integer'image(pct1000(g_pairs_same(r), g_pairs_checked(r))) &
							" active_scanlines=" & integer'image(g_active_lines(r)) &
							" distinct_lines_sum=" & integer'image(g_distinct_sum(r)) &
							" avg_distinct_lines_x1000=" &
							integer'image(pct1000(g_distinct_sum(r), g_active_lines(r)));
					end if;
				end loop;
				report "=== DEADLINE MISS (dbg_deadline_miss) MEASUREMENT ===";
				report "deadline_misses_total=" & integer'image(g_dmiss_total);
				for r in 0 to 20 loop
					if g_dmiss_region(r) > 0 or g_rtot(r) > 0 then
						report "DMISS " & region_name(r) &
							" misses=" & integer'image(g_dmiss_region(r)) &
							" real_reads=" & integer'image(g_rtot(r)) &
							" permille_of_real_reads=" &
							integer'image(pct1000(g_dmiss_region(r), g_rtot(r)));
					end if;
				end loop;
			end if;
			was_measuring := measuring;
		end if;
	end process;

	------------------------------------------------------------- Q_A CORRECTNESS CHECK (new)
	-- Answers the question the deadline-miss report explicitly left open: when
	-- dbg_deadline_miss fires, is q_a (the actual data huc6270 latches as RAM_DI) ever
	-- VISIBLY wrong, or does the "late" refill still land correct data in time despite
	-- missing this instrumentation's own deadline signal (or vice versa -- does q_a ever
	-- go wrong WITHOUT dbg_deadline_miss firing)? Method: reconstruct, from the SAME
	-- upload formulas the drv process used (bi/ci -> bat_word/cg_word, see
	-- expected_value() above), the known-correct value for every real BAT/CG0/CG1
	-- address, and compare against a HISTORY of the actual q_a (=ram_di, the signal
	-- wired to vram0_cache's q_a port, `q_a => ram_di` in the port map above -- the
	-- literal value huc6270 reads as RAM_DI, not an internal cache probe) taken at a
	-- range of candidate cycle offsets relative to this access's own req_valid_d capture
	-- -- rather than hand-deriving which single offset is "the real consuming cycle"
	-- (this session's own report already caught one hand-derived timing formula that was
	-- off by ~1 cycle from real GHDL behavior, and a second manual attempt at re-deriving
	-- q_a's exact pipeline offset for THIS check produced two different, mutually
	-- contradictory answers before this sweep-and-calibrate approach replaced both). The
	-- correct offset shows near-0% mismatch on HIT accesses (where no refill is ever in
	-- flight, so q_a is uncontroversially correct by construction, hit or not) -- see the
	-- report for which offset that turned out to be and the real numbers read off that
	-- row.
	qa_check : process (CLK)
		constant HIST_DEPTH : integer := 10;
		type hist_t is array (0 to HIST_DEPTH-1) of std_logic_vector(15 downto 0);
		variable hist : hist_t := (others => (others => '0'));

		-- Shadow reference model: mirrors the mock SDRAM's own REAL committed content,
		-- built live from dbg_wr_commit/dbg_wr_addr/dbg_wr_data (see their declaration-site
		-- comment) rather than re-derived from the drv process's upload formula -- immune
		-- to the real, empirically-confirmed setup-time write/address skew described there.
		type shadow_mem_t is array (0 to 32767) of std_logic_vector(15 downto 0);
		variable shadow_mem : shadow_mem_t := (others => (others => '0'));

		type region_arr_t is array (0 to 20) of integer;
		type off_region_arr_t is array (0 to HIST_DEPTH-1) of region_arr_t;
		variable cal_reg_checked, cal_reg_wrong : off_region_arr_t := (others => (others => 0));
		type off_int_t is array (0 to HIST_DEPTH-1) of integer;
		variable cal_hit_checked, cal_hit_wrong : off_int_t := (others => 0);

		type bool_arr_t is array (0 to HIST_DEPTH-1) of boolean;
		variable pend_valid  : boolean := false;
		variable pend_region : integer := 20;
		variable pend_addr_v : std_logic_vector(14 downto 0) := (others => '0');
		variable pend_wrong  : bool_arr_t;

		type xt_counts_t is array (0 to HIST_DEPTH-1) of region_arr_t;
		variable xt_dm_wrong, xt_dm_right, xt_ndm_wrong, xt_ndm_right : xt_counts_t := (others => (others => 0));
		variable xt_addr_mismatch : integer := 0;   -- sanity counter, see report

		variable prev_rp2 : std_logic := '0';
		variable region_v, addr_v : integer;
		variable expected_v : std_logic_vector(15 downto 0);
		variable is_real_v, is_read_v : boolean;
		variable was_measuring2 : std_logic := '0';
		variable ckpt_scanline : integer := 0;
	begin
		if rising_edge(CLK) then
			-- Shadow reference model update: runs UNCONDITIONALLY (not gated on measuring),
			-- since all real BAT/CG0/CG1 content is committed during setup, before the
			-- measurement window ever starts.
			if dbg_wr_commit = '1' then
				shadow_mem(to_integer(unsigned(dbg_wr_addr))) := dbg_wr_data;
			end if;

			if measuring = '1' then
				-- Shift the q_a (=ram_di) history: hist(0) = this cycle's value, hist(k) =
				-- k cycles ago.
				for i in HIST_DEPTH-1 downto 1 loop
					hist(i) := hist(i-1);
				end loop;
				hist(0) := ram_di;

				-- Resolution of a previously-tracked outstanding miss: refill_pending_e's
				-- own falling edge marks EITHER a give-up (dbg_deadline_miss='1' the same
				-- cycle, see vram0_cache.vhd's cache_ctrl -- both driven off the identical
				-- pre-edge dck_ce/refill_pending pair) or a natural completion
				-- (dbg_deadline_miss='0' that cycle). Checked BEFORE a same-cycle new-miss
				-- capture below can overwrite pend_* (both CAN coincide on the same cycle
				-- -- the give-up/resolution of access N and the req_valid_d capture of
				-- access N+1 are driven off the identical dck_ce edge, see report).
				if prev_rp2 = '1' and refill_pending_e = '0' then
					if pend_valid then
						if refill_addr_e /= pend_addr_v then
							xt_addr_mismatch := xt_addr_mismatch + 1;
						end if;
						for off in 0 to HIST_DEPTH-1 loop
							if dbg_deadline_miss = '1' then
								if pend_wrong(off) then
									xt_dm_wrong(off)(pend_region) := xt_dm_wrong(off)(pend_region) + 1;
								else
									xt_dm_right(off)(pend_region) := xt_dm_right(off)(pend_region) + 1;
								end if;
							else
								if pend_wrong(off) then
									xt_ndm_wrong(off)(pend_region) := xt_ndm_wrong(off)(pend_region) + 1;
								else
									xt_ndm_right(off)(pend_region) := xt_ndm_right(off)(pend_region) + 1;
								end if;
							end if;
						end loop;
					end if;
					pend_valid := false;
				end if;
				prev_rp2 := refill_pending_e;

				-- New real BAT/CG0/CG1 READ access: same is_real gating as the existing
				-- mon process's BAT/CG0/CG1 arms (SATB/sprite arms dropped -- no
				-- known-content source reused here, out of scope for this check).
				if reqvalid_e = '1' then
					addr_v   := to_integer(unsigned(reqaddr_e));
					region_v := classify(addr_v);
					is_real_v := (dbg_bg_fetch = '1' and region_v = 0 and addr_v >= 16)
						or (dbg_bg_fetch = '1' and (region_v = 1 or region_v = 2));
					is_read_v := (reqwr_e = '0');
					if is_real_v and is_read_v then
						expected_v := shadow_mem(addr_v);
						for off in 0 to HIST_DEPTH-1 loop
							cal_reg_checked(off)(region_v) := cal_reg_checked(off)(region_v) + 1;
							if hist(off) /= expected_v then
								cal_reg_wrong(off)(region_v) := cal_reg_wrong(off)(region_v) + 1;
							end if;
							if hit_e = '1' then
								cal_hit_checked(off) := cal_hit_checked(off) + 1;
								if hist(off) /= expected_v then
									cal_hit_wrong(off) := cal_hit_wrong(off) + 1;
								end if;
							end if;
						end loop;
						if hit_e = '0' then
							pend_valid  := true;
							pend_region := region_v;
							pend_addr_v := reqaddr_e;
							for off in 0 to HIST_DEPTH-1 loop
								pend_wrong(off) := (hist(off) /= expected_v);
							end loop;
						end if;
					end if;
				end if;

				-- Periodic checkpoint (every 100 scanlines) -- crash-survival safety net,
				-- same rationale as `mon`'s own STRIDE-CKPT, and lets a human sanity-check
				-- the calibration is converging sanely long before the full run finishes.
				if hsync_f = '1' then
					ckpt_scanline := ckpt_scanline + 1;
					if ckpt_scanline mod 100 = 0 then
						report "QACAL-CKPT@" & integer'image(ckpt_scanline) &
							" xt_addr_mismatch=" & integer'image(xt_addr_mismatch);
						for off in 0 to HIST_DEPTH-1 loop
							report "  off=" & integer'image(off) &
								" hit_checked=" & integer'image(cal_hit_checked(off)) &
								" hit_wrong=" & integer'image(cal_hit_wrong(off)) &
								" permille_wrong=" & integer'image(pct1000(cal_hit_wrong(off), cal_hit_checked(off)));
						end loop;
					end if;
				end if;
			end if;

			if was_measuring2 = '1' and measuring = '0' then
				report "=== Q_A CORRECTNESS CHECK (candidate offsets, pick the one with ~0% HIT mismatch) ===";
				report "xt_addr_mismatch (sanity, should be 0) = " & integer'image(xt_addr_mismatch);
				for off in 0 to HIST_DEPTH-1 loop
					report "QACAL off=" & integer'image(off) &
						" hit_checked=" & integer'image(cal_hit_checked(off)) &
						" hit_wrong=" & integer'image(cal_hit_wrong(off)) &
						" permille_wrong=" & integer'image(pct1000(cal_hit_wrong(off), cal_hit_checked(off)));
				end loop;
				for off in 0 to HIST_DEPTH-1 loop
					for r in 0 to 2 loop
						if cal_reg_checked(off)(r) > 0 then
							report "QAREG off=" & integer'image(off) & " " & region_name(r) &
								" checked=" & integer'image(cal_reg_checked(off)(r)) &
								" wrong=" & integer'image(cal_reg_wrong(off)(r)) &
								" permille_wrong=" & integer'image(pct1000(cal_reg_wrong(off)(r), cal_reg_checked(off)(r)));
						end if;
					end loop;
				end loop;
				for off in 0 to HIST_DEPTH-1 loop
					for r in 0 to 2 loop
						if xt_dm_wrong(off)(r) + xt_dm_right(off)(r) + xt_ndm_wrong(off)(r) + xt_ndm_right(off)(r) > 0 then
							report "QAXTAB off=" & integer'image(off) & " " & region_name(r) &
								" dm_wrong=" & integer'image(xt_dm_wrong(off)(r)) &
								" dm_right=" & integer'image(xt_dm_right(off)(r)) &
								" ndm_wrong=" & integer'image(xt_ndm_wrong(off)(r)) &
								" ndm_right=" & integer'image(xt_ndm_right(off)(r));
						end if;
					end loop;
				end loop;
			end if;
			was_measuring2 := measuring;
		end if;
	end process;

	------------------------------------------------------------- CG-EXTENSION CORRECTNESS CHECK
	-- Answers the task's own headline question for G_CG_PREFETCH: for every REAL access
	-- (reqvalid_e='1', a genuine read, same-cycle gating already validated by qa_check's
	-- own off=0/1 giving hit_checked=66739/hit_wrong=0 against the real, un-buffered
	-- vram0_cache baseline above) where dbg_cg_hit was ALSO asserted THAT SAME CYCLE, is
	-- the delivered q_a (=ram_di) byte-identical to a correct, un-buffered read of that
	-- exact address? Ground truth is the same live shadow_mem technique qa_check above
	-- already uses -- generalized here to check on dbg_cg_hit specifically rather than
	-- classify()-restricted regions, per the task's own instruction.
	--
	-- WHY SAME-CYCLE, NOT A SEPARATE OFFSET SWEEP ON dbg_cg_hit ITSELF: an earlier version
	-- of this process swept a raw address_a shift register against dbg_cg_hit directly
	-- (unconditional on reqvalid_e) and got a nonsensical ~90% "address mismatch" rate at
	-- every candidate offset -- traced to dbg_cg_hit being a REGISTERED signal that stays
	-- asserted for the entire multi-cycle inter-DCK_CE dwell (vram0_prefetch.vhd's `match`
	-- process runs every clock, not gated to dck_ce), so most cycles it's high are NOT the
	-- one real per-access cycle reqvalid_e/reqaddr_e/ram_di are all defined at -- checking
	-- dbg_cg_hit unconditionally counts the same real access many times over and compares
	-- it against address_a samples that have since drifted across dwell boundaries. Gating
	-- on reqvalid_e='1' (exactly qa_check's own already-proven-correct discipline) fixes
	-- this: at that one cycle per real access, ram_di/reqaddr_e/hit_e are ALL guaranteed
	-- (by the empirical off=0 baseline match) to refer to the SAME originating address_a,
	-- and vram0_prefetch.vhd's own header claims its match pipeline has the "same total
	-- depth" as vram0_cache's req_addr_d->hit->q_a_i chain -- so dbg_cg_hit sampled at that
	-- SAME cycle should refer to the SAME access too. A small backward-looking sanity
	-- sweep (off 0..-3 on a short dbg_cg_hit history) is kept below to empirically confirm
	-- off=0 really is the right alignment rather than trusting the claim blindly.
	------------------------------------------------------------- ROOT-CAUSE DUMP: hit_e-gated wrong
	-- qa_check above (unchanged, already-validated methodology) reports a nonzero
	-- hit_wrong count (QACAL) when G_CG_PREFETCH=true that reads exactly 0 in the
	-- G_CG_PREFETCH=false baseline -- a real regression signal independent of dbg_cg_hit's
	-- own alignment. This process mirrors qa_check's exact off=0 check (hit_e/reqvalid_e/
	-- reqaddr_e/is_real_v, unchanged) and dumps full context for every wrong instance, to
	-- find out whether it's a genuine CG-buffer-caused corruption or a coincidental
	-- artifact this specific harness introduces.
	hitwrong_dump : process (CLK)
		type shadow_mem_t is array (0 to 32767) of std_logic_vector(15 downto 0);
		variable shadow_mem : shadow_mem_t := (others => (others => '0'));
		variable addr_v : integer;
		variable region_v : integer;
		variable is_real_v : boolean;
		variable expected_v : std_logic_vector(15 downto 0);
		variable n : integer := 0;
		-- Recent history of seq_is_pf/wren_a (raw ram_we, the live write-enable
		-- vram0_cache itself sees), to check whether a HITWRONG cycle correlates with
		-- concurrent pf (CG-fetch) byte_seq traffic or a live write racing the same
		-- refill-install window (refill_can_install's own "and not wren_a" term).
		constant CTX_DEPTH : integer := 8;
		type ctx_sl_t is array (0 to CTX_DEPTH-1) of std_logic;
		variable seqpf_hist, wren_hist : ctx_sl_t := (others => '0');
		variable seqpf_s, wren_s : string(1 to CTX_DEPTH);
	begin
		if rising_edge(CLK) then
			if dbg_wr_commit = '1' then
				shadow_mem(to_integer(unsigned(dbg_wr_addr))) := dbg_wr_data;
			end if;
			for i in CTX_DEPTH-1 downto 1 loop
				seqpf_hist(i) := seqpf_hist(i-1);
				wren_hist(i)  := wren_hist(i-1);
			end loop;
			seqpf_hist(0) := dbg_seq_is_pf;
			wren_hist(0)  := ram_we;
			if measuring = '1' and reqvalid_e = '1' then
				addr_v := to_integer(unsigned(reqaddr_e));
				region_v := classify(addr_v);
				is_real_v := (dbg_bg_fetch = '1' and region_v = 0 and addr_v >= 16)
					or (dbg_bg_fetch = '1' and (region_v = 1 or region_v = 2));
				if is_real_v and reqwr_e = '0' and hit_e = '1' then
					expected_v := shadow_mem(addr_v);
					if ram_di /= expected_v and n < 30 then
						for i in 0 to CTX_DEPTH-1 loop
							if seqpf_hist(i) = '1' then seqpf_s(i+1) := '1'; else seqpf_s(i+1) := '0'; end if;
							if wren_hist(i)  = '1' then wren_s(i+1)  := '1'; else wren_s(i+1)  := '0'; end if;
						end loop;
						report "HITWRONG#" & integer'image(n) &
							" addr=" & to_hstring(reqaddr_e) &
							" region=" & region_name(region_v) &
							" ram_di=" & to_hstring(ram_di) &
							" ds_q_a=" & to_hstring(ds_q_a) &
							" expected=" & to_hstring(expected_v) &
							" dbg_cg_hit=" & std_logic'image(dbg_cg_hit) &
							" dbg_pf_hit=" & std_logic'image(dbg_pf_hit) &
							" dbg_deadline_miss=" & std_logic'image(dbg_deadline_miss) &
							" refill_pending=" & std_logic'image(refill_pending_e) &
							" cur_cg_row=" & to_hstring(std_logic_vector(dbg_cur_cg_row_e)) &
							" cg_done=" & std_logic'image(dbg_cg_done_e) &
							" ofsy=" & to_hstring(ofs_y_dbg_s) &
							" byr=" & to_hstring(byr_dbg_s) &
							" screen=" & to_hstring(screen_dbg_s) &
							" seqpf_hist(new..old)=" & seqpf_s &
							" wren_hist(new..old)=" & wren_s;
						n := n + 1;
					end if;
				end if;
			end if;
		end if;
	end process;

	cg_check : process (CLK)
		type shadow_mem_t is array (0 to 32767) of std_logic_vector(15 downto 0);
		variable shadow_mem : shadow_mem_t := (others => (others => '0'));

		-- Backward-looking dbg_cg_hit history: cg_hit_hist(0) = dbg_cg_hit this cycle,
		-- cg_hit_hist(k) = dbg_cg_hit k cycles ago.
		constant CG_HIST_DEPTH : integer := 4;
		type cg_hist_t is array (0 to CG_HIST_DEPTH-1) of std_logic;
		variable cg_hit_hist : cg_hist_t := (others => '0');

		type off_int_t is array (0 to CG_HIST_DEPTH-1) of integer;
		variable cg_checked, cg_wrong : off_int_t := (others => 0);

		-- Headline (off=0, same-cycle) tallies, split by stress window.
		variable cg_checked_byr,    cg_wrong_byr    : integer := 0;
		variable cg_checked_screen, cg_wrong_screen : integer := 0;
		variable cg_checked_steady, cg_wrong_steady : integer := 0;

		-- Overrun-window cross-check (Step 3's own explicit ask: every overrun window
		-- really had zero wrong hits, not just the run as a whole). in_overrun_recovery
		-- goes true the cycle dbg_cg_overrun pulses and stays true until cg_done's own
		-- next rising edge (the pass that overran finally completes) -- any real
		-- dbg_cg_hit access occurring in that span is tallied separately.
		variable in_overrun_recovery : boolean := false;
		variable prev_cg_done : std_logic := '1';
		variable cg_checked_overrun, cg_wrong_overrun : integer := 0;
		variable overrun_windows_total : integer := 0;

		variable expected_v : std_logic_vector(15 downto 0);
		variable addr_i      : integer;
		variable is_wrong    : boolean;
		variable region_v    : integer;
		variable is_real_v   : boolean;
		variable was_measuring4 : std_logic := '0';
		variable ckpt_scanline4 : integer := 0;
		variable n_wrong_dump : integer := 0;
	begin
		if rising_edge(CLK) then
			-- Shadow reference model, same as qa_check's own (kept as a separate local
			-- copy so this process is fully self-contained/independently auditable).
			if dbg_wr_commit = '1' then
				shadow_mem(to_integer(unsigned(dbg_wr_addr))) := dbg_wr_data;
			end if;

			-- dbg_cg_hit history shift register (backward-looking sanity sweep only).
			for i in CG_HIST_DEPTH-1 downto 1 loop
				cg_hit_hist(i) := cg_hit_hist(i-1);
			end loop;
			cg_hit_hist(0) := dbg_cg_hit;

			-- Overrun-window bookkeeping (unconditional on `measuring` so a window that
			-- straddles the measurement boundary is still tracked correctly; only the
			-- CHECKED/WRONG tallies themselves are gated on measuring, below).
			if dbg_cg_overrun = '1' then
				in_overrun_recovery := true;
				overrun_windows_total := overrun_windows_total + 1;
			end if;
			if prev_cg_done = '0' and dbg_cg_done_e = '1' then
				in_overrun_recovery := false;
			end if;
			prev_cg_done := dbg_cg_done_e;

			-- Same is_real_v gate as qa_check's own (see that process's header for the
			-- full derivation): dbg_bg_fetch='1' AND (a genuine BAT read with addr>=16,
			-- dodging the NOP-filler phantom-address-0 artifact documented at length in
			-- `mon`'s own BAT arm carve-out comment, OR a genuine CG0/CG1 read). Without
			-- this gate, idle/CPU-filler dots that happen to re-present a stale address
			-- landing inside the buffer's own content-addressable range are miscounted
			-- as "wrong hits" even though huc6270 never actually consumes RAM_DI on
			-- those dots -- confirmed via this session's own CGWRONG dump below (every
			-- early "wrong" hit before this gate was added was addr=0000, region=BAT,
			-- exactly that known artifact, not a real CG0/CG1 access at all).
			if measuring = '1' and reqvalid_e = '1' and reqwr_e = '0' then
				addr_i := to_integer(unsigned(reqaddr_e));
				region_v := classify(addr_i);
				is_real_v := (dbg_bg_fetch = '1' and region_v = 0 and addr_i >= 16)
					or (dbg_bg_fetch = '1' and (region_v = 1 or region_v = 2));
			else
				is_real_v := false;
			end if;

			if is_real_v then
				expected_v := shadow_mem(addr_i);
				is_wrong := (ram_di /= expected_v);

				-- Backward-looking sanity sweep: off=0 is the headline alignment: does
				-- dbg_cg_hit sampled at this SAME cycle explain a CG-buffer-served
				-- access? off=1..3 check whether an EARLIER dbg_cg_hit sample would have
				-- fit better (it shouldn't, if the module's own "matching depth" claim
				-- and qa_check's own off=0 baseline alignment both hold).
				for off in 0 to CG_HIST_DEPTH-1 loop
					if cg_hit_hist(off) = '1' then
						cg_checked(off) := cg_checked(off) + 1;
						if is_wrong then
							cg_wrong(off) := cg_wrong(off) + 1;
						end if;
					end if;
				end loop;

				-- Headline (off=0) tallies, split by stress window / overrun-recovery.
				if cg_hit_hist(0) = '1' then
					if stress_byr = '1' then
						cg_checked_byr := cg_checked_byr + 1;
						if is_wrong then cg_wrong_byr := cg_wrong_byr + 1; end if;
					elsif stress_screen = '1' then
						cg_checked_screen := cg_checked_screen + 1;
						if is_wrong then cg_wrong_screen := cg_wrong_screen + 1; end if;
					else
						cg_checked_steady := cg_checked_steady + 1;
						if is_wrong then cg_wrong_steady := cg_wrong_steady + 1; end if;
					end if;

					if in_overrun_recovery then
						cg_checked_overrun := cg_checked_overrun + 1;
						if is_wrong then cg_wrong_overrun := cg_wrong_overrun + 1; end if;
					end if;

					-- ROOT-CAUSE DUMP: full internal-state snapshot for the first several
					-- wrong CG hits, to distinguish a real RTL bug from a checker/timing
					-- artifact.
					if is_wrong and n_wrong_dump < 30 then
						report "CGWRONG#" & integer'image(n_wrong_dump) &
							" addr=" & to_hstring(reqaddr_e) &
							" region=" & region_name(classify(addr_i)) &
							" ram_di=" & to_hstring(ram_di) &
							" expected=" & to_hstring(expected_v) &
							" hit_e=" & std_logic'image(hit_e) &
							" dbg_deadline_miss=" & std_logic'image(dbg_deadline_miss) &
							" stress_byr=" & std_logic'image(stress_byr) &
							" stress_screen=" & std_logic'image(stress_screen) &
							" cur_cg_row=" & to_hstring(std_logic_vector(dbg_cur_cg_row_e)) &
							" pending_cg_row=" & to_hstring(std_logic_vector(dbg_pending_cg_row_e)) &
							" cg_done=" & std_logic'image(dbg_cg_done_e) &
							" cg_i=" & integer'image(dbg_cg_i_e) &
							" ofsy=" & to_hstring(ofs_y_dbg_s) &
							" byr=" & to_hstring(byr_dbg_s) &
							" screen=" & to_hstring(screen_dbg_s);
						n_wrong_dump := n_wrong_dump + 1;
					end if;
				end if;
			end if;

			if measuring = '1' and hsync_f = '1' then
				ckpt_scanline4 := ckpt_scanline4 + 1;
				if ckpt_scanline4 mod 100 = 0 then
					report "CGCAL-CKPT@" & integer'image(ckpt_scanline4);
					for off in 0 to CG_HIST_DEPTH-1 loop
						report "  off=" & integer'image(off) &
							" cg_hit_checked=" & integer'image(cg_checked(off)) &
							" cg_hit_wrong=" & integer'image(cg_wrong(off));
					end loop;
				end if;
			end if;

			if was_measuring4 = '1' and measuring = '0' then
				report "=== CG-EXTENSION CORRECTNESS CHECK (backward sanity sweep) ===";
				for off in 0 to CG_HIST_DEPTH-1 loop
					report "CGCAL off=" & integer'image(off) &
						" cg_hit_checked=" & integer'image(cg_checked(off)) &
						" cg_hit_wrong=" & integer'image(cg_wrong(off));
				end loop;
				report "=== CG-EXTENSION HEADLINE (off=0) STRESS-WINDOW BREAKDOWN ===";
				report "STEADY  cg_hit_checked=" & integer'image(cg_checked_steady) &
					" cg_hit_wrong=" & integer'image(cg_wrong_steady);
				report "STRESS_BYR    cg_hit_checked=" & integer'image(cg_checked_byr) &
					" cg_hit_wrong=" & integer'image(cg_wrong_byr);
				report "STRESS_SCREEN cg_hit_checked=" & integer'image(cg_checked_screen) &
					" cg_hit_wrong=" & integer'image(cg_wrong_screen);
				report "=== CG-EXTENSION OVERRUN-WINDOW CROSS-CHECK ===";
				report "overrun_windows_total=" & integer'image(overrun_windows_total) &
					" cg_hit_checked_during_overrun_recovery=" & integer'image(cg_checked_overrun) &
					" cg_hit_wrong_during_overrun_recovery=" & integer'image(cg_wrong_overrun);
			end if;
			was_measuring4 := measuring;
		end if;
	end process;

	------------------------------------------------------------- VALIDATION-ONLY: dwell width
	-- and real refill_pending rise-to-fall cycle count (advisor-directed, see report).
	-- Not part of the deadline-miss measurement itself -- purely to confirm the header's
	-- hand-derived timing model (dwell width in CLK cycles between consecutive
	-- vdc_clken='1' pulses; refill rise-to-fall = B+6) against real GHDL behavior before
	-- trusting any conclusion drawn from it.
	valid_mon : process (CLK)
		variable since_clken : integer := 0;
		variable dwell_reports : integer := 0;
		variable prev_rp : std_logic := '0';
		variable since_rp : integer := 0;
		variable rp_reports : integer := 0;
	begin
		if rising_edge(CLK) then
			if measuring = '1' then
				since_clken := since_clken + 1;
				if vdc_clken = '1' then
					if dwell_reports < 40 then
						report "DWELL cycles_since_prev_clken=" & integer'image(since_clken);
						dwell_reports := dwell_reports + 1;
					end if;
					since_clken := 0;
				end if;

				if refill_pending_e = '1' then
					since_rp := since_rp + 1;   -- pulse-width cycle count, inclusive
				end if;
				if prev_rp = '1' and refill_pending_e = '0' then
					if rp_reports < 40 then
						report "REFILL_PENDING pulse_width_cycles=" & integer'image(since_rp);
						rp_reports := rp_reports + 1;
					end if;
					since_rp := 0;
				end if;
				prev_rp := refill_pending_e;
			end if;
		end if;
	end process;

	-- TEMP DEBUG: dump pf internals at the first several hsync_f edges, unconditionally
	-- (not gated on `measuring`), to diagnose why cur_supported/pf_hit stayed at 0.
	dbg_probe : process (CLK)
		variable n : integer := 0;
		variable n2 : integer := 0;
		type shadow_mem_t is array (0 to 32767) of std_logic_vector(15 downto 0);
		variable shadow : shadow_mem_t := (others => (others => '0'));
	begin
		if rising_edge(CLK) then
			if dbg_wr_commit = '1' then
				shadow(to_integer(unsigned(dbg_wr_addr))) := dbg_wr_data;
			end if;
			if measuring = '1' and hsync_f = '1' and n < 30 then
				report "PFDBG n=" & integer'image(n) &
					" screen=" & to_hstring(screen_dbg_s) &
					" ofsy=" & to_hstring(ofs_y_dbg_s) &
					" byr=" & to_hstring(byr_dbg_s) &
					" cur_supported=" & std_logic'image(dbg_cur_supported) &
					" pending_supported=" & std_logic'image(dbg_pending_supported) &
					" restart_req=" & std_logic'image(dbg_restart_req) &
					" cur_total=" & integer'image(dbg_cur_total) &
					" burst_i=" & integer'image(dbg_burst_i) &
					" bufvalid=" & to_hstring(dbg_buf_valid) &
					" cur_row=" & to_hstring(std_logic_vector(dbg_cur_row));
				n := n + 1;
			end if;
			if measuring = '1' and reqvalid_e = '1' and classify(to_integer(unsigned(reqaddr_e))) = 0
					and unsigned(reqaddr_e) >= 16 and dbg_bg_fetch = '1' and n2 < 20 then
				report "PFDBG2 addr=" & to_hstring(reqaddr_e) &
					" ram_di=" & to_hstring(ram_di) &
					" expected=" & to_hstring(shadow(to_integer(unsigned(reqaddr_e)))) &
					" hit_e=" & std_logic'image(hit_e);
				n2 := n2 + 1;
			end if;
		end if;
	end process;

	-- TEMP DEBUG: count real pf_req/pf_done/seq_is_pf pulses over the whole run.
	dbg_pf_counters : process (CLK)
		variable n_req, n_done, n_seqpf : integer := 0;
		variable n_addr_x, n_addr_x_bg, n_cycles : integer := 0;
		variable was_m : std_logic := '0';
	begin
		if rising_edge(CLK) then
			if pf_req = '1' then n_req := n_req + 1; end if;
			if pf_done = '1' then n_done := n_done + 1; end if;
			if dbg_seq_is_pf = '1' then n_seqpf := n_seqpf + 1; end if;
			n_cycles := n_cycles + 1;
			if is_x(ram_a(5 downto 0)) then
				n_addr_x := n_addr_x + 1;
				if dbg_bg_fetch = '1' then
					n_addr_x_bg := n_addr_x_bg + 1;
				end if;
			end if;
			if was_m = '1' and measuring = '0' then
				report "PFCOUNT pf_req_cycles=" & integer'image(n_req) &
					" pf_done_pulses=" & integer'image(n_done) &
					" seq_is_pf_cycles=" & integer'image(n_seqpf) &
					" cycles=" & integer'image(n_cycles) &
					" addr_x_cycles=" & integer'image(n_addr_x) &
					" addr_x_bgfetch_cycles=" & integer'image(n_addr_x_bg);
			end if;
			was_m := measuring;
		end if;
	end process;

	------------------------------------------------------------- BAT PREFETCH VARIANT: pf stats
	-- dbg_pf_hit: this cycle's finished (2-cycle-latency) access was served from the
	-- buffer. dbg_pf_overrun: an hsync_f fired before the CURRENT target row's own fill
	-- finished (item 4's real starvation instrumentation, see vram0_prefetch.vhd).
	pf_mon : process (CLK)
		variable n_hit, n_overrun : integer := 0;
		variable n_cg_hit, n_cg_overrun : integer := 0;
		variable was_measuring3 : std_logic := '0';
	begin
		if rising_edge(CLK) then
			if measuring = '1' then
				if dbg_pf_hit = '1' then
					n_hit := n_hit + 1;
				end if;
				if dbg_pf_overrun = '1' then
					n_overrun := n_overrun + 1;
				end if;
				if dbg_cg_hit = '1' then
					n_cg_hit := n_cg_hit + 1;
				end if;
				if dbg_cg_overrun = '1' then
					n_cg_overrun := n_cg_overrun + 1;
				end if;
			end if;
			if was_measuring3 = '1' and measuring = '0' then
				report "=== PREFETCH STATS ===";
				report "pf_hit_total=" & integer'image(n_hit) &
					" pf_overrun_total=" & integer'image(n_overrun) &
					" cg_hit_total=" & integer'image(n_cg_hit) &
					" cg_overrun_total=" & integer'image(n_cg_overrun);
			end if;
			was_measuring3 := measuring;
		end if;
	end process;

	------------------------------------------------------------- diagnostic-only: SATB DMA edges
	dmas_mon : process (CLK)
		variable prev : std_logic := '0';
		variable n : integer := 0;
	begin
		if rising_edge(CLK) then
			if dbg_dmas_exec = '1' and prev = '0' then
				n := n + 1;
				report "DMAS_EXEC start #" & integer'image(n) & " at time now";
			end if;
			prev := dbg_dmas_exec;
		end if;
	end process;

end architecture;
