-- SPDX-License-Identifier: GPL-3.0-or-later
-- Modifications copyright (c) 2026 Romain Tisserand.
-- This file is derived from third-party code and is NOT original work of
-- this project; only the changes made here are covered by the line above.
-- See THIRD_PARTY_LICENSES.md for the upstream project, author and licence.

-- FORKED from upstream/tg16-mister/rtl/pce_top.vhd. One change: a new EXT_VRAM0 generic
-- (default 0, byte-identical to the donor) that, when nonzero, replaces VRAM0's on-chip
-- dpram with src/common/mem/vram0_cache.vhd -- Nano 20K only, see NECTang's docs/PORTING.md's
-- "VRAM0 external memory" section for why (GW2AR-18C can't fit VRAM0 in on-chip BSRAM
-- alongside the rest of the engine) and the design that module implements. Console 60K/
-- Primer 25K leave EXT_VRAM0 at its default and get the exact donor behaviour, unchanged.
--
-- The on-chip path's VRAM0 also clear-sweeps to zero on COLD_RESET via CLR_A/CLR_WE
-- (donor behaviour, unchanged here). vram0_cache.vhd does NOT replicate this: real SDRAM
-- content is undefined at power-on regardless, a full 32K-word external clear-sweep
-- wasn't judged worth the complexity for this pass, and real games initialize the VRAM
-- they use before relying on its content, same as real hardware. A deliberate, documented
-- scope decision, not an oversight -- revisit if it ever turns out to matter.
--
-- SECOND CHANGE (2026-08-27): a new `CD_RAM_RDY` input (default '1', so existing callers
-- are unaffected), ANDed into `WAIT_N` alongside `ROM_RDY`. CD-RAM's own `CD_RAM_DI` has
-- no wait path in the donor -- it muxes into the CPU read path combinationally, same
-- cycle -- because the donor assumes CD-RAM is backed by fast local memory. A board
-- backing it with external SDRAM instead needs to stall the CPU the same way the ROM
-- path already does; see docs/ARCHITECTURE.md's "Real syscard boot" section.
--
-- NOT VERIFIED ON HARDWARE.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.all;

