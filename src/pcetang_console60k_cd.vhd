-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Phase 2: Tang Console 60K, the combined target -- PCE + PCE-CD + SGX all
-- elaborated together (NO_CD=>0, LITE=>0, SGX=>'1'), not a separate SGX variant file.
-- Sibling to pcetang_console60k.vhd's Phase 1 (HuCard-only, no CD, no SGX) build.
--
-- SGX (2026-08-29): LITE flipped 1->0 and SGX flipped '0'->'1' for real, permanently --
-- this board's target config is PCE+PCE-CD+SGX combined, per direct instruction, not a
-- separate SGX variant. Needed a real Gowin BSRAM cross-instance-merge bug fixed first
-- (huc6270.vhd's BG_COLOR/SPR_COLOR, commit 2f7ccdc, gated on a new SGX_BUILD generic
-- so boards without a second VDC instance are unaffected -- see that commit and session
-- memory for the full investigation, including a reverted first attempt that regressed
-- Nano 20K). Real gw_sh, confirmed: 0 setup/hold violations, BSRAM 113/118 (96%),
-- clk_pce 42.920/42.857 MHz (+0.15%), clk_sdram 120.273/120 MHz (+0.23%) -- fits, but
-- razor-thin on both clocks and BSRAM, essentially zero headroom for future growth on
-- this board. LITE=0 also elaborates the cheat-code engine (GAMEGENIE/CODES,
-- build_console60k_cd.tcl now includes cheatcodes.sv) -- stays dead-code-swept since
-- GG_EN='0', costs nothing in the measurement above.
--
-- VIDEO PATH: pce2hdmi_sd.sv (line-doubling scandoubler), NOT pce2hdmi.sv (full-frame
-- capture) -- a full-frame buffer at this board's ~19-33 real measured BSRAM block cost
-- (docs/OVERHEAD.md section 1, and the legal-stub A/B in section 5-7) left no room for
-- CD's real 64KB ADPCM_DRAM. The scandoubler measures ~1 block by construction. Real
-- history: two failed full-64KB-ADPCM attempts (BSRAM 118/118, routing fails outright),
-- an interim 16KB-ADPCM reduction that passed (115/118) as a documented capacity
-- tradeoff, then this scandoubler swap restoring full 64KB fidelity -- see
-- docs/ARCHITECTURE.md's "Phase 2" section and docs/OVERHEAD.md for the complete real
-- measurement history behind this design. Real precedent for the technique:
-- MiSTle-Dev/FPGA-Companion's MiSTeryNano (same Tang board family) uses the same
-- line-doubling approach for Atari ST.
--
-- CD_COMM/CD_DATA/CD_STAT (the SCSI-command host interface) had a minimal target stub
-- added 2026-08-28 -- see the note below at that date. Real CD/CHD function (actual
-- disc data, not just "responds to a command") still needs BL616 firmware SCSI-target
-- work, unstarted, separate from and unblocked by this FPGA-side result.
--
-- AUDIO (2026-08-26): PSG_SL/PSG_SR/CDDA_SL/CDDA_SR/ADPCM_S are wired real (previously
-- open), into pce2hdmi_sd.sv's new audio ports -- deliberately, to correct a
-- silent-audio measurement (docs/ARCHITECTURE.md's Phase 2 section). This is NOT a real
-- mixer: summed only, no resampling, no CDC synchronizer across the clk_pce/clk_audio
-- boundary (relies on the SDC's asynchronous clock group, so no real timing check runs
-- on this path either). Real numbers with this wiring: BSRAM 110/118 (94%). Real audio
-- correctness (mixing, resampling, CDC) is unstarted work, same status as the picture.
--
-- ROM + CD-RAM on real SDRAM (2026-08-28): the on-chip 32K ROM buffer and the CD-RAM
-- stub (both previously `open`/unbacked) are replaced by bridges to sdram.sv's port B
-- (ROM, 256KB, exact real syscard3.pce size) and port C (CD-RAM, 256KB, cd.vhd's own
-- RAM_SEL window) -- same recipe as pcetang_primer25k_cd.vhd's own ROM+CD-RAM work, see
-- that file's header for the fuller rationale and pcetang_console60k.vhd's header for
-- the sibling ROM-only version of this same change. `CD_EN` flipped '0'->'1' so the CD
-- subsystem (and CD-RAM's real decode) actually elaborates. Also added `core_resetn`
-- (this board was still missing the reset-gating fix pcetang_console60k.vhd/
-- pcetang_primer25k.vhd already carry -- now that ROM reads have real SDRAM latency,
-- without it the CPU could issue ROM_RD mid-load, racing the write bridge on port B).
--
-- ADPCM OFFLOAD (2026-08-28): moved off the on-chip dpram(17,4) shim onto sdram.sv's
-- port C, shared with the CD-RAM bridge above via a real owner arbiter (cdr_owner_t) --
-- same design as pcetang_primer25k_cd.vhd's own ADPCM offload, copied here rather than
-- re-derived. This board previously kept ADPCM on-chip deliberately (real BSRAM
-- headroom existed and it wasn't broken) -- moved anyway per direct request, for
-- consistency with Primer 25K CD's design. See that file's own ADPCM_SDRAM_BASE
-- comment for the real interface trace (cd.vhd's DRAM_CLKEN timing, the byte-spans-
-- two-WRITE-slots bug it already found and fixed, not re-litigated here).
--
-- Real gw_sh, confirmed: 0 setup/hold violations, BSRAM 94/118 (80%) -> 62/118 (53%)
-- -- 32 blocks freed, matching ADPCM_DRAM's real cost exactly (same number Primer 25K
-- CD's own offload measured). clk_pce 44.843/42.857 MHz (+4.63%, improved again),
-- clk_sdram 170.122/120 MHz (+41.8%, comfortable).
--
-- SCSI TARGET STUB (2026-08-28): real, unmodified from pcetang_primer25k_cd.vhd's own
-- design (spec-checked there against Mednafen's pce_fast/pcecd_drive.cpp, see that
-- file's own signal-block comment for the full protocol trace) -- copied verbatim, not
-- re-derived. Any command other than REQUEST SENSE (0x03) gets CHECK CONDITION;
-- REQUEST SENSE gets real NOT-READY sense data (NEC's own 0x0B "no disc, tray closed")
-- pushed through CD_DATA/CD_DATA_WR into SCSI.vhd's own DATA-IN FIFO. Answers a real
-- syscard's boot-time polling with the honest "no disc" response; does not implement
-- any command needed once a real disc image is actually served (unstarted BL616
-- firmware work, see the top of this header). No hardware or simulation test of this
-- responder exists on this board specifically -- same caveat as Primer 25K CD's.
--
-- Real gw_sh, confirmed: 0 setup/hold violations, BSRAM unchanged at 94/118 (80%) --
-- cd_fifos.vhd's SCSI_FIFO was already shrunk 4096->64 entries by Primer 25K CD's own
-- earlier fix (that file is shared, not per-board), so un-sweeping it here via a real
-- CD_STAT_GET cost nothing extra. clk_pce 44.559/42.857 MHz (+3.97%, improved from the
-- pre-SCSI-stub build's +0.55%), clk_sdram 136.228/120 MHz (+13.5%).
--
-- ARCADE CARD RAM (2026-08-29): DONE for real -- sdram.sv's per-port address bus is now
-- 25 bits (32MB), not 21 (2MB) -- see that file's own header for the real chip
-- confirmation (Winbond W9825G6KH-6, 256Mbit, 4 banks) that made this a real port-width
-- change, not a redesign. AC_RAM_A (arcade.sv, 21 bits = 2MB) now gets its own real,
-- non-overlapping window at AC_SDRAM_BASE (0x200000, the 2MB boundary) instead of
-- aliasing into CD-RAM's 256KB slice -- decoded from cd_ram_a's own top bit (see the
-- CDR_IDLE arbiter's own comment for the exact decode). `AC_EN` is now '1'. Real gw_sh
-- result for this change: see this file's own build-log commit message (not repeated
-- here to avoid drift -- check `git log` for the real numbers, not this comment).
--
-- Otherwise identical to pcetang_console60k.vhd: ROM loading via iosys_bl616, real
-- joypad input.
--
-- NOT VERIFIED ON HARDWARE. Joypad button mapping (iosys_bl616's DS2/SNES-shaped
-- joy1[11:0] onto pce_top's 2-select-bit/4-data-bit protocol) is a reasonable first
-- guess, not verified against real PCE controller protocol documentation.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_console60k_cd is
   port (
      clk         : in    std_logic;                      -- 50 MHz crystal
      key_reset_n : in    std_logic;                       -- S2, active low
      leds_n      : out   std_logic_vector(1 downto 0);

      O_sdram_clk   : out   std_logic;
      O_sdram_cke   : out   std_logic;
      O_sdram_cs_n  : out   std_logic;
      O_sdram_cas_n : out   std_logic;
      O_sdram_ras_n : out   std_logic;
      O_sdram_wen_n : out   std_logic;
      O_sdram_dqm   : out   std_logic_vector(1 downto 0);
      O_sdram_addr  : out   std_logic_vector(12 downto 0);
      O_sdram_ba    : out   std_logic_vector(1 downto 0);
      IO_sdram_dq   : inout std_logic_vector(15 downto 0);

      -- HDMI
      tmds_clk_n  : out   std_logic;
      tmds_clk_p  : out   std_logic;
      tmds_d_n    : out   std_logic_vector(2 downto 0);
      tmds_d_p    : out   std_logic_vector(2 downto 0);

      -- BL616 UART link. Real pins confirmed 2026-09-01 (V14/U15, see
      -- pcetang_console60k.cst) against tangcore/monitor's own hardware-proven
      -- assignment -- the original guess (R13/U13, the JTAG TDI/TDO pins) was real but
      -- wrong, see that .cst file's header for the full story.
      uart_rxd    : in    std_logic;
      uart_txd    : out   std_logic
   );
end entity;

architecture rtl of pcetang_console60k_cd is

   component console60k_pll is
      port (
         clkin     : in  std_logic;
         reset     : in  std_logic;
         clk_pce   : out std_logic;
         clk_sdram : out std_logic;
         lock      : out std_logic
      );
   end component;

   -- 2026-09-06: swapped to the 720p PLL -- some real HDMI sinks reject the 480p60
   -- output outright ("no signal"), while 1280x720p60 is near-universally accepted.
   -- gw_sh-clean and confirmed on real hardware (monitor locks 1280x720p60). See
   -- pcetang_console60k_hdmi_pll_720p.vhd for the real PLLA derivation.
   component pcetang_console60k_hdmi_pll_720p is
      port (
         clkin        : in  std_logic;
         reset        : in  std_logic;
         clk_pixel    : out std_logic;
         clk_5x_pixel : out std_logic;
         lock         : out std_logic
      );
   end component;

   component sdram is
      port (
         clk        : in    std_logic;
         init       : in    std_logic;
         SDRAM_A    : out   std_logic_vector(12 downto 0);
         SDRAM_DQ   : inout std_logic_vector(15 downto 0);
         SDRAM_BA   : out   std_logic_vector(1 downto 0);
         SDRAM_DQML : out   std_logic;
         SDRAM_DQMH : out   std_logic;
         SDRAM_nWE  : out   std_logic;
         SDRAM_nCAS : out   std_logic;
         SDRAM_nRAS : out   std_logic;
         SDRAM_nCS  : out   std_logic;
         SDRAM_CKE  : out   std_logic;
         SDRAM_CLK  : out   std_logic;
         -- PCE PORT (2026-08-29): widened 21->25 bits -- see sdram.sv's own header note.
         RAM_A_ADDR : in    std_logic_vector(24 downto 0);
         RAM_A_REQ  : in    std_logic;
         RAM_A_RD_n : in    std_logic;
         RAM_A_DI   : in    std_logic_vector(15 downto 0);
         RAM_A_DO   : out   std_logic_vector(15 downto 0);
         RAM_A_WAIT : out   std_logic;
         RAM_A_LINE_REFILL : in    std_logic;
         RAM_A_LINE_DO     : out   std_logic_vector(63 downto 0);
         RAM_B_ADDR : in    std_logic_vector(24 downto 0);
         RAM_B_REQ  : in    std_logic;
         RAM_B_WE   : in    std_logic;
         RAM_B_DI   : in    std_logic_vector(7 downto 0);
         RAM_B_DO   : out   std_logic_vector(7 downto 0);
         RAM_B_WAIT : out   std_logic;
         RAM_C_ADDR : in    std_logic_vector(24 downto 0);
         RAM_C_REQ  : in    std_logic;
         RAM_C_RD_n : in    std_logic;
         RAM_C_DI   : in    std_logic_vector(7 downto 0);
         RAM_C_DO   : out   std_logic_vector(7 downto 0);
         RAM_C_WAIT : out   std_logic;
         -- PCE PORT (2026-08-30): real 16-bit + line-refill additions for a wide port-C
         -- client (VRAM1/SGX, not used on this board -- Console 60K keeps VRAM1 on-chip)
         -- -- see sdram.sv's own header. Tied off explicitly below, same mixed-language-
         -- boundary rationale as every other RAM_C_*/RAM_A_LINE_REFILL tie-off here.
         RAM_C_WIDE : in    std_logic;
         RAM_C_DI16 : in    std_logic_vector(15 downto 0);
         RAM_C_DO16 : out   std_logic_vector(15 downto 0);
         RAM_C_LINE_REFILL : in    std_logic;
         RAM_C_LINE_DO     : out   std_logic_vector(63 downto 0)
      );
   end component;

   component iosys_bl616 is
      generic (
         FREQ      : integer := 21_477_000;
         COLOR_LOGO : std_logic_vector(14 downto 0) := (others => '0');
         CORE_ID   : std_logic_vector(15 downto 0) := (others => '0');
         LOADING_STATE : std_logic_vector(7 downto 0) := (others => '0');
         -- Real RTL debug-trace channel, enabled on THIS board only -- see
         -- iosys_bl616.v's own DBG_TRACE parameter comment for the measured timing
         -- cost it carries on boards that don't read traces.
         DBG_TRACE : integer := 0
      );
      port (
         clk       : in  std_logic;
         hclk      : in  std_logic;
         resetn    : in  std_logic;

         overlay       : out std_logic;
         overlay_x     : in  std_logic_vector(7 downto 0);
         overlay_y     : in  std_logic_vector(7 downto 0);
         overlay_color : out std_logic_vector(14 downto 0);
         joy1          : in  std_logic_vector(11 downto 0);
         joy2          : in  std_logic_vector(11 downto 0);
         hid1          : out std_logic_vector(15 downto 0);
         hid2          : out std_logic_vector(15 downto 0);

         rom_loading   : out std_logic_vector(7 downto 0);
         rom_do        : out std_logic_vector(7 downto 0);
         rom_do_valid  : out std_logic;

         mgmt_address   : out std_logic_vector(15 downto 0);
         mgmt_read      : out std_logic;
         mgmt_readdata  : in  std_logic_vector(15 downto 0);
         mgmt_write     : out std_logic;
         mgmt_writedata : out std_logic_vector(15 downto 0);
         fdd_request    : in  std_logic_vector(1 downto 0);

         kbd_data       : out std_logic_vector(7 downto 0);
         kbd_data_valid : out std_logic;

         core_config : out std_logic_vector(31 downto 0);

         cd_mounted           : out std_logic;
         toc_wr               : out std_logic;
         toc_track            : out std_logic_vector(7 downto 0);
         toc_control          : out std_logic_vector(7 downto 0);
         toc_lba              : out std_logic_vector(23 downto 0);
         cd_sector_data       : out std_logic_vector(7 downto 0);
         cd_sector_data_valid : out std_logic;
         cd_sector_data_last  : out std_logic;
         cd_sector_req        : in  std_logic;
         cd_sector_lba        : in  std_logic_vector(23 downto 0);
         cd_sector_is_audio   : in  std_logic;
         dbg_trace_req        : in  std_logic;
         dbg_trace_tag        : in  std_logic_vector(7 downto 0);
         dbg_trace_data       : in  std_logic_vector(63 downto 0);

         uart_rx : in  std_logic;
         uart_tx : out std_logic
      );
   end component;

   component pce2hdmi_sd is
      generic (
         MAX_LINE_SAMPLES : integer := 540;
         VIDEOID       : integer := 2;
         VIDEO_REFRESH : real    := 60.0;
         CLKFRQ        : integer := 27000;
         SCREEN_WIDTH  : integer := 720;
         SCREEN_HEIGHT : integer := 480
      );
      port (
         clk    : in std_logic;
         resetn : in std_logic;

         video_r    : in std_logic_vector(2 downto 0);
         video_g    : in std_logic_vector(2 downto 0);
         video_b    : in std_logic_vector(2 downto 0);
         video_ce   : in std_logic;
         video_hs   : in std_logic;
         video_vs   : in std_logic;
         video_hbl  : in std_logic;
         video_vbl  : in std_logic;

         overlay       : in  std_logic;
         overlay_x     : out std_logic_vector(7 downto 0);
         overlay_y     : out std_logic_vector(7 downto 0);
         overlay_color : in  std_logic_vector(14 downto 0);

         clk_pixel    : in std_logic;
         clk_5x_pixel : in std_logic;

         psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s : in std_logic_vector(15 downto 0);

         tmds_clk_n : out std_logic;
         tmds_clk_p : out std_logic;
         tmds_d_n   : out std_logic_vector(2 downto 0);
         tmds_d_p   : out std_logic_vector(2 downto 0)
      );
   end component;

   signal clk_pce, clk_sdram, clk_pixel, clk_5x_pixel : std_logic;
   signal pll_lock, hdmi_pll_lock, reset_n : std_logic;
   signal sdram_init : std_logic;

   signal psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s : signed(15 downto 0);

   signal overlay       : std_logic;
   signal overlay_x     : std_logic_vector(7 downto 0);
   signal overlay_y     : std_logic_vector(7 downto 0);
   signal overlay_color : std_logic_vector(14 downto 0);
   signal joy1_ds2      : std_logic_vector(11 downto 0);
   signal hid1, hid2    : std_logic_vector(15 downto 0);
   signal joy1          : std_logic_vector(11 downto 0);
   signal joy2          : std_logic_vector(11 downto 0);

   -- Real multitap/2-player support (2026-08-31) -- see joy_active's own
   -- header comment further down for the full derivation.
   signal core_config_r : std_logic_vector(31 downto 0) := (others => '0');
   signal multitap_en   : std_logic;
   signal joy_port      : unsigned(2 downto 0) := (others => '0');
   signal joy_out_r     : std_logic_vector(1 downto 0) := (others => '0');
   signal joy_active    : std_logic_vector(11 downto 0);

   signal rom_loading  : std_logic_vector(7 downto 0);
   signal rom_do       : std_logic_vector(7 downto 0);
   signal rom_do_valid : std_logic;

   -- ROM + CD-RAM/Arcade-Card window, both real SDRAM now (2026-08-28) -- same recipe
   -- as pcetang_primer25k_cd.vhd's own ROM (port B) + CD-RAM (port C) bridges, see that
   -- file's header for the fuller rationale. Console 60K CD needs this for real: a
   -- syscard BIOS is 256KB, far past what fit on-chip before (32K), and CD-RAM/Arcade
   -- Card backup RAM has no on-chip home at all in the donor once real size is honored.
   --
   -- No VRAM0-on-SDRAM co-tenant here (EXT_VRAM0=>0, stays on-chip -- Console 60K's
   -- whole engine minus ROM/CD-RAM already fits), so the split is simpler than Primer
   -- 25K's: CD-RAM at 0x040000 (256KB, cd.vhd's own RAM_SEL window, confirmed from
   -- source same as Primer 25K's).
   -- PCE PORT (2026-08-29): all three base constants widened 21->25 bits alongside
   -- sdram.sv's own port widening. AC_SDRAM_BASE (below, near AC_EN) is a real,
   -- non-overlapping 2MB window for Arcade Card RAM, placed at the 2MB boundary --
   -- see that constant's own comment for why this closes the real aliasing bug the
   -- file's own header used to describe.
   -- ROM dynamic-size port (2026-08-30, real lever 17 fix, was hardcoded 256K syscard-
   -- only): moved from 0x000000 to the free gap after ADPCM_SDRAM_BASE's own 128KB
   -- region, widened 256KB->1MB -- same real HuCard capacity Nano 20K CD already
   -- supports (128K-1MB dynamic bucket rounding, see rom_sz_r below).
   --
   -- MOVED + WIDENED AGAIN 2026-08-30 (real lever 19 fix): Street Fighter II' Champion
   -- Edition is a genuine 2560KB HuCard using pce_top.vhd's own already-real bank-switch
   -- mapper (rombank, rom_sz=X"280" -- verified real, latches on writes to ROM offset
   -- 0x1FF0, matches real SF2' cartridge hardware, zero RTL change needed there). The
   -- 1MB window/counter from lever 17 couldn't even COUNT past 1MB. Moved past Arcade
   -- Card RAM's own 2MB window (0x0A0000's old gap was too small for 4MB) -- this chip
   -- is the same real 32MB Winbond as Primer 25K CD's, trivial capacity margin here.
   -- **Real risk, flagged not hidden**: this board had ZERO free timing margin left
   -- after lever 17 (clk_pce +0.236%, clk_sdram +0.017%) -- this change needs a real
   -- gw_sh re-run before being trusted, may not fit even though the RTL is correct.
   constant ROM_SDRAM_BASE   : unsigned(24 downto 0) := to_unsigned(16#400000#, 25);
   constant ROM_SDRAM_ABITS  : integer := 22;  -- 4MB, real SF2' ceiling (dynamic, see rom_sz_r)
   constant CDRAM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#040000#, 25);

   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal rom_loading_r : std_logic := '0';
   signal rom_sz_r    : std_logic_vector(11 downto 0) := x"040";

   -- Core reset gated on rom_loading (same fix as pcetang_console60k.vhd's
   -- core_resetn) -- held in reset through the whole ROM load, released exactly on
   -- loading's falling edge. Needed now that ROM reads have real SDRAM latency: without
   -- this, the CPU could run and issue ROM_RD mid-load, racing the write bridge on the
   -- same SDRAM port B.
   signal core_resetn : std_logic := '0';

   -- TEMP DEBUG (2026-09-06): traces the first N cart-ROM fetches out over
   -- iosys_bl616.v's real RTL debug-trace channel, so they land as text lines in
   -- debug.log on the SD card instead of having to be painted on HDMI and read off the
   -- screen. Gated on core_resetn (the CPU actually running), NOT on reset_n -- earlier
   -- probe rounds produced false positives precisely because reset_n-gated flags latch
   -- during the SDRAM's own power-on init, before anything real has happened.
   signal dbg_trace_req  : std_logic := '0';
   signal dbg_trace_tag  : std_logic_vector(7 downto 0) := (others => '0');
   signal dbg_trace_data : std_logic_vector(63 downto 0) := (others => '0');
   signal dbg_fetch_cnt  : unsigned(7 downto 0) := (others => '0');
   signal dbg_hb_cnt     : unsigned(21 downto 0) := (others => '0');
   signal rd_state_bits  : std_logic_vector(1 downto 0);

   signal romb_addr : std_logic_vector(24 downto 0);
   signal romb_req  : std_logic := '0';
   signal romb_we   : std_logic := '0';
   signal romb_di   : std_logic_vector(7 downto 0);
   signal romb_do   : std_logic_vector(7 downto 0);
   -- REAL CDC FIX (2026-09-06). sdram.sv runs on clk_sdram (120 MHz); every consumer of
   -- these WAIT flags runs on clk_pce (42.857 MHz). They were sampled DIRECTLY by the
   -- bridge state machines with no synchroniser -- an asynchronous input into a FSM.
   --
   -- Static timing analysis cannot see this: the crossing is an unconstrained async path,
   -- so gw_sh reports "0 violations" no matter how bad it is, and the real behaviour is
   -- placement luck that changes on every rebuild. That is exactly what was observed on
   -- hardware across three builds that ALL reported 0 setup/0 hold violations:
   --   build 4a1f7073 -- ROM self-test swept all 512K, 2 read timeouts, CPU ran to 76958
   --                    VDC writes
   --   build 4bff83b3 -- identical read bridge, only sweep-side logic added: the sweep
   --                    aborted on its FIRST read and the runtime timeout counter
   --                    saturated at 65535 (~27k stalled reads/second)
   -- A metastable or skewed romb_wait makes the bridge miss the completion edge, which
   -- then presents as the deadlock/stall this file's read bridge already had to grow a
   -- watchdog for.
   --
   -- Two flops in the destination domain. The 2-cycle latency this adds is harmless: the
   -- read bridge's own settle is 5 cycles (WAIT rises ~1 clk_sdram + 2 sync << 5) and
   -- RB_WAIT waits indefinitely for the fall.
   signal romb_wait_raw : std_logic;
   signal romb_wait_m   : std_logic := '0';
   signal romb_wait : std_logic := '0';

   -- RB_ADDR added 2026-09-06 -- see the read bridge's own header comment for the real
   -- hardware deadlock it fixes. It exists purely to give the address a full clk_pce
   -- cycle of setup before the request toggles.
   type romb_state_t is (RB_IDLE, RB_ADDR, RB_SETTLE, RB_WAIT);

   -- REAL FIX 2026-09-06/07: the "toggle request, count 5 cycles, then sample romb_wait"
   -- handshake every bridge here used is UNSOUND, and the 2-flop WAIT synchroniser added
   -- earlier made it worse by delaying WAIT another 2 clk_pce without the settle being
   -- extended to match. If WAIT has not risen yet when the counter expires, the bridge
   -- concludes "done", latches stale data, and immediately toggles the request again --
   -- and on sdram.sv's XOR-detected port B that second toggle CANCELS the still-pending
   -- first request. The FPGA-written pattern self-test caught it outright: 88 of 256
   -- bytes wrong with no UART or loader in the path at all, first failure "wrote 0x5A,
   -- read 0x00" (i.e. the write never landed). The loader was never the problem -- it
   -- only looked healthier because UART pacing spaces its writes ~214 cycles apart,
   -- while the self-test issues them back to back.
   --
   -- Replaced by a real handshake: latch the fact that WAIT was ever observed HIGH, and
   -- only call the transaction complete when it has gone high and come back low. The
   -- cache-hit path in sdram.sv never raises WAIT at all, so that case is covered by a
   -- generous fixed delay instead (SETTLE_HIT) rather than by a 5-cycle guess.
   constant SETTLE_HIT : unsigned(5 downto 0) := "010000";  -- 16 clk_pce, hit-path only
   signal rd_state       : romb_state_t := RB_IDLE;
   signal rd_settle_cnt  : unsigned(5 downto 0) := (others => '0');
   signal rd_seen_wait   : std_logic := '0';
   -- One-cycle pulse when the bridge latches a byte for the CPU. The trap's first
   -- version sampled on `rd_state = RB_SETTLE and rom_rdy_i = '1'`, which is never
   -- true: rom_rdy_i is held LOW for the whole of RB_SETTLE and only rises at
   -- completion. The buffer came back all zeros as a result.
   signal rd_done        : std_logic := '0';
   signal rd_req         : std_logic := '0';
   signal rd_addr        : std_logic_vector(24 downto 0);
   -- Watchdog + its escape counter -- see the read bridge's header for why a CDC fix
   -- ships WITH a live recurrence counter rather than on its own.
   signal rd_wdog        : unsigned(11 downto 0) := (others => '0');
   signal dbg_rd_timeout_cnt : unsigned(15 downto 0) := (others => '0');

   -- ROM-load byte holding register + drop counter (2026-09-07). The write bridge only
   -- samples rom_do_valid while it is in RB_IDLE. Any byte arriving while it is mid
   -- transaction was SILENTLY DROPPED -- yet rom_wr_addr (in the other process) still
   -- incremented, so that address kept whatever stale content SDRAM already held. That
   -- reads back as a random byte, in BOTH bit directions, scattered through the image --
   -- exactly what the run-8 dump shows now that the SDRAM interface itself is proven
   -- clean (pattern self-test: 0 mismatches in 256 bytes).
   -- One byte of holding is enough by a wide margin: the UART delivers a byte every
   -- ~214 clk_pce cycles at 2 Mbaud while a write completes in ~25, so the bridge is
   -- idle >90% of the time and only needs to cover the occasional overlap.
   -- wr_drop_cnt counts any byte lost even WITH the holding register, so the next run
   -- reports whether this was really the mechanism instead of leaving it assumed.
   signal wr_hold_valid  : std_logic := '0';
   signal wr_hold_data   : std_logic_vector(7 downto 0) := (others => '0');
   signal wr_hold_addr   : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal wr_drop_cnt    : unsigned(15 downto 0) := (others => '0');

   signal wr_state       : romb_state_t := RB_IDLE;
   signal wr_settle_cnt  : unsigned(5 downto 0) := (others => '0');
   signal wr_seen_wait   : std_logic := '0';
   signal wr_req         : std_logic := '0';
   signal wr_addr        : std_logic_vector(24 downto 0);
   signal wr_data        : std_logic_vector(7 downto 0);

   -- TEMP DEBUG (2026-09-06): ROM-image self-test. A GHDL boot testbench (sim/boot/,
   -- commit eab68ee) proved this exact ROM boots pce_top given an IDEAL zero-wait ROM --
   -- first VDC write at 15.28 ms, 7 distinct ROM banks touched, VBLANK running -- while
   -- the same ROM on real hardware stays black. That bisection leaves two candidates the
   -- testbench structurally cannot reach: the SDRAM-resident ROM image being wrong, and
   -- synthesis/timing-level failures. This settles the first one.
   --
   -- Between the end of the MCU's ROM load and the release of core_resetn (a window
   -- where port B is otherwise idle and the CPU is still held in reset, so nothing can
   -- race it) this FSM sweeps the whole loaded image back out of SDRAM, accumulating a
   -- rotate-and-add checksum, and emits one trace line per 16KB block. Comparing those
   -- against the same checksum computed over the .pce file on the PC (see
   -- scripts/rom_checksum.py) localises any corruption to a 16KB block, or rules the
   -- image out entirely. Only ~9 bytes of the trace payload are used per block, and
   -- blocks are ~2.3 ms apart, far wider than the ~50 us a 10-byte trace frame takes at
   -- 2 Mbaud, so no trace can overrun the single-outstanding channel.
   -- 32KB blocks: 16 per pass for a 512K HuCard, so TWO passes plus a 32-sample
   -- heartbeat come to 64 trace lines total -- the same volume as the previous run that
   -- was known to survive the MCU's SD-write path intact. (An earlier opcode-9 bug
   -- truncated debug.log mid-line, so trace volume is not a free parameter here.)
   constant VFY_BLK_BITS : integer := 15;
   type vfy_state_t is (VF_IDLE,
                        -- SDRAM pattern self-test phase, runs first (see PAT_BASE)
                        PT_WA, PT_WR, PT_WS, PT_RA, PT_RR, PT_RS, PT_EMIT,
                        WR_W, WR_R, WR_C, WR_EMIT,
                        VF_REQ, VF_ADDR, VF_SETTLE, VF_WAIT, VF_ACC,
                        VF_EMIT, VF_GAP, VF_RESUME, VF_DONE);
   signal vfy_state   : vfy_state_t := VF_IDLE;
   signal vfy_active  : std_logic := '0';
   signal vfy_req     : std_logic := '0';
   signal vfy_addr    : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal vfy_len     : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal vfy_sum     : unsigned(31 downto 0) := (others => '0');
   signal vfy_blk     : unsigned(7 downto 0) := (others => '0');
   signal vfy_settle  : unsigned(5 downto 0) := (others => '0');
   signal vfy_seen_wait : std_logic := '0';
   -- Bounded so a stuck SDRAM can never keep the core in reset forever: on timeout the
   -- sweep gives up, emits what it has, and releases the core anyway.
   signal vfy_timeout : unsigned(11 downto 0) := (others => '0');
   -- ~23 ms spacing between checksum emits, see VF_EMIT's comment.
   signal vfy_gap     : unsigned(19 downto 0) := (others => '0');
   signal vfy_emit    : std_logic := '0';
   signal vfy_emit_d  : std_logic := '0';
   signal vfy_sum_lat : unsigned(31 downto 0) := (others => '0');
   signal vfy_blk_lat : unsigned(7 downto 0) := (others => '0');
   -- The sweep runs TWICE over the same bytes, and both results are emitted (pass 0 as
   -- tags 0x00-0x3F, pass 1 as 0x40-0x7F). This is what separates the two candidates
   -- instead of just flagging one:
   --   passes agree with each other AND with the file -> image is good, read path is
   --     good; the fault is elsewhere entirely.
   --   passes agree with each other but NOT the file  -> the image really is corrupt.
   --   passes DISAGREE with each other                -> the READ PATH is unreliable
   --     (the image may be perfectly fine), which is the far more likely fault given
   --     the bridge's unsynchronised clk_pce/clk_sdram crossing.
   -- Without the second pass a mismatch would be ambiguous between those last two, and
   -- would most likely have been misread as "image corrupt" -- costing a hardware cycle
   -- and pointing the whole investigation the wrong way.
   -- RAW READ-BACK DUMP (2026-09-06). Run 2 proved the deadlock fix works (VDC writes
   -- 9 -> 76958, climbing) but every 32KB checksum came back wrong with BOTH passes
   -- agreeing byte-for-byte -- so SDRAM reads are now perfectly repeatable yet do not
   -- match the file. A checksum cannot be inverted, and no simple transformation of the
   -- file (byte-pair swap, byte-lane duplication, +-1/+512 offsets, 16-bit half swap)
   -- reproduces the observed value, so guessing the corruption is a dead end. Dump the
   -- first 128 bytes verbatim instead and diff them against the .pce directly -- that
   -- names the transformation in one hardware cycle instead of N.
   signal vfy_dump     : std_logic_vector(63 downto 0) := (others => '0');
   signal vfy_dump_lat : std_logic_vector(63 downto 0) := (others => '0');
   signal vfy_is_dump  : std_logic := '0';
   signal vfy_dump_idx : unsigned(3 downto 0) := (others => '0');
   -- Latched at VF_EMIT: vfy_dump_idx increments and vfy_is_dump is cleared before
   -- the trace process fires (one cycle later, on vfy_emit_d), same reason vfy_sum
   -- and vfy_pass are latched there.
   signal vfy_is_dump_lat  : std_logic := '0';
   signal vfy_dump_idx_lat : unsigned(3 downto 0) := (others => '0');
   constant VFY_DUMP_BYTES : integer := 128;

   -- SDRAM PATTERN SELF-TEST (2026-09-06). The ROM read-back is corrupt, but that test
   -- cannot say WHERE: the bytes travel MCU -> UART -> iosys -> write bridge -> SDRAM ->
   -- read bridge, and a fault anywhere looks identical at the end. This writes a known
   -- pattern to a scratch SDRAM window FROM THE FPGA (no UART, no loader) and reads it
   -- straight back through the same port B, so it isolates the SDRAM interface itself:
   --   pattern clean + ROM corrupt -> the SDRAM interface is fine, the fault is upstream
   --                                  in the UART/loader/write-bridge path
   --   pattern corrupt             -> the SDRAM interface (or its DQ timing) is the fault
   -- Pattern is `addr xor 0x5A`, which walks all 256 byte values so every DQ line sees
   -- both polarities -- important because every corruption seen so far has been strictly
   -- 0->1, so a pattern of mostly-ones would hide it.
   constant PAT_BASE  : unsigned(24 downto 0) := to_unsigned(16#500000#, 25);
   constant PAT_BYTES : integer := 256;
   signal pat_active  : std_logic := '0';
   signal pat_we      : std_logic := '0';
   signal pat_addr    : unsigned(8 downto 0) := (others => '0');
   signal pat_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal pat_req     : std_logic := '0';
   signal pat_settle  : unsigned(5 downto 0) := (others => '0');
   signal pat_seen_wait : std_logic := '0';
   signal pat_wdog    : unsigned(11 downto 0) := (others => '0');
   signal pat_errs    : unsigned(15 downto 0) := (others => '0');
   signal pat_first   : std_logic_vector(15 downto 0) := (others => '0');
   signal pat_done    : std_logic := '0';
   -- WORK-RAM pattern test (2026-09-07). Runs right after the SDRAM one, still with the
   -- core in reset, borrowing pce_top's otherwise-idle RAM port B. Work RAM has never
   -- been verified, and it is now the prime suspect: the CPU is sweeping addresses inside
   -- nonexistent bank $ED, which is a block transfer's signature, and this game builds
   -- its TII trampoline in RAM at $2480 with operands from RAM.
   -- Single-cycle write and read on port B, no handshake needed -- it is on-chip BSRAM.
   signal wram_en     : std_logic := '0';
   signal wram_a      : unsigned(14 downto 0) := (others => '0');
   signal wram_d      : std_logic_vector(7 downto 0);
   signal wram_we     : std_logic;
   signal wram_q      : std_logic_vector(7 downto 0);
   signal wram_errs   : unsigned(15 downto 0) := (others => '0');
   signal wram_first  : std_logic_vector(15 downto 0) := (others => '1');
   signal wram_phase  : unsigned(1 downto 0) := (others => '0');
   signal wram_done   : std_logic := '0';

   -- DERAILMENT TRAP (2026-09-07). Every ROM verification so far runs with the CPU in
   -- RESET -- no VDC, no video, no contention -- and passes. The CPU reads ROM under
   -- completely different conditions, and that is the one path never checked. This keeps
   -- a rolling window of the last 8 bytes the CPU actually RECEIVED from the ROM bridge,
   -- and freezes it the instant CPU_A lands in a bank that does not exist on a PCE
   -- (valid: $00-$7F ROM, $80-$87 CD-RAM, $F7 BRAM, $F8-$FB work RAM, $FF I/O).
   -- Comparing those bytes against the .pce offline says whether the CPU was fed
   -- corrupt data at the moment it went off the rails, or whether it was fed correct
   -- data and mis-executed it.
   type trap_arr is array (0 to 7) of std_logic_vector(23 downto 0);  -- addr(15:0) & data
   signal trap_buf   : trap_arr := (others => (others => '0'));
   signal trap_fired : std_logic := '0';
   -- 3 bits, not 2: at 2 bits `trap_sent < 4` is always true, so the emitter looped
   -- forever and flooded debug.log with 36 copies of each trap tag, crowding out the
   -- runtime heartbeat entirely.
   signal trap_sent  : unsigned(2 downto 0) := (others => '0');
   signal trap_emit  : std_logic := '0';
   signal trap_gap   : unsigned(19 downto 0) := (others => '0');
   signal cpu_bank   : std_logic_vector(7 downto 0);
   signal bank_bad   : std_logic;
   -- MPR register file, latched at the instant the CPU derails. jsr $4003 goes through
   -- MPR2; the trap says which MPR actually holds the bogus bank and what the others
   -- contain, which separates "TAM never wrote it" from "TAM wrote the wrong value"
   -- from "TAM wrote the wrong register".
   signal dbg_mpr     : std_logic_vector(63 downto 0);
   signal trap_mpr    : std_logic_vector(63 downto 0) := (others => '0');
   -- TAM evidence frozen at the same instant as trap_mpr. The boot path runs EXACTLY
   -- 7 TAMs before `jsr $4003`; every A it writes is <= $05, so the $A0 in the MPR
   -- readback cannot have come from this code. dbg_tam(31:24) is the TAM fire count,
   -- which separates "the write-enable never fired" from "it fired and the storage or
   -- the read select is wrong" -- the two hypotheses the MPR dump alone cannot tell apart.
   signal trap_tam    : std_logic_vector(31 downto 0) := (others => '0');
   signal dbg_tam     : std_logic_vector(31 downto 0);
   signal wram_dly    : unsigned(2 downto 0) := (others => '0');
   constant WRAM_BYTES : integer := 8192;   -- the 8KB a plain HuCard actually uses

   signal vfy_pass     : std_logic := '0';
   signal vfy_pass_lat : std_logic := '0';

   -- Debug taps from pce_top (see that file's DBG_CPU_A/DBG_VDC_WR port comments).
   signal dbg_cpu_a   : std_logic_vector(20 downto 0);
   signal dbg_vdc_wr  : std_logic;
   -- VDC BUSY-derived CPU stall (pce_top RDY). Low = a VDC is holding the CPU, which
   -- freezes it even with WAIT_N high. Latched sticky so a brief assertion cannot be
   -- missed between 100 ms heartbeats.
   signal dbg_vdc_rdy : std_logic;
   signal dbg_vdc_stall : std_logic := '0';
   signal dbg_cpu_ce    : std_logic;
   signal dbg_irq1_n    : std_logic;
   signal dbg_irq2_n    : std_logic;
   signal dbg_cpu_cyc   : unsigned(15 downto 0) := (others => '0');
   signal dbg_irq1_cnt  : unsigned(15 downto 0) := (others => '0');
   signal dbg_irq1_r    : std_logic := '1';
   signal dbg_vdc_cnt : unsigned(31 downto 0) := (others => '0');
   signal dbg_vbl_r   : std_logic := '0';
   signal dbg_vbl_cnt : unsigned(15 downto 0) := (others => '0');

   -- CD-RAM bridge: pce_top's CD_RAM_A/CD_RAM_DO/CD_RAM_DI/CD_RAM_RD/CD_RAM_WR through
   -- sdram.sv's port C -- shared with ADPCM RAM (2026-08-28, see the cdr_owner_t signal
   -- block above), same as pcetang_primer25k_cd.vhd. Level-held REQ (port A's
   -- convention, not port B's toggle), matching CD_RAM_RDY's contribution to WAIT_N.
   signal cd_ram_a     : std_logic_vector(21 downto 0);
   signal cd_ram_do    : std_logic_vector(7 downto 0);
   signal cd_ram_di_i  : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_ram_rd    : std_logic;
   signal cd_ram_wr    : std_logic;
   signal cd_ram_rdy_i : std_logic := '1';

   signal cdr_addr : std_logic_vector(24 downto 0);
   signal cdr_req  : std_logic := '0';
   signal cdr_rd_n : std_logic := '0';
   signal cdr_di   : std_logic_vector(7 downto 0);
   signal cdr_do   : std_logic_vector(7 downto 0);
   -- Same crossing, same fix -- see romb_wait above.
   signal cdr_wait_raw : std_logic;
   signal cdr_wait_m   : std_logic := '0';
   signal cdr_wait : std_logic := '0';

   type cdr_state_t is (CDR_IDLE, CDR_SETTLE, CDR_HOLD);
   signal cdr_state      : cdr_state_t := CDR_IDLE;
   signal cdr_settle_cnt : unsigned(5 downto 0) := (others => '0');
   signal cdr_seen_wait  : std_logic := '0';
   signal cdr_wdog       : unsigned(11 downto 0) := (others => '0');
   signal dbg_cdr_timeout_cnt : unsigned(7 downto 0) := (others => '0');
   -- Plain signal, not an inline conditional in the trace concatenation: Gowin's VHDL
   -- front-end rejects a conditional expression there (ERROR EX4155, "only supported
   -- in VHDL 1076-2019").
   signal cdr_busy_bit   : std_logic;
   signal cdram_rd_r, cdram_wr_r : std_logic := '0';

   -- Real SCSI target -- cd_bridge.vhd (shared across all 3 boards, 2026-08-31), see that
   -- file's own header for the full command decode/protocol trace.
   signal cd_stat_i      : std_logic_vector(7 downto 0);
   signal cd_msg_i       : std_logic_vector(7 downto 0);
   signal cd_stat_get_i  : std_logic;
   signal cd_comm_i      : std_logic_vector(95 downto 0);
   signal cd_comm_send_i : std_logic;
   signal cd_data_i      : std_logic_vector(7 downto 0);
   signal cd_data_wr_i   : std_logic;
   signal cd_data_end_i  : std_logic;

   -- Real sector-source signals (2026-08-31) between iosys_bl616's new UART commands and
   -- cd_bridge's generic sector interface -- see pcetang_cd_scsi_plan.md.
   signal cd_mounted_i           : std_logic;
   signal toc_wr_i               : std_logic;
   signal toc_track_i            : std_logic_vector(7 downto 0);
   signal toc_control_i          : std_logic_vector(7 downto 0);
   signal toc_lba_i              : std_logic_vector(23 downto 0);
   signal cd_sector_data_i       : std_logic_vector(7 downto 0);
   signal cd_sector_data_valid_i : std_logic;
   signal cd_sector_data_last_i  : std_logic;
   signal cd_sector_req_i        : std_logic;
   signal cd_sector_lba_i        : std_logic_vector(23 downto 0);
   signal cd_sector_is_audio_i   : std_logic;
   signal cd_audio_wr_i          : std_logic;
   signal cd_dm_i                : std_logic;


   signal video_r, video_g, video_b : std_logic_vector(2 downto 0);
   signal video_ce, video_hs, video_vs, video_hbl, video_vbl : std_logic;

   signal joy_out : std_logic_vector(1 downto 0);
   signal joy_in  : std_logic_vector(3 downto 0);

   signal brm_a  : std_logic_vector(10 downto 0);
   signal brm_di : std_logic_vector(7 downto 0);
   signal brm_do : std_logic_vector(7 downto 0);
   signal brm_we : std_logic;

   -- ADPCM RAM offload to SDRAM (2026-08-28): moved off the on-chip dpram(17,4) shim
   -- onto sdram.sv's port C, sharing it with the CD-RAM bridge above -- same design as
   -- pcetang_primer25k_cd.vhd's own ADPCM offload (real, gw_sh-verified there, 27
   -- BSRAM blocks freed), copied here rather than re-derived. One nibble packed per
   -- SDRAM byte (avoids read-modify-write, which would double port C's transaction
   -- count). 128KB region at ADPCM_SDRAM_BASE, doubling the real 64KB (128Kx4)
   -- ADPCM_DRAM capacity -- same provisional sizing as Primer 25K CD's.
   --
   -- Edge basis is ADPCM_RAM_SLOT_CNT changing, NOT ADPCM_RAM_REQ's own level -- see
   -- pcetang_primer25k_cd.vhd's identical comment for the real reason (a byte write
   -- spans two consecutive WRITE slots at two different addresses; REQ stays high
   -- across both, so edge-detecting REQ itself would silently drop the second nibble).
   -- PCE PORT (2026-08-29): widened 21->25 bits alongside sdram.sv's own port widening --
   -- layout unchanged (still 0x080000).
   constant ADPCM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#080000#, 25);
   -- PCE PORT (2026-08-29): real Arcade Card RAM window, finally possible now that
   -- sdram.sv's address bus reaches past 21 bits (see that file's own header, and the
   -- session's real hardware/datasheet confirmation of 32MB physical SDRAM behind it --
   -- W9825G6KH-6, 256Mbit, 4 banks). Placed at the 2MB boundary: existing ROM+CD-RAM+
   -- ADPCM only span 0x000000-0x09FFFF (640KB), so this is a clean, non-overlapping
   -- placement with plenty of gap either side, not a tight-fit squeeze. AC_RAM_A
   -- (arcade.sv) is 21 bits (2MB) -- fits exactly in this one window, unlike before when
   -- it had to alias into CD-RAM's own 256KB slice (the real bug this file's header used
   -- to describe under "ARCADE CARD RAM: NOT done").
   constant AC_SDRAM_BASE    : unsigned(24 downto 0) := to_unsigned(16#200000#, 25);

   signal adpcm_ram_a_i     : std_logic_vector(16 downto 0);
   signal adpcm_ram_do_i    : std_logic_vector(3 downto 0);
   signal adpcm_ram_we_i    : std_logic;
   signal adpcm_ram_req_i   : std_logic;
   signal adpcm_ram_slot_cnt_i : std_logic_vector(1 downto 0);
   signal adpcm_ram_di_i    : std_logic_vector(3 downto 0) := (others => '0');
   signal adpcm_ram_ready_i : std_logic := '1';
   signal adpcm_slot_cnt_r  : std_logic_vector(1 downto 0) := (others => '0');

   -- CD-RAM/ADPCM port-C owner arbiter -- same shape as pcetang_primer25k_cd.vhd's
   -- cdr_owner. CD-RAM wins ties (it directly stalls the CPU via CD_RAM_RDY/WAIT_N);
   -- ADPCM tolerates real slack (~420ns/slot budget vs. ~83ns SDRAM round trip).
   type cdr_owner_t is (OWNER_NONE, OWNER_CDRAM, OWNER_ADPCM);
   signal cdr_owner : cdr_owner_t := OWNER_NONE;
   signal cd_pend, adpcm_pend : std_logic := '0';

begin

   reset_n <= key_reset_n and pll_lock and hdmi_pll_lock;

   pll: console60k_pll
   port map (clkin => clk, reset => not key_reset_n, clk_pce => clk_pce,
             clk_sdram => clk_sdram, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll_720p
   port map (clkin => clk, reset => not key_reset_n, clk_pixel => clk_pixel,
             clk_5x_pixel => clk_5x_pixel, lock => hdmi_pll_lock);

   -- Same init-hold shape as pcetang_console60k.vhd's sdram_init process.
   process (clk_pce)
      variable reset_cnt : unsigned(15 downto 0) := (others => '0');
   begin
      if rising_edge(clk_pce) then
         if pll_lock = '0' or reset_n = '0' then
            reset_cnt := (others => '0');
         elsif reset_cnt /= X"FFFF" then
            reset_cnt := reset_cnt + 1;
         end if;
         if reset_cnt < X"2000" then
            sdram_init <= '1';
         else
            sdram_init <= '0';
         end if;
      end if;
   end process;

   -- DS2/SNES-shaped bit order per iosys_bl616.v's own comment: R L X A RT LT DN UP
   -- START SELECT Y B. Not wired to a real controller in this first cut -- tied
   -- inactive (all 1, active-low-style unpressed per that convention) so iosys_bl616
   -- still has something well-formed to poll.
   joy1_ds2 <= (others => '0');
   joy1     <= joy1_ds2 or hid1(11 downto 0);
   joy2     <= hid2(11 downto 0);

   sys_inst: iosys_bl616
   generic map (
      FREQ => 42_857_000,     -- matches clk_pce below, not the AUDIO/hclk domain
      COLOR_LOGO => "011000000001000",   -- purple-ish, arbitrary first-cut choice
      CORE_ID => x"0008",                -- must match firmware-bl616 cores.cpp id 8 ("PC Engine CD")
      LOADING_STATE => x"00",
      DBG_TRACE => 1
   )
   port map (
      clk => clk_pce, hclk => clk_pixel, resetn => reset_n,

      overlay => overlay, overlay_x => overlay_x, overlay_y => overlay_y,
      overlay_color => overlay_color,
      joy1 => joy1, joy2 => (others => '0'),
      hid1 => hid1, hid2 => hid2,

      rom_loading => rom_loading, rom_do => rom_do, rom_do_valid => rom_do_valid,

      mgmt_address => open, mgmt_read => open, mgmt_readdata => (others => '0'),
      mgmt_write => open, mgmt_writedata => open, fdd_request => "00",

      kbd_data => open, kbd_data_valid => open,
      core_config => core_config_r,

      cd_mounted => cd_mounted_i,
      toc_wr => toc_wr_i, toc_track => toc_track_i, toc_control => toc_control_i, toc_lba => toc_lba_i,
      cd_sector_data => cd_sector_data_i,
      cd_sector_data_valid => cd_sector_data_valid_i, cd_sector_data_last => cd_sector_data_last_i,
      cd_sector_req => cd_sector_req_i, cd_sector_lba => cd_sector_lba_i,
      cd_sector_is_audio => cd_sector_is_audio_i,
      dbg_trace_req => dbg_trace_req,
      dbg_trace_tag => dbg_trace_tag,
      dbg_trace_data => dbg_trace_data,

      uart_rx => uart_rxd, uart_tx => uart_txd
   );

   multitap_en <= core_config_r(3);

   -- Real multitap/2-player support (2026-08-31). Verified against MiSTer's
   -- own TurboGrafx16.sv (upstream/tg16-mister/TurboGrafx16.sv:966-977, real
   -- source, not guessed): CLR (JOY_OUT(1)) high resets the player pointer to
   -- 0; a SEL (JOY_OUT(0)) rising edge while CLR is low advances it. Real PCE
   -- hardware disambiguates a TurboTap's player-select from the base
   -- 2-button/6-button read cycle (which also toggles SEL) purely through
   -- this sequencing -- a game that never expects a tap simply never drives
   -- SEL/CLR in a pattern that advances the pointer past 0. Gated by
   -- multitap_en (CONF_STR's real "Multitap" OSD option, iosys_bl616.v,
   -- core_config bit 3) -- previously `core_config` was wired `open` on every
   -- board (the OSD system itself was always real, MCU-side, just never
   -- consumed here) -- defaults OFF exactly like MiSTer's own equivalent
   -- toggle.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         joy_out_r <= joy_out;
         if multitap_en = '0' then
            joy_port <= (others => '0');
         elsif joy_out(1) = '1' then
            joy_port <= (others => '0');
         elsif joy_out(0) = '1' and joy_out_r(0) = '0' then
            joy_port <= joy_port + 1;
         end if;
      end if;
   end process;

   -- Real per-player HID source: only 2 real slots exist (hid1/hid2) -- any
   -- other multitap position (2-4) reads back idle-high (no controller
   -- present), matching real hardware's own idle convention (see MiSTer's
   -- own `default: joy_data = 16'h0FFF`).
   joy_active <= joy1 when joy_port = 0 else
                 joy2 when joy_port = 1 else
                 (others => '1');

   -- ROM loader: rom_loading[0] pulses 0->1 at load start (per iosys_bl616.v's UART
   -- protocol comment) -- reset the write-address counter on that edge, then just
   -- count up one byte per rom_do_valid pulse. No iNES-style header parsing needed --
   -- ROM_SZ/ROM_POP are pce_top.vhd generics/ports already handling PCE-side metadata,
   -- separate from this byte stream.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         rom_loading_r <= rom_loading(0);

         -- TEMP DEBUG: the release on loading's falling edge is now deferred until the
         -- ROM self-test sweep finishes (vfy_state = VF_DONE below). The sweep is
         -- bounded and always terminates, so the core is always released.
         if reset_n = '0' then
            core_resetn <= '0';
         elsif rom_loading(0) = '1' and rom_loading_r = '0' then
            core_resetn <= '0';
         elsif vfy_state = VF_DONE then
            core_resetn <= '1';
         end if;

         if rom_loading(0) = '1' and rom_loading_r = '0' then
            rom_wr_addr <= (others => '0');
         elsif rom_do_valid = '1' then
            rom_wr_addr <= rom_wr_addr + 1;
         end if;

         -- Real HuCard dynamic bucket rounding (2026-08-30), same pattern as
         -- pcetang_nano20k_cd.vhd -- finalize ROM_SZ from the real loaded byte count
         -- exactly on the loading-done edge, while the core is still held in
         -- core_resetn's reset (see above), so pce_top never sees a mid-load ROM_SZ.
         if rom_loading(0) = '0' and rom_loading_r = '1' then
            if rom_wr_addr <= 131072 then
               rom_sz_r <= x"020"; -- 128K
            elsif rom_wr_addr <= 262144 then
               rom_sz_r <= x"040"; -- 256K
            elsif rom_wr_addr <= 393216 then
               rom_sz_r <= x"060"; -- 384K
            elsif rom_wr_addr <= 524288 then
               rom_sz_r <= x"080"; -- 512K
            elsif rom_wr_addr <= 786432 then
               rom_sz_r <= x"0C0"; -- 768K
            elsif rom_wr_addr <= 1048576 then
               rom_sz_r <= x"000"; -- 1MB, straight mapping
            else
               -- Real SF2' bank-switch mapper (2026-08-30, lever 19): no known real
               -- commercial HuCard exists between 1MB and Street Fighter II' Champion
               -- Edition's own 2560KB -- anything bigger than the straight-mapping 1MB
               -- tier is real SF2', not a guess.
               rom_sz_r <= x"280"; -- >1MB, real SF2' bank-switched mapping
            end if;
         end if;
      end if;
   end process;

   -- Static mux: write bridge (load) owns port B while rom_loading_r is set, read
   -- bridge (gameplay fetch) owns it otherwise. Mutually exclusive because the core is
   -- held in core_resetn's reset for the whole load, so ROM_RD cannot fire during it.
   -- TEMP DEBUG: three-way now -- the ROM self-test owns port B in the window between
   -- load-done and core release. It cannot overlap either of the other two: the write
   -- bridge is done (rom_loading_r is low) and the read bridge cannot have started
   -- (core_resetn is still low, so pce_top drives no ROM_RD).
   romb_addr <= wr_addr when rom_loading_r = '1' else
                std_logic_vector(PAT_BASE + resize(pat_addr, 25)) when pat_active = '1' else
                std_logic_vector(ROM_SDRAM_BASE + resize(vfy_addr, 25)) when vfy_active = '1' else
                rd_addr;
   romb_we   <= '1'     when rom_loading_r = '1' else pat_we;
   romb_di   <= wr_data when rom_loading_r = '1' else pat_data;

   -- REAL LATENT HAZARD, fixed 2026-09-06 (NOTE: this did NOT resolve the black-screen
   -- symptom it was found while chasing -- the hazard below is real and worth fixing on
   -- its own merits, but the black screen has another cause, still open). This was
   --    romb_req <= wr_req when rom_loading_r = '1' else rd_req;
   -- but sdram.sv's port B is EDGE/TOGGLE-triggered (`old_b_req ^ RAM_B_REQ`), not
   -- level-triggered, and wr_req/rd_req are two independent toggle registers. Muxing
   -- between them makes romb_req jump discontinuously the moment ownership switches at
   -- end-of-load. If the last write's request was still pending then (RAM_B_WAIT set,
   -- not yet launched from STATE_IDLE), that jump flips the XOR mismatch back to 0 and
   -- silently CANCELS it: RAM_B_WAIT then stays high forever with nothing pending, no
   -- ch1_busy, and the state machine sitting idle in MODE_NORMAL. The read bridge's
   -- first real fetch then waits on romb_wait forever, pce_top hangs mid-fetch holding
   -- ROM_RDY low, and the CPU never reaches the code that programs the VDC. That was
   -- the hypothesis this fix was written against; on-screen probes suggested it, but
   -- those probes turned out to have their own false-positive (counters gated on
   -- reset_n rather than on "SDRAM reached MODE_NORMAL once"), and applying this fix
   -- did NOT change the symptom. Keeping it regardless: an edge-triggered port fed from
   -- a muxed pair of independent toggle registers is a genuine hazard either way.
   -- XOR has no such discontinuity: each bridge toggling its own register still toggles
   -- the combined signal exactly once, the pending mismatch survives the ownership
   -- switch, and a quiet bridge contributes a constant. Both bridges are mutually
   -- exclusive in time anyway (see above), so they never toggle in the same cycle.
   -- TEMP DEBUG: vfy_req folded in with the same XOR rationale as wr_req/rd_req above --
   -- each owner toggling its own register still toggles the combined signal exactly
   -- once, and a quiet owner contributes a constant, so no request is ever cancelled by
   -- an ownership switch.
   romb_req  <= wr_req xor rd_req xor vfy_req xor pat_req;

   -- Two-flop synchronisers for the clk_sdram -> clk_pce WAIT flags. See romb_wait's
   -- declaration for the real hardware evidence that made these necessary.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         romb_wait_m <= romb_wait_raw;
         romb_wait   <= romb_wait_m;
         cdr_wait_m  <= cdr_wait_raw;
         cdr_wait    <= cdr_wait_m;
      end if;
   end process;

   -- ROM write bridge: one iosys_bl616 byte becomes one real SDRAM write via port B.
   -- Same pattern as pcetang_console60k.vhd's ROM write bridge.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case wr_state is
            when RB_IDLE =>
               if wr_hold_valid = '1' then
                  -- drain the held byte first so ordering is preserved
                  wr_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(wr_hold_addr, 25));
                  wr_data <= wr_hold_data;
                  wr_hold_valid <= '0';
                  wr_state <= RB_ADDR;
               elsif rom_do_valid = '1' then
                  wr_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(rom_wr_addr, 25));
                  wr_data <= rom_do;
                  wr_state <= RB_ADDR;
               end if;

            -- Same address-before-request setup as the read bridge -- see its header for
            -- the real deadlock. A corrupted ROM *load* would be far harder to spot than
            -- a hung fetch, so this side gets the same treatment even though the observed
            -- failure was on the read path.
            when RB_ADDR =>
               wr_req  <= not wr_req;
               wr_settle_cnt <= (others => '0');
               wr_seen_wait  <= '0';
               wr_state <= RB_SETTLE;

            when RB_SETTLE =>
               -- Same real handshake as the read bridge. A write NEVER hits the cache
               -- path (sdram.sv excludes RAM_B_WE from it), so WAIT must rise; the
               -- SETTLE_HIT arm here is a safety net, not an expected path.
               if romb_wait = '1' then
                  wr_seen_wait <= '1';
                  wr_state     <= RB_WAIT;
               elsif wr_settle_cnt = SETTLE_HIT then
                  wr_state <= RB_IDLE;
               else
                  wr_settle_cnt <= wr_settle_cnt + 1;
               end if;

            when RB_WAIT =>
               if romb_wait = '0' then
                  wr_state <= RB_IDLE;
               end if;
         end case;

         -- Capture the incoming byte AFTER the case above, deliberately. Placed before
         -- it (as first written) this raced: when the bridge sat in RB_IDLE draining the
         -- held byte and a new byte arrived the same cycle, the capture saw the stale
         -- wr_hold_valid='1', counted a drop, and the byte really was lost -- RB_IDLE
         -- takes the HELD byte, not the new one. That race is what saturated
         -- wr_drop_cnt at 65535 on run 9. Ordered after the case, RB_IDLE's
         -- `wr_hold_valid <= '0'` is overridden here in the same cycle, so the slot is
         -- freed and refilled atomically and nothing is lost.
         if rom_do_valid = '1' then
            if wr_state = RB_IDLE and wr_hold_valid = '0' then
               null;   -- the case above took it straight into the bridge
            elsif wr_hold_valid = '0' or wr_state = RB_IDLE then
               wr_hold_valid <= '1';
               wr_hold_data  <= rom_do;
               wr_hold_addr  <= rom_wr_addr;
            elsif wr_drop_cnt /= x"FFFF" then
               wr_drop_cnt <= wr_drop_cnt + 1;
            end if;
         end if;
      end if;
   end process;

   -- TEMP DEBUG: ROM-image self-test sweep. See the vfy_* declarations above for why
   -- this exists and what its output is compared against. Uses the same 5-cycle-settle
   -- then check-wait handshake the read/write bridges already use, so it exercises the
   -- real port-B path rather than a special-cased one -- if the bridge handshake itself
   -- returns wrong data, this sweep sees exactly the same wrong data the CPU would.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         vfy_emit   <= '0';
         vfy_emit_d <= vfy_emit;

         case vfy_state is
            when VF_IDLE =>
               vfy_active <= '0';
               -- Start on loading's falling edge, the same edge that used to release
               -- the core directly.
               if rom_loading(0) = '0' and rom_loading_r = '1' then
                  vfy_active  <= '1';
                  vfy_addr    <= (others => '0');
                  vfy_sum     <= (others => '0');
                  vfy_blk     <= (others => '0');
                  vfy_pass    <= '0';
                  vfy_is_dump <= '0';
                  vfy_dump_idx <= (others => '0');
                  vfy_len     <= rom_wr_addr;
                  pat_addr    <= (others => '0');
                  pat_errs    <= (others => '0');
                  pat_first   <= (others => '1');
                  pat_active  <= '1';
                  vfy_state   <= PT_WA;
               end if;

            -- ---- pattern WRITE: addr+data settle, then toggle req (same one-cycle
            -- address setup the ROM bridges use -- see the read bridge's header).
            when PT_WA =>
               pat_data <= std_logic_vector(pat_addr(7 downto 0) xor x"5A");
               pat_we   <= '1';
               vfy_state <= PT_WR;

            when PT_WR =>
               pat_req   <= not pat_req;
               pat_settle<= (others => '0');
               pat_seen_wait <= '0';
               pat_wdog  <= (others => '0');
               vfy_state <= PT_WS;

            when PT_WS =>
               if romb_wait = '1' then
                  pat_seen_wait <= '1';
               end if;
               if (pat_seen_wait = '1' and romb_wait = '0')
                  or (pat_seen_wait = '0' and pat_settle = SETTLE_HIT) then
                     pat_we <= '0';
                     pat_seen_wait <= '0';
                     if pat_addr = PAT_BYTES-1 then
                        pat_addr  <= (others => '0');
                        vfy_state <= PT_RA;      -- writes done, read them back
                     else
                        pat_addr  <= pat_addr + 1;
                        vfy_state <= PT_WA;
                     end if;
               elsif pat_wdog = x"FFF" then
                  pat_we <= '0';
                  vfy_state <= PT_EMIT;       -- SDRAM never answered; report
               else
                  pat_settle <= pat_settle + 1;
                  pat_wdog   <= pat_wdog + 1;
               end if;

            -- ---- pattern READ-BACK and compare
            when PT_RA =>
               pat_we    <= '0';
               vfy_state <= PT_RR;

            when PT_RR =>
               pat_req   <= not pat_req;
               pat_settle<= (others => '0');
               pat_seen_wait <= '0';
               pat_wdog  <= (others => '0');
               vfy_state <= PT_RS;

            when PT_RS =>
               if romb_wait = '1' then
                  pat_seen_wait <= '1';
               end if;
               if (pat_seen_wait = '1' and romb_wait = '0')
                  or (pat_seen_wait = '0' and pat_settle = SETTLE_HIT) then
                     pat_seen_wait <= '0';
                     if romb_do /= std_logic_vector(pat_addr(7 downto 0) xor x"5A") then
                        pat_errs <= pat_errs + 1;
                        if pat_first = x"FFFF" then
                           -- remember the first failing address and what it returned
                           pat_first <= romb_do & std_logic_vector(pat_addr(7 downto 0));
                        end if;
                     end if;
                     if pat_addr = PAT_BYTES-1 then
                        vfy_state <= PT_EMIT;
                     else
                        pat_addr  <= pat_addr + 1;
                        vfy_state <= PT_RA;
                     end if;
               elsif pat_wdog = x"FFF" then
                  vfy_state <= PT_EMIT;
               else
                  pat_settle <= pat_settle + 1;
                  pat_wdog   <= pat_wdog + 1;
               end if;

            when PT_EMIT =>
               pat_active <= '0';
               pat_done   <= '1';
               wram_en    <= '1';
               wram_a     <= (others => '0');
               wram_errs  <= (others => '0');
               wram_first <= (others => '1');
               wram_phase <= (others => '0');
               vfy_gap    <= (others => '0');
               vfy_emit   <= '1';
               vfy_state  <= VF_GAP;   -- emit the SDRAM result, then WR_W via VF_RESUME

            -- ---- WORK RAM pattern test: write 8KB, then read it all back.
            -- Two separate passes (not write-then-read per address) so a byte that reads
            -- back only because it is still sitting in a pipeline register cannot pass.
            -- wram_we and wram_d are CONCURRENT (see below), driven off the address
            -- currently presented, so the write lands at the address in wram_a rather
            -- than the next one. The first version registered all three together, which
            -- wrote data(A) at address A+1 and reported 8192/8192 mismatches -- a pure
            -- test bug that read back exactly the stray byte it had written.
            when WR_W =>
               if wram_a = WRAM_BYTES-1 then
                  wram_a    <= (others => '0');
                  wram_dly  <= (others => '0');
                  vfy_state <= WR_R;
               else
                  wram_a <= wram_a + 1;
               end if;

            when WR_R =>
               -- dpram registers q_b, so allow a cycle of read latency before comparing
               wram_dly  <= wram_dly + 1;
               if wram_dly = "010" then
                  vfy_state <= WR_C;
               end if;

            when WR_C =>
               if wram_q /= std_logic_vector(wram_a(7 downto 0) xor x"A5") then
                  if wram_errs /= x"FFFF" then
                     wram_errs <= wram_errs + 1;
                  end if;
                  if wram_first = x"FFFF" then
                     wram_first <= wram_q & std_logic_vector(wram_a(7 downto 0));
                  end if;
               end if;
               if wram_a = WRAM_BYTES-1 then
                  vfy_state <= WR_EMIT;
               else
                  wram_a   <= wram_a + 1;
                  wram_dly <= (others => '0');
                  vfy_state <= WR_R;
               end if;

            when WR_EMIT =>
               wram_en   <= '0';
               wram_done <= '1';
               vfy_gap   <= (others => '0');
               vfy_emit  <= '1';
               vfy_state <= VF_GAP;

            when VF_REQ =>
               -- Nothing loaded (or a zero-length load): don't sweep, just release.
               if vfy_len = 0 then
                  vfy_state <= VF_DONE;
               else
                  vfy_state <= VF_ADDR;
               end if;

            -- Address settled (romb_addr follows vfy_addr combinationally), so the
            -- request toggle now happens a full cycle later -- same fix as both bridges.
            when VF_ADDR =>
               vfy_req     <= not vfy_req;
               vfy_settle  <= (others => '0');
               vfy_seen_wait <= '0';
               vfy_timeout <= (others => '0');
               vfy_state   <= VF_SETTLE;

            when VF_SETTLE =>
               if romb_wait = '1' then
                  vfy_seen_wait <= '1';
                  vfy_state     <= VF_WAIT;
               elsif vfy_settle = SETTLE_HIT then
                  vfy_state <= VF_ACC;
               else
                  vfy_settle <= vfy_settle + 1;
               end if;

            when VF_WAIT =>
               vfy_timeout <= vfy_timeout + 1;
               if romb_wait = '0' then
                  vfy_state <= VF_ACC;
               elsif vfy_timeout = x"FFF" then
                  -- SDRAM never answered. Give up rather than hold the core in reset
                  -- forever; the emitted checksum will be visibly wrong, which is
                  -- itself the finding.
                  vfy_state <= VF_DONE;
               end if;

            when VF_ACC =>
               -- Rotate-left-1 then add, so byte ORDER matters (a plain sum would miss
               -- a shuffled image). scripts/rom_checksum.py computes the identical
               -- function over the .pce file.
               vfy_sum  <= (vfy_sum(30 downto 0) & vfy_sum(31)) + resize(unsigned(romb_do), 32);
               -- Always advance, then decide on the ADVANCED value -- otherwise the
               -- final block's end test can never become true and the sweep re-reads
               -- the last byte forever.
               vfy_addr <= vfy_addr + 1;
               -- Raw dump window: pass 0 only, first VFY_DUMP_BYTES bytes, MSB-first so
               -- the trace line reads left-to-right in address order.
               vfy_dump <= vfy_dump(55 downto 0) & romb_do;
               if (vfy_addr + 1 = vfy_len)
                  or (vfy_addr(VFY_BLK_BITS-1 downto 0) = (VFY_BLK_BITS-1 downto 0 => '1')) then
                  vfy_is_dump <= '0';
                  vfy_state   <= VF_EMIT;
               elsif vfy_pass = '0' and vfy_addr < VFY_DUMP_BYTES
                     and vfy_addr(2 downto 0) = "111" then
                  vfy_is_dump <= '1';
                  vfy_state   <= VF_EMIT;
               else
                  vfy_state <= VF_REQ;
               end if;

            when VF_EMIT =>
               -- 2026-09-06: the previous run's log showed the frame parser losing sync
               -- partway through the sweep (raw `aa 00 0a 09` headers leaking into
               -- payloads). Traces were already ~5 ms apart, so the likely cause is an
               -- SD f_sync stall on the MCU overrunning its UART RX. Hold the sweep for
               -- ~23 ms after each emit -- the sweep's wall-clock cost is irrelevant
               -- (the CPU is still in reset) and a readable log is not.
               vfy_gap <= (others => '0');
               -- Latch before clearing: vfy_sum is zeroed in this same cycle, so the
               -- trace process (which fires one cycle later, on vfy_emit_d) would
               -- otherwise sample an already-cleared accumulator.
               vfy_sum_lat  <= vfy_sum;
               vfy_blk_lat  <= vfy_blk;
               vfy_dump_lat <= vfy_dump;
               vfy_is_dump_lat  <= vfy_is_dump;
               vfy_dump_idx_lat <= vfy_dump_idx;
               -- Latched here too: vfy_pass flips in this same cycle on the last block,
               -- so the latch correctly captures the pass this checksum belongs to.
               vfy_pass_lat <= vfy_pass;
               vfy_emit     <= '1';
               -- A dump emit is NOT a block boundary: leave the checksum accumulator and
               -- the block counter alone, or the 32KB sums would be silently wrong.
               if vfy_is_dump = '0' then
                  vfy_blk <= vfy_blk + 1;
                  vfy_sum <= (others => '0');
               else
                  vfy_dump_idx <= vfy_dump_idx + 1;
               end if;
               vfy_state <= VF_GAP;

            when VF_GAP =>
               vfy_gap <= vfy_gap + 1;
               if vfy_gap = x"FFFFF" then
                  vfy_state <= VF_RESUME;
               end if;

            when VF_RESUME =>
               if pat_done = '1' then
                  pat_done  <= '0';
                  vfy_state <= WR_W;        -- SDRAM reported; now test WORK RAM
               elsif wram_done = '1' then
                  wram_done <= '0';
                  vfy_state <= VF_REQ;      -- work RAM reported; now sweep the ROM
               elsif vfy_is_dump = '1' then
                  vfy_is_dump <= '0';
                  vfy_state   <= VF_REQ;
               elsif vfy_addr >= vfy_len then
                  if vfy_pass = '0' then
                     -- Second pass over the identical byte range, same order. See
                     -- vfy_pass's declaration for how the two results are read.
                     vfy_pass  <= '1';
                     vfy_addr  <= (others => '0');
                     vfy_blk   <= (others => '0');
                     vfy_state <= VF_REQ;
                  else
                     vfy_state <= VF_DONE;
                  end if;
               else
                  vfy_state <= VF_REQ;
               end if;

            when VF_DONE =>
               vfy_active <= '0';
         end case;

         -- Re-arm on the START of any load, AFTER the case so it always wins. Without
         -- this, VF_DONE is terminal, and since core_resetn's own process releases the
         -- core whenever `vfy_state = VF_DONE`, a SECOND ROM load would be released from
         -- reset immediately instead of being held for the duration of the load --
         -- exactly the race core_resetn exists to prevent. Not reachable today (the MCU
         -- reprograms the FPGA per core load) but a real trap for whoever changes that.
         if rom_loading(0) = '1' and rom_loading_r = '0' then
            vfy_state  <= VF_IDLE;
            vfy_active <= '0';
         end if;
      end if;
   end process;

   -- ROM read bridge: one pce_top ROM_RD per CPU cart-ROM byte access becomes one real
   -- SDRAM read via port B.
   --
   -- REAL DEADLOCK, found on hardware 2026-09-06 and fixed here. The RTL trace showed 30
   -- consecutive heartbeats with rd_state = RB_WAIT, romb_wait = '1' and rom_rdy_i = '0'
   -- -- i.e. this bridge waiting forever on an SDRAM read that never completes, holding
   -- pce_top's WAIT_N low, freezing the HuC6280 mid-fetch at ROM ~0x400-0x7FF after only
   -- 9 VDC writes. Video timing kept running, which is exactly why the symptom was a
   -- black screen with sync rather than lost sync, and why the CPU LOOKED like it was
   -- sitting in a data table: that address was the frozen fetch, not executing code.
   --
   -- Root cause: rd_addr and rd_req were assigned in the SAME clk_pce cycle, and both
   -- cross into clk_sdram UNSYNCHRONISED (sdram.sv samples RAM_B_REQ directly, there is
   -- no synchroniser on that port). sdram.sv decides hit-vs-miss on RAM_B_ADDR at the
   -- cycle it observes the RAM_B_REQ toggle, then LAUNCHES from STATE_IDLE re-evaluating
   -- `fetch_req_b` against RAM_B_ADDR again. If those two evaluations see the address
   -- differently -- exactly what simultaneous ADDR/REQ transitions across an
   -- unsynchronised boundary allow -- the miss branch can set RAM_B_WAIT while the launch
   -- condition reads false. `old_b_req` is then never consumed, nothing is ever launched,
   -- and RAM_B_WAIT stays high forever with no transaction pending. Deadlock.
   --
   -- Fix: RB_ADDR gives the address a full clk_pce cycle (~2.8 clk_sdram cycles) of setup
   -- before the request toggles, so every observation of RAM_B_REQ's edge sees a settled,
   -- identical RAM_B_ADDR.
   --
   -- The watchdog is deliberate and stays in: a CDC bug argued away on paper is not the
   -- same as one proven gone on hardware. If the deadlock ever recurs, the CPU keeps
   -- running (with one bad byte) instead of freezing, and dbg_rd_timeout_cnt reports how
   -- often over the trace channel -- a live count is far better evidence than another
   -- silent freeze.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         rd_done <= '0';
         case rd_state is
            when RB_IDLE =>
               rom_rdy_i <= '1';
               if rom_rd_i = '1' then
                  rd_addr <= std_logic_vector(ROM_SDRAM_BASE +
                             resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 25));
                  rom_rdy_i <= '0';
                  rd_state <= RB_ADDR;
               end if;

            when RB_ADDR =>
               -- Address settled last cycle; only now toggle the request.
               rd_req <= not rd_req;
               rd_settle_cnt <= (others => '0');
               rd_seen_wait  <= '0';
               rd_wdog <= (others => '0');
               rd_state <= RB_SETTLE;

            when RB_SETTLE =>
               -- Latch WAIT ever going high: that is the only positive evidence the
               -- request was actually accepted. See SETTLE_HIT's declaration.
               if romb_wait = '1' then
                  rd_seen_wait <= '1';
                  rd_state     <= RB_WAIT;
               elsif rd_settle_cnt = SETTLE_HIT then
                  -- WAIT never rose in a generous window -> sdram.sv served this from
                  -- its 4-byte line cache, which legitimately never asserts WAIT.
                  rom_do_i  <= romb_do;
                  rom_rdy_i <= '1';
                  rd_done   <= '1';
                  rd_state  <= RB_IDLE;
               else
                  rd_settle_cnt <= rd_settle_cnt + 1;
               end if;

            when RB_WAIT =>
               rd_wdog <= rd_wdog + 1;
               if romb_wait = '0' then
                  rom_do_i <= romb_do;
                  rom_rdy_i <= '1';
                  rd_done  <= '1';
                  rd_state <= RB_IDLE;
               elsif rd_wdog = x"3FF" then
                  -- ~1024 clk_pce cycles (~24 us) is orders of magnitude beyond any real
                  -- SDRAM read. Give up, release the CPU, and count it.
                  rom_do_i <= romb_do;
                  rom_rdy_i <= '1';
                  rd_state  <= RB_IDLE;
                  if dbg_rd_timeout_cnt /= x"FFFF" then
                     dbg_rd_timeout_cnt <= dbg_rd_timeout_cnt + 1;
                  end if;
               end if;
         end case;
      end if;
   end process;

   -- CD-RAM + ADPCM RAM bridge: pce_top's CD_RAM_RD/CD_RAM_WR (raw, level-held) and
   -- ADPCM_RAM_REQ (level-held for one DRAM_CLKEN slot, ~420ns) both become SDRAM
   -- accesses via the same shared port C, one at a time, CD-RAM winning ties. Real,
   -- unmodified from pcetang_primer25k_cd.vhd's own cdr_owner arbiter -- see that
   -- file's identical comment for the full pend/ready-drop timing rationale.
   process (clk_pce)
      variable cd_new, adpcm_new : std_logic;
   begin
      if rising_edge(clk_pce) then
         cdram_rd_r      <= cd_ram_rd;
         cdram_wr_r      <= cd_ram_wr;
         adpcm_slot_cnt_r <= adpcm_ram_slot_cnt_i;

         cd_new := (cd_ram_rd and not cdram_rd_r) or (cd_ram_wr and not cdram_wr_r);
         if adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r then
            adpcm_new := adpcm_ram_req_i;
         else
            adpcm_new := '0';
         end if;

         if cd_new = '1' then
            cd_pend      <= '1';
            cd_ram_rdy_i <= '0';
         end if;
         if adpcm_new = '1' then
            adpcm_pend        <= '1';
            adpcm_ram_ready_i <= '0';
         end if;

         case cdr_state is
            when CDR_IDLE =>
               cdr_req <= '0';
               if cd_pend = '1' or cd_new = '1' then
                  -- PCE PORT (2026-08-29): real Arcade Card RAM support. cd_ram_a
                  -- (pce_top.vhd's own combined CD_RAM_A) already distinguishes the two
                  -- real devices sharing this bus by its own top bit, per pce_top.vhd's
                  -- mux: `CD_RAM_A <= '0' & AC_RAM_A when AC_RAM_CS_N='0' else "1000" &
                  -- CPU_A(17 downto 0)` -- AC's own real address always has bit 21 = 0
                  -- (it's only 21 bits, zero-extended by one), real CD-RAM/backup-RAM's
                  -- synthetic offset always has bit 21 = 1 (the "1000" prefix). Route
                  -- each to its own real, non-overlapping SDRAM window instead of both
                  -- collapsing onto CD-RAM's 256KB slice (the real aliasing bug this
                  -- file's header used to describe under "ARCADE CARD RAM: NOT done").
                  if cd_ram_a(21) = '0' then
                     cdr_addr <= std_logic_vector(AC_SDRAM_BASE +
                                 resize(unsigned(cd_ram_a(20 downto 0)), 25));
                  else
                     cdr_addr <= std_logic_vector(CDRAM_SDRAM_BASE +
                                 resize(unsigned(cd_ram_a(17 downto 0)), 25));
                  end if;
                  cdr_rd_n <= not cd_ram_wr;   -- '0' read, '1' write
                  cdr_di   <= cd_ram_do;
                  cdr_req  <= '1';
                  cdr_owner <= OWNER_CDRAM;
                  cd_pend  <= '0';
                  cdr_settle_cnt <= (others => '0');
                  cdr_seen_wait  <= '0';
                  cdr_wdog       <= (others => '0');
                  cdr_state <= CDR_SETTLE;
               elsif adpcm_pend = '1' or adpcm_new = '1' then
                  cdr_addr <= std_logic_vector(ADPCM_SDRAM_BASE +
                              resize(unsigned(adpcm_ram_a_i), 25));
                  cdr_rd_n <= not adpcm_ram_we_i;
                  cdr_di   <= "0000" & adpcm_ram_do_i;  -- one nibble packed per SDRAM byte
                  cdr_req  <= '1';
                  cdr_owner <= OWNER_ADPCM;
                  adpcm_pend <= '0';
                  cdr_settle_cnt <= (others => '0');
                  cdr_seen_wait  <= '0';
                  cdr_wdog       <= (others => '0');
                  cdr_state <= CDR_SETTLE;
               end if;

            when CDR_SETTLE =>
               cdr_req <= '1';
               -- Real handshake, same fix as the ROM read/write bridges (696313d). This
               -- FSM was MISSED by that commit and it is the one that matters most: it
               -- owns cd_ram_rdy_i, the other term of pce_top's
               -- `WAIT_N <= ROM_RDY and CD_RAM_RDY`. cd_ram_rdy_i is dropped the moment a
               -- CD-RAM access starts and only restored when this FSM completes, so if it
               -- mis-samples cdr_wait and hangs, the CPU is frozen FOREVER -- with the ROM
               -- bridge sitting innocently in RB_IDLE, which is exactly what run 11
               -- showed: ROM image byte-perfect, rd_state=IDLE, rom_rdy=1, 0 timeouts,
               -- and the VDC write count stuck at 10 while video kept running.
               -- The 2-flop cdr_wait synchroniser added in c9e936c made this strictly
               -- worse by delaying WAIT two more cycles without widening the window.
               if cdr_wait = '1' then
                  cdr_seen_wait <= '1';
                  cdr_state <= CDR_HOLD;
               elsif cdr_settle_cnt = SETTLE_HIT then
                  -- WAIT never rose in a generous window: sdram.sv served this from its
                  -- line cache, which legitimately never asserts WAIT.
                  if cdr_owner = OWNER_CDRAM then
                     cd_ram_di_i  <= cdr_do;
                     cd_ram_rdy_i <= '1';
                  else
                     adpcm_ram_di_i    <= cdr_do(3 downto 0);
                     adpcm_ram_ready_i <= '1';
                  end if;
                  cdr_req <= '0';
                  cdr_owner <= OWNER_NONE;
                  cdr_state <= CDR_IDLE;
               else
                  cdr_settle_cnt <= cdr_settle_cnt + 1;
               end if;

            when CDR_HOLD =>
               cdr_req <= '1';
               cdr_wdog <= cdr_wdog + 1;
               -- Watchdog, same rationale as the ROM read bridge's. cd_ram_rdy_i held low
               -- here freezes the CPU outright, so this path must never be able to stall
               -- forever on a WAIT that does not fall. On timeout, release the client with
               -- whatever data is present and count it -- a wrong byte the CPU can survive
               -- and we can see, rather than a silent freeze we cannot.
               if cdr_wait = '0' or cdr_wdog = x"3FF" then
                  if cdr_wdog = x"3FF" and dbg_cdr_timeout_cnt /= x"FF" then
                     dbg_cdr_timeout_cnt <= dbg_cdr_timeout_cnt + 1;
                  end if;
                  if cdr_owner = OWNER_CDRAM then
                     cd_ram_di_i  <= cdr_do;
                     cd_ram_rdy_i <= '1';
                  else
                     adpcm_ram_di_i    <= cdr_do(3 downto 0);
                     adpcm_ram_ready_i <= '1';
                  end if;
                  cdr_req <= '0';
                  cdr_owner <= OWNER_NONE;
                  cdr_state <= CDR_IDLE;
               end if;
         end case;
      end if;
   end process;

   -- Real SCSI target, wired to the real MCU-side mount/TOC/sector protocol via
   -- iosys_bl616.v (see pcetang_cd_scsi_plan.md for the full wire-protocol design).
   cd_bridge_inst: entity work.cd_bridge
   port map (
      CLK          => clk_pce,
      RST_N        => core_resetn,
      CD_STAT      => cd_stat_i,
      CD_MSG       => cd_msg_i,
      CD_STAT_GET  => cd_stat_get_i,
      CD_COMM      => cd_comm_i,
      CD_COMM_SEND => cd_comm_send_i,
      CD_DATA      => cd_data_i,
      CD_DATA_WR   => cd_data_wr_i,
      CD_DATA_END  => cd_data_end_i,

      DISC_MOUNTED      => cd_mounted_i,
      TOC_WR            => toc_wr_i,
      TOC_TRACK         => toc_track_i,
      TOC_CONTROL       => toc_control_i,
      TOC_LBA           => toc_lba_i,
      CD_AUDIO_WR       => cd_audio_wr_i,
      CD_DM             => cd_dm_i,
      SECTOR_REQ        => cd_sector_req_i,
      SECTOR_LBA        => cd_sector_lba_i,
      SECTOR_IS_AUDIO   => cd_sector_is_audio_i,
      SECTOR_DATA       => cd_sector_data_i,
      SECTOR_DATA_VALID => cd_sector_data_valid_i,
      SECTOR_DATA_LAST  => cd_sector_data_last_i
   );

   sdram_inst: sdram
   port map (
      clk        => clk_sdram,
      init       => sdram_init,
      SDRAM_A    => O_sdram_addr,
      SDRAM_DQ   => IO_sdram_dq,
      SDRAM_BA   => O_sdram_ba,
      SDRAM_DQML => O_sdram_dqm(0),
      SDRAM_DQMH => O_sdram_dqm(1),
      SDRAM_nWE  => O_sdram_wen_n,
      SDRAM_nCAS => O_sdram_cas_n,
      SDRAM_nRAS => O_sdram_ras_n,
      SDRAM_nCS  => O_sdram_cs_n,
      SDRAM_CKE  => O_sdram_cke,
      SDRAM_CLK  => O_sdram_clk,
      -- No VRAM0 on SDRAM on this board (EXT_VRAM0=>0, stays on-chip).
      RAM_A_ADDR => (others => '0'),
      RAM_A_REQ  => '0',
      RAM_A_RD_n => '1',
      RAM_A_DI   => (others => '0'),
      RAM_A_DO   => open,
      RAM_A_WAIT => open,
      RAM_A_LINE_REFILL => '0',
      RAM_A_LINE_DO     => open,
      RAM_B_ADDR => romb_addr,
      RAM_B_REQ  => romb_req,
      RAM_B_WE   => romb_we,
      RAM_B_DI   => romb_di,
      RAM_B_DO   => romb_do,
      RAM_B_WAIT => romb_wait_raw,
      RAM_C_ADDR => cdr_addr,
      RAM_C_REQ  => cdr_req,
      RAM_C_RD_n => cdr_rd_n,
      RAM_C_DI   => cdr_di,
      RAM_C_DO   => cdr_do,
      RAM_C_WAIT => cdr_wait_raw,
      RAM_C_WIDE => '0',
      RAM_C_DI16 => (others => '0'),
      RAM_C_DO16 => open,
      RAM_C_LINE_REFILL => '0',
      RAM_C_LINE_DO     => open
   );

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   core: entity work.pce_top
   -- LITE => 1 (2026-09-07): drop SuperGrafx for HuCard bring-up. LITE=0 keeps VDC1 and
   -- its 32K-word VRAM1 alive, and BOTH of VDC1's control lines are ANDed into the CPU's:
   -- `RDY => VDC0_BUSY_N and VDC1_BUSY_N` and `IRQ1_N => VDC0_IRQ_N and VDC1_IRQ_N`. A
   -- plain HuCard never programs VDC1 and its handler at $E065 reads VDC0's status only,
   -- so it can never clear a VDC1 interrupt -- the same failure class as the CD_EN/IRQ2
   -- storm found at the start of this investigation, one AND gate over.
   -- generate_NOSGX ties both to '1', and this also frees VRAM1 from a build already at
   -- 112/118 BSRAM, which session notes flag as a real Gowin inference hazard here.
   -- Costs SuperGrafx support: five games, none of which run today.
   generic map (LITE => 1, EXT_VRAM0 => 0, NO_CD => 0)
   port map (
      RESET      => not core_resetn,
      COLD_RESET => not core_resetn,
      CLK        => clk_pce,

      VRAM0_RAM_A_ADDR => open, VRAM0_RAM_A_REQ => open, VRAM0_RAM_A_RD_N => open,
      VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0'),
      VRAM0_RAM_A_WAIT => '0',
      DBG_DEADLINE_MISS => open, DBG_FIFO_OVERFLOW => open,
      VRAM0_RAM_A_LINE_REFILL => open, VRAM0_RAM_A_LINE_DO => (others => '0'),

      -- TEMP DEBUG (2026-09-06): see pce_top.vhd's own port comments and the trace
      -- process near the bottom of this file.
      DBG_CPU_A => dbg_cpu_a, DBG_VDC_WR => dbg_vdc_wr, DBG_VDC_RDY => dbg_vdc_rdy,
      DBG_CPU_CE => dbg_cpu_ce, DBG_IRQ1_N => dbg_irq1_n, DBG_IRQ2_N => dbg_irq2_n,
      RAMTEST_EN => wram_en, RAMTEST_A => std_logic_vector(wram_a),
      RAMTEST_D => wram_d, RAMTEST_WE => wram_we, RAMTEST_Q => wram_q,
      DBG_MPR => dbg_mpr,
      DBG_TAM => dbg_tam,

      ROM_RD    => rom_rd_i,
      ROM_RDY   => rom_rdy_i,
      ROM_A     => rom_a,
      ROM_DO    => rom_do_i,
      ROM_SZ    => rom_sz_r,       -- dynamic 128K-1MB real HuCard bucket, see rom_sz_r above
      ROM_POP   => '0',
      ROM_CLKEN => open,

      BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => brm_do, BRM_WE => brm_we,

      GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

      SP64 => '0', SGX => '1',

      JOY_OUT => joy_out, JOY_IN => joy_in,

      -- REAL FIX (2026-09-06), found on real Console 60K hardware via the RTL debug
      -- trace channel: CD_EN was hardwired '1', so a plain HuCard booted with the CD
      -- subsystem live and no disc mounted. The traced CPU fetch pattern showed the
      -- HuC6280 re-reading its IRQ2 vector ($FFF6) once per loop and re-entering the
      -- handler at ROM 0x464 (40 RTI / 48 PHA / a9 01 LDA #$01 / 53 TAM ...) forever --
      -- i.e. IRQ2 (the CD-ROM interrupt) asserting continuously, so the CPU never
      -- reached the code that programs the VDC. Video timing kept running, so the
      -- symptom was a black screen rather than lost sync.
      -- Gate it on a real disc actually being mounted (cd_mounted_i, driven by the MCU's
      -- own mount/unmount protocol -- loadpce leaves it 0, loadpcecd sets it 1). This
      -- also makes the joypad port's CD-presence bit (pce_top.vhd:483, `not CD_EN`)
      -- report the truth instead of always claiming a CD unit is attached.
      CD_EN => cd_mounted_i, CD_RAM_A => cd_ram_a, CD_RAM_DO => cd_ram_do,
      CD_RAM_DI => cd_ram_di_i, CD_RAM_RD => cd_ram_rd, CD_RAM_WR => cd_ram_wr,
      CD_RAM_RDY => cd_ram_rdy_i,

      ADPCM_RAM_A => adpcm_ram_a_i, ADPCM_RAM_DO => adpcm_ram_do_i,
      ADPCM_RAM_WE => adpcm_ram_we_i, ADPCM_RAM_REQ => adpcm_ram_req_i,
      ADPCM_RAM_SLOT_CNT => adpcm_ram_slot_cnt_i,
      ADPCM_RAM_DI => adpcm_ram_di_i, ADPCM_RAM_READY => adpcm_ram_ready_i,

      -- PCE PORT (2026-08-29): '0'->'1' -- real, non-aliasing 2MB SDRAM window now
      -- exists (AC_SDRAM_BASE, see that constant's own comment) -- see this file's
      -- header for the updated real gw_sh result.
      AC_EN => '1',

      CD_STAT => cd_stat_i, CD_MSG => cd_msg_i, CD_STAT_GET => cd_stat_get_i,
      CD_COMM => cd_comm_i, CD_COMM_SEND => cd_comm_send_i,
      CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
      -- CD_REGION (2026-08-30, verified real, not a guess): checked against the real
      -- MiSTer TurboGrafx16.sv upstream -- CD_REGION isn't a fixed hardware constant,
      -- it's a real runtime OSD option (`cd_region <= cd_out[17]`, driven by HPS/menu
      -- config there), reset to '0' on every core reset/cart-download. This project has
      -- no OSD/config-menu path yet to expose that toggle, so '0' is kept -- it matches
      -- the real upstream reset default exactly, not an arbitrary/unverified choice.
      -- Which physical region (JP vs US syscard) numeric value 0 vs 1 corresponds to is
      -- NOT verified here (cd.vhd's own C5/C6/C7 byte patterns weren't cross-checked
      -- against a real BIOS trace) -- treat this as "correct default", not "confirmed
      -- region-locked to X". Real follow-up, not yet scoped: a runtime switch once any
      -- config-menu mechanism exists on this project.
      CD_REGION => '0', CD_RESET => open,
      CD_DATA => cd_data_i, CD_DATA_WR => cd_data_wr_i, CD_AUDIO_WR => cd_audio_wr_i,
      CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end_i, CD_DM => cd_dm_i,

      CDDA_SL => cdda_sl, CDDA_SR => cdda_sr, ADPCM_S => adpcm_s, PSG_SL => psg_sl, PSG_SR => psg_sr,

      BG_EN => '1', SPR_EN => '1', GRID_EN => (others => '0'), CPU_PAUSE_EN => '0',

      BORDER_EN => '0', ReducedVBL => '0',
      VIDEO_R => video_r, VIDEO_G => video_g, VIDEO_B => video_b,
      VIDEO_BW => open, VIDEO_CE => video_ce, VIDEO_CE_FS => open,
      VIDEO_VS => video_vs, VIDEO_HS => video_hs,
      VIDEO_HBL => video_hbl, VIDEO_VBL => video_vbl
   );

   -- PCE joypad protocol (pce_top.vhd:335,344): JOY_OUT(0) selects which 4-bit nibble
   -- JOY_IN returns. First-cut mapping, not verified against real PCE controller docs
   -- -- see this file's header. Reads from joy_active (real per-player mux, see its
   -- own header comment above), not directly from joy1 -- joy_port selects which
   -- real player's HID state is currently active.
   joy_in <= joy_active(4) & joy_active(5) & joy_active(11) & joy_active(10) when joy_out(0) = '1' else
             joy_active(3) & joy_active(2) & joy_active(1)  & joy_active(0);

   -- TEMP DEBUG (2026-09-06): periodic HEARTBEAT snapshot of the ROM-read bridge, over
   -- iosys_bl616.v's RTL debug-trace channel -> debug.log on the SD card.
   --
   -- Deliberately a heartbeat and NOT a per-completion trace: the first attempt only
   -- fired on the fast completion path (rd_settle_cnt="100" with romb_wait='0'), which
   -- produced ZERO output on real hardware. That is itself consistent with the read
   -- bridge sitting in RB_WAIT forever on a romb_wait that never drops -- exactly the
   -- hang this is trying to characterise -- so the probe was blind to the very failure
   -- it was meant to catch. A timer-driven snapshot fires regardless of whether anything
   -- ever completes, so it cannot be silenced by the bug.
   --
   -- Payload (see the concatenation below): current CPU ROM address, the last byte SDRAM
   -- returned, the ROM_SZ bucket in force, and the live handshake/state bits. Comparing
   -- the address against the .pce file on the PC separates "SDRAM read path broken" from
   -- "address mapping wrong" (rom_sz_r bucket rounding / SF2' mapping, never exercised
   -- on real hardware); the state bits say whether the bridge is stuck and where.
   -- Capped at 64 snapshots so the log stays readable and the UART is not flooded.
   --
   -- 2026-09-06 SECOND PASS. The first pass traced rom_a and concluded "the CPU never
   -- leaves ROM bank 0". That conclusion was WRONG, and the way it was wrong is worth
   -- recording: sim/boot/'s testbench shows a perfectly healthy run of this same ROM
   -- also spends almost every 100 ms sample inside bank 0, because the game's main loop
   -- lives at $F000-$FFFF (ROM 0x1000-0x1FFF, bank 0) and only visits other banks in
   -- short bursts. A 100 ms sampler cannot distinguish "stuck in bank 0" from "healthy,
   -- and mostly in bank 0". So this pass traces things whose value is unambiguous
   -- rather than an address that has to be interpreted statistically:
   --
   --   tags 0x00-0x3F : ROM self-test block checksums (see the vfy_* FSM above). These
   --                    answer "is the image in SDRAM the image on the SD card?" against
   --                    scripts/rom_checksum.py's output for the same file. This is the
   --                    first candidate the GHDL bisection left open.
   --   tags 0x80+     : runtime heartbeat, now carrying DBG_VDC_WR's cumulative count
   --                    and the VBLANK count. A nonzero, climbing VDC write count means
   --                    the CPU DID reach the code that programs the VDC and the fault
   --                    is downstream (video path); a flat zero means it did not, and
   --                    the fault is upstream. That single number splits the remaining
   --                    search space in half, which the previous payload could not.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         dbg_trace_req <= '0';

         -- Phase 1: one trace per completed ROM self-test block.
         if vfy_emit_d = '1' then
            dbg_trace_req  <= '1';
            -- tag = 0_P_bbbbbb : bit 6 is the pass, so pass 0 lands at 0x00-0x3F and
            -- pass 1 at 0x40-0x7F, leaving 0x80+ for the runtime heartbeat. Supports up
            -- to 64 blocks per pass = 2MB at 32KB blocks; SF2's 2560K would exceed that,
            -- which is fine for a debug build but worth knowing before reusing this.
            -- Raw dump lines get tags 0xC0-0xCF, clear of the checksum tags (0x00-0x7F)
            -- and the runtime heartbeat (0x80+).
            if wram_done = '1' then
               dbg_trace_tag <= x"D1";
            elsif pat_done = '1' then
               dbg_trace_tag <= x"D0";
            elsif vfy_is_dump_lat = '1' then
               dbg_trace_tag <= x"C" & std_logic_vector(vfy_dump_idx_lat);
            else
               dbg_trace_tag <= '0' & vfy_pass_lat & std_logic_vector(vfy_blk_lat(5 downto 0));
            end if;
            -- [63:56] block | [55:24] checksum | [23:2] end address | [1:0] pad
            if wram_done = '1' then
               -- WORK RAM: [63:48] mismatches | [47:32] first bad {got, addr}
               -- | [31:16] bytes tested | [15:0] 0
               dbg_trace_data <= std_logic_vector(wram_errs)
                                 & wram_first
                                 & std_logic_vector(to_unsigned(WRAM_BYTES,16))
                                 & x"0000";
            elsif pat_done = '1' then
               -- [63:48] mismatch count | [47:32] first bad {got, addr}
               -- | [31:16] bytes tested | [15:0] 0
               dbg_trace_data <= std_logic_vector(pat_errs)
                                 & pat_first
                                 & std_logic_vector(to_unsigned(PAT_BYTES,16))
                                 & std_logic_vector(wr_drop_cnt);
            elsif vfy_is_dump_lat = '1' then
               -- 8 raw SDRAM bytes, MSB first = ascending address order.
               dbg_trace_data <= vfy_dump_lat;
            else
               dbg_trace_data <= std_logic_vector(vfy_blk_lat)
                                 & std_logic_vector(vfy_sum_lat)
                                 & std_logic_vector(vfy_addr)
                                 & "00";
            end if;
         elsif core_resetn = '0' then
            dbg_fetch_cnt <= (others => '0');
            dbg_hb_cnt    <= (others => '0');
            trap_sent     <= (others => '0');
         else
            dbg_hb_cnt <= dbg_hb_cnt + 1;
            -- ~4.2M clk_pce cycles at 42.86MHz = ~100ms between snapshots
            -- 32, not 64: two checksum passes now emit 32 lines before the core is even
            -- released, and the heartbeat comes LAST -- so if the log were ever
            -- truncated it is the VDC count, the more valuable half, that would be lost.
            -- 32+32 keeps total volume at the 64 lines a previous run survived.
            -- Once the trap has fired, spend the next three heartbeat slots emitting the
            -- frozen window (tags 0xE0-0xE2) before resuming the normal heartbeat.
            if dbg_hb_cnt = 0 and trap_fired = '1' and trap_sent < 5 then
               trap_sent     <= trap_sent + 1;
               dbg_trace_req <= '1';
               dbg_trace_tag <= x"E" & "0" & std_logic_vector(trap_sent);
               case trap_sent is
                  when "000" => dbg_trace_data <= trap_buf(0) & trap_buf(1) & "0000000000000000";
                  when "001" => dbg_trace_data <= trap_buf(2) & trap_buf(3) & "0000000000000000";
                  when "010" => dbg_trace_data <= trap_buf(4) & trap_buf(5) & "0000000000000000";
                  when "011" => dbg_trace_data <= trap_mpr;   -- MPR7..MPR0, tag 0xE3
                  -- tag 0xE4: TAM_CNT | IR | T | A, all frozen at the trap.
                  when others => dbg_trace_data <= trap_tam & x"00000000";
               end case;
            elsif dbg_hb_cnt = 0 and dbg_fetch_cnt < 32 then
               dbg_fetch_cnt <= dbg_fetch_cnt + 1;
               -- 0x80+ so heartbeat tags can never be confused with a block checksum.
               dbg_trace_tag <= std_logic_vector(dbg_fetch_cnt or x"80");
               dbg_trace_req <= '1';
               -- [63:32] cumulative VDC0 write count | [31:16] ROM-read watchdog
               -- timeouts | [15:14] rd_state | [13:11] rom_rd/rom_rdy/romb_wait
               -- | [10:0] VBLANK count
               -- The watchdog count replaces the old VBLANK slot because it is now the
               -- number that decides whether the CDC fix actually worked: 0 means no
               -- ROM read ever stalled, nonzero means the deadlock still happens and is
               -- merely being escaped. VBLANK keeps the low 11 bits, which is plenty to
               -- show video is alive.
               -- [63:32] VDC writes | [31:24] ROM-read timeouts
               -- | [23:16] port-C: cdr_timeouts(4) cd_ram_rdy cdr_busy cd_ram_rd adpcm_req
               -- | [15:14] rd_state | [13:11] rom_rd/rom_rdy/romb_wait | [10:0] VBLANK
               -- Run 11 froze with the ROM path provably healthy, so the port-C side --
               -- which owns cd_ram_rdy_i, the other term of WAIT_N -- is now visible too.
               -- Run 14: CPU_CE advances ~42441/heartbeat (full speed, continuous),
               -- IRQ1 assertions 0, VDC writes stuck at 10, and CPU_A(20:16) pinned at
               -- 0x1D for 30 straight samples -- physical banks $E8-$EF, which are
               -- UNMAPPED on a PCE. So the CPU is not stalled and not interrupt-stormed;
               -- it has jumped into nowhere and is fetching $FF forever. Five address
               -- bits was enough to see that and not enough to say why, so the full
               -- 21-bit CPU_A goes in the payload now. IRQ1 is dropped -- proven 0.
               -- [63:48] VDC writes | [47:27] CPU_A(20:0) | [26:11] CPU_CE | [10:0] VBLANK
               dbg_trace_data <= std_logic_vector(dbg_vdc_cnt(15 downto 0))
                                 & dbg_cpu_a
                                 & std_logic_vector(dbg_cpu_cyc)
                                 & std_logic_vector(dbg_vbl_cnt(10 downto 0));
            end if;
         end if;
      end if;
   end process;

   -- TEMP DEBUG: cumulative counters feeding the heartbeat payload above. Both are
   -- gated on core_resetn (the CPU actually running), NOT on reset_n -- earlier probe
   -- rounds produced false positives precisely because reset_n-gated counters latch
   -- during the SDRAM's own power-on init, before anything real has happened.
   -- Rolling window of bytes actually delivered to the CPU, frozen on derailment.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         -- trap_sent is driven ONLY by the heartbeat process below (it is the emitter);
         -- resetting it here too gave ERROR (EX2000) "constantly driven from multiple
         -- places". Single driver per signal.
         if core_resetn = '0' then
            trap_fired <= '0';
         else
            -- record each completed CPU ROM fetch until the trap fires
            if trap_fired = '0' and rd_done = '1' then
               trap_buf(0) <= rd_addr(15 downto 0) & romb_do;
               for i in 1 to 7 loop
                  trap_buf(i) <= trap_buf(i-1);
               end loop;
            end if;
            if trap_fired = '0' and bank_bad = '1' then
               trap_fired <= '1';   -- CPU just entered a nonexistent bank: freeze
               trap_mpr   <= dbg_mpr;
               trap_tam   <= dbg_tam;
            end if;
         end if;
      end if;
   end process;

   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         dbg_vbl_r <= video_vbl;
         if core_resetn = '0' then
            dbg_vdc_cnt <= (others => '0');
            dbg_vbl_cnt <= (others => '0');
         else
            if dbg_vdc_wr = '1' then
               dbg_vdc_cnt <= dbg_vdc_cnt + 1;
            end if;
            if dbg_vdc_rdy = '0' then
               dbg_vdc_stall <= '1';   -- sticky: a VDC stalled the CPU at least once
            end if;
            -- Is the CPU executing at all, and is it being interrupted to death?
            if dbg_cpu_ce = '1' then
               dbg_cpu_cyc <= dbg_cpu_cyc + 1;
            end if;
            dbg_irq1_r <= dbg_irq1_n;
            if dbg_irq1_n = '0' and dbg_irq1_r = '1' then
               dbg_irq1_cnt <= dbg_irq1_cnt + 1;
            end if;
            if video_vbl = '1' and dbg_vbl_r = '0' then
               dbg_vbl_cnt <= dbg_vbl_cnt + 1;
            end if;
         end if;
      end if;
   end process;

   -- 2-bit encoding of the read bridge's state, for the heartbeat payload above.
   -- Work-RAM test port B: assert the write strobe and data combinationally for the
   -- address currently in wram_a, so address/data/we all present together.
   wram_we <= '1' when vfy_state = WR_W else '0';
   wram_d  <= std_logic_vector(wram_a(7 downto 0) xor x"A5");

   cpu_bank <= dbg_cpu_a(20 downto 13);
   bank_bad <= '0' when unsigned(cpu_bank) <= 16#7F#                                  -- ROM
               else '0' when unsigned(cpu_bank) >= 16#80# and unsigned(cpu_bank) <= 16#87#  -- CD-RAM
               else '0' when cpu_bank = x"F7"                                          -- BRAM
               else '0' when unsigned(cpu_bank) >= 16#F8# and unsigned(cpu_bank) <= 16#FB#  -- work RAM
               else '0' when cpu_bank = x"FF"                                          -- I/O
               else '1';

   cdr_busy_bit <= '0' when cdr_state = CDR_IDLE else '1';

   rd_state_bits <= "00" when rd_state = RB_IDLE else
                    "01" when rd_state = RB_SETTLE else
                    "10";   -- RB_WAIT


   -- 2026-09-06: 720p60 output (see hdmi_pll instance above). Vertical
   -- scale stays the existing fixed 2x line-double (pce2hdmi_sd.sv's own cy[0]==0
   -- check) -- fills roughly the top 484 of 720 active lines, real picture but
   -- letterboxed, not a full-height scale. Horizontal fill is automatic (the
   -- module's Bresenham stretch already targets SCREEN_WIDTH generically).
   hdmi_out: pce2hdmi_sd
   generic map (
      VIDEOID       => 4,        -- CEA-861 1280x720p60
      CLKFRQ        => 74375,    -- kHz, matches the real 720p PLL's actual clk_pixel
      SCREEN_WIDTH  => 1280,
      SCREEN_HEIGHT => 720
   )
   port map (
      clk => clk_pce, resetn => reset_n,
      video_r => video_r, video_g => video_g, video_b => video_b,
      video_ce => video_ce, video_hs => video_hs, video_vs => video_vs,
      video_hbl => video_hbl, video_vbl => video_vbl,
      overlay => overlay, overlay_x => overlay_x, overlay_y => overlay_y,
      overlay_color => overlay_color,
      clk_pixel => clk_pixel, clk_5x_pixel => clk_5x_pixel,
      psg_sl => std_logic_vector(psg_sl), psg_sr => std_logic_vector(psg_sr),
      cdda_sl => std_logic_vector(cdda_sl), cdda_sr => std_logic_vector(cdda_sr),
      adpcm_s => std_logic_vector(adpcm_s),
      tmds_clk_n => tmds_clk_n, tmds_clk_p => tmds_clk_p,
      tmds_d_n => tmds_d_n, tmds_d_p => tmds_d_p
   );

   leds_n(0) <= not (pll_lock and hdmi_pll_lock);
   leds_n(1) <= not rom_loading(0);

end architecture;