entity pce_top is
	generic (
		LITE : integer := 0;
		-- CD-DA FIFO depth exponent, forwarded to cd.vhd -> CDDA_FIFO. 11 = 2048 entries
		-- (46 ms), 12 = 4096 (93 ms). Depth decides how far cd_bridge may prefetch audio
		-- sectors, and hiding libchdr's ~62 ms hunk decode needs ~5.3 sectors in flight.
		-- Default stays at the current value so no board changes behaviour implicitly.
		CDDA_DEPTH_LOG2 : integer := 11;
		EXT_VRAM0 : integer := 0;
		-- Nano 20K only (default 0 = donor behaviour, CD present, unchanged everywhere
		-- else). CD's ADPCM_DRAM alone measures 32 of GW2AR-18C's 46 BSRAM blocks --
		-- incompatible with this board regardless of VRAM0, confirmed by a real gw_sh
		-- run with EXT_VRAM0=1 and CD still present: fits (barely, 46/46) but drags
		-- MCODE and vram0_cache's own metadata into logic fallback too and leaves 1545
		-- setup violations. See NECTang's docs/PORTING.md's "VRAM0 external memory" section.
		NO_CD : integer := 0;
		-- PCE PORT (2026-09-09): omit the Arcade Card ENTIRELY (default 1 = present,
		-- donor behaviour). This is a BUILD-TIME generic, not the runtime AC_EN port,
		-- and the difference is the whole point: AC_EN only gates the card's EN input,
		-- so with AC_EN='0' the hardware and -- critically -- its LOAD on the CPU's
		-- physical address bus still exist. Post-PnR timing on Console 60K showed
		-- SEVEN of the eight worst setup paths in the whole design running from the
		-- CPU microcode through core/CPU/CORE/MPR_SEL (the MPR bank-register read mux)
		-- into core/AC/port[N].base_*, the Arcade Card's port base registers, with as
		-- little as 0.224 ns slack on a 23.33 ns period -- under 1% margin. 24 of the
		-- 50 reported paths went through MPR_SEL. A plain HuCard never touches the
		-- Arcade Card, so on a HuCard build that load is pure cost on the exact signal
		-- the black-screen investigation has localised the fault to.
		AC_BUILD : integer := 1;
		-- PCE PORT (2026-08-28): 4-word VRAM0 line-refill (see vram0_cache.vhd's own
		-- G_LINE_REFILL generic and sdram.sv's "line refill" header note). Only
		-- meaningful when EXT_VRAM0 /= 0 AND the board's own external controller
		-- actually implements it (sdram.sv does; sdram32.sv/Nano 20K does not).
		-- Defaults to 0 (off) -- every board must opt in explicitly, matching
		-- vram0_cache.vhd's own false-by-default safety rationale (a board with
		-- EXT_VRAM0/=0 but a controller that can't answer a line-refill request would
		-- otherwise silently install all-zero data into every refilled cache line).
		VRAM0_LINE_REFILL : integer := 0;
		-- PCE PORT (2026-08-28): vram0_prefetch.vhd's BAT prefetch engine (see that
		-- file's own header) -- requires VRAM0_LINE_REFILL /= 0 too (gen_vram0_ext
		-- below ANDs them at the vram0_cache instantiation site). Kept as its OWN
		-- generic, separate from VRAM0_LINE_REFILL, deliberately NOT tied to it:
		-- this session only GHDL-verified and gw_sh-checked the prefetch engine on
		-- Primer 25K plain (sdram.sv); Nano 20K (sdram32.sv) already has
		-- VRAM0_LINE_REFILL=>1 from an earlier session's work, and tying this
		-- generic to that one would have silently turned the (unverified-there)
		-- prefetch engine on for Nano 20K too. Defaults to 0 (off) -- every board
		-- must opt in explicitly, same rationale as VRAM0_LINE_REFILL's own.
		VRAM0_PREFETCH : integer := 0;
		-- PCE PORT (2026-08-29): vram0_prefetch.vhd's CG0/CG1 tile-pattern prefetch
		-- extension (see that file's own "G_CG_PREFETCH EXTENSION" header) -- only ever
		-- meaningful chained onto the BAT engine, and structurally can't apply without
		-- it: PREFETCH0 (the only place this generic is read) exists only inside
		-- `gen_vram0_pf: if VRAM0_PREFETCH /= 0 generate` below, so this generic is
		-- implicitly gated by VRAM0_PREFETCH by construction, not by an explicit AND.
		-- Kept as its OWN generic, same "must opt in
		-- explicitly" rationale as VRAM0_PREFETCH's own -- GHDL-verified (real bug
		-- found+fixed, cg_hit_wrong=0 across steady-state/BYR-rewrite/SCREEN-change
		-- stress) and gw_sh-clean on Primer 25K (0.656% clk_pce margin when on, tighter
		-- than the BAT-only baseline but 0 violations) -- not yet measured on every
		-- board that could carry it. Defaults to 0 (off).
		VRAM0_CG_PREFETCH : integer := 0;

		-- PCE PORT (2026-08-30): VRAM1/SGX's own EXT_VRAM0 equivalent -- see that
		-- generic's own comment above for the shared rationale (a board whose engine
		-- doesn't fit VRAM1 on-chip alongside VDC0/VRAM0/CD/Arcade-Card routes VDC1's
		-- own VRAM through an external SDRAM controller's port C instead, via
		-- vram0_cache.vhd -- the SAME entity VRAM0 uses, reused as-is: its interface
		-- (address_a/data_a/wren_a/q_a, ram_a_*) has nothing VDC0-specific in it).
		-- GHDL-verified feasible via a real two-VDC bus-contention testbench
		-- (sim/vram0/tb_sgx_contention.vhd) before this generic existed -- see session
		-- memory for the real numbers. Only meaningful when LITE=0 (SGX enabled) --
		-- gen_vram1_ext below sits inside generate_SGX, so this generic is a no-op on
		-- any LITE=1 board regardless of its own value, same relationship
		-- VRAM0_PREFETCH has to gen_vram0_pf. Defaults to 0 (on-chip dpram, donor
		-- behaviour) so every existing SGX board (Console 60K CD) is unaffected.
		EXT_VRAM1 : integer := 0;
		-- Same real 4-word line-refill mechanism as VRAM0_LINE_REFILL, VDC1's own copy.
		-- Only meaningful when EXT_VRAM1 /= 0 AND the board's own sdram.sv instance
		-- implements it on port C (RAM_C_LINE_REFILL -- see sdram.sv's own header).
		VRAM1_LINE_REFILL : integer := 0;
		-- Same real BAT prefetch engine as VRAM0_PREFETCH, VDC1's own copy (PREFETCH1
		-- below, a second instance of the same vram0_prefetch entity). Required for
		-- correctness, not just performance, on any board that enables EXT_VRAM1 with
		-- VDC1 actively rendering in real time -- without it, VDC1 is exposed to the
		-- exact same deadline-miss corruption class VDC0 had before its own BAT fix
		-- (see vram0_prefetch.vhd's header). Kept as its own opt-in generic anyway,
		-- matching VRAM0_PREFETCH's own precedent, rather than tying it to EXT_VRAM1
		-- directly -- lets a first bring-up pass verify basic wiring/fit before
		-- trusting the prefetch engine's own real-time behaviour on a second VDC.
		VRAM1_PREFETCH : integer := 0;
		-- Same real CG0/CG1 tile-pattern extension as VRAM0_CG_PREFETCH, VDC1's own
		-- copy. Same structural gating as that generic (only meaningful inside
		-- gen_vram1_pf below, which itself only exists when VRAM1_PREFETCH /= 0).
		VRAM1_CG_PREFETCH : integer := 0;
		-- Pass-through to psg.vhd's own VT_PATH_A generic (via HUC6280.vhd) --
		-- see that file's entity header for the real rationale. Default 1
		-- (Path A on, real closed-form VT, -6 BSRAM blocks vs the donor's BRAM
		-- table). Nano 20K CD is the one real, verified exception -- set to 0
		-- there (see pcetang_status_matrix.md lever 19/20's real isolation
		-- record: SF2' widening and PSG Path A each pass clean alone on that
		-- board, but their combination real-fails timing).
		VT_PATH_A : integer := 1;
		-- Pass-through to HUC6280_CPU's DBG_PROBES (via HUC6280.vhd). Default 0.
		-- Only Console 60K's debug build turns these on; they cost real timing.
		DBG_PROBES : integer := 0
	);
	port(
		RESET			: in  std_logic;
		COLD_RESET	: in  std_logic;
		CLK 			: in  std_logic;

		-- Only meaningful when EXT_VRAM0 /= 0 (Nano 20K) -- wired straight to
		-- src/common/mem/sdram32.sv's port A by the board top. Unused/left open on every
		-- other board.
		VRAM0_RAM_A_ADDR : out std_logic_vector(20 downto 0);
		VRAM0_RAM_A_REQ  : out std_logic;
		VRAM0_RAM_A_RD_N : out std_logic;
		VRAM0_RAM_A_DI   : out std_logic_vector(15 downto 0);
		VRAM0_RAM_A_DO   : in  std_logic_vector(15 downto 0) := (others => '0');
		VRAM0_RAM_A_WAIT : in  std_logic := '0';

		-- vram0_cache.vhd's own dbg_deadline_miss/dbg_fifo_overflow, exposed here for the
		-- first time (2026-08-27, per an independent Fable-model audit's P3) -- previously
		-- tied open inside gen_vram0_ext below, invisible to every board top. '0' always
		-- on EXT_VRAM0=0 boards (gen_vram0_onchip, no vram0_cache instance to drive them).
		DBG_DEADLINE_MISS : out std_logic;
		DBG_FIFO_OVERFLOW : out std_logic;

		-- PCE PORT (2026-08-28): 4-word VRAM0 line-refill -- see VRAM0_LINE_REFILL
		-- generic's own comment. Only meaningful when that generic is nonzero; tied
		-- '0'/open on every other board configuration (see both generate branches
		-- below).
		VRAM0_RAM_A_LINE_REFILL : out std_logic;
		VRAM0_RAM_A_LINE_DO     : in  std_logic_vector(63 downto 0) := (others => '0');

		-- PCE PORT (2026-08-30): VDC1's own copy of every VRAM0_RAM_A_* port above --
		-- see EXT_VRAM1's own generic comment. Unused/left open on every board that
		-- doesn't set EXT_VRAM1 (including every LITE=1 board, where gen_vram1_ext
		-- doesn't exist at all).
		VRAM1_RAM_A_ADDR : out std_logic_vector(20 downto 0);
		VRAM1_RAM_A_REQ  : out std_logic;
		VRAM1_RAM_A_RD_N : out std_logic;
		VRAM1_RAM_A_DI   : out std_logic_vector(15 downto 0);
		VRAM1_RAM_A_DO   : in  std_logic_vector(15 downto 0) := (others => '0');
		VRAM1_RAM_A_WAIT : in  std_logic := '0';
		VRAM1_RAM_A_LINE_REFILL : out std_logic;
		VRAM1_RAM_A_LINE_DO     : in  std_logic_vector(63 downto 0) := (others => '0');

		-- VDC1's own copy of DBG_DEADLINE_MISS/DBG_FIFO_OVERFLOW -- '0' always unless
		-- EXT_VRAM1 /= 0 (no gen_vram1_ext instance to drive them otherwise).
		DBG_DEADLINE_MISS_1 : out std_logic;
		DBG_FIFO_OVERFLOW_1 : out std_logic;

		-- PCE PORT (2026-09-06): read-only taps on the internal CPU bus, for the board's
		-- RTL debug-trace channel (see pcetang_rtl_trace_channel.md). Purely
		-- combinational reads of signals that already exist below -- no new logic, same
		-- precedent as SCREEN_DBG/OFS_Y_DBG in huc6270.vhd. Every board that doesn't
		-- want them leaves them `open`.
		--
		-- Why these two specifically: a GHDL boot testbench (sim/boot/) proved this core
		-- boots a real HuCard given an ideal ROM -- first VDC write at 15.28 ms, 7 ROM
		-- banks touched -- while the same ROM on real Console 60K hardware stays black.
		-- DBG_VDC_WR settles the one question the board top cannot otherwise see: does
		-- the CPU ever reach the code that programs the VDC on real hardware? DBG_CPU_A
		-- is the physical (post-MPR) address, which the board's own ROM_A cannot show
		-- (ROM_A drops CPU_A(19) on the 512K bucket and shows nothing for RAM/IO cycles).
		DBG_CPU_A  : out std_logic_vector(20 downto 0);
		DBG_VDC_WR : out std_logic;
		-- VCE writes are the palette path. A game whose splash is a palette fade can run
		-- its whole display loop -- VDC writes climbing, frames emitted -- and still show
		-- pure black if the palette never lands. DBG_VCE_WR pulses on any CPU write that
		-- selects the VCE, and DBG_VCE_DO carries what was written, so "never programmed"
		-- and "programmed to black" are distinguishable.
		-- Full CPU bus tap, so the board can trace CD-register traffic the way the GHDL
		-- testbench does. The sim prints every $1800-page access and that is how the CD
		-- init sequence was read; hardware had no equivalent, and hardware is where the
		-- failure actually reproduces.
		DBG_CPU_WR_N : out std_logic;
		DBG_CPU_RD_N : out std_logic;
		DBG_CPU_DO   : out std_logic_vector(7 downto 0);
		DBG_CPU_DI   : out std_logic_vector(7 downto 0);
		DBG_VCE_WR : out std_logic;
		DBG_VCE_DO : out std_logic_vector(7 downto 0);
		-- PCE PORT (2026-09-07): the HuC6280's OTHER stall input. `RDY` below is
		-- `VDC0_BUSY_N and VDC1_BUSY_N`, entirely separate from WAIT_N's
		-- ROM_RDY/CD_RAM_RDY. A VDC holding BUSY low freezes the CPU while every memory
		-- path looks perfectly healthy -- which is exactly the state real hardware
		-- reached: ROM image byte-perfect, rd_state IDLE, cd_ram_rdy high, and the VDC
		-- write count stuck at 10. Exposed so the board can trace it.
		DBG_VDC_RDY : out std_logic;
		-- CPU execution heartbeat + IRQ visibility. "VDC writes stopped" does NOT mean
		-- the CPU stopped -- it can be running full speed inside an interrupt handler it
		-- can never leave. DBG_CPU_CE counting while DBG_VDC_WR stays flat says exactly
		-- that, and DBG_IRQ1_N/DBG_IRQ2_N name which line is doing it.
		DBG_CPU_CE  : out std_logic;
		DBG_IRQ1_N  : out std_logic;
		DBG_IRQ2_N  : out std_logic;
		-- PCE PORT (2026-09-07): work-RAM pattern-test hooks. Work RAM has never been
		-- tested directly, and it is now the prime suspect: hardware shows the CPU
		-- sweeping ADDRESSES inside nonexistent bank $ED, which is the signature of a
		-- block transfer (TII/TAI) rather than a wild jump -- and this game assembles
		-- its TII trampoline IN RAM at $2480 and takes its parameters from RAM. Corrupt
		-- RAM therefore means executing garbage with garbage operands, exactly as seen.
		-- Port B of the RAM is otherwise idle after the cold-reset clear sweep (q_b is
		-- unconnected), so the board borrows it to write a known pattern and read it
		-- back while the CPU is still held in reset. Same playbook as the SDRAM pattern
		-- self-test, which is what finally cracked the memory path.
		RAMTEST_EN : in  std_logic := '0';
		RAMTEST_A  : in  std_logic_vector(14 downto 0) := (others => '0');
		RAMTEST_D  : in  std_logic_vector(7 downto 0) := (others => '0');
		RAMTEST_WE : in  std_logic := '0';
		RAMTEST_Q  : out std_logic_vector(7 downto 0);
		-- PCE PORT (2026-09-07): MPR bank registers, for the board's derailment trace.
		DBG_MPR    : out std_logic_vector(63 downto 0);
		DBG_TAM    : out std_logic_vector(31 downto 0);
		DBG_TLOAD  : out std_logic_vector(191 downto 0);
		DBG_TLOAD_STB : out std_logic;
		DBG_SEL    : out std_logic_vector(21 downto 0);
		-- Sticky: has WAIT_N EVER been low since reset? The previous "WAIT_N never asserted"
		-- claim came from a heartbeat sample, which can miss a stall entirely. If the CPU is
		-- never stalled while ROM reads are outstanding, mechanism (b) -- stale DI -- is live.
		DBG_WAIT_EVER : out std_logic;

		ROM_RD		: out std_logic;
		ROM_RDY		: in  std_logic;
		ROM_A 		: out std_logic_vector(21 downto 0);
		ROM_DO 		: in  std_logic_vector(7 downto 0);
		ROM_SZ 		: in  std_logic_vector(11 downto 0);
		ROM_POP		: in  std_logic;
		ROM_CLKEN	: out std_logic;

		BRM_A 		: out std_logic_vector(10 downto 0);
		BRM_DI 		: out std_logic_vector(7 downto 0);
		BRM_DO 		: in  std_logic_vector(7 downto 0);
		BRM_WE 		: out std_logic;

		GG_EN			: in  std_logic;
		GG_CODE		: in  std_logic_vector(128 downto 0);
		GG_RESET		: in  std_logic;
		GG_AVAIL		: out std_logic;

		SP64			: in  std_logic;
		SGX			: in  std_logic;

		JOY_OUT     : out std_logic_vector(1 downto 0);
		JOY_IN      : in  std_logic_vector(3 downto 0);

		CD_EN			: in  std_logic;
		CD_RAM_A 	: out std_logic_vector(21 downto 0);
		CD_RAM_DO 	: out std_logic_vector(7 downto 0);
		CD_RAM_DI 	: in  std_logic_vector(7 downto 0);
		CD_RAM_RD	: out std_logic;
		CD_RAM_WR	: out std_logic;
		-- CD-RAM has no wait path of its own (CD_RAM_DI muxes straight into the CPU read
		-- path combinationally, see below) -- added so a board backing CD_RAM with
		-- external memory can stall the CPU the same way ROM_RDY already does, instead of
		-- needing a VRAM0-style zero-wait cache. Defaults to '1' (no board-level effect)
		-- so existing callers that don't connect it are unaffected.
		CD_RAM_RDY	: in  std_logic := '1';

		-- ADPCM RAM offload (2026-08-27): pass-through to cd.vhd's own ADPCM_RAM_*
		-- ports (see cd.vhd's header for the full design rationale -- wait-gated
		-- DRAM_CLKEN, not speculative prefetch). Defaults preserve the original
		-- never-stall behavior for any board that doesn't connect these.
		ADPCM_RAM_A		: out std_logic_vector(16 downto 0);
		ADPCM_RAM_DO	: out std_logic_vector(3 downto 0);
		ADPCM_RAM_WE	: out std_logic;
		ADPCM_RAM_REQ	: out std_logic;
		ADPCM_RAM_SLOT_CNT : out std_logic_vector(1 downto 0);
		ADPCM_RAM_DI	: in  std_logic_vector(3 downto 0) := (others => '0');
		ADPCM_RAM_READY: in  std_logic := '1';

		AC_EN			: in  std_logic;

		CD_STAT		: in  std_logic_vector(7 downto 0);
		CD_MSG		: in  std_logic_vector(7 downto 0);
		CD_STAT_GET	: in  std_logic;

		CD_COMM		: out std_logic_vector(95 downto 0);
		CD_COMM_SEND: out std_logic;

		CD_DOUT_REQ	: in  std_logic;
		CD_DOUT		: out std_logic_vector(79 downto 0);
		CD_DOUT_SEND: out std_logic;

		CD_REGION   : in  std_logic;
		CD_RESET		: out std_logic;

		CD_DATA		: in  std_logic_vector(7 downto 0);
		CD_DATA_WR	: in  std_logic;
		CD_AUDIO_WR	: in  std_logic;
		CD_SUBCD_WR	: in  std_logic;			-- subcode data
		CD_DATA_END	: out std_logic;
		-- SCSI DATA-IN probes (see cd.vhd / SCSI.vhd). Tied off in the NO_CD generate.
		CD_DBG_DATAIN_CNT : out unsigned(15 downto 0);
		CD_DBG_FIRST8     : out std_logic_vector(63 downto 0);
		CD_DBG_SP         : out std_logic_vector(3 downto 0);
		-- ADPCM activity, the last CD-only subsystem never verified. A game that runs its
		-- display loop forever but issues no further CD command is waiting on something,
		-- and ADPCM_END/ADPCM_HALF feed IRQ_N -- so "started playing and never ended" has
		-- exactly that shape. HuCard never touches any of this.
		CD_DBG_ADPCM      : out std_logic_vector(2 downto 0);   -- PLAY, END, HALF
		CD_DBG_COMM_POS   : out unsigned(3 downto 0);
		CD_DBG_COMM0      : out std_logic_vector(7 downto 0);
		CD_DBG_COMM1      : out std_logic_vector(7 downto 0);
		CD_DBG_SEL_CNT    : out unsigned(15 downto 0);
		CD_DBG_FIFO_SPACE : out unsigned(12 downto 0);
		-- PCE PORT (2026-09-16): free entries in cd.vhd's CD-DA FIFO. cd_bridge lives in
		-- the BOARD file, not here, so audio prefetch flow control has to travel
		-- cd.vhd -> pce_top -> board -> cd_bridge, exactly like CD_DBG_FIFO_SPACE
		-- already does for the SCSI data FIFO. See docs/CD_AUDIO_TIMING.md.
		CD_DBG_CDDA_SPACE : out unsigned(12 downto 0);
		CD_DBG_FIFO_DROPS : out unsigned(15 downto 0);
		CD_DBG_GDI        : out std_logic_vector(127 downto 0);
		-- cd_bridge -> SCSI.vhd, expected sector count of the READ(6) in flight.
		CD_DATAIN_SECTORS : in  unsigned(8 downto 0) := (others => '0');
		-- VIDEO GEOMETRY TAP. [2:0] VDC0's live SCREEN (MWR bits 6:4 -- BAT size: bit2
		-- selects 32/64 rows, bits1:0 select 32/64/128 columns), and the VCE's control
		-- register (CR(1:0) = DOTCLOCK, 256/336/512-wide). A picture that TILES rather
		-- than resizes when a game changes video mode means the BAT size in force does not
		-- match the display geometry, so these two say which half is wrong.
		DBG_VDC_SCREEN : out std_logic_vector(2 downto 0) := (others => '0');
		DBG_VCE_CR     : out std_logic_vector(7 downto 0) := (others => '0');
		CD_DBG_RD_TOTAL   : out unsigned(15 downto 0);
		-- DATA IN bursts that ran dry mid-burst; see SCSI.vhd's BURST_RDY. 0 = the sector
		-- gate is doing its job.
		CD_DBG_UNDERRUNS  : out unsigned(15 downto 0);
		CD_DM			: in  std_logic;

		CDDA_SL		: out signed(15 downto 0);
		CDDA_SR		: out signed(15 downto 0);
		ADPCM_S		: out signed(15 downto 0);
		PSG_SL		: out signed(15 downto 0);
		PSG_SR		: out signed(15 downto 0);

		BG_EN			: in  std_logic;
		SPR_EN		: in  std_logic;
		GRID_EN		: in  std_logic_vector(1 downto 0);
		CPU_PAUSE_EN: in  std_logic;

		BORDER_EN	: in  std_logic;
		ReducedVBL	: in  std_logic;
		VIDEO_R		: out std_logic_vector(2 downto 0);
		VIDEO_G		: out std_logic_vector(2 downto 0);
		VIDEO_B		: out std_logic_vector(2 downto 0);
		VIDEO_BW		: out std_logic;
		VIDEO_CE		: out std_logic;
		VIDEO_CE_FS	: out std_logic;
		VIDEO_VS		: out std_logic;
		VIDEO_HS		: out std_logic;
		VIDEO_HBL	: out std_logic;
		VIDEO_VBL	: out std_logic
	);
end pce_top;

architecture rtl of pce_top is

signal RESET_N			: std_logic := '0';

-- CPU signals
signal CPU_CE			: std_logic;
signal CPU_CE2			: std_logic;
signal CPU_RD_N		: std_logic;
signal CPU_WR_N		: std_logic;
signal CPU_DI			: std_logic_vector(7 downto 0);
signal CPU_DO			: std_logic_vector(7 downto 0);
signal CPU_A			: std_logic_vector(20 downto 0);
signal CPU_CLKEN		: std_logic;
signal CPU_VCE_SEL_N	: std_logic;
signal CPU_VDC_SEL_N	: std_logic;
signal CPU_RAM_SEL_N	: std_logic;
signal CPU_BRM_SEL_N	: std_logic;
signal CPU_IO_DO		: std_logic_vector(7 downto 0);

signal CPU_VDC0_SEL_N: std_logic;
signal CPU_VDC1_SEL_N: std_logic;
signal CPU_VPC_SEL_N	: std_logic;

signal CPU_ROM_SEL_N	: std_logic;

-- RAM signals
-- RAM_A's "when SGX='1' else" mux was tested as the Gowin BSRAM inference failure
-- (ERROR (IF0008), full engine only) but is NOT the cause -- see NECTang's docs/PORTING.md's SGX
-- section. Reverted to this original form because SGX doesn't fit Nano 20K on Logic
-- capacity regardless (real, measured, ERROR (RP0006)), so chasing a production fix
-- for the inference bug is moot for now; this form correctly preserves 8K mirroring
-- for SGX-inactive builds, which a hardcoded diagnostic fold does not.
signal RAM_DO			: std_logic_vector(7 downto 0);
signal RAM_A			: std_logic_vector(14 downto 0);

signal PRAM_DO			: std_logic_vector(7 downto 0);
signal CPU_PRAM_SEL_N: std_logic;

-- VCE signals
signal VCE_DO			: std_logic_vector(7 downto 0);

-- VDC signals
signal VDC0_DO			: std_logic_vector(15 downto 0);		-- only lower 8 bits are used in 8-bit mode
alias  VDC0_DO_LO		: std_logic_vector(7 downto 0) is VDC0_DO(7 downto 0);
signal VDC0_BUSY_N	: std_logic;
signal VDC0_IRQ_N		: std_logic;
signal VDC0_COLNO		: std_logic_vector(8 downto 0);

-- PCE PORT (2026-08-28): VDC0's own SCREEN_DBG/OFS_Y_DBG/BYR_DBG taps, feeding
-- vram0_prefetch.vhd's BAT prefetch engine below (gen_vram0_ext only -- unused, left
-- open, on the EXT_VRAM0=0 on-chip path). Always wired from VDC0 regardless of
-- EXT_VRAM0, same as every other *_DBG port on that entity -- harmless dead logic on
-- boards that don't consume them (synthesis strips unused combinational fanout).
signal VDC0_SCREEN_DBG : std_logic_vector(2 downto 0);
signal VDC0_OFS_Y_DBG  : std_logic_vector(8 downto 0);
signal VDC0_BYR_DBG    : std_logic_vector(8 downto 0);
-- PCE PORT (2026-08-30): VDC1's own copy, for gen_vram1_ext/PREFETCH1 -- see EXT_VRAM1's
-- own generic comment. Harmless dead logic on any board where gen_vram1_ext doesn't
-- exist (LITE=1, or LITE=0 with EXT_VRAM1=0), same as VDC0_SCREEN_DBG's own note above.
signal VDC1_SCREEN_DBG : std_logic_vector(2 downto 0);
signal VDC1_OFS_Y_DBG  : std_logic_vector(8 downto 0);
signal VDC1_BYR_DBG    : std_logic_vector(8 downto 0);
signal VDC1_DO			: std_logic_vector(15 downto 0);		-- only lower 8 bits are used in 8-bit mode
alias  VDC1_DO_LO		: std_logic_vector(7 downto 0) is VDC1_DO(7 downto 0);
signal VDC1_BUSY_N	: std_logic;
signal VDC1_IRQ_N		: std_logic;
signal VDC1_COLNO		: std_logic_vector(8 downto 0);
signal VDC_CLKEN		: std_logic;
signal VDC_CLKEN_F	: std_logic;
signal VPC_DO			: std_logic_vector(7 downto 0);
signal VDCNUM    		: std_logic;
signal VDC_COLNO		: std_logic_vector(8 downto 0);

-- CD signals
signal CD_SEL_N		: std_logic;
signal CD_DO			: std_logic_vector(7 downto 0);
signal CD_IRQ_N    	: std_logic;

-- NTSC/RGB Video Output
signal VS_N				: std_logic;
signal HS_N				: std_logic;

signal PCE_SL			: std_logic_vector(23 downto 0);
signal PCE_SR			: std_logic_vector(23 downto 0);

signal rombank			: std_logic_vector(1 downto 0);

signal gamepad_out	: std_logic_vector(1 downto 0);
signal gamepad_port	: unsigned(2 downto 0);
signal gamepad_nibble: std_logic;

signal GENIE		: boolean;
signal GENIE_DO	: std_logic_vector(7 downto 0);
signal GENIE_DI   : std_logic_vector(7 downto 0);

component CODES is
	generic(
		ADDR_WIDTH  : in integer := 16;
		DATA_WIDTH  : in integer := 8
	);
	port(
		clk         : in  std_logic;
		reset       : in  std_logic;
		enable      : in  std_logic;
		addr_in     : in  std_logic_vector(20 downto 0);
		data_in     : in  std_logic_vector(7 downto 0);
		code        : in  std_logic_vector(128 downto 0);
		available   : out std_logic;
		genie_ovr   : out boolean;
		genie_data  : out std_logic_vector(7 downto 0)
	);
end component;

signal VCE_HSYNC_F, VCE_HSYNC_R, VCE_VSYNC_F, VCE_VSYNC_R: std_logic;
signal VRAM0_A	   : std_logic_vector(15 downto 0);
signal VRAM0_DI	: std_logic_vector(15 downto 0);
signal VRAM0_DO	: std_logic_vector(15 downto 0);
signal VRAM0_WE	: std_logic;
signal VRAM1_A	   : std_logic_vector(15 downto 0);
signal VRAM1_DI	: std_logic_vector(15 downto 0);
signal VRAM1_DO	: std_logic_vector(15 downto 0);
signal VRAM1_WE	: std_logic;
signal CLR_A	   : std_logic_vector(14 downto 0);
-- Work RAM port-B mux (clear sweep vs the board's pattern test). Separate signals
-- because a VHDL-93 port map cannot take a conditional expression.
signal RAMB_A	   : std_logic_vector(14 downto 0);
signal RAMB_D	   : std_logic_vector(7 downto 0);
signal RAMB_WE	   : std_logic;
signal CLR_WE		: std_logic;
signal VDC0_BORDER: std_logic;
signal VDC0_GRID	: std_logic_vector(1 downto 0);
signal CPU_PRE_RD	: std_logic;
signal CPU_PRE_WR	: std_logic;
signal CD_RAM_CS_N: std_logic;
-- PCE PORT (2026-09-19), DELIBERATE DEVIATION FROM THE DONOR -- see the comment at the
-- CPU_DI mux below for the full story and the measurements.
signal CD_RAM_CS_N_G : std_logic;
signal CD_BRAM_EN	: std_logic;

signal BORDER		: std_logic;
signal GRID			: std_logic_vector(1 downto 0);

signal AC_SEL_N   : std_logic;
signal AC_RAM_CS_N: std_logic;
signal AC_RAM_A   : std_logic_vector(20 downto 0);
signal AC_DO      : std_logic_vector(7 downto 0);
signal CPU_WAIT_N_I : std_logic;
signal WAIT_EVER_LOW : std_logic := '0';

component ARCADE_CARD is
	port(
		CLK     : in  std_logic;
		RST_N   : in  std_logic;

		EN      : in  std_logic;
		WR_N    : in  std_logic;
		RD_N    : in  std_logic;
		A       : in  std_logic_vector(20 downto 0);
		DI      : in  std_logic_vector(7 downto 0);
		DO      : out std_logic_vector(7 downto 0);

		SEL_N   : out std_logic;

		RAM_CS_N: out std_logic;
		RAM_A   : out std_logic_vector(20 downto 0)
	);
end component;

begin

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

generate_CHEAT: if (LITE = 0) generate begin

-- Game Genie
GAMEGENIE : component CODES
generic map(
	ADDR_WIDTH => 21,
	DATA_WIDTH => 8
)
port map(
	clk => CLK,
	reset => GG_RESET,
	enable => not GG_EN,
	addr_in => CPU_A,
	data_in => CPU_DI,
	code => GG_CODE,
	available => GG_AVAIL,
	genie_ovr => GENIE,
	genie_data => GENIE_DO
);

GENIE_DI <= GENIE_DO when GENIE else CPU_DI;

end generate;

generate_NOCHEAT: if (LITE /= 0) generate begin
	GENIE_DI <= CPU_DI;
	GG_AVAIL <= '0';
end generate;

CPU : entity work.HUC6280
generic map ( VT_PATH_A => VT_PATH_A, DBG_PROBES => DBG_PROBES )
port map(
	CLK 		=> CLK,
	RST_N		=> RESET_N,
	WAIT_N	=> CPU_WAIT_N_I,

	IRQ1_N	=> VDC0_IRQ_N and VDC1_IRQ_N,
	IRQ2_N	=> CD_IRQ_N,
	NMI_N		=> '1',

	DI			=> GENIE_DI,
	DO 		=> CPU_DO,

	A 			=> CPU_A,
	WR_N 		=> CPU_WR_N,
	RD_N		=> CPU_RD_N,

	RDY		=> VDC0_BUSY_N and VDC1_BUSY_N,

	CE			=> CPU_CE,
	CEK_N		=> CPU_VCE_SEL_N,
	CE7_N		=> CPU_VDC_SEL_N,
	CER_N		=> CPU_RAM_SEL_N,
	PRE_RD   => CPU_PRE_RD,
	PRE_WR   => CPU_PRE_WR,

	K			=> not CD_EN & "011" & JOY_IN,
	O			=> CPU_IO_DO,

	VDCNUM   => VDCNUM,
	MPR_DBG  => DBG_MPR,
	TAM_DBG  => DBG_TAM,
	TLOAD_DBG => DBG_TLOAD,
	TLOAD_STB => DBG_TLOAD_STB,
	SEL_DBG  => DBG_SEL,

	AUD_LDATA=> PCE_SL,
	AUD_RDATA=> PCE_SR
);

JOY_OUT <= CPU_IO_DO(1 downto 0);

CPU_CLKEN <= CPU_CE when rising_edge( CLK );

VIDEO_CE <= VDC_CLKEN;
VIDEO_VS <= not VS_N;
VIDEO_HS <= not HS_N;

VCE : entity work.huc6260
port map(
	CLK 		=> CLK,
	RESET_N	=> RESET_N,

	-- CPU Interface
	A			=> CPU_A(2 downto 0),
	CE_N		=> CPU_VCE_SEL_N,
	WR_N		=> CPU_WR_N,
	RD_N		=> CPU_RD_N,
	DI			=> CPU_DO,
	DO 		=> VCE_DO,

	-- VDC Interface
	COLNO		=> VDC_COLNO,
	CLKEN		=> VDC_CLKEN,
	CLKEN_F  => VDC_CLKEN_F,
	HSYNC_F	=> VCE_HSYNC_F,
	HSYNC_R	=> VCE_HSYNC_R,
	VSYNC_F	=> VCE_VSYNC_F,
	VSYNC_R	=> VCE_VSYNC_R,
	CLKEN_FS => VIDEO_CE_FS,
	RVBL		=> ReducedVBL,
	
	GRID_EN	=> GRID_EN,
	BORDER_EN=> BORDER_EN,
	BORDER	=> BORDER,
	GRID		=> GRID,
		
	-- NTSC/RGB Video Output
	R			=> VIDEO_R,
	G			=> VIDEO_G,
	B			=> VIDEO_B,
	BW			=> VIDEO_BW,
	VS_N		=> VS_N,
	HS_N		=> HS_N,
	HBL		=> VIDEO_HBL,
	VBL		=> VIDEO_VBL,
	CR_DBG => DBG_VCE_CR
);

VDC0 : entity work.HUC6270
generic map (SGX_BUILD => (LITE = 0))
port map(
	CLK 		=> CLK,
	RST_N		=> RESET_N,
	CLR_MEM  => COLD_RESET,

	-- CPU Interface
	CPU_CE	=> CPU_CE,
	BYTEWORD => '1',						-- 8-bit access
	A			=> CPU_A(1 downto 0),
	CS_N		=> CPU_VDC0_SEL_N,
	WR_N		=> CPU_WR_N,
	RD_N		=> CPU_RD_N,
	DI			=> "00000000" & CPU_DO,
	DO 		=> VDC0_DO,
	BUSY_N	=> VDC0_BUSY_N,
	IRQ_N		=> VDC0_IRQ_N,

	-- VCE Interface
	DCK_CE	=> VDC_CLKEN,
	DCK_CE_F => VDC_CLKEN_F,
	HSYNC_F	=> VCE_HSYNC_F,
	HSYNC_R	=> VCE_HSYNC_R,
	VSYNC_F	=> VCE_VSYNC_F,
	VSYNC_R	=> VCE_VSYNC_R,
	VD			=> VDC0_COLNO,
	
	BORDER	=> VDC0_BORDER,
	GRID		=> VDC0_GRID,
	SP64     => SP64,

	RAM_A		=> VRAM0_A,
	RAM_DI	=> VRAM0_DI,
	RAM_DO	=> VRAM0_DO,
	RAM_WE	=> VRAM0_WE,

	BG_EN		=> BG_EN,
	SPR_EN	=> SPR_EN,

	SCREEN_DBG => VDC0_SCREEN_DBG,
	OFS_Y_DBG  => VDC0_OFS_Y_DBG,
	BYR_DBG    => VDC0_BYR_DBG
);

-- EXT_VRAM0 = 0: donor behaviour, byte-identical, including the CLR_A/CLR_WE cold-reset
-- clear-sweep on port B.
gen_vram0_onchip: if EXT_VRAM0 = 0 generate
begin
	VRAM0 : entity work.dpram generic map (addr_width => 15, data_width => 16, disable_value => '0')
	port map (
		clock		=> CLK,
		address_a=> VRAM0_A(14 downto 0),
		data_a	=> VRAM0_DO,
		cs_a		=> not VRAM0_A(15),
		wren_a	=> VRAM0_WE,
		q_a		=> VRAM0_DI,

		address_b=> CLR_A,
		data_b	=> (others => '0'),
		wren_b	=> CLR_WE
	);
	DBG_DEADLINE_MISS <= '0';
	DBG_FIFO_OVERFLOW <= '0';
	VRAM0_RAM_A_LINE_REFILL <= '0';
end generate;

-- EXT_VRAM0 /= 0 (Nano 20K): src/common/mem/vram0_cache.vhd instead, backed by
-- sdram32.sv's port A via the board top. wren_a additionally gated by "not VRAM0_A(15)"
-- to match the on-chip path's cs_a semantics -- vram0_cache has no chip-select input of
-- its own (single-purpose, always selected). No CLR_A/CLR_WE equivalent -- see this
-- file's header for why that's a deliberate scope decision.
gen_vram0_ext: if EXT_VRAM0 /= 0 generate
begin

	-- PCE PORT (2026-08-28): VRAM0_PREFETCH /= 0 -- vram0_prefetch.vhd's BAT prefetch
	-- engine (see that file's own header) sits between VDC0's real RAM_A/RAM_DI/RAM_DO/
	-- RAM_WE and vram0_cache's own address_a/q_a/data_a/wren_a. Split into its own
	-- nested generate, NOT just an inert-when-off internal mux, so that a board which
	-- does NOT opt in (VRAM0_PREFETCH left at its default 0 -- Nano 20K, as of
	-- 2026-08-29) pays exactly ZERO extra BSRAM/logic for this feature and is wired
	-- byte-identically to before this port existed (see gen_vram0_pf_none below).
	-- Primer 25K plain AND Primer 25K CD both opt in as of this port (VRAM0_PREFETCH
	-- => 1 in each board's own top-level generic map).
	gen_vram0_pf: if VRAM0_PREFETCH /= 0 generate
		signal ds_address_a : std_logic_vector(14 downto 0);
		signal ds_data_a    : std_logic_vector(15 downto 0);
		signal ds_wren_a    : std_logic;
		signal ds_q_a       : std_logic_vector(15 downto 0);
		signal pf_addr      : std_logic_vector(14 downto 0);
		signal pf_req       : std_logic;
		signal pf_rdata     : std_logic_vector(63 downto 0);
		signal pf_done      : std_logic;
	begin
		PREFETCH0 : entity work.vram0_prefetch
		generic map (G_CG_PREFETCH => VRAM0_CG_PREFETCH /= 0)
		port map (
			clock      => CLK,
			hsync_f    => VCE_HSYNC_F,
			screen_dbg => VDC0_SCREEN_DBG,
			ofs_y_dbg  => VDC0_OFS_Y_DBG,
			byr_dbg    => VDC0_BYR_DBG,

			address_a  => VRAM0_A(14 downto 0),
			data_a     => VRAM0_DO,
			wren_a     => VRAM0_WE and not VRAM0_A(15),
			q_a        => VRAM0_DI,

			ds_address_a => ds_address_a,
			ds_data_a    => ds_data_a,
			ds_wren_a    => ds_wren_a,
			ds_q_a       => ds_q_a,

			pf_addr  => pf_addr,
			pf_req   => pf_req,
			pf_rdata => pf_rdata,
			pf_done  => pf_done,

			dbg_pf_hit     => open,
			dbg_pf_overrun => open
		);

		VRAM0 : entity work.vram0_cache
		generic map (
			G_LINE_REFILL => VRAM0_LINE_REFILL /= 0,
			G_PREFETCH    => true
		)
		port map (
			clock      => CLK,
			dck_ce     => VDC_CLKEN,
			address_a  => ds_address_a,
			data_a     => ds_data_a,
			wren_a     => ds_wren_a,
			q_a        => ds_q_a,
			pf_addr    => pf_addr,
			pf_req     => pf_req,
			pf_rdata   => pf_rdata,
			pf_done    => pf_done,
			ram_a_addr => VRAM0_RAM_A_ADDR,
			ram_a_req  => VRAM0_RAM_A_REQ,
			ram_a_rd_n => VRAM0_RAM_A_RD_N,
			ram_a_di   => VRAM0_RAM_A_DI,
			ram_a_do   => VRAM0_RAM_A_DO,
			ram_a_wait => VRAM0_RAM_A_WAIT,
			ram_a_line_refill => VRAM0_RAM_A_LINE_REFILL,
			ram_a_line_do     => VRAM0_RAM_A_LINE_DO,
			dbg_deadline_miss => DBG_DEADLINE_MISS,
			dbg_fifo_overflow => DBG_FIFO_OVERFLOW
		);
	end generate;

	-- VRAM0_PREFETCH = 0 (the default): byte-identical to the file as it existed before
	-- vram0_prefetch.vhd -- no extra module, no extra BRAM, VDC0's real signals wired
	-- straight into vram0_cache exactly as before this port.
	gen_vram0_pf_none: if VRAM0_PREFETCH = 0 generate
	begin
		VRAM0 : entity work.vram0_cache
		generic map (G_LINE_REFILL => VRAM0_LINE_REFILL /= 0)
		port map (
			clock      => CLK,
			dck_ce     => VDC_CLKEN,
			address_a  => VRAM0_A(14 downto 0),
			data_a     => VRAM0_DO,
			wren_a     => VRAM0_WE and not VRAM0_A(15),
			q_a        => VRAM0_DI,
			ram_a_addr => VRAM0_RAM_A_ADDR,
			ram_a_req  => VRAM0_RAM_A_REQ,
			ram_a_rd_n => VRAM0_RAM_A_RD_N,
			ram_a_di   => VRAM0_RAM_A_DI,
			ram_a_do   => VRAM0_RAM_A_DO,
			ram_a_wait => VRAM0_RAM_A_WAIT,
			ram_a_line_refill => VRAM0_RAM_A_LINE_REFILL,
			ram_a_line_do     => VRAM0_RAM_A_LINE_DO,
			dbg_deadline_miss => DBG_DEADLINE_MISS,
			dbg_fifo_overflow => DBG_FIFO_OVERFLOW
		);
	end generate;

end generate;

RAMB_A  <= RAMTEST_A  when RAMTEST_EN = '1' else CLR_A;
RAMB_D  <= RAMTEST_D  when RAMTEST_EN = '1' else (others => '0');
RAMB_WE <= RAMTEST_WE when RAMTEST_EN = '1' else CLR_WE;

CLR_A  <= CLR_A + 1  when rising_edge(CLK);
CLR_WE <= COLD_RESET when rising_edge(CLK);

generate_SGX: if (LITE = 0) generate begin

	VDC1 : entity work.HUC6270
	generic map (SGX_BUILD => true)
	port map(
		CLK 		=> CLK,
		CLR_MEM  => COLD_RESET,
		RST_N		=> RESET_N,

		-- CPU Interface
		CPU_CE	=> CPU_CE,
		BYTEWORD => '1',						-- 8-bit access
		A			=> CPU_A(1 downto 0),
		CS_N		=> CPU_VDC1_SEL_N,
		WR_N		=> CPU_WR_N,
		RD_N		=> CPU_RD_N,
		DI			=> "00000000" & CPU_DO,
		DO 		=> VDC1_DO,
		BUSY_N	=> VDC1_BUSY_N,
		IRQ_N		=> VDC1_IRQ_N,

		-- VCE Interface
		DCK_CE	=> VDC_CLKEN,
		DCK_CE_F => VDC_CLKEN_F,
		HSYNC_F	=> VCE_HSYNC_F,
		HSYNC_R	=> VCE_HSYNC_R,
		VSYNC_F	=> VCE_VSYNC_F,
		VSYNC_R	=> VCE_VSYNC_R,
		VD			=> VDC1_COLNO,
		--GRID		=> VDC1_GRID,

		SP64     => SP64,

		RAM_A		=> VRAM1_A,
		RAM_DI	=> VRAM1_DI,
		RAM_DO	=> VRAM1_DO,
		RAM_WE	=> VRAM1_WE,

		BG_EN		=> BG_EN,
		SPR_EN	=> SPR_EN,

		SCREEN_DBG => VDC1_SCREEN_DBG,
		OFS_Y_DBG  => VDC1_OFS_Y_DBG,
		BYR_DBG    => VDC1_BYR_DBG
	);

	-- EXT_VRAM1 = 0: donor behaviour, byte-identical, including the CLR_A/CLR_WE
	-- cold-reset clear-sweep on port B -- see EXT_VRAM1's own generic comment and
	-- gen_vram0_ext's identical structure above.
	gen_vram1_onchip: if EXT_VRAM1 = 0 generate
	begin
		VRAM1 : entity work.dpram generic map (addr_width => 15, data_width => 16, disable_value => '0')
		port map (
			clock		=> CLK,
			address_a=> VRAM1_A(14 downto 0),
			data_a	=> VRAM1_DO,
			cs_a		=> not VRAM1_A(15),
			wren_a	=> VRAM1_WE and not VRAM1_A(15),
			q_a		=> VRAM1_DI,

			address_b=> CLR_A,
			data_b	=> (others => '0'),
			wren_b	=> CLR_WE
		);
		DBG_DEADLINE_MISS_1 <= '0';
		DBG_FIFO_OVERFLOW_1 <= '0';
		VRAM1_RAM_A_LINE_REFILL <= '0';
	end generate;

	-- EXT_VRAM1 /= 0 (Primer 25K SGX): src/common/mem/vram0_cache.vhd instead -- the
	-- SAME entity VRAM0 uses, a second real instance, backed by sdram.sv's port C via
	-- the board top's own real 16-bit/line-refill additions (see sdram.sv's
	-- RAM_C_WIDE/RAM_C_LINE_REFILL header comment). Mirrors gen_vram0_ext's own
	-- structure exactly -- see that generate's comments for the wren_a chip-select
	-- gating and the "no CLR_A/CLR_WE equivalent" scope decision, both apply here too.
	gen_vram1_ext: if EXT_VRAM1 /= 0 generate
	begin

		-- Mirrors gen_vram0_pf's own split exactly -- see that generate's comment for
		-- why this is a nested generate rather than an inert-when-off internal mux.
		gen_vram1_pf: if VRAM1_PREFETCH /= 0 generate
			signal ds_address_a : std_logic_vector(14 downto 0);
			signal ds_data_a    : std_logic_vector(15 downto 0);
			signal ds_wren_a    : std_logic;
			signal ds_q_a       : std_logic_vector(15 downto 0);
			signal pf_addr      : std_logic_vector(14 downto 0);
			signal pf_req       : std_logic;
			signal pf_rdata     : std_logic_vector(63 downto 0);
			signal pf_done      : std_logic;
		begin
			PREFETCH1 : entity work.vram0_prefetch
			generic map (G_CG_PREFETCH => VRAM1_CG_PREFETCH /= 0)
			port map (
				clock      => CLK,
				hsync_f    => VCE_HSYNC_F,
				screen_dbg => VDC1_SCREEN_DBG,
				ofs_y_dbg  => VDC1_OFS_Y_DBG,
				byr_dbg    => VDC1_BYR_DBG,

				address_a  => VRAM1_A(14 downto 0),
				data_a     => VRAM1_DO,
				wren_a     => VRAM1_WE and not VRAM1_A(15),
				q_a        => VRAM1_DI,

				ds_address_a => ds_address_a,
				ds_data_a    => ds_data_a,
				ds_wren_a    => ds_wren_a,
				ds_q_a       => ds_q_a,

				pf_addr  => pf_addr,
				pf_req   => pf_req,
				pf_rdata => pf_rdata,
				pf_done  => pf_done,

				dbg_pf_hit     => open,
				dbg_pf_overrun => open
			);

			VRAM1 : entity work.vram0_cache
			generic map (
				G_LINE_REFILL => VRAM1_LINE_REFILL /= 0,
				G_PREFETCH    => true
			)
			port map (
				clock      => CLK,
				dck_ce     => VDC_CLKEN,
				address_a  => ds_address_a,
				data_a     => ds_data_a,
				wren_a     => ds_wren_a,
				q_a        => ds_q_a,
				pf_addr    => pf_addr,
				pf_req     => pf_req,
				pf_rdata   => pf_rdata,
				pf_done    => pf_done,
				ram_a_addr => VRAM1_RAM_A_ADDR,
				ram_a_req  => VRAM1_RAM_A_REQ,
				ram_a_rd_n => VRAM1_RAM_A_RD_N,
				ram_a_di   => VRAM1_RAM_A_DI,
				ram_a_do   => VRAM1_RAM_A_DO,
				ram_a_wait => VRAM1_RAM_A_WAIT,
				ram_a_line_refill => VRAM1_RAM_A_LINE_REFILL,
				ram_a_line_do     => VRAM1_RAM_A_LINE_DO,
				dbg_deadline_miss => DBG_DEADLINE_MISS_1,
				dbg_fifo_overflow => DBG_FIFO_OVERFLOW_1
			);
		end generate;

		-- VRAM1_PREFETCH = 0: byte-identical to a version that never had PREFETCH1 --
		-- see gen_vram0_pf_none's own comment.
		gen_vram1_pf_none: if VRAM1_PREFETCH = 0 generate
		begin
			VRAM1 : entity work.vram0_cache
			generic map (G_LINE_REFILL => VRAM1_LINE_REFILL /= 0)
			port map (
				clock      => CLK,
				dck_ce     => VDC_CLKEN,
				address_a  => VRAM1_A(14 downto 0),
				data_a     => VRAM1_DO,
				wren_a     => VRAM1_WE and not VRAM1_A(15),
				q_a        => VRAM1_DI,
				ram_a_addr => VRAM1_RAM_A_ADDR,
				ram_a_req  => VRAM1_RAM_A_REQ,
				ram_a_rd_n => VRAM1_RAM_A_RD_N,
				ram_a_di   => VRAM1_RAM_A_DI,
				ram_a_do   => VRAM1_RAM_A_DO,
				ram_a_wait => VRAM1_RAM_A_WAIT,
				ram_a_line_refill => VRAM1_RAM_A_LINE_REFILL,
				ram_a_line_do     => VRAM1_RAM_A_LINE_DO,
				dbg_deadline_miss => DBG_DEADLINE_MISS_1,
				dbg_fifo_overflow => DBG_FIFO_OVERFLOW_1
			);
		end generate;

	end generate;

	VPC : entity work.huc6202
	port map(
		CLK 		=> CLK,
		CLKEN		=> VDC_CLKEN,
		RESET_N	=> RESET_N,

		-- CPU Interface
		A			=> CPU_A(2 downto 0),
		WR_N		=> CPU_WR_N or CPU_VPC_SEL_N or not CPU_CE,
		DI			=> CPU_DO,
		DO 		=> VPC_DO,
		
		HS_F		=> VCE_HSYNC_F,
		VDC0_IN  => VDC0_COLNO,
		VDC1_IN  => VDC1_COLNO,
		VDC_OUT  => VDC_COLNO,
		
		SGX		=> SGX,

		VDCNUM   => VDCNUM
	);

	CPU_VDC0_SEL_N <= CPU_VDC_SEL_N or     CPU_A(3) or     CPU_A(4) when SGX = '1' else CPU_VDC_SEL_N;
	CPU_VDC1_SEL_N <= CPU_VDC_SEL_N or     CPU_A(3) or not CPU_A(4) when SGX = '1' else '1';
	CPU_VPC_SEL_N  <= CPU_VDC_SEL_N or not CPU_A(3) or     CPU_A(4) when SGX = '1' else '1';
	
	process( CLK )
	begin
		if rising_edge( CLK ) then
			if VDC_CLKEN = '1' then
				BORDER <= VDC0_BORDER;
				GRID <= VDC0_GRID;
			end if;
		end if;
	end process;

end generate;

generate_NOSGX: if (LITE /= 0) generate begin

	CPU_VDC0_SEL_N <= CPU_VDC_SEL_N;
	CPU_VDC1_SEL_N <= '1';
	CPU_VPC_SEL_N  <= '1';
	VDC1_BUSY_N <= '1';
	VDC1_IRQ_N <= '1';

	VDCNUM <= '0';
	VDC1_DO <= (others => '1');
	VPC_DO <= (others => '1');
	VDC_COLNO <= VDC0_COLNO;

	BORDER <= VDC0_BORDER;
	GRID <= VDC0_GRID;

	-- PCE PORT (2026-08-30): gen_vram1_ext/gen_vram1_onchip both live entirely inside
	-- generate_SGX, which doesn't exist at all here (LITE=1) -- these outputs need a
	-- driver on this path too, same rationale as VDC1_BUSY_N/VDC1_IRQ_N/etc above.
	VRAM1_RAM_A_ADDR <= (others => '0');
	VRAM1_RAM_A_REQ  <= '0';
	VRAM1_RAM_A_RD_N <= '1';
	VRAM1_RAM_A_DI   <= (others => '0');
	VRAM1_RAM_A_LINE_REFILL <= '0';
	DBG_DEADLINE_MISS_1 <= '0';
	DBG_FIFO_OVERFLOW_1 <= '0';

end generate;

--TODO: check address mirroring for HuCard games
CPU_BRM_SEL_N <= '0' when CPU_A(20 downto 11) = x"F7"&"00" and CD_BRAM_EN = '1' else '1'; -- BRM : Page $F7

CPU_ROM_SEL_N <= CPU_A(20);

-- CPU data bus
CPU_DI <= RAM_DO         when CPU_RAM_SEL_N  = '0'
			else CD_DO      when CD_SEL_N       = '0'
			else CD_RAM_DI  when CD_RAM_CS_N_G  = '0' or AC_RAM_CS_N = '0'
			else AC_DO      when AC_SEL_N       = '0'
			else BRM_DO     when CPU_BRM_SEL_N  = '0'
			else PRAM_DO    when CPU_PRAM_SEL_N = '0'
			else ROM_DO     when CPU_ROM_SEL_N  = '0'
			else VCE_DO     when CPU_VCE_SEL_N  = '0'
			else VDC0_DO_LO when CPU_VDC0_SEL_N = '0'
			else VDC1_DO_LO when CPU_VDC1_SEL_N = '0'
			else VPC_DO     when CPU_VPC_SEL_N  = '0'
			else X"FF";

-- Perform address mangling to mimic HuCard chip mapping.
-- 384K ROM, split in 3, mapped ABABCCCC
	                                     -- bits 19 downto 16
	-- 00000 -> 20000  => 00000 -> 20000		0000 -> 0000
	-- 20000 -> 40000  => 20000 -> 40000		0010 -> 0010
	-- 40000 -> 60000  => 00000 -> 20000		0100 -> 0000
	-- 60000 -> 80000  => 20000 -> 40000		0110 -> 0010
	-- 80000 -> A0000  => 40000 -> 60000		1000 -> 0100
	-- A0000 -> C0000  => 40000 -> 60000		1010 -> 0100
	-- C0000 -> E0000  => 40000 -> 60000		1100 -> 0100
	-- E0000 ->100000  => 40000 -> 60000		1110 -> 0100

-- 768K ROM, split in 6, mapped ABCDEFEF
				                            -- bits 19 downto 16
	-- 00000 -> 20000  => 00000 -> 20000		0000 -> 0000
	-- 20000 -> 40000  => 20000 -> 40000		0010 -> 0010
	-- 40000 -> 60000  => 40000 -> 60000		0100 -> 0100
	-- 60000 -> 80000  => 60000 -> 80000		0110 -> 0110
	-- 80000 -> A0000  => 80000 -> A0000		1000 -> 1000
	-- A0000 -> C0000  => A0000 -> C0000		1010 -> 1010
	-- C0000 -> E0000  => 80000 -> A0000		1100 -> 1000
	-- E0000 ->100000  => A0000 -> C0000		1110 -> 1010

--2560K ROM, ABCDEFGH, ABCDIJKL, ABCDMNOP, ABCDQRST = SF2
                                      -- bits 21 downto 19 (bank)
	-- 00000 -> 80000 XX => 00000 -> 80000		0 XX -> 000
	-- 80000 ->100000 00 => 80000 ->100000		1 00 -> 001
	-- 80000 ->100000 01 =>100000 ->180000		1 01 -> 010
	-- 80000 ->100000 10 =>180000 ->200000		1 10 -> 011
	-- 80000 ->100000 11 =>200000 ->280000		1 11 -> 100

-- 128K ROM, mapped AAAAAAAA -> simple repeat
-- 256K ROM, mapped ABABABAB -> simple repeat
-- 512K ROM, mapped ABCDABCD -> simple repeat
-- 1MB and others            -> Straight mapping

ROM_A <=   "00000"&CPU_A(16 downto 0)                                       when rom_sz = X"020" -- 128K
      else "0000"&CPU_A(17 downto 0)                                        when rom_sz = X"040" -- 256K
      else "000"&CPU_A(19)&(CPU_A(17) and not CPU_A(19))&CPU_A(16 downto 0) when rom_sz = X"060" -- 384K
      else "000"&CPU_A(18 downto 0)                                         when rom_sz = X"080" -- 512K
      else "00" &CPU_A(19)&(CPU_A(18) and not CPU_A(19))&CPU_A(17 downto 0) when rom_sz = X"0C0" -- 768K
      else (CPU_A(19) and (rombank(0) and rombank(1)))
          &(CPU_A(19) and (rombank(0) xor rombank(1)))
          &(CPU_A(19) and not rombank(0))&CPU_A(18 downto 0)                when rom_sz = X"280" -- SF2
      else "00"&CPU_A(19 downto 0);                                                             -- 1MB and others

ROM_RD    <= CPU_PRE_RD and not CPU_ROM_SEL_N and CPU_PRAM_SEL_N and ((AC_RAM_CS_N and CD_RAM_CS_N) or not CD_EN);
ROM_CLKEN <= CPU_CLKEN;

-- PCE PORT (2026-09-06): debug taps, see the port declarations above. DBG_VDC_WR is a
-- one-CPU-cycle pulse on any CPU write that lands on VDC0 -- the same condition the
-- GHDL boot testbench counts via CPU_VDC0_SEL_N, so a hardware count and a sim count
-- mean exactly the same thing and can be compared directly.
DBG_CPU_A  <= CPU_A;
DBG_VDC_WR <= CPU_CE and not CPU_WR_N and not CPU_VDC0_SEL_N;
DBG_CPU_WR_N <= CPU_WR_N;
DBG_CPU_RD_N <= CPU_RD_N;
DBG_CPU_DO   <= CPU_DO;
DBG_CPU_DI   <= CPU_DI;
DBG_VCE_WR <= CPU_CE and not CPU_WR_N and not CPU_VCE_SEL_N;
DBG_VCE_DO <= CPU_DO;
DBG_VDC_RDY <= VDC0_BUSY_N and VDC1_BUSY_N;
DBG_CPU_CE  <= CPU_CE;
DBG_IRQ1_N  <= VDC0_IRQ_N and VDC1_IRQ_N;
DBG_IRQ2_N  <= CD_IRQ_N;

process( CLK ) begin
	if rising_edge( CLK ) then
		if RESET = '1' then
			rombank <= "00";
		elsif CPU_CE = '1' then
			-- CPU_A(12 downto 2) = X"7FC" means CPU_A & 0x1FFC = 0x1FF0
			if CPU_A(20) = '0' and ('0' & CPU_A(12 downto 2)) = X"7FC" and CPU_WR_N = '0' then
				rombank <= CPU_A(1 downto 0);
			end if;
		end if;
		RESET_N <= not RESET;
	end if;
end process;

PRAM : entity work.dpram generic map (15,8)
port map (
	clock		=> CLK,
	address_a=> CPU_A(14 downto 0),
	data_a	=> CPU_DO,
	wren_a	=> CPU_CE and not CPU_PRAM_SEL_N and not CPU_WR_N,
	q_a		=> PRAM_DO,

	address_b=> CLR_A,
	data_b	=> (others => '0'),
	wren_b	=> CLR_WE
);

CPU_PRAM_SEL_N <= CPU_A(20) or not CPU_A(19) or not ROM_POP;


RAM : entity work.dpram generic map (15,8)
port map (
	clock		=> CLK,
	address_a=> RAM_A(14 downto 0),
	data_a	=> CPU_DO,
	wren_a	=> CPU_CE and not CPU_RAM_SEL_N and not CPU_WR_N,
	q_a		=> RAM_DO,

	-- Port B: the cold-reset clear sweep normally, or the board's pattern test while
	-- RAMTEST_EN is asserted (core held in reset, so the two never overlap).
	address_b=> RAMB_A,
	data_b	=> RAMB_D,
	wren_b	=> RAMB_WE,
	q_b		=> RAMTEST_Q
);

RAM_A(12 downto 0)  <= CPU_A(12 downto 0);
RAM_A(14 downto 13) <= CPU_A(14 downto 13) when SGX = '1' else "00";

-- Backup RAM
BRM_A <= CPU_A(10 downto 0);
BRM_DI <= CPU_DO;
BRM_WE <= CPU_CE and not CPU_BRM_SEL_N and not CPU_WR_N;


-- NO_CD = 0: donor behaviour, byte-identical (still unconditional EN => '1', matching the
-- donor exactly -- CD_EN only gates ROM_RD's address-decode term and the Arcade Card
-- enable elsewhere, not this instantiation).
gen_cd: if NO_CD = 0 generate
begin
	CD : entity work.cd
	generic map( CDDA_DEPTH_LOG2 => CDDA_DEPTH_LOG2 )
	port map(
		CLK 			=> CLK,
		RST_N			=> RESET_N,
		EN				=> '1',

		EXT_A			=> CPU_A,
		EXT_DI		=> CPU_DO,
		EXT_DO		=> CD_DO,
		EXT_WR_N		=> CPU_WR_N,
		EXT_RD_N		=> CPU_RD_N,
		CPU_CE		=> CPU_CE,

		RAM_CS_N		=> CD_RAM_CS_N,
		BRAM_EN		=> CD_BRAM_EN,

		SEL_N			=> CD_SEL_N,
		IRQ_N			=> CD_IRQ_N,

		CD_STAT		=> CD_STAT,
		CD_MSG		=> CD_MSG,
		CD_STAT_GET	=> CD_STAT_GET,
		CD_COMM		=> CD_COMM,
		CD_COMM_SEND=> CD_COMM_SEND,
		CD_DOUT_REQ	=> CD_DOUT_REQ,
		CD_DOUT		=> CD_DOUT,
		CD_DOUT_SEND=> CD_DOUT_SEND,

		CD_DATA		=> CD_DATA,
		CD_DATA_WR	=> CD_DATA_WR,
		CD_AUDIO_WR	=> CD_AUDIO_WR,
		CD_SUBCD_WR	=> CD_SUBCD_WR,
		CD_DATA_END	=> CD_DATA_END,

		DBG_DATAIN_CNT => CD_DBG_DATAIN_CNT,
		DBG_FIRST8     => CD_DBG_FIRST8,
		DBG_SP         => CD_DBG_SP,
		DBG_ADPCM      => CD_DBG_ADPCM,
		DBG_COMM_POS   => CD_DBG_COMM_POS,
		DBG_COMM0      => CD_DBG_COMM0,
		DBG_COMM1      => CD_DBG_COMM1,
		DBG_SEL_CNT    => CD_DBG_SEL_CNT,
		DBG_FIFO_SPACE => CD_DBG_FIFO_SPACE,
		DBG_CDDA_SPACE => CD_DBG_CDDA_SPACE,
		DBG_FIFO_DROPS => CD_DBG_FIFO_DROPS,
		DBG_GDI        => CD_DBG_GDI,
		CD_DATAIN_SECTORS => CD_DATAIN_SECTORS,
		DBG_RD_TOTAL   => CD_DBG_RD_TOTAL,
		DBG_UNDERRUNS  => CD_DBG_UNDERRUNS,

		CD_REGION   => CD_REGION,
		CD_RESET		=> CD_RESET,

		DM				=> CD_DM,

		CD_SL			=> CDDA_SL,
		CD_SR			=> CDDA_SR,
		AD_S			=> ADPCM_S,

		ADPCM_RAM_A		=> ADPCM_RAM_A,
		ADPCM_RAM_DO	=> ADPCM_RAM_DO,
		ADPCM_RAM_WE	=> ADPCM_RAM_WE,
		ADPCM_RAM_REQ	=> ADPCM_RAM_REQ,
		ADPCM_RAM_SLOT_CNT => ADPCM_RAM_SLOT_CNT,
		ADPCM_RAM_DI	=> ADPCM_RAM_DI,
		ADPCM_RAM_READY=> ADPCM_RAM_READY
	);
end generate;

-- NO_CD /= 0 (Nano 20K): CD entirely absent (not just CD_EN='0' -- ADPCM_DRAM's 32 BSRAM
-- blocks exist the moment cd.vhd is elaborated at all, regardless of runtime enable).
-- Safe deselected/inactive defaults for every signal the CD instance would otherwise
-- drive, so the rest of pce_top.vhd's address decode and IRQ logic still analyses and
-- behaves sanely with no CD present.
gen_no_cd: if NO_CD /= 0 generate
begin
	CD_DO       <= (others => '0');
	CD_RAM_CS_N <= '1';
	CD_BRAM_EN  <= '0';
	CD_SEL_N    <= '1';
	CD_IRQ_N    <= '1';
	CD_COMM     <= (others => '0');
	CD_COMM_SEND<= '0';
	CD_DOUT     <= (others => '0');
	CD_DOUT_SEND<= '0';
	CD_DATA_END <= '0';
	CD_DBG_DATAIN_CNT <= (others => '0');
	CD_DBG_FIRST8     <= (others => '0');
	CD_DBG_SP         <= (others => '0');
	CD_DBG_ADPCM      <= (others => '0');
	CD_DBG_COMM_POS   <= (others => '0');
	CD_DBG_COMM0      <= (others => '0');
	CD_DBG_COMM1      <= (others => '0');
	CD_DBG_SEL_CNT    <= (others => '0');
	CD_DBG_FIFO_SPACE <= (others => '0');
	-- 0 = "no room", which DISABLES prefetch. Deliberately the fail-safe direction:
	-- a board that never wires this loses the speed-up, it does not overrun the FIFO.
	-- (The opposite default is what made an unwired FIFO_SPACE manufacture a fake stall
	-- in simulation -- see docs/MEMORY_BRIDGE_CONTRACT.md.)
	CD_DBG_CDDA_SPACE <= (others => '0');
	CD_DBG_FIFO_DROPS <= (others => '0');
	CD_DBG_GDI        <= (others => '0');
	CD_DBG_RD_TOTAL   <= (others => '0');
	CD_DBG_UNDERRUNS  <= (others => '0');
	CD_RESET    <= '0';
	CDDA_SL     <= (others => '0');
	CDDA_SR     <= (others => '0');
	ADPCM_S     <= (others => '0');
	ADPCM_RAM_A   <= (others => '0');
	ADPCM_RAM_DO  <= (others => '0');
	ADPCM_RAM_WE  <= '0';
	ADPCM_RAM_REQ <= '0';
	ADPCM_RAM_SLOT_CNT <= (others => '0');
end generate;

-- PCE PORT (2026-09-19): CD-RAM only answers when a disc is actually mounted.
--
-- THE BUG (measured, sim/boot with 1941 - Counter Attack, a 1MB SuperGrafx HuCard):
-- cd.vhd decodes physical banks $68-$87 as Super CD-ROM RAM
--     RAM_SEL  <= '1' when EXT_A(20 downto 13) >= x"68" and <= x"87"
--     RAM_CS_N <= not (RAM_SEL and EN)
-- and pce_top instantiates that CD with EN => '1', unconditionally. CD_RAM_CS_N therefore
-- goes low for banks $68-$87 whether or not a disc is present, and CD-RAM outranks ROM in
-- the CPU_DI mux below. A 1MB HuCard spans banks $00-$7F, so its TOP 192KB ($68-$7F) was
-- read from uninitialised CD-RAM instead of the cartridge. Measured at the failing
-- instruction: 59 of 59 reads in $68-$7F returned FF to the CPU while ROM_A was correct,
-- ROM_DO held the right byte and CPU_ROM_SEL_N was '0' -- the fetch worked and the mux
-- threw it away. 1941 then executed FF as opcodes, wrote 0x7F to the VDC address register,
-- abandoned VDC1 and never uploaded its palette: a black screen.
--
-- NOT a SuperGrafx bug. Anything over 832KB is affected -- Street Fighter II' (2560K),
-- Bomberman '94, Parodius Da!, Salamander, PC Genjin 3, Fire Pro Wrestling 3 and the 1MB
-- SGX titles. 512K cards never reach bank $68, which is why they always worked.
--
-- WHY REAL HARDWARE DOESN'T HAVE THIS: the two mappings are mutually exclusive. Mednafen's
-- huc.cpp maps banks $00-$7F to the cartridge on the HuCard path (PCE_IsCD = 0) and maps
-- NO CD-RAM at all; on the CD path (PCE_IsCD = 1) the "HuCard" is the System Card, which is
-- only 256KB at $00-$3F, and CD-RAM then owns $68-$87. A 1MB HuCard and CD-RAM are never
-- live together. Our always-on CD unit was a state the console cannot enter.
--
-- INHERITED FROM THE DONOR, not introduced here: upstream TurboGrafx16_MiSTer's
-- rtl/pce_top.vhd has the same EN => '1' with the same mux, so this is a real MiSTer bug
-- and worth reporting there. That makes this line a deliberate divergence -- do not
-- "restore donor behaviour" without reading the above.
--
-- WHY GATE HERE RATHER THAN EN => CD_EN ON THE CD INSTANCE: EN gates thirteen places
-- inside cd.vhd -- the $1800 register decode, BRAM_EN, the ADPCM reset and the SCSI/ADPCM/
-- CDDA state machines. Gating only the RAM claim keeps the blast radius at the three
-- consumers below, and when CD_EN = '1' this expression reduces to CD_RAM_CS_N exactly, so
-- a mounted-disc build is bit-identical to before. The CD path, which works today, cannot
-- regress by construction.
--
-- CD_EN is cd_mounted_i on Console 60K, which lives in iosys and is NOT cleared by
-- core_resetn, so it is stable and settled long before the CPU's first fetch.
CD_RAM_CS_N_G <= CD_RAM_CS_N or not CD_EN;

CD_RAM_A  <= '0' & AC_RAM_A when AC_RAM_CS_N = '0' else "1000" & CPU_A(17 downto 0);
CD_RAM_DO <= CPU_DO;
-- Gated too, and the WRITE matters as much as the read: without it a big HuCard writing
-- into its own bank $68-$7F range (an SF2'-style mapper write, say) would land in CD-RAM.
CD_RAM_RD <= CPU_PRE_RD and not (CD_RAM_CS_N_G and AC_RAM_CS_N);
CD_RAM_WR <= CPU_PRE_WR and not (CD_RAM_CS_N_G and AC_RAM_CS_N);

gen_ac : if AC_BUILD /= 0 generate
AC : ARCADE_CARD
port map(
	CLK     => CLK,
	RST_N   => RESET_N,

	EN      => CD_EN and AC_EN,
	WR_N    => CPU_WR_N,
	RD_N    => CPU_RD_N,
	A       => CPU_A,
	DI      => CPU_DO,
	DO      => AC_DO,
	SEL_N   => AC_SEL_N,

	RAM_CS_N=> AC_RAM_CS_N,
	RAM_A   => AC_RAM_A
);
end generate;

gen_no_ac : if AC_BUILD = 0 generate
	-- Deselected constants, matching what the card drives when it is not addressed.
	-- Every consumer (the CPU_DI mux, ROM_RD, CD_RAM_A/RD/WR) reads these as
	-- "Arcade Card not selected", so behaviour is identical to a build whose AC is
	-- present but never addressed -- minus the logic and the address-bus load.
	AC_DO       <= (others => '1');
	AC_SEL_N    <= '1';
	AC_RAM_CS_N <= '1';
	AC_RAM_A    <= (others => '0');
end generate;

CPU_WAIT_N_I <= ROM_RDY and CD_RAM_RDY and not CPU_PAUSE_EN;
DBG_WAIT_EVER <= WAIT_EVER_LOW;

-- Sticky, not sampled. A heartbeat sample of WAIT_N can sit entirely between stalls and
-- report "never asserted" on a design that stalls constantly, which is how the earlier
-- claim was produced. This latches the first stall and never clears.
process (CLK) begin
	if rising_edge(CLK) then
		if RESET_N = '0' then
			WAIT_EVER_LOW <= '0';
		elsif CPU_WAIT_N_I = '0' then
			WAIT_EVER_LOW <= '1';
		end if;
	end if;
end process;

PSG_SR <= signed(PCE_SR(23 downto 8));
PSG_SL <= signed(PCE_SL(23 downto 8));

	DBG_VDC_SCREEN <= VDC0_SCREEN_DBG;

end rtl;
