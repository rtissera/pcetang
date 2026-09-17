-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- pcetang Phase 2: Tang Console 60K, PCE + PCE-CD.
-- CURRENT CONFIG (2026-09-17): NO_CD=>0, LITE=>1 (SuperGrafx NOT elaborated),
-- AC_BUILD=>0, DBG_PROBES=>0, CDDA_DEPTH_LOG2=>12 -- see the comments on pce_top's
-- generic map below for why each is set. The SGX input is still tied '1'; with LITE=>1
-- its only live effect is pce_top's work-RAM address (pages $F9-$FB get their own 24KB
-- instead of mirroring $F8 like a real PC Engine). Should follow LITE -- a bitstream
-- change, deferred until the current build is confirmed on hardware.
-- Sibling to pcetang_console60k.vhd's Phase 1 (HuCard-only, no CD, no SGX) build.
--
-- HISTORY -- SGX (2026-08-29, SUPERSEDED 2026-09-07 by LITE => 1): LITE flipped 1->0 and SGX flipped '0'->'1' for real, permanently --
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

      -- DS2 (PlayStation-style) pads on PMOD1, both players. Pins and wiring copied from
      -- tangcore's monitor core (monitor/src/boards/console.cst), which is the bitstream
      -- that reads these pads for the TangCore menu -- that is why the menu responds to a
      -- pad while a game core does not: the reader lives in the monitor, and any core
      -- that does not implement one gets nothing.
      ds_cs       : out   std_logic;                      -- PMOD1_IO0
      ds_mosi     : out   std_logic;                      -- PMOD1_IO2
      ds_miso     : in    std_logic;                      -- PMOD1_IO4
      ds_clk      : out   std_logic;                      -- PMOD1_IO6
      ds_cs2      : out   std_logic;                      -- PMOD1_IO1
      ds_mosi2    : out   std_logic;                      -- PMOD1_IO3
      ds_miso2    : in    std_logic;                      -- PMOD1_IO5
      ds_clk2     : out   std_logic;                      -- PMOD1_IO7

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
         tmds_d_p   : out std_logic_vector(2 downto 0);
         dbg_out_frame_tog : out std_logic;
         dbg_vs_cy         : out std_logic_vector(9 downto 0);
         dbg_vtotal_extra  : out std_logic_vector(7 downto 0)
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
   -- Verilog reader, vendored from tangcore's monitor core (src/input/). Outputs are
   -- ACTIVE HIGH in the same 12-bit DS2/SNES order iosys_bl616.v documents:
   -- (R L X A RT LT DN UP START SELECT Y B).
   component controller_ds2 is
      generic ( FREQ : integer := 21_600_000 );
      port (
         clk          : in  std_logic;
         snes_buttons : out std_logic_vector(11 downto 0);
         ds_clk       : out std_logic;
         ds_miso      : in  std_logic;
         ds_mosi      : out std_logic;
         ds_cs        : out std_logic
      );
   end component;

   signal joy1_ds2      : std_logic_vector(11 downto 0);
   signal hid1, hid2    : std_logic_vector(15 downto 0);
   signal joy1          : std_logic_vector(11 downto 0);
   signal joy2          : std_logic_vector(11 downto 0);
   signal joy2_ds2      : std_logic_vector(11 downto 0);

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
   -- PCE PORT (2026-09-09): ROM_RDY as pce_top actually sees it. rom_rdy_i is a REGISTER,
   -- so on the cycle a new read is requested it still carries the PREVIOUS transaction's
   -- '1' -- one cycle in which the CPU sees "ready" sitting next to the previous byte in
   -- rom_do_i. Whether the CPU samples in that window depends on CPU_CE alignment, which
   -- is why most fetches were fine and only some were not.
   --
   -- MEASURED on hardware (trace tags 0xE9/0xEA, latched on the CPU's own T-load strobe):
   -- at the instant the CPU committed its fetch of ROM offset 0475 the bridge was
   -- presenting $53, the byte at 0474. Simulation of the identical cycle returns $40.
   -- The CPU consumed the previous byte because nothing held it. Every TAM then took $53
   -- as its MPR write-enable mask and wrote MPR0/1/4/6 -- exactly the set bits of $53 --
   -- which is precisely the hardware MPR dump, and MPR2 never being written is why
   -- `jsr $4003` left for a bank that does not exist.
   --
   -- The `rd_done` term is what keeps this from deadlocking: on the completion cycle the
   -- FSM is back in RB_IDLE with the NEW byte in rom_do_i and rd_done high, so ready must
   -- be '1' there even though rom_rd_i is still asserted, or the CPU could never consume
   -- the byte it asked for. From the next cycle on, a still-asserted rom_rd_i means a new
   -- fetch and ready drops immediately -- with no stale window.
   signal rom_rdy_comb : std_logic;
   -- Previous cycle's rom_rd_i, and the address of the last request actually started.
   -- Together these turn a level into a real "new request" event -- see RB_IDLE.
   signal rom_rd_prev  : std_logic := '0';
   signal rd_a_last    : std_logic_vector(21 downto 0) := (others => '1');
   -- Single definition of "a new ROM read is pending". Used BOTH by the FSM's start
   -- condition and by rom_rdy_comb: if those two ever disagreed, ROM_RDY could sit low
   -- waiting for a fetch the FSM has decided not to start, and the CPU would hang.
   signal rd_new_req   : std_logic;
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

   -- VTOTAL-servo probe (see the heartbeat payload below). The source side is counted
   -- here in clk_pce, where video_vbl already lives, so there is no crossing on it at
   -- all; the output side crosses as a single toggle bit and is counted here too. Only
   -- vs_cy/vtotal_extra cross as buses, and both are snapshotted once per output frame
   -- and sampled ~100 ms apart, so a torn sample is possible but would show as one
   -- outlier against 32 samples rather than a wrong trend.
   signal vid_out_frame_tog : std_logic;
   signal vid_vs_cy         : std_logic_vector(9 downto 0);
   signal vid_vtotal_extra  : std_logic_vector(7 downto 0);
   signal vid_oft_meta, vid_oft_sync, vid_oft_prev : std_logic := '0';
   signal vid_out_frames    : unsigned(15 downto 0) := (others => '0');
   signal vid_src_vbl_r     : std_logic := '0';
   signal vid_src_frames    : unsigned(15 downto 0) := (others => '0');
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
   -- 2026-09-10: the ROM self-test sweep is debug scaffolding from the HuCard
   -- black-screen hunt, which closed at 777ba38. It is now actively harmful. Its PT_*
   -- states WRITE test patterns into memory, which is why core_resetn's release was
   -- deferred to `vfy_state = VF_DONE` rather than to loading's falling edge -- and
   -- cd_bridge is instantiated with RST_N => core_resetn, so it sits in reset, with its
   -- TOC tables cleared, for the whole sweep. The MCU sends the entire TOC within about
   -- a millisecond of dropping the loading flag, so every TOC_WR lands while the bridge
   -- is held in reset and is discarded. cd_mounted survives only because it lives in
   -- iosys, which core_resetn does not reset -- exactly the asymmetry the trace showed
   -- (mount=1, toc_wr_count=0).
   -- Turning the sweep off releases the core on loading's falling edge as originally
   -- designed, removes the pattern-write hazard, and frees tags 0x00-0x7F on the trace
   -- channel. Set true to get it back.
   constant SELFTEST : boolean := false;
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
   signal trap_sent  : unsigned(3 downto 0) := (others => '0');
   signal trap_emit  : std_logic := '0';
   signal trap_gap   : unsigned(19 downto 0) := (others => '0');
   signal cpu_bank   : std_logic_vector(7 downto 0);
   signal bank_bad   : std_logic;
   -- MPR register file, latched at the instant the CPU derails. jsr $4003 goes through
   -- MPR2; the trap says which MPR actually holds the bogus bank and what the others
   -- contain, which separates "TAM never wrote it" from "TAM wrote the wrong value"
   -- from "TAM wrote the wrong register".
   signal dbg_mpr     : std_logic_vector(63 downto 0);
   -- See gen_cd_bridge below for what this switches off and why.
   -- 2026-09-10: false, to instantiate cd_bridge for the first real PC Engine CD test.
   -- This is a SECOND gate on the CD path, independent of pce_top's NO_CD generic, and
   -- missing it is what made the first CD attempt look like an MCU problem: the syscard
   -- loaded and ran, but with cd_bridge absent SECTOR_REQ is hard-tied to '0' in
   -- gen_no_cd_bridge, so the syscard sat on "JUST A MOMENT..." forever and the MCU's
   -- sector-request counters stayed at zero because nothing ever asked it for anything.
   constant HUCARD_ONLY : boolean := false;

   signal trap_mpr    : std_logic_vector(63 downto 0) := (others => '0');
   -- TAM evidence frozen at the same instant as trap_mpr. The boot path runs EXACTLY
   -- 7 TAMs before `jsr $4003`; every A it writes is <= $05, so the $A0 in the MPR
   -- readback cannot have come from this code. dbg_tam(31:24) is the TAM fire count,
   -- which separates "the write-enable never fired" from "it fired and the storage or
   -- the read select is wrong" -- the two hypotheses the MPR dump alone cannot tell apart.
   signal trap_tam    : std_logic_vector(31 downto 0) := (others => '0');
   -- Four most recent T-loads, frozen with the rest of the trap. Tags 0xE5..0xE8.
   signal dbg_tload   : std_logic_vector(191 downto 0);
   signal trap_tload  : std_logic_vector(191 downto 0) := (others => '0');
   signal dbg_wait_ever : std_logic;
   signal trap_wait_ever : std_logic := '0';
   -- The BOARD's own view of the ROM bridge, latched on the CPU's T-load strobe. This is
   -- what compares "what the CPU committed" against "what the bridge was presenting" at
   -- the SAME instant. The derailment trap's (rd_addr, romb_do) pairs all look correct,
   -- but they only prove the bridge is self-consistent -- if it latches CPU_A a fetch
   -- behind, it fetches the wrong byte and reports it as right.
   signal dbg_tload_stb : std_logic;
   signal dbg_sel    : std_logic_vector(21 downto 0);
   signal trap_sel   : std_logic_vector(21 downto 0) := (others => '0');
   type bridge_view_t is array(0 to 1) of std_logic_vector(31 downto 0);
   signal bview      : bridge_view_t := (others => (others => '0'));
   signal trap_bview : bridge_view_t := (others => (others => '0'));
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
   -- IRQ1 is the VDC interrupt. Its LEVEL sampled at heartbeat instants is nearly
   -- useless (reads inactive almost always, even on a healthy system) -- what matters
   -- is whether it ever fires, which is what this counts. Pre-existing; tag 0xD2 now
   -- reports it.
   signal dbg_irq1_cnt  : unsigned(15 downto 0) := (others => '0');
   signal dbg_irq1_r    : std_logic := '1';
   -- IRQ2 is the CD interrupt (cd.vhd: IRQ_N <= not ((CD_DTR_EN and CD_DTR) or
   -- (CD_DTD_EN and CD_DTD) or ...)). Prime suspect now: the CD data path and CD-RAM are
   -- both verified good, the CPU runs at full speed with VBlank firing, yet VDC writes
   -- stop -- which is what a game waiting forever on a CD interrupt looks like.
   signal dbg_irq2_cnt  : unsigned(15 downto 0) := (others => '0');
   signal dbg_irq2_r    : std_logic := '1';
   signal dbg_vdc_cnt : unsigned(31 downto 0) := (others => '0');
   signal dbg_vbl_r   : std_logic := '0';
   signal dbg_vbl_cnt : unsigned(15 downto 0) := (others => '0');

   -- CD-RAM bridge: pce_top's CD_RAM_A/CD_RAM_DO/CD_RAM_DI/CD_RAM_RD/CD_RAM_WR through
   -- sdram.sv's port C -- shared with ADPCM RAM (2026-08-28, see the cdr_owner_t signal
   -- block above), same as pcetang_primer25k_cd.vhd. Level-held REQ (port A's
   -- convention, not port B's toggle), matching CD_RAM_RDY's contribution to WAIT_N.
   -- CD-RAM SELF-TEST (2026-09-11). CD-RAM is the largest subsystem the HuCard path
   -- never touches -- 256KB offloaded to SDRAM through the cdr_* arbiter below -- and it
   -- is the prime suspect now that EVERY HuCard game boots while NO CD game reaches a
   -- boot screen. The CD data path is verified byte-for-byte against beetle-pce-fast, so
   -- if the bytes arrive correctly and the program still will not run, the next thing to
   -- doubt is where they are STORED.
   --
   -- A passive read-after-write snoop was tried first and measured NOTHING (ok=0, bad=0):
   -- it only compared when a read hit the most recent write address, and a loader writes
   -- a buffer forwards then reads it back from the start, so the addresses never match.
   -- "Zero" was indistinguishable from "never ran" -- the same trap as every other
   -- self-gated probe on this project. This drives the bus itself instead, so a zero is
   -- a real zero.
   --
   -- Runs while the core is still held in reset (after the ROM sweep, before
   -- core_resetn is released), so pce_top is not driving CD_RAM_* and the mux below is
   -- uncontested. Bounded and always terminating: 1024 writes, then 1024 read-backs.
   -- ANSWERED, NOW OFF. Hardware result 2026-09-11: ok = 256 KiB, bad = 0 -- the entire
   -- 256KB window read back exactly what was written, with ADDRESS-DERIVED data, so the
   -- SDRAM offload neither corrupts nor aliases. CD-RAM is cleared as a suspect, and
   -- there is no reason to back it with BSRAM.
   --
   -- Off because it has a REAL SIDE EFFECT: per pce_top's own mux, backup RAM shares this
   -- "1000" address window with CD-RAM, so sweeping all 262144 offsets overwrites BRAM's
   -- save-data signature. With the sweep on, Dungeon Explorer II stopped booting and
   -- dropped into the syscard's CD PLAYER -- the BIOS not finding what it expected in
   -- backup RAM. Re-enable only for a deliberate diagnosis, and expect saves destroyed.
   -- ENABLED 2026-09-14. This test was previously worthless: the arbiter's CD-RAM
   -- branch took its address from cd_ram_a instead of cdr_a_mux, so all 262144 accesses
   -- landed on ONE address (the halted core's idle bus) and its "256 KiB, 0 bad" result
   -- cleared a CD-RAM that was in fact completely broken by the inverted RAM_C_RD_n.
   -- Both bugs are fixed, so this now sweeps for real -- and its results are finally
   -- reported (tag 0xC9), which they never were either.
   -- OFF by default, and turning it on is not free. The sweep runs with the core HALTED,
   -- so it delays core_resetn release by ~1.4 s. On 2026-09-14 that delay pushed the
   -- MCU's TOC upload inside the reset window and cd_bridge's (then) async reset dropped
   -- the whole TOC, sending every disc to the CD player -- a full round trip spent
   -- diagnosing the instrument. cd_bridge no longer resets its TOC, so that hazard is
   -- closed, but the 1.4 s delay and the extra port-C traffic remain real side effects.
   --
   -- Its answer is already banked: 256 KiB verified, 0 bad bytes, 0 port-C timeouts, and
   -- CD-RAM contents separately verified byte-for-byte against the real CHD. Turn it on
   -- only to re-check memory itself, never as a passenger on some other experiment.
   -- Read it ONE direction only: bad /= 0 is conclusive, bad = 0 is not -- with the core
   -- halted there is no ADPCM port-C traffic, no ROM contention, no refresh pressure.
   -- Retires every CD-RAM probe generation in one switch: the 0xC0-0xC8 read/write
   -- snoop, the 0xCA-0xCE write capture and extents, and the 0xCF page watch. They have
   -- all answered and their answers are recorded -- CD-RAM is correct, and its contents
   -- were separately verified byte-for-byte against the real CHD, so nothing here is
   -- still a live question.
   --
   -- They are retired because they were no longer free. Worst setup slack fell
   -- 0.597 -> 0.403 -> 0.303 -> 0.095 -> 0.076 -> 0.023 ns as these accumulated, and at
   -- 23 ps a failure on real silicon can be a timing failure wearing a logic failure's
   -- clothes -- which is the worst possible thing to hand a debugging session.
   --
   -- A constant-false `if` is eliminated at elaboration, so the registers and their
   -- fanout genuinely disappear. (The "a tie-off does not prune" rule from 984d3ce is
   -- about ports of an INSTANTIATED module, which is a different situation.)
   -- LEFT TRUE DELIBERATELY. Setting it false to "recover timing margin" was tried on
   -- 2026-09-14 and made timing WORSE, twice: place_option 2 went from +0.023 ns (passing)
   -- to -0.085 ns / 21 negative endpoints, and place_option 0 to -0.134 ns / 3. The reason
   -- is that these probes are NOT on the critical path at all -- the worst path is
   -- hdmi_out/act_h_2_s1 through ~14 levels of hdmi_out nets, i.e. the HDMI output block.
   -- Removing unrelated logic only reshuffles placement around an already-marginal path.
   -- If margin is needed, fix hdmi_out (it was pipelined once before for exactly this
   -- reason); do not go probe-hunting for it.
   constant CDRAM_PROBES : boolean := true;
   constant CDRAM_SELFTEST : boolean := false;
   type cdt_state_t is (CDT_IDLE, CDT_W, CDT_W_WAIT, CDT_R, CDT_R_WAIT, CDT_DONE);
   signal cdt_state  : cdt_state_t := CDT_IDLE;
   -- FULL 256KB sweep, not a 1KB sample. The first version wrote 1024 bytes at offset 0
   -- and passed 1024/1024, which proves the offload moves bytes but says NOTHING about
   -- the window's size or whether it aliases -- and an aliasing CD-RAM window is exactly
   -- the bug that lets a small boot loader work while a real game's data quietly
   -- overwrites itself. This file's own history contains one such bug (the Arcade Card
   -- window, fixed 2026-08-29), so it is a live possibility, not a hypothetical.
   --
   -- Data is derived from the ADDRESS, so if two offsets collide the later write changes
   -- the earlier one and the read-back pass catches it. A fixed pattern could not.
   signal cdt_idx    : unsigned(17 downto 0) := (others => '0');
   signal cdt_wait   : unsigned(3 downto 0) := (others => '0');
   signal cdt_a      : std_logic_vector(21 downto 0) := (others => '0');
   signal cdt_do     : std_logic_vector(7 downto 0) := (others => '0');
   signal cdt_rd     : std_logic := '0';
   signal cdt_wr     : std_logic := '0';
   signal cdt_active : std_logic := '0';
   signal cdv_ok     : unsigned(15 downto 0) := (others => '0');
   signal cdv_bad    : unsigned(15 downto 0) := (others => '0');
   signal cdv_first  : std_logic_vector(15 downto 0) := (others => '0');
   -- One-shot latch so the 0xC9 result is emitted once, not re-emitted every heartbeat.
   signal cdv_sent   : std_logic := '0';

   -- what the arbiter actually sees: the self-test while it runs, pce_top afterwards
   signal cdr_a_mux  : std_logic_vector(21 downto 0);
   signal cdr_do_mux : std_logic_vector(7 downto 0);
   signal cdr_rd_mux : std_logic;
   signal cdr_wr_mux : std_logic;

   signal cd_ram_a     : std_logic_vector(21 downto 0);
   signal cd_ram_do    : std_logic_vector(7 downto 0);
   signal cd_ram_di_i  : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_ram_rd    : std_logic;
   signal cd_ram_wr    : std_logic;
   signal cd_ram_rdy_i : std_logic := '1';

   -- CD-RAM READ SNOOP (2026-09-13). The sim boots this disc to its title screen; the
   -- board runs the same RTL, is handed byte-identical sector data (tag 0xA4's eight
   -- bytes match the sim's CD-RAM image exactly), reports 0 drops and 0 underruns, and
   -- still never issues command 9 -- it drops into the syscard's error loop instead
   -- (tags 0xD7/0xD8/0xD9: $1800-$1807 cleared, $1802 toggled, palette rewritten all
   -- black). Everything on the delivery path is therefore accounted for, and the one
   -- subsystem that differs between sim and board is where those bytes are STORED:
   -- simulation models CD-RAM as a plain VHDL array, the board puts it in SDRAM behind
   -- the cdr_owner arbiter, shared with ADPCM.
   --
   -- This snoops the CPU's OWN CD-RAM reads instead of adding a second SDRAM reader:
   -- no new port, no extra arbitration on a design with ~0 timing margin, and it
   -- reports exactly the bytes the CPU executed rather than what some other agent read.
   --
   -- Window is CPU_A(17:0) = 0x0100xx. pce_top drives `CD_RAM_A <= "1000" & CPU_A(17
   -- downto 0)` (pce_top.vhd:1344), so the tag is bits 21:18 and the low 18 bits are the
   -- raw CPU address. The sim's own CD-RAM tracker shows every write of this boot landing
   -- in 0x010000..0x01076B, and its CPU begins executing at 0x0100BB.
   --
   -- REFERENCE (sim, 16 bytes at 0x010000, from sim/cd/tb_cd_boot.vhd's [cdram] dump):
   --   4C F6 42 4C A8 40 4C 0F 42 4C B6 49 4C BF 49 4C
   -- Each captured entry is addr(7:0) & data(7:0), oldest first from the MSB.
   -- v2 (2026-09-13, after the first run came back ALL ZEROS). Two corrections:
   --
   -- 1. The address is now latched when the access is ACCEPTED, not when its data
   --    arrives. cd_ram_a is level-held only until rdy rises, and the CPU can start the
   --    next access on that same edge -- v1 sampled the address one access late, which
   --    is why it reported odd addresses stepping by two instead of an instruction
   --    fetch pattern. The DATA was always right; only the label was skewed.
   -- 2. WRITES are snooped too. "CD-RAM returns zero" has two readings -- the loader
   --    stored the program and readback is broken, or the loader never stored it at all
   --    -- and only the write side separates them. Writes are NOT gated on
   --    sum_cmd_cnt >= 8: the program is stored DURING commands 6-8, so gating them the
   --    way the reads are gated would capture nothing and look like "never written".
   -- 32-bit entries carrying the FULL 18-bit CD-RAM address, captured anywhere in
   -- CD-RAM rather than only the 0x0100xx page. Pinning the window meant that once
   -- CD-RAM actually worked and the CPU stored the program somewhere else, the capture
   -- stayed empty and said nothing at all -- which is what the first post-fix run did.
   signal cdsnoop_buf    : std_logic_vector(511 downto 0) := (others => '0');
   signal cdsnoop_cnt    : unsigned(4 downto 0) := (others => '0');
   -- Nine frames per pass (0xC0-0xC8), three passes. Kept as an explicit index+pass
   -- pair rather than one counter masked down: a 0..26 counter with a 3-bit mask makes
   -- frame 9 re-emit as tag 0xC1, which is exactly the tag-collision class that has
   -- already cost this project hardware rounds.
   signal cdsnoop_idx    : unsigned(3 downto 0) := (others => '0');
   signal cdsnoop_pass   : unsigned(1 downto 0) := (others => '0');
   signal cd_rdy_r       : std_logic := '1';
   signal cdsn_rd_r      : std_logic := '0';
   signal cdsn_wr_r      : std_logic := '0';
   signal cdsn_a_lat18   : std_logic_vector(17 downto 0) := (others => '0');
   signal cdsn_rd_pend   : std_logic := '0';
   signal cdsnoop_wbuf   : std_logic_vector(255 downto 0) := (others => '0');
   signal cdsnoop_wcnt   : unsigned(4 downto 0) := (others => '0');
   -- Lowest / highest CD-RAM address the loader ever wrote. lo starts at all-ones so the
   -- first write sets it; if no write ever happens lo stays 0x3FFFF and hi stays 0.
   signal cdram_wr_lo    : unsigned(17 downto 0) := (others => '1');
   signal cdram_wr_hi    : unsigned(17 downto 0) := (others => '0');
   -- Page watch on 0x137xx -- the page the CPU reads 0x00 from. See the capture site.
   signal wr137_cnt      : unsigned(15 downto 0) := (others => '0');
   signal wr137_last_a   : std_logic_vector(7 downto 0) := (others => '0');
   signal wr137_last_d   : std_logic_vector(7 downto 0) := (others => '0');
   signal wr137_first20  : std_logic_vector(7 downto 0) := (others => '0');
   signal wr137_hit20    : std_logic := '0';
   -- Totals over the WHOLE CD-RAM space, not just the window: if the CPU never touches
   -- CD-RAM at all these stay 0, which is a different fault from a bad readback.
   signal cdram_rd_total : unsigned(15 downto 0) := (others => '0');
   signal cdram_wr_total : unsigned(15 downto 0) := (others => '0');
   -- Core-reset census. "The boot restarts" has two very different causes -- the user
   -- pressing RUN, or the core resetting itself -- and the trace could not tell them
   -- apart, so the probe-block repeat count got misread as automatic resets once.
   -- Counts core_resetn falling edges since the FPGA was loaded; trap/bank_bad are
   -- sticky so a fault that happened in an EARLIER attempt is still visible.
   signal core_rst_cnt   : unsigned(5 downto 0) := (others => '0');
   signal core_rst_r     : std_logic := '0';
   signal trap_sticky    : std_logic := '0';
   signal bank_sticky    : std_logic := '0';

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
   -- PCE PORT (2026-09-15). ROOT CAUSE of "CD games load, then dark screen".
   --
   -- cdr_a_last / cd_new_comb / cd_done / cd_ram_rdy_comb are the CD-RAM half of the fix
   -- 777ba38 applied to the ROM bridge and never applied here. The defect, measured on
   -- DD2: the CPU executed a TAM at $D7C8 out of CD-RAM and took $53 -- the TAM OPCODE --
   -- as its operand mask. $53 = bits 0,1,4,6, and the trapped MPR file reads
   -- 00 97 83 97 81 80 97 97: MPR0/1/4/6 = $97 and MPR2/3/5/7 untouched, a bit-exact
   -- fingerprint. $97 is not a bank, so I/O and work RAM (the STACK) unmapped, and the
   -- next RTI jumped into nowhere. Identical signature to the ROM bridge's, recorded in
   -- RB_IDLE's own comment below.
   --
   -- Mechanism: CD_RAM_RD is a LEVEL, not a pulse --
   --   pce_top.vhd    CD_RAM_RD <= CPU_PRE_RD and not (CD_RAM_CS_N and AC_RAM_CS_N)
   --   HUC6280.vhd    PRE_RD    <= CPU_WE_N and CPU_MCYCLE
   --   HUC6280_CPU    MCYCLE    <= MC.MEM_CYCLE      (combinational, per microcode row)
   -- TAM's rows are STATE0 '[PC]->IR, PC++' and STATE1 '[PC]->T, PC++', both MEM_CYCLE=1
   -- and both in CD-RAM, so the read line never falls between them. cd_new was a rising
   -- edge ONLY, so the second fetch launched no access at all: cd_ram_rdy_i stayed '1'
   -- (the CPU was never stalled) and cd_ram_di_i still held the first byte. Generally:
   -- ANY run of consecutive CD-RAM fetches returns the FIRST byte of the run, which means
   -- multi-byte code cannot execute from CD-RAM. That is why the DATA path always
   -- measured clean -- the syscard's CD-RAM traffic is interleaved with I/O/RAM/ROM
   -- cycles, so the line toggles and every access gets its edge (hence the 16/16
   -- byte-identical CD-RAM readback) -- while every disc died the instant the syscard
   -- JUMPED into CD-RAM.
   --
   -- Why the donor does not have this bug: it never edge-detects. TurboGrafx16.sv:768 is
   --   .rd(use_sdr & (rom_rd | cd_ram_rd) & ce_rom)
   -- where ce_rom is pce_top's ROM_CLKEN, i.e. CPU_CLKEN, the CPU's own bus-cycle clock
   -- enable exported for exactly this purpose -- one launch per memory cycle, so a
   -- level-held read line is harmless. The donor also gives ROM and CD-RAM ONE SDRAM
   -- port, ONE data bus and ONE ready (its pce_top has no CD_RAM_RDY port at all), so
   -- CD-RAM inherits ROM's stall path for free. This port split them onto SDRAM ports B
   -- and C with two independent arbiters and wired `ROM_CLKEN => open`, discarding the
   -- per-cycle strobe; each arbiter then had to rediscover that a level-held line needs a
   -- per-cycle trigger. The ROM bridge did (777ba38). This one did not -- and CDR_SETTLE's
   -- comment shows it had already been skipped once, by 696313d.
   --
   -- The ROM idiom is ported rather than ROM_CLKEN revived, deliberately: the address
   -- compare is proven on THIS board (1943 Kai boots on it), the cdt_active self-test
   -- drives cdr_rd_mux from its own toggling source so the edge term has to stay in any
   -- case, and one idiom across both bridges is worth more than fidelity to a mechanism
   -- neither bridge currently uses. Reviving ROM_CLKEN for both at once is the cleanup.
   signal cdr_a_last     : std_logic_vector(21 downto 0) := (others => '0');
   signal cd_new_comb    : std_logic;
   signal cd_done        : std_logic := '0';
   signal cd_ram_rdy_comb : std_logic;

   -- Real SCSI target -- cd_bridge.vhd (shared across all 3 boards, 2026-08-31), see that
   -- file's own header for the full command decode/protocol trace.
   signal cd_stat_i      : std_logic_vector(7 downto 0);
   signal cd_msg_i       : std_logic_vector(7 downto 0);
   signal cd_stat_get_i  : std_logic;
   signal cd_comm_i      : std_logic_vector(95 downto 0);
   signal cd_comm_send_i : std_logic;
   -- TEMP CD trace (2026-09-10): the syscard reaches CD PLAYER, meaning it read the TOC
   -- and concluded there was nothing bootable, and the MCU's own counters show it was
   -- never asked for a single data sector. Everything MCU-side checks out (TOC LBAs and
   -- the data-track control bit are both right, verified against the .chd on the host),
   -- so the question is what cd_bridge is actually being ASKED and what it answers --
   -- which nothing on this board can currently see. Latch every SCSI CDB the core sends.
   -- TEMP TOC trace (2026-09-10): the syscard issues TEST UNIT READY, then GETDIRINFO,
   -- then gives up -- it never issues READ(6) at all, so it is deciding from what the
   -- TOC tells it. The MCU builds that TOC correctly (verified against the .chd on the
   -- host: 34 tracks, track 2 MODE1_RAW at LBA 3590, lead-out 316011). What has NEVER
   -- been checked is whether it survives the trip across the wire into cd_bridge. These
   -- latch what the top level actually hands the bridge. Only the entries that decide
   -- bootability are kept, not all 35 -- the trace channel is single-outstanding and a
   -- back-to-back burst would drop most of them; these are emitted at heartbeat cadence.
   signal toc_wr_r        : std_logic := '0';
   signal toc_wr_count    : unsigned(7 downto 0) := (others => '0');
   -- TOC_WR pulses that arrived while the core was still held in reset (saturating).
   signal toc_wr_inrst    : unsigned(7 downto 0) := (others => '0');
   signal toc_t1_lba      : std_logic_vector(23 downto 0) := (others => '0');
   signal toc_t2_lba      : std_logic_vector(23 downto 0) := (others => '0');
   signal toc_lo_lba      : std_logic_vector(23 downto 0) := (others => '0');
   signal toc_t1_ctl      : std_logic_vector(7 downto 0) := (others => '0');
   signal toc_t2_ctl      : std_logic_vector(7 downto 0) := (others => '0');
   signal toc_maxtrack    : std_logic_vector(7 downto 0) := (others => '0');
   signal toc_sent_cnt    : unsigned(2 downto 0) := (others => '0');

   signal cd_comm_send_r  : std_logic := '0';
   -- Rate limit for CD command traces. The syscard polls, so commands arrive far faster
   -- than a 9-byte trace frame takes to leave at 2 Mbaud, and back-to-back requests
   -- overran the channel: payloads came back containing "aa 00 0a 09 <tag>", i.e. the
   -- NEXT frame's own protocol header. Anything decoded from such a frame is fiction.
   -- One trace per ~1 ms (42857 clk_pce cycles) is far longer than a frame takes.
   signal cdcmd_gap       : unsigned(15 downto 0) := (others => '0');
   -- 2026-09-11: CD command tracing OFF. It shares the FPGA->MCU link with the CD
   -- SECTOR REQUESTS, and the MCU's opcode-9 handler calls file_log() -- f_write plus
   -- f_sync to the SD card -- from inside the UART RX parser. That blocks for
   -- milliseconds; at 2 Mbaud the RX stream overflows and desyncs, and once desynced it
   -- never recovers. The signature is unmistakable: the first few frames decode cleanly
   -- and then every payload contains "aa 00 0a 09 <tag>", i.e. the NEXT frame's own
   -- protocol header, read as data. A desynced stream also swallows the opcode-6 sector
   -- requests, which is why cdprog stayed empty -- the reads may have been arriving all
   -- along. Rate-limiting to 1 ms did not help because the cost is per frame, not per
   -- burst. It has already told us what it was for (TOC lands, syscard issues READ(6)),
   -- so it comes out rather than keep corrupting the channel it is measuring.
   -- The heartbeat (32 frames over ~3.2 s) and the four TOC frames are sparse enough.
   constant CDCMD_TRACE : boolean := false;
   -- Trace ONLY READ(6) (opcode 0x08), capped at 2 frames, tags 0xA8/0xA9. With the
   -- stream now clean and still no sector request reaching the MCU, cd_bridge is simply
   -- not pulsing SECTOR_REQ, and the likeliest reason is its own lead-out bounds check
   -- (`if sa > toc_leadout_lba` in the READ(6) decode) rejecting the address. That needs
   -- the REAL address, and the only previous sighting of a READ CDB came from a frame
   -- corrupted by the flood this replaces -- so its LBA meant nothing. Two frames total
   -- cannot flood anything: the MCU logs each trace to SD from inside its UART RX
   -- parser, so trace volume is what desynced the link before.
   signal rdcmd_cnt   : unsigned(1 downto 0) := (others => '0');
   signal rdcmd_pend  : std_logic := '0';
   signal rdcmd_data  : std_logic_vector(63 downto 0) := (others => '0');
   -- What cd_bridge ANSWERS to GETDIRINFO. The TOC it holds is provably right (traced:
   -- 35 writes, track 2 control 0x04 @ 3590, lead-out 316011), yet the syscard then asks
   -- to READ LBA 0x1FFF9B = -101, whose byte 1 is 0xFF when only its low 5 bits are
   -- address. That is not an address derived from a sane TOC, so the reply path is the
   -- suspect, not the table. Capture the first 8 bytes the bridge writes out after a
   -- GETDIRINFO (0xDE), which covers mode 0 (first/last track, BCD), mode 1 (lead-out
   -- AMSF) and mode 2 (per-track AMSF). Capped at 2 frames: the MCU logs each trace to
   -- SD from inside its UART RX parser, so volume is what desyncs the link.
   signal dirinfo_arm  : std_logic := '0';
   signal dirinfo_cnt  : unsigned(3 downto 0) := (others => '0');
   signal dirinfo_sent : unsigned(1 downto 0) := (others => '0');
   signal dirinfo_pend : std_logic := '0';
   signal dirinfo_data : std_logic_vector(63 downto 0) := (others => '0');
   signal cd_data_wr_r : std_logic := '0';
   -- 2026-09-11, sector-transfer counters. cd_bridge's multi-sector READ(6) is PROVEN
   -- correct in simulation (sim/cd/tb_cd_bridge.vhd issues sa=0x1000 sc=2, checks all 4096
   -- bytes and the second sector's LBA), and iosys's request latch has priority over the
   -- debug traces and is cleared after transmit. Yet hardware fires exactly ONE
   -- SECTOR_REQ. The bridge only advances to the next sector once SCSI_READ_GAP has
   -- counted 2048 SECTOR_DATA_VALID pulses, so the question is purely how many bytes
   -- actually cross, and these three counters answer it from top-level signals alone:
   --   valid  == 2048 and wr == 2048 -> the sector completed; look at why REQ #2 is lost
   --   valid  == 2048 and wr <  2048 -> the bridge is dropping bytes
   --   valid  <  2048               -> iosys/MCU delivered short, bridge waits forever
   signal sum_alt      : unsigned(3 downto 0) := (others => '0');  -- cycles 0xAE/0xAF/0xAD/0xA4/0xA5/0xA6/0xAA/0xAB/0xA7/0xAC
   -- 2026-09-11: WHY the syscard rejects a transfer it received correctly.
   -- Both sectors of the 2-sector READ(6) reach it (0xAF: valid=4096, req=2), the sector
   -- at file frame 3368 self-identifies as LBA 3590 in its own sync header, and the IPL
   -- signature sits in the next sector -- yet it issues no further READ and loops on
   -- REQUEST SENSE. So either the bridge handed back a CHECK CONDITION, or the syscard
   -- rejected the content. The sense key/ASC it is being given separates those: they are
   -- bytes 2 and 12 of the REQUEST SENSE response, captured off CD_DATA the same way the
   -- GETDIRINFO reply already is.
   signal sense_arm    : std_logic := '0';
   signal sense_idx    : unsigned(4 downto 0) := (others => '0');
   signal sense_key    : std_logic_vector(7 downto 0) := (others => '0');
   signal sense_asc    : std_logic_vector(7 downto 0) := (others => '0');
   signal last_stat    : std_logic_vector(7 downto 0) := (others => '0');
   signal chk_cond_cnt : unsigned(15 downto 0) := (others => '0');
   signal stat_get_r   : std_logic := '0';
   signal sd_valid_r   : std_logic := '0';
   signal sd_valid_cnt : unsigned(15 downto 0) := (others => '0');
   signal cd_wr_cnt    : unsigned(15 downto 0) := (others => '0');
   signal sect_req_r   : std_logic := '0';
   signal sect_req_cnt : unsigned(15 downto 0) := (others => '0');
   -- ROLLING SUMMARY, emitted at heartbeat cadence (~100ms) instead of one-shot traces.
   -- One-shot traces of transient events proved unreliable: READ(6) appeared twice in one
   -- run and not at all in the next, and GETDIRINFO's reply is only 2-3 bytes so an
   -- 8-byte capture never completed. Adding more one-shots is not an option either --
   -- the MCU logs every trace to SD from inside its UART RX parser, and f_sync can block
   -- far longer than the 1 ms spacing I tried, which is why volume corrupted the link.
   -- Accumulating in RTL and reporting periodically is bounded by construction: the
   -- summary is always current whenever the log happens to be read.
   -- CPU-side SCSI probes (see SCSI.vhd DBG_* port comment). These answer the one
   -- question the bridge-side counters structurally cannot: whether the bytes we fed
   -- into the FIFO are the bytes the CPU took out, and in what order.
   signal scsi_datain_cnt_i : unsigned(15 downto 0);
   signal scsi_first8_i     : std_logic_vector(63 downto 0);
   signal scsi_sp_i         : std_logic_vector(3 downto 0);
   signal scsi_gdi_i        : std_logic_vector(127 downto 0);
   signal scsi_dend_i       : std_logic_vector(31 downto 0);
   -- ADPCM activity: PLAY/END/HALF, plus counters for how often the offloaded ADPCM
   -- RAM is actually accessed. A game stuck waiting for an ADPCM end that never comes
   -- keeps rendering (VDC writes and frames climb) while issuing no further CD command
   -- -- exactly what Dungeon Explorer II does on this board.
   signal adpcm_dbg_i       : std_logic_vector(2 downto 0);
   signal adpcm_play_r      : std_logic := '0';
   signal adpcm_end_r       : std_logic := '0';
   signal adpcm_play_cnt    : unsigned(15 downto 0) := (others => '0');
   signal adpcm_end_cnt     : unsigned(15 downto 0) := (others => '0');
   signal adpcm_req_cnt     : unsigned(15 downto 0) := (others => '0');
   signal adpcm_req_r       : std_logic := '0';
   -- SCSI command-phase state, to tell a real stalled command from a PHANTOM selection.
   -- Any write to $1800 asserts SEL and SP_FREE treats that as a selection without
   -- checking the data bus for a target ID -- so the game's routine that clears
   -- $1800-$1807 starts a command phase nobody intended, and BSY never releases.
   signal scsi_comm_pos_i   : unsigned(3 downto 0);
   signal scsi_comm0_i      : std_logic_vector(7 downto 0);
   signal scsi_comm1_i      : std_logic_vector(7 downto 0);
   signal scsi_sel_cnt_i    : unsigned(15 downto 0);
   signal scsi_fifo_space_i : unsigned(12 downto 0);
   -- Free entries in cd.vhd's CD-DA FIFO, pce_top -> cd_bridge, for audio prefetch
   -- flow control (2026-09-16). cd_bridge lives here rather than inside pce_top, so
   -- this has to be routed through the top level exactly like scsi_fifo_space_i is.
   -- See docs/CD_AUDIO_TIMING.md.
   signal cdda_space_i      : unsigned(12 downto 0);
   -- SCSI bus reset from cd.vhd (CPU writes $1802 bit 1). Was `CD_RESET => open`, which
   -- left cd_bridge parked mid-transfer across a host bus reset -- see BUS_RST's own
   -- comment in cd_bridge.vhd.
   signal cd_bus_rst_i      : std_logic;
   signal scsi_fifo_drops_i : unsigned(15 downto 0);
   -- TRACE HOLD-OFF. Every trace frame this board emits is received by the BL616 inside
   -- uart1_rx_task, which writes it to the SD card (file_log -> f_write + f_sync) from
   -- that same task -- so each frame blocks the MCU's UART RX for milliseconds. The CD
   -- sector request is a 5-byte frame on that same RX path, sent the instant the bridge
   -- has consumed 2048 bytes, and a request that lands in an f_sync window is simply
   -- lost: the bridge then parks in SCSI_READ_WAIT_BYTE forever.
   --
   -- Measured 2026-09-11: the run before this one delivered 4096 bytes (both sectors);
   -- adding seven diagnostic tags roughly doubled the frame rate and it dropped to 2048.
   -- The instrumentation was competing with the protocol it was measuring.
   --
   -- So: reload a timer on any real sector-channel activity and emit nothing until the
   -- channel has been quiet for ~20ms. Deliberately keyed on ACTIVITY (SECTOR_REQ /
   -- SECTOR_DATA_VALID pulses) and NOT on the bridge FSM state -- a bridge parked
   -- waiting for a sector that never comes would hold a state-based gate shut forever
   -- and suppress the very trace that diagnoses the stall. With an activity-based gate
   -- a stall goes quiet, the timer expires, and the trace resumes and reports it.
   -- The ten CD summary tags added while debugging the boot consume EVERY heartbeat
   -- slot, and the chain below them (TOC, trap 0xE0+, video heartbeat 0x80+) is an
   -- elsif chain -- so once they existed, the CPU/video probes silently stopped being
   -- emitted entirely. Measured 2026-09-11: a whole run came back with 109 copies each
   -- of the CD tags and not one 0x8x or 0xE frame. Give the CD rotation a budget so it
   -- reports the boot and then hands the channel back.
   -- Budget is re-armed by a real SCSI command, NOT counted down from power-on. The
   -- wall-clock version (2026-09-11) expired ~3s after reset, which is before the user
   -- has even pressed RUN, so it reported the idle period and nothing else: every
   -- RTL[ae]/[af] in that run read zero. Keyed to activity, the tags go quiet when the
   -- CD is quiet and report the few seconds after each command, which is the window
   -- that carries information.
   -- Starts at ZERO, not 3. The core is released while the MCU is still finishing
   -- load_rom, and a full CD rotation fired straight into that window: ~30 frames, each
   -- costing the MCU an f_sync inside its polled UART RX task. Measured 2026-09-11: the
   -- MCU wedged between "loadpcecd: returning 0" and "menu_loadrom: load_rom returned"
   -- and not one trace frame was ever received for the whole run. Nothing to report at
   -- t=0 anyway -- no SCSI command has happened yet.
   signal cd_rot_left       : unsigned(3 downto 0) := (others => '0');
   -- Hold the whole trace channel off for ~1s after the core is released, for the same
   -- reason: let the MCU finish its load path before giving it anything to log.
   signal trace_warmup      : unsigned(25 downto 0) := (others => '0');
   signal trace_ready       : std_logic := '0';
   signal cpu_tag_cnt       : unsigned(7 downto 0) := (others => '0');
   signal cdv_tag_cnt       : unsigned(7 downto 0) := (others => '0');
   signal d6_tag_cnt        : unsigned(7 downto 0) := (others => '0');
   -- VCE/palette activity. In mednafen this game's splash appears immediately after the
   -- load, WITH a palette effect; here the CPU renders happily and the screen stays
   -- black, which is what a palette that never lands (or lands all-black) looks like.
   -- Rolling ring of the last four CD-register ($1FF800 page) accesses. A game stuck
   -- in a poll loop fills this with the same register over and over, which names what
   -- it is waiting on -- the one thing the hardware trace could not show and the sim
   -- could. Each entry: R/W flag, register low byte, data.
   signal dbg_cpu_wr_n      : std_logic;
   signal dbg_cpu_rd_n      : std_logic;
   signal dbg_cpu_do        : std_logic_vector(7 downto 0);
   signal dbg_cpu_di        : std_logic_vector(7 downto 0);
   -- ONE-SHOT capture of the first twelve CD-register accesses after the last SCSI
   -- command, rather than a rolling ring. The ring showed the poll loop
   -- ($1802/$1803 alternating, CH_SEL toggling) but a 4-deep ring of a 4-access loop can
   -- never show what came BEFORE it, which is the part that explains why the game is
   -- waiting. Armed when the command count stops advancing.
   signal cdreg_shot        : std_logic_vector(191 downto 0) := (others => '0');
   signal cdreg_idx         : unsigned(4 downto 0) := (others => '0');
   signal cdreg_armed       : std_logic := '0';
   signal cdreg_cmd_r       : unsigned(7 downto 0) := (others => '0');
   signal cdreg_ring        : std_logic_vector(63 downto 0) := (others => '0');
   signal cdreg_cnt         : unsigned(15 downto 0) := (others => '0');
   signal cdreg_acc_r       : std_logic := '0';
   signal cdreg_data        : std_logic_vector(7 downto 0);

   -- ------------------------------------------------------------------ 0xDB
   -- CONTINUOUS CD-register stream, as opposed to every probe above it, which is a
   -- snapshot. The reason to switch: an instrumented mednafen run of this disc that
   -- reaches the title screen logs 158645 CD-register accesses, but 94477 of those are
   -- reads of $1800 (the busy poll) and 63488 are reads of $1808 (the sector payload,
   -- 31 sectors x 2048 bytes). Drop those two and the ENTIRE boot is 680 accesses --
   -- small enough to stream over this link in full and diff against the reference with
   -- scripts/cd_golden_diff.py. Every snapshot probe in this file has cost a hardware
   -- round trip and answered a question narrower than it looked; a 12-entry window over
   -- a handful of writes is how "the game clears its registers" and "SP_COMM_END is
   -- normal" both got read as smoking guns when neither was.
   --
   -- One entry per trace frame, with a sequence number, so a gap is VISIBLE rather than
   -- silently changing the meaning of the stream. 680 frames over a boot is ~3.4 ms of
   -- link time in total, so the wasted 32 bits per frame cost nothing and buy a single
   -- 64:1 read mux instead of four.
   -- OFF (2026-09-13). Turning this on regressed real hardware: the CPU issued all six
   -- of the boot's opening commands and asked the MCU for LBA 3590, and the MCU never saw
   -- the request -- no cdprog/DECODE-START/SERVED line for that run at all, while earlier
   -- runs in the same log served it correctly. A frame per CD register access is ~110
   -- frames (~1 KB at 2 Mbaud) before the first READ even happens, and the BL616's polled
   -- RX has ~7 bytes of margin (rxhi=21 of 32): it desyncs and swallows the opcode-6
   -- sector request along with the trace. This is the hazard already recorded in
   -- pcetang_trace_channel_vs_cd_protocol.md, and gating on cd_link_busy is not enough
   -- because the flood happens BEFORE any sector transfer is in flight.
   --
   -- Re-enable only with the link problem solved first -- chunk-level flow control, or a
   -- second wire. Until then the golden-trace diff has to come from simulation, which
   -- reproduces the full boot anyway.
   -- DO NOT SET THIS TRUE. It was tried on 2026-09-14 and killed the run it was meant
   -- to measure: streaming one trace frame per CD register access floods the FPGA->BL616
   -- link, the MCU's polled UART RX desyncs (payloads come back containing `aa aa aa`,
   -- the next frame's protocol header read as data), and SECTOR REQUESTS ARE EATEN. The
   -- board got 6 commands, 1 READ(6), REQRING "0 traced of 0 total" -- zero sectors
   -- served -- and hung on "just a moment" waiting for LBA 3890 forever. The changed
   -- symptom looks like new information; it is the instrument.
   --
   -- Volume, not timing, is the constraint on this link. To observe CD register
   -- behaviour, aggregate in RTL and report on the heartbeat: tags 0xB0/0xB1 record only
   -- DISTINCT $1800 phase values plus counters, which is bounded by construction (the
   -- reference polls $1800 430047 times per boot but changes value ~10 times per
   -- command). See memory pcetang_broken_probes.
   constant CDREG_STREAM : boolean := false;
   -- SCSI phase-transition recorder; see the capture site for why this is a change
   -- recorder and not a stream. ph_last starts at 0xFF, which $1800 can never return
   -- (bits 2..0 read as 0), so the very first real value always registers as a change.
   signal ph_last : std_logic_vector(7 downto 0)  := x"FF";
   signal ph_ring : std_logic_vector(63 downto 0) := (others => '0');
   signal ph_chg  : unsigned(15 downto 0) := (others => '0');
   signal ph_d8   : unsigned(15 downto 0) := (others => '0');
   signal ph_f8   : unsigned(15 downto 0) := (others => '0');
   signal ph_bf   : unsigned(15 downto 0) := (others => '0');
   signal ph_tag  : unsigned(4 downto 0)  := (others => '0');
   type cdt_mem_t is array (0 to 63) of std_logic_vector(15 downto 0);
   signal cdt_mem    : cdt_mem_t := (others => (others => '0'));
   -- 7-bit pointers over a 64-entry ring: the extra bit distinguishes full from empty.
   -- cdtq_wr is driven only by the capture process, cdtq_rd only by the emitter, so the
   -- two never share a driver (EX2000, hit in this file before).
   signal cdtq_wr    : unsigned(6 downto 0) := (others => '0');
   signal cdtq_rd    : unsigned(6 downto 0) := (others => '0');
   signal cdt_seq    : unsigned(15 downto 0) := (others => '0');
   signal cdt_drops  : unsigned(15 downto 0) := (others => '0');
   signal d7_tag_cnt        : unsigned(7 downto 0) := (others => '0');
   signal da_tag_cnt        : unsigned(7 downto 0) := (others => '0');
   signal dbg_vce_wr        : std_logic;
   signal dbg_vce_do        : std_logic_vector(7 downto 0);
   signal vce_wr_cnt        : unsigned(15 downto 0) := (others => '0');
   signal vce_nonzero_cnt   : unsigned(15 downto 0) := (others => '0');
   signal vce_last          : std_logic_vector(7 downto 0) := (others => '0');
   signal hb_alt            : std_logic := '0';
   signal cd_quiet_ct       : unsigned(19 downto 0) := (others => '0');
   signal cd_link_busy      : std_logic := '0';
   signal scsi_underruns_i  : unsigned(15 downto 0);
   signal scsi_rd_total_i   : unsigned(15 downto 0);
   signal cd_dbg_state_i    : std_logic_vector(4 downto 0) := (others => '0');
   -- Opcodes of the first eight commands of the boot sequence, one byte each, oldest
   -- in [63:56]. Diffed directly against a reference trace from beetle-pce-fast.
   signal op_first8    : std_logic_vector(63 downto 0) := (others => '0');
   signal op_idx       : unsigned(3 downto 0) := (others => '0');
   -- GETDIRINFO is issued several times in a row at boot and the opcode alone cannot
   -- tell those apart, so the mode byte (CDB[1]) and track byte (CDB[2]) of the first
   -- eight are kept separately. Reference for Dungeon Explorer II, captured from
   -- beetle-pce-fast on the same disc, is four calls: modes 00 01 02 02, tracks
   -- ca ca 01 02. This board issues five, and which one is extra is the open question.
   signal gdi_modes    : std_logic_vector(63 downto 0) := (others => '0');
   signal gdi_tracks   : std_logic_vector(63 downto 0) := (others => '0');
   signal gdi_idx      : unsigned(3 downto 0) := (others => '0');

   signal sum_cmd_cnt  : unsigned(7 downto 0) := (others => '0');
   signal sum_last_op  : std_logic_vector(7 downto 0) := (others => '0');
   signal sum_read_cnt : unsigned(7 downto 0) := (others => '0');
   signal sum_read_lba : std_logic_vector(23 downto 0) := (others => '0');
   signal sum_dir_cnt  : unsigned(7 downto 0) := (others => '0');
   signal sum_dir_b0   : std_logic_vector(7 downto 0) := (others => '0');
   signal sum_dir_b1   : std_logic_vector(7 downto 0) := (others => '0');
   signal cdcmd_cnt       : unsigned(5 downto 0) := (others => '0');
   signal cdcmd_pend      : std_logic := '0';
   signal cdcmd_data      : std_logic_vector(63 downto 0) := (others => '0');
   signal cd_data_i      : std_logic_vector(7 downto 0);
   signal cd_datain_sectors_i : unsigned(8 downto 0);
   -- video geometry tap, see tag 0xB3
   signal dbg_vdc_screen_i : std_logic_vector(2 downto 0);
   signal dbg_vce_cr_i     : std_logic_vector(7 downto 0);
   signal vdc_screen_seen  : std_logic_vector(7 downto 0) := (others => '0');
   signal vce_cr_seen      : std_logic_vector(7 downto 0) := (others => '0');
   signal vdc_screen_chg   : unsigned(15 downto 0) := (others => '0');
   signal vce_cr_chg       : unsigned(15 downto 0) := (others => '0');
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
   signal adpcm_bridge_req_r   : std_logic := '0';
   signal adpcm_new_comb       : std_logic;
   signal adpcm_ram_ready_comb : std_logic;

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
   -- PCE PORT (2026-09-09): REAL pad readers. joy1_ds2 used to be tied to zero with the
   -- note "not wired to a real controller in this first cut", which meant the core had NO
   -- pad input at all: joy1 collapsed to hid1, itself only populated by USB gamepads.
   -- The board's pads are DS2 over PMOD1 and were never read by this bitstream.
   --
   -- Note the data flow, which is easy to get backwards: the FPGA reads the pads and
   -- SENDS them to the BL616 (iosys opcode 3, main.cpp:441 fills joy1_state from it).
   -- The MCU does not read these pads. So a core without a reader breaks menu navigation
   -- too -- the menu only kept working because it runs on monitor.bin, a different
   -- bitstream that has one.
   ds2_p1 : controller_ds2
      generic map ( FREQ => 42_857_000 )      -- clk_pce
      port map ( clk => clk_pce, snes_buttons => joy1_ds2,
                 ds_clk => ds_clk, ds_miso => ds_miso, ds_mosi => ds_mosi, ds_cs => ds_cs );

   ds2_p2 : controller_ds2
      generic map ( FREQ => 42_857_000 )
      port map ( clk => clk_pce, snes_buttons => joy2_ds2,
                 ds_clk => ds_clk2, ds_miso => ds_miso2, ds_mosi => ds_mosi2, ds_cs => ds_cs2 );

   joy1     <= joy1_ds2 or hid1(11 downto 0);
   joy2     <= joy2_ds2 or hid2(11 downto 0);

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
      joy1 => joy1, joy2 => joy2,
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
         elsif vfy_state = VF_DONE
               and (not CDRAM_SELFTEST or cdt_state = CDT_DONE) then
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
               if rom_loading(0) = '0' and rom_loading_r = '1' and not SELFTEST then
                  -- Scaffolding off: release the core at once, as the original design did.
                  vfy_state   <= VF_DONE;
               elsif rom_loading(0) = '0' and rom_loading_r = '1' then
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
   rd_new_req <= '1' when rom_rd_i = '1' and (rom_rd_prev = '0' or rom_a /= rd_a_last)
                 else '0';

   -- Low the instant a NEW read is pending, so the CPU cannot sample the previous byte
   -- in the cycle before the registered rom_rdy_i catches up. The rd_done term is
   -- load-bearing: on the completion cycle the FSM is back in RB_IDLE with the new byte
   -- in rom_do_i, so ready must be '1' there for the CPU to consume it, even though
   -- rom_rd_i is still asserted for that same bus cycle.
   rom_rdy_comb <= '0' when rd_state /= RB_IDLE
                   else '0' when (rd_new_req = '1' and rd_done = '0')
                   else '1';

   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         rd_done <= '0';
         rom_rd_prev <= rom_rd_i;
         case rd_state is
            when RB_IDLE =>
               rom_rdy_i <= '1';
               -- PCE PORT (2026-09-09): start on a NEW request, not on a level.
               --
               -- rom_rd_i is a LEVEL held for the whole CPU bus cycle. Starting whenever
               -- it is high means that the instant this FSM returns to RB_IDLE it
               -- re-triggers on the SAME still-asserted read and the SAME unchanged
               -- rom_a -- fetching every byte twice, which is exactly what the
               -- derailment trap shows (0476, 0476, 0477, 0477).
               --
               -- That duplicate is what corrupts the CPU. While it is in flight the CPU
               -- advances to the next byte; when it completes the bridge presents the
               -- PREVIOUS byte and raises ROM_RDY, so the CPU accepts byte(N-1) as its
               -- byte(N). Measured: at the instant the CPU committed its fetch of ROM
               -- offset 0475 the bridge was presenting $53, the byte at 0474.
               -- Simulation of the identical cycle returns $40.
               --
               -- Everything downstream is that one byte: T took $53 (the TAM opcode)
               -- instead of the operand mask, so every TAM wrote MPR0/1/4/6 -- exactly
               -- the set bits of $53 -- leaving MPR1 = $A0 instead of $F8, and the CPU
               -- died on its first zero-page/stack access through MPR1.
               --
               -- Two independent conditions, deliberately OR'd rather than picking one:
               -- a rising edge of rom_rd_i catches a genuinely new bus cycle, and a
               -- change of rom_a catches back-to-back fetches where the CPU never lets
               -- the read line drop. Requiring BOTH would stall on whichever case the
               -- CPU does not exhibit; requiring either cannot miss a real request.
               if rd_new_req = '1' then
                  rd_addr <= std_logic_vector(ROM_SDRAM_BASE +
                             resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 25));
                  rom_rdy_i <= '0';
                  rd_a_last <= rom_a;
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

   -- PCE PORT (2026-09-15): the new-request detect, mirroring the ROM bridge's
   -- rd_new_req. Two conditions OR'd for the same reason stated there: a rising edge
   -- catches a genuinely new bus cycle, and a change of address catches back-to-back
   -- accesses where the CPU never lets the line drop -- which is the case this bridge was
   -- losing. Requiring both would miss whichever case the CPU does not exhibit.
   -- The address term covers writes too: consecutive same-level writes (a remapped stack)
   -- hit the identical hole, and block transfers alternate R/W so it costs nothing there.
   cd_new_comb <= '1' when (cdr_rd_mux = '1' or cdr_wr_mux = '1')
                           and ((cdr_rd_mux = '1' and cdram_rd_r = '0')
                                or (cdr_wr_mux = '1' and cdram_wr_r = '0')
                                or cdr_a_mux /= cdr_a_last)
                  else '0';

   -- Low the instant a new CD-RAM access is pending, so the CPU cannot sample the
   -- previous byte in the cycle before the REGISTERED cd_ram_rdy_i catches up -- the same
   -- one-cycle hole rom_rdy_comb closes, and cd_done is the same load-bearing term (on the
   -- completion cycle the FSM is back in CDR_IDLE with the new byte published, so ready
   -- must be '1' there even though cdr_rd_mux is still asserted for that bus cycle).
   --
   -- NOT the ROM bridge's `'0' when rd_state /= RB_IDLE` form: this arbiter is SHARED with
   -- ADPCM, and cdr_state is non-idle for every ADPCM RAM slot (~420ns, continuously
   -- during playback). That form would stall the CPU on accesses it is not making.
   -- cd_ram_rdy_i already encodes CD-RAM ownership correctly through cd_pend; the
   -- combinational term only closes the hole ahead of it.
   cd_ram_rdy_comb <= cd_ram_rdy_i and not (cd_new_comb and not cd_done);

   cdr_a_mux  <= cdt_a  when cdt_active = '1' else cd_ram_a;
   cdr_do_mux <= cdt_do when cdt_active = '1' else cd_ram_do;
   cdr_rd_mux <= cdt_rd when cdt_active = '1' else cd_ram_rd;
   cdr_wr_mux <= cdt_wr when cdt_active = '1' else cd_ram_wr;

   -- CD-RAM self-test driver (see CDRAM_SELFTEST's declaration comment).
   -- Address form matches pce_top's own CD-RAM mux: "1000" & an 18-bit offset, so bit 21
   -- is the tag that routes it to the CD-RAM window rather than the Arcade Card's.
   cdt_a  <= "1000" & std_logic_vector(cdt_idx);
   cdt_do <= (std_logic_vector(cdt_idx(7 downto 0)) xor std_logic_vector(cdt_idx(15 downto 8)))
             xor ("000000" & std_logic_vector(cdt_idx(17 downto 16)));

   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case cdt_state is
            when CDT_IDLE =>
               if CDRAM_SELFTEST and vfy_state = VF_DONE then
                  cdt_active <= '1';
                  cdt_idx    <= (others => '0');
                  cdt_state  <= CDT_W;
               end if;

            when CDT_W =>
               cdt_wr    <= '1';
               cdt_wait  <= to_unsigned(8, 4);
               cdt_state <= CDT_W_WAIT;

            when CDT_W_WAIT =>
               cdt_wr <= '0';
               -- hold off before believing cd_ram_rdy_i: it is still high for the first
               -- few cycles, until the arbiter has seen the access and dropped it.
               if cdt_wait /= 0 then
                  cdt_wait <= cdt_wait - 1;
               elsif cd_ram_rdy_i = '1' then
                  if cdt_idx = 262143 then
                     cdt_idx   <= (others => '0');
                     cdt_state <= CDT_R;
                  else
                     cdt_idx   <= cdt_idx + 1;
                     cdt_state <= CDT_W;
                  end if;
               end if;

            when CDT_R =>
               cdt_rd    <= '1';
               cdt_wait  <= to_unsigned(8, 4);
               cdt_state <= CDT_R_WAIT;

            when CDT_R_WAIT =>
               cdt_rd <= '0';
               if cdt_wait /= 0 then
                  cdt_wait <= cdt_wait - 1;
               elsif cd_ram_rdy_i = '1' then
                  -- ok counts in KiB, not bytes: 262144 read-backs would wrap a
                  -- 16-bit counter four times over, and a wrapped counter has misread
                  -- results three times on this project already. bad counts every byte,
                  -- since any nonzero value is the whole story and it will not wrap in
                  -- any case worth reporting.
                  if cd_ram_di_i = cdt_do then
                     if cdt_idx(9 downto 0) = 0 then
                        cdv_ok <= cdv_ok + 1;
                     end if;
                  else
                     cdv_bad <= cdv_bad + 1;
                     if cdv_bad = 0 then
                        cdv_first <= cdt_do & cd_ram_di_i;   -- wrote | read back
                     end if;
                  end if;
                  if cdt_idx = 262143 then
                     cdt_state <= CDT_DONE;
                  else
                     cdt_idx <= cdt_idx + 1;
                     cdt_state <= CDT_R;
                  end if;
               end if;

            when CDT_DONE =>
               cdt_active <= '0';
         end case;
      end if;
   end process;

   -- CD-RAM + ADPCM RAM bridge: pce_top's CD_RAM_RD/CD_RAM_WR (raw, level-held) and
   -- ADPCM_RAM_REQ (level-held for one DRAM_CLKEN slot, ~420ns) both become SDRAM
   -- accesses via the same shared port C, one at a time, CD-RAM winning ties. Real,
   -- unmodified from pcetang_primer25k_cd.vhd's own cdr_owner arbiter -- see that
   -- file's identical comment for the full pend/ready-drop timing rationale.
   -- PCE PORT (2026-09-17): ADPCM RAM new-request detect. ROOT CAUSE of missing ADPCM
   -- voices (e.g. Dracula X Rondo's speech), with the cd.vhd DRAM_REQ_SEEN change.
   --
   -- This used to launch an SDRAM access only on the FIRST cycle of a DRAM slot
   -- (`if slot changed then adpcm_new := req`). But the pend flags behind ADPCM_RAM_REQ
   -- rise at arbitrary times -- PLAY_READ_PEND on the MSM5205 sample clock, DMA_WRITE_PEND
   -- on SCSI REQ, CPU $180A accesses -- not on slot boundaries. A request that rose
   -- mid-slot launched nothing, READY was still '1' from the previous access, cd.vhd's
   -- wait gate passed, and it consumed a stale nibble or counted a write that never
   -- reached SDRAM. Same bug class as the CD-RAM stale byte: see MEMORY_BRIDGE_CONTRACT.md,
   -- which wrongly listed this bridge as correct by construction.
   --
   -- Measured in sim/cd/tb_adpcm_bridge.vhd (real cd.vhd, this logic, an SDRAM model, no
   -- CD-RAM contention = best case), 4000 nibbles each way:
   --   before:                     16.7% of writes never reached SDRAM, 23.7% of reads stale
   --   this + cd.vhd DRAM_REQ_SEEN: 0 lost, 0 stale (a negative control with the old cd.vhd
   --                                confirms the checker catches the remaining race)
   --
   -- Now: launch on a slot change OR on REQ rising within the slot -- the "edge OR address
   -- change" rule, with the slot change standing in for the address change, so a two-nibble
   -- write still gets its second launch. READY drops combinationally the instant a new
   -- request appears, so the gate can never pass on a stale '1' from the previous access.
   adpcm_new_comb <= '1' when adpcm_ram_req_i = '1'
                               and (adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r
                                    or adpcm_bridge_req_r = '0')
                     else '0';
   adpcm_ram_ready_comb <= adpcm_ram_ready_i and not adpcm_new_comb;

   process (clk_pce)
      variable cd_new, adpcm_new : std_logic;
   begin
      if rising_edge(clk_pce) then
         cd_done <= '0';
         cdram_rd_r      <= cdr_rd_mux;
         cdram_wr_r      <= cdr_wr_mux;
         adpcm_slot_cnt_r <= adpcm_ram_slot_cnt_i;
         adpcm_bridge_req_r <= adpcm_ram_req_i;

         -- PCE PORT (2026-09-15): the address-change term lives in cd_new_comb now; see
         -- its declaration. Was `(cdr_rd_mux and not cdram_rd_r) or (cdr_wr_mux and not
         -- cdram_wr_r)` -- a rising edge only, which silently dropped every back-to-back
         -- CD-RAM access and handed the CPU byte N-1.
         cd_new := cd_new_comb;
         adpcm_new := adpcm_new_comb;   -- see adpcm_new_comb's comment

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
                  if cdr_a_mux(21) = '0' then
                     cdr_addr <= std_logic_vector(AC_SDRAM_BASE +
                                 resize(unsigned(cdr_a_mux(20 downto 0)), 25));
                  else
                     -- cdr_a_mux, NOT cd_ram_a: the AC branch above already uses the
                     -- mux, and taking the raw core signal here meant the CD-RAM
                     -- self-test (cdt_active='1', driving cdt_a through the mux) sent
                     -- every one of its 262144 accesses to ONE constant address -- the
                     -- halted core's idle cd_ram_a. That is why its "256 KiB, 0 bad"
                     -- result cleared a CD-RAM that was in fact completely broken.
                     -- Identical when cdt_active='0', so the shipped path is unchanged.
                     cdr_addr <= std_logic_vector(CDRAM_SDRAM_BASE +
                                 resize(unsigned(cdr_a_mux(17 downto 0)), 25));
                  end if;
                  -- POLARITY FIX (2026-09-13). This read WRONG for the whole life of
                  -- the CD path and is why no CD game ever booted.
                  --
                  -- sdram.sv uses this signal DIRECTLY as the write enable --
                  -- `we <= RAM_C_RD_n;` (sdram.sv:572, and :510 for port A) -- and
                  -- `last_valid[2] <= ~RAM_C_RD_n;` invalidates the line cache on a
                  -- write. So RAM_C_RD_n = '1' means WRITE, '0' means READ, exactly as
                  -- the old comment here said. The `not` then inverted every access:
                  --   CPU write -> rd_n='0' -> we=0 -> an SDRAM READ, data never stored
                  --   CPU read  -> rd_n='1' -> we=1 -> an SDRAM WRITE of cd_ram_do,
                  --                and sdram.sv:650-652 returns `RAM_C_DO <= data[7:0]`
                  --                on a write, i.e. the byte just written -- which for a
                  --                read is the CPU's idle write-data bus, 0.
                  -- Measured on hardware (trace tags 0xC4-0xC7 vs 0xC0-0xC3): the CPU's
                  -- writes carry the correct program bytes, every readback is 0x00, and
                  -- the arbiter reports 0 timeouts. 0x00 is BRK, so the CPU vectored
                  -- straight into the syscard's error handler -- the black screen.
                  --
                  -- The correct idiom is vram0_cache.vhd:808's `ram_a_rd_n <=
                  -- seq_is_write;` -- assign the write flag, do not invert it.
                  --
                  -- Nano 20K is unaffected: it routes CD-RAM through port B's explicit
                  -- RAM_B_WE instead of this arbiter.
                  cdr_rd_n <= cdr_wr_mux;   -- '0' read, '1' write (mux, see cdr_addr)
                  cdr_di   <= cdr_do_mux;
                  cdr_req  <= '1';
                  cdr_owner <= OWNER_CDRAM;
                  cd_pend  <= '0';
                  -- Consume the address this access is being launched for, so the
                  -- address-change term in cd_new_comb falls until the CPU moves on.
                  cdr_a_last <= cdr_a_mux;
                  cdr_settle_cnt <= (others => '0');
                  cdr_seen_wait  <= '0';
                  cdr_wdog       <= (others => '0');
                  cdr_state <= CDR_SETTLE;
               elsif adpcm_pend = '1' or adpcm_new = '1' then
                  cdr_addr <= std_logic_vector(ADPCM_SDRAM_BASE +
                              resize(unsigned(adpcm_ram_a_i), 25));
                  -- Same inversion as the CD-RAM branch above -- see that comment.
                  cdr_rd_n <= adpcm_ram_we_i;
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
                     cd_done      <= '1';
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
                     cd_done      <= '1';
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

   -- CD-RAM read snoop capture (see cdsnoop_buf's declaration comment). Gated on
   -- sum_cmd_cnt >= 8 so it samples the program the boot actually loaded, not the
   -- syscard's own earlier scratch traffic. cd_ram_rdy_i's rising edge is when the
   -- arbiter has published cd_ram_di_i for the access that just completed; cd_ram_a is
   -- level-held by pce_top for the whole access, so sampling it here is the same address.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         cd_rdy_r  <= cd_ram_rdy_i;
         cdsn_rd_r <= cd_ram_rd;
         cdsn_wr_r <= cd_ram_wr;

         core_rst_r <= core_resetn;
         if core_resetn = '0' and core_rst_r = '1' and core_rst_cnt /= "111111" then
            core_rst_cnt <= core_rst_cnt + 1;
         end if;
         if trap_fired = '1' then trap_sticky <= '1'; end if;
         if bank_bad   = '1' then bank_sticky <= '1'; end if;

         -- NOT cleared on core_resetn. The syscard boot is retried (manually or by its
         -- own error path) and each retry pulses the core reset, so clearing here wiped
         -- the capture before it could ever be emitted -- which is exactly what the
         -- 2026-09-13 post-fix run showed: every 0xC frame zero, proving nothing.
         -- These are first-capture-wins and hold their value until the FPGA is reloaded.
         if core_resetn = '0' and cdsnoop_cnt = 0 and cdsnoop_wcnt = 0 then
            cdsn_rd_pend   <= '0';
            cdram_rd_total <= (others => '0');
            cdram_wr_total <= (others => '0');
         else
            -- Access accepted: same edge the arbiter's own cd_new uses (see its
            -- `cd_new := (cdr_rd_mux and not cdram_rd_r) or ...`). cdt_active is false
            -- in this build, so cdr_*_mux is just cd_ram_*.
            if CDRAM_PROBES and cd_ram_rd = '1' and cdsn_rd_r = '0' then
               cdsn_a_lat18 <= cd_ram_a(17 downto 0);
               if cd_ram_a(21 downto 18) = "1000" then
                  cdsn_rd_pend <= '1';
               else
                  cdsn_rd_pend <= '0';
               end if;
               if cd_ram_a(21 downto 18) = "1000" and cdram_rd_total /= x"FFFF" then
                  cdram_rd_total <= cdram_rd_total + 1;
               end if;
            end if;

            -- Write side: data is valid at request time, no completion to wait for.
            if CDRAM_PROBES and cd_ram_wr = '1' and cdsn_wr_r = '0'
               and cd_ram_a(21 downto 18) = "1000" then
               if cdram_wr_total /= x"FFFF" then
                  cdram_wr_total <= cdram_wr_total + 1;
               end if;
               -- FREE-RUNNING, and the FULL address (2026-09-14). This used to keep the
               -- first 16 writes with only cd_ram_a(7 downto 0) -- eight bits, so the
               -- write could not be located at all -- and it was never emitted on any
               -- tag, so 16 captured writes were discarded every single run.
               --
               -- Same 32-bit entry format as the read buffer ("000000" & addr & data) so
               -- the two can be diffed directly. Free-running keeps the LAST 8 writes,
               -- which is what matters: the reads that come back as 0x00 happen at the
               -- END of the load, and a first-16 window only ever showed the beginning.
               cdsnoop_wbuf <= cdsnoop_wbuf(223 downto 0)
                               & "000000" & cd_ram_a(17 downto 0) & cd_ram_do;
               if cdsnoop_wcnt < 16 then
                  cdsnoop_wcnt <= cdsnoop_wcnt + 1;
               end if;
               -- Extent of everything the loader wrote. THE discriminator: the CPU reads
               -- 0x00 at 0x1372x after 61441 writes landed. If that address is inside
               -- [wr_lo, wr_hi] the data was written and CD-RAM lost it under real load
               -- (which the core-halted sweep structurally cannot detect); if it is
               -- outside, nothing ever wrote there and the fault is the CPU executing
               -- somewhere it was never loaded -- a completely different bug.
               -- PAGE WATCH on 0x137xx. [wr_lo,wr_hi] turned out NOT to settle the
               -- question it was built for: the span is 0x12000-0x33FFF (139264 bytes)
               -- but only 61441 writes happened, so it is less than half covered and
               -- "inside the span" does not mean "was written". This counts writes to
               -- the ONE page the CPU actually reads 0x00 from -- 0x13720..0x13734,
               -- identical on two consecutive runs -- which does settle it:
               --   count = 0            -> nothing ever wrote there; the CPU is
               --                           executing from a region never loaded, and
               --                           memory is innocent (mapping / bad jump).
               --   count > 0, data /= 0 -> it WAS written and reads back 0x00; the
               --                           fault is between the CPU and the chip, i.e.
               --                           the cdr_owner arbiter (sdram.sv itself is
               --                           already cleared by sim/sdram).
               --   count > 0, data  = 0 -> it was written with zeros; the load put
               --                           nothing there and the bug is upstream.
               if cd_ram_a(17 downto 8) = "0100110111" then     -- 0x137xx
                  if wr137_cnt /= x"FFFF" then
                     wr137_cnt <= wr137_cnt + 1;
                  end if;
                  wr137_last_a <= cd_ram_a(7 downto 0);
                  wr137_last_d <= cd_ram_do;
                  if cd_ram_a(7 downto 0) = x"20" then           -- exactly 0x13720
                     wr137_hit20 <= '1';
                     if wr137_hit20 = '0' then
                        wr137_first20 <= cd_ram_do;
                     end if;
                  end if;
               end if;
               if unsigned(cd_ram_a(17 downto 0)) < cdram_wr_lo then
                  cdram_wr_lo <= unsigned(cd_ram_a(17 downto 0));
               end if;
               if unsigned(cd_ram_a(17 downto 0)) > cdram_wr_hi then
                  cdram_wr_hi <= unsigned(cd_ram_a(17 downto 0));
               end if;
            end if;

            -- Completion: pair the latched address with the data just published.
            if CDRAM_PROBES and cd_ram_rdy_i = '1' and cd_rdy_r = '0' then
               if cdsn_rd_pend = '1' and sum_cmd_cnt >= 8 and cdsnoop_cnt < 16 then
                  cdsnoop_buf <= cdsnoop_buf(479 downto 0)
                                 & "000000" & cdsn_a_lat18 & cd_ram_di_i;
                  cdsnoop_cnt <= cdsnoop_cnt + 1;
               end if;
               cdsn_rd_pend <= '0';
            end if;
         end if;
      end if;
   end process;

   -- Real SCSI target, wired to the real MCU-side mount/TOC/sector protocol via
   -- iosys_bl616.v (see pcetang_cd_scsi_plan.md for the full wire-protocol design).
   -- PCE PORT (2026-09-09): HuCard-only build. CD, Arcade Card (which needs CD) and
   -- SuperGrafx are all deferred until a plain HuCard boots and runs, so everything they
   -- pull in is removed rather than merely disabled at runtime -- disabled logic still
   -- costs area and, more importantly, still loads the timing paths that matter. The
   -- previous build's overall worst setup path was cd_bridge_inst -> read_lba_23_s4 at
   -- 0.050 ns slack. Flip HUCARD_ONLY to false (and NO_CD => 0, AC_BUILD => 1 at the
   -- pce_top instance) to get CD back.
   gen_cd_bridge : if not HUCARD_ONLY generate
   -- see cd_quiet_ct's declaration comment
   cdreg_data <= dbg_cpu_do when dbg_cpu_wr_n = '0' else dbg_cpu_di;

   cd_link_busy <= '1' when cd_quiet_ct /= 0 else '0';
   trace_ready  <= '1' when trace_warmup >= 42860000 else '0';

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
      SECTOR_DATA_LAST  => cd_sector_data_last_i,
      DBG_STATE         => cd_dbg_state_i,
      DATAIN_SECTORS    => cd_datain_sectors_i,
      DBG_DEND          => scsi_dend_i,
      FIFO_SPACE        => scsi_fifo_space_i,
      CDDA_SPACE        => cdda_space_i,
      BUS_RST           => cd_bus_rst_i
   );
   end generate;

   gen_no_cd_bridge : if HUCARD_ONLY generate
      -- The ten signals cd_bridge drives, held inactive. pce_top is built NO_CD => 1 so
      -- it ignores them anyway; these exist so the board still elaborates with no bridge.
      cd_stat_i            <= (others => '0');
      cd_msg_i             <= (others => '0');
      cd_stat_get_i        <= '0';
      cd_data_i            <= (others => '0');
      cd_data_wr_i         <= '0';
      cd_sector_req_i      <= '0';
      cd_sector_lba_i      <= (others => '0');
      cd_audio_wr_i        <= '0';
      cd_dm_i              <= '0';
      cd_sector_is_audio_i <= '0';
      cd_datain_sectors_i  <= (others => '0');
      scsi_dend_i          <= (others => '0');
   end generate;

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

   -- mem_init_file => "pce_bram": preload the "HUBM" backup-RAM header, so the CD unit's
   -- BRAM looks FORMATTED at power-on the way a real battery-backed one does, instead of
   -- presenting every game with an unformatted 2KB of zeros on every single boot.
   -- See init_spram in bram_gowin.vhd for the signature and where it comes from.
   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8, mem_init_file => "pce_bram")
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
   -- AC_BUILD => 0 (2026-09-09): omit the Arcade Card. Post-PnR timing showed seven of
   -- the eight worst setup paths in this design running from the CPU microcode through
   -- core/CPU/CORE/MPR_SEL -- the MPR bank-register read mux, the exact signal the
   -- black-screen fault is localised to -- into core/AC/port[N].base_*, at 0.224 ns
   -- slack on a 23.33 ns period. See pce_top.vhd's AC_BUILD comment.
   -- CDDA_DEPTH_LOG2 => 12 (4096 entries, 93 ms) restores the donor's CD-DA FIFO depth,
   -- halved in 2026-08 when this board's BSRAM was the binding constraint. It no longer
   -- is (74/118), and the depth is what lets cd_bridge keep ~6 audio sectors in flight,
   -- which is what hides libchdr's ~62 ms hunk decode. Measured cost of the restore was
   -- +8 blocks. Primer 25K and Nano 20K keep the 11 default -- Nano 20K sits at 39/46
   -- and has no room. See docs/CD_AUDIO_TIMING.md.
   -- DBG_PROBES => 0 (2026-09-16). These are the CPU-internal probes (MPR_DBG/TAM_DBG/
   -- TLOAD_DBG/SEL_DBG) built for the T-corruption hunt, which is CLOSED -- the fault was
   -- the CD-RAM bridge handing the CPU byte N-1, not the microcode. HUC6280_CPU.vhd's own
   -- header warns they "hang heavy fanout off the microcode outputs" and cost real timing,
   -- and they just did: a build that differed only by one constant came back with 140
   -- setup violations on clk_pce, TNS -184.125 ns, worst -2.301 ns, on a path running
   -- MCODE/MI.ALUCtrl -> dbg_sel_8_* -> ADDR_BUS -> brm_a -> PSG -> VCE -> CD. That path
   -- has been marginal all along and the earlier 0/0 results were partly placement luck.
   -- Turning them off buys back real margin. The trace tags 0xE0-0xE8 that read them now
   -- report zeros; the CD tags this project actually uses (cdprog, 0xA5/0xA6/0xB0) come
   -- from the CD path and are unaffected.
   generic map (LITE => 1, EXT_VRAM0 => 0, NO_CD => 0, AC_BUILD => 0, DBG_PROBES => 0,
                CDDA_DEPTH_LOG2 => 12)
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
      DBG_CPU_A => dbg_cpu_a, DBG_VDC_WR => dbg_vdc_wr,
      DBG_VCE_WR => dbg_vce_wr, DBG_VCE_DO => dbg_vce_do,
      DBG_CPU_WR_N => dbg_cpu_wr_n, DBG_CPU_RD_N => dbg_cpu_rd_n,
      DBG_CPU_DO => dbg_cpu_do, DBG_CPU_DI => dbg_cpu_di, DBG_VDC_RDY => dbg_vdc_rdy,
      DBG_CPU_CE => dbg_cpu_ce, DBG_IRQ1_N => dbg_irq1_n, DBG_IRQ2_N => dbg_irq2_n,
      RAMTEST_EN => wram_en, RAMTEST_A => std_logic_vector(wram_a),
      RAMTEST_D => wram_d, RAMTEST_WE => wram_we, RAMTEST_Q => wram_q,
      DBG_MPR => dbg_mpr,
      DBG_TAM => dbg_tam,
      DBG_TLOAD => dbg_tload,
      DBG_TLOAD_STB => dbg_tload_stb,
      DBG_SEL => dbg_sel,
      DBG_WAIT_EVER => dbg_wait_ever,

      ROM_RD    => rom_rd_i,
      ROM_RDY   => rom_rdy_comb,
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
      -- PCE PORT (2026-09-15): the COMBINATIONAL ready, not the registered cd_ram_rdy_i.
      -- Same reason the ROM bridge feeds rom_rdy_comb and not rom_rdy_i: the registered
      -- form is one clk_pce late, and in that window the CPU can sample the previous
      -- byte. Every other consumer of cd_ram_rdy_i (the read snoop, the self-test) still
      -- wants the registered edge and is unchanged.
      CD_RAM_RDY => cd_ram_rdy_comb,

      ADPCM_RAM_A => adpcm_ram_a_i, ADPCM_RAM_DO => adpcm_ram_do_i,
      ADPCM_RAM_WE => adpcm_ram_we_i, ADPCM_RAM_REQ => adpcm_ram_req_i,
      ADPCM_RAM_SLOT_CNT => adpcm_ram_slot_cnt_i,
      ADPCM_RAM_DI => adpcm_ram_di_i, ADPCM_RAM_READY => adpcm_ram_ready_comb,

      -- PCE PORT (2026-08-29): '0'->'1' -- real, non-aliasing 2MB SDRAM window now
      -- exists (AC_SDRAM_BASE, see that constant's own comment) -- see this file's
      -- header for the updated real gw_sh result.
      -- PCE PORT (2026-09-09): AC_EN is the RUNTIME enable and does not remove the
      -- Arcade Card's load on the CPU physical address bus. AC_BUILD => 0 (below, in
      -- the generic map) omits the instance outright. TRADEOFF: this bitstream can no
      -- longer run Arcade Card CD titles. Set AC_BUILD => 1 to restore them.
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
      CD_REGION => '0', CD_RESET => cd_bus_rst_i,
      CD_DATA => cd_data_i, CD_DATA_WR => cd_data_wr_i, CD_AUDIO_WR => cd_audio_wr_i,
      CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end_i,
      CD_DBG_DATAIN_CNT => scsi_datain_cnt_i,
      CD_DBG_FIRST8     => scsi_first8_i,
      CD_DBG_SP         => scsi_sp_i,
      CD_DBG_ADPCM      => adpcm_dbg_i,
      CD_DBG_COMM_POS   => scsi_comm_pos_i,
      CD_DBG_COMM0      => scsi_comm0_i,
      CD_DBG_COMM1      => scsi_comm1_i,
      CD_DBG_SEL_CNT    => scsi_sel_cnt_i,
      CD_DBG_FIFO_SPACE => scsi_fifo_space_i,
      CD_DBG_CDDA_SPACE => cdda_space_i,
      CD_DBG_FIFO_DROPS => scsi_fifo_drops_i,
      CD_DBG_GDI        => scsi_gdi_i,
      CD_DATAIN_SECTORS => cd_datain_sectors_i,
      DBG_VDC_SCREEN    => dbg_vdc_screen_i,
      DBG_VCE_CR        => dbg_vce_cr_i,
      CD_DBG_RD_TOTAL   => scsi_rd_total_i,
      CD_DBG_UNDERRUNS  => scsi_underruns_i,
      CD_DM => cd_dm_i,

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
   -- PCE PORT (2026-09-09): REWRITTEN. The first-cut mapping above this comment's
   -- predecessor was wrong in two independent ways, both of which had to be fixed before
   -- a pad could do anything:
   --
   -- 1. POLARITY. A real PCE pad is ACTIVE LOW -- pce_top's own default is 16#0FFF#,
   --    i.e. "nothing pressed" is all ones. iosys_bl616's joy1 is ACTIVE HIGH. The old
   --    mapping passed it straight through, so with no buttons pressed (joy1 = 0) the
   --    core read all four lines as held, permanently, on both nibbles. Hence "the pad
   --    does nothing": the game saw every direction and every button stuck down.
   --
   -- 2. D-PAD BITS. iosys_bl616.v:44 documents joy1[11:0] as
   --        (R L X A RT LT DN UP START SELECT Y B)
   --    so UP/DN/LT/RT are bits 4/5/6/7 and bits 10/11 are the L/R SHOULDER buttons.
   --    The old mapping read 10 and 11 for left/right, i.e. the shoulders, and had the
   --    remaining directions in the wrong order too.
   --
   -- Real PCE protocol: JOY_OUT(0) = SEL selects the nibble.
   --    SEL = 1 -> D0 UP,  D1 RIGHT, D2 DOWN,   D3 LEFT
   --    SEL = 0 -> D0 I,   D1 II,    D2 SELECT, D3 RUN
   --
   -- I and II each accept either of two pad buttons on purpose. This is a PS2-style pad
   -- with no canonical PCE layout, and accepting A-or-B for I and X-or-Y for II means it
   -- works whichever cluster the user reaches for, at the cost of nothing.
   joy_in <= not (joy_active(6) & joy_active(5) & joy_active(7) & joy_active(4))
                when joy_out(0) = '1'
             else not (joy_active(3)
                       & joy_active(2)
                       & (joy_active(9) or joy_active(1))    -- II  <- X or Y
                       & (joy_active(8) or joy_active(0)));  -- I   <- A or B

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
   --   tags 0xA0-0xA3 : TOC as cd_bridge received it (tracks 1/2, lead-out, counts).
   --   tags 0xA4-0xA6 : CPU-side SCSI view, added 2026-09-11 to separate "we fed the
   --                    wrong bytes" from "the CPU never took them" -- 0xA4 the first
   --                    eight bytes the CPU ACKed after a READ(6), 0xA5 the DATA-IN
   --                    byte count plus both FSM states, 0xA6 the first eight command
   --                    opcodes for a direct diff against a beetle-pce-fast trace.
   --   tags 0xA8-0xA9 : first two READ(6) CDBs, one-shot.
   --   tags 0xAA-0xAB : GETDIRINFO mode/track bytes of the first eight calls.
   --   tags 0xA7/0xAC : the GETDIRINFO reply bytes as the CPU took them off the bus.
   --   tag  0xD2      : CPU_CE / VDC writes / source frames / trap+IRQ flags.
   --   tag  0xD5      : IRQ2/IRQ1 assertions + ADPCM play/end counts.
   --   tag  0xD6      : VCE palette writes / nonzero / last byte + ADPCM.
   --   tags 0xD7-0xD9 : first 12 CD-register accesses after the last SCSI command.
   --   tag  0xAD      : sense/status summary.   0xAE : rolling CD summary.
   --   tag  0xAF      : sector-transfer counters.
   --   tags 0xB0-0xBF : general CDB trace (CDCMD_TRACE only).
   --   tags 0xC0-0xCF : ROM raw dumps -- NOT free.
   --   tags 0xE0+     : trap window.
   --   tags 0x80+     : runtime heartbeat, now carrying DBG_VDC_WR's cumulative count
   --                    and the VBLANK count. A nonzero, climbing VDC write count means
   --                    the CPU DID reach the code that programs the VDC and the fault
   --                    is downstream (video path); a flat zero means it did not, and
   --                    the fault is upstream. That single number splits the remaining
   --                    search space in half, which the previous payload could not.
   -- Source frames: video_vbl's falling edge is the first active line (huc6260.vhd
   -- drives VBL low at V_CNT = TOP_BL_LINES), i.e. exactly the event the servo locks to.
   -- Counting it here proves the reference edge exists and fires once per frame -- if
   -- this stays flat, the servo has no input and every conclusion about it is moot.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         vid_src_vbl_r <= video_vbl;
         if vid_src_vbl_r = '1' and video_vbl = '0' then
            vid_src_frames <= vid_src_frames + 1;
         end if;

         vid_oft_meta <= vid_out_frame_tog;
         vid_oft_sync <= vid_oft_meta;
         vid_oft_prev <= vid_oft_sync;
         if vid_oft_sync /= vid_oft_prev then
            vid_out_frames <= vid_out_frames + 1;
         end if;
      end if;
   end process;

   -- TOC capture lives in its OWN process, deliberately gated on NOTHING. It was inside
   -- the trace process's `if vfy_emit_d ... elsif core_resetn = '0' ... else` chain, so it
   -- only counted while the core was out of reset -- and the MCU sends the whole TOC
   -- within a millisecond of releasing the core, long before the first heartbeat. A
   -- counter that can be masked by the state you are measuring around reports zero and
   -- looks exactly like "the wire is dead".
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         sd_valid_r <= cd_sector_data_valid_i;
         if cd_sector_data_valid_i = '1' and sd_valid_r = '0' then
            sd_valid_cnt <= sd_valid_cnt + 1;
         end if;
         sect_req_r <= cd_sector_req_i;
         if cd_sector_req_i = '1' and sect_req_r = '0' then
            sect_req_cnt <= sect_req_cnt + 1;
         end if;

         toc_wr_r <= toc_wr_i;
         if toc_wr_i = '1' and toc_wr_r = '0' then
            toc_wr_count <= toc_wr_count + 1;
            -- Sticky evidence for the TOC-vs-core-reset race, reported on 0xC9's
            -- [15:8]. A TOC_WR that lands while core_resetn is low used to be
            -- dropped entirely (cd_bridge's TOC_CAPTURE had an async RST_N; it no
            -- longer does). This counter says whether the window is ever actually
            -- hit on a normal build, so "the race exists" stops being an inference:
            -- 0 here means the upload always won and the race is not a live cause.
            if core_resetn = '0' and toc_wr_inrst /= x"FF" then
               toc_wr_inrst <= toc_wr_inrst + 1;
            end if;
            if unsigned(toc_track_i) > unsigned(toc_maxtrack)
               and unsigned(toc_track_i) /= 100 then
               toc_maxtrack <= toc_track_i;
            end if;
            case toc_track_i is
               when x"01" => toc_t1_lba <= toc_lba_i; toc_t1_ctl <= toc_control_i;
               when x"02" => toc_t2_lba <= toc_lba_i; toc_t2_ctl <= toc_control_i;
               when x"64" => toc_lo_lba <= toc_lba_i;   -- 100 = lead-out
               when others => null;
            end case;
         end if;
      end if;
   end process;

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
            -- Rate-limit timer for CD command traces. Decremented HERE, in the same
            -- process that reloads it below -- driving a signal from two processes is
            -- what the previous build failed on (EX2000, multiple drivers).
            if cdcmd_gap /= 0 then
               cdcmd_gap <= cdcmd_gap - 1;
            end if;

            -- Edge-detect the core's own command strobe and latch the CDB.
            cd_comm_send_r <= cd_comm_send_i;
            if cd_comm_send_i = '1' and cd_comm_send_r = '0'
               and cd_comm_i(7 downto 0) = x"08" then
               rdcmd_data <= cd_comm_i(63 downto 0);
               rdcmd_pend <= '1';
            end if;
            -- status handed to the CPU, and how many were CHECK CONDITION (0x02)
            stat_get_r <= cd_stat_get_i;
            if cd_stat_get_i = '1' and stat_get_r = '0' then
               last_stat <= cd_stat_i;
               if cd_stat_i = x"02" then
                  chk_cond_cnt <= chk_cond_cnt + 1;
               end if;
            end if;
            -- REQUEST SENSE (0x03): byte 2 is the sense key, byte 12 the ASC
            if cd_comm_send_i = '1' and cd_comm_send_r = '0'
               and cd_comm_i(7 downto 0) = x"03" then
               sense_arm <= '1';
               sense_idx <= (others => '0');
            end if;
            if sense_arm = '1' and cd_data_wr_i = '1' and cd_data_wr_r = '0' then
               if sense_idx = 2  then sense_key <= cd_data_i; end if;
               if sense_idx = 12 then sense_asc <= cd_data_i; sense_arm <= '0'; end if;
               sense_idx <= sense_idx + 1;
            end if;

            if cd_comm_send_i = '1' and cd_comm_send_r = '0'
               and cd_comm_i(7 downto 0) = x"de" then
               dirinfo_arm  <= '1';
               dirinfo_cnt  <= (others => '0');
               dirinfo_data <= (others => '0');
            end if;
            cd_data_wr_r <= cd_data_wr_i;
            if cd_data_wr_i = '1' and cd_data_wr_r = '0' then
               cd_wr_cnt <= cd_wr_cnt + 1;
            end if;
            if dirinfo_arm = '1' and cd_data_wr_i = '1' and cd_data_wr_r = '0' then
               dirinfo_data <= dirinfo_data(55 downto 0) & cd_data_i;
               dirinfo_cnt  <= dirinfo_cnt + 1;
               if dirinfo_cnt = 7 then
                  dirinfo_arm  <= '0';
                  dirinfo_pend <= '1';
               end if;
            end if;

            if cd_comm_send_i = '1' and cd_comm_send_r = '0' then
               cdcmd_data  <= cd_comm_i(63 downto 0);
               cdcmd_pend  <= '1';
               sum_cmd_cnt <= sum_cmd_cnt + 1;
               cd_rot_left <= x"3";   -- re-arm the CD tag budget on real CD activity
               if op_idx < 8 then
                  op_first8(63 - to_integer(op_idx)*8 downto 56 - to_integer(op_idx)*8)
                     <= cd_comm_i(7 downto 0);
                  op_idx <= op_idx + 1;
               end if;
               if cd_comm_i(7 downto 0) = x"de" and gdi_idx < 8 then
                  gdi_modes(63 - to_integer(gdi_idx)*8 downto 56 - to_integer(gdi_idx)*8)
                     <= cd_comm_i(15 downto 8);
                  gdi_tracks(63 - to_integer(gdi_idx)*8 downto 56 - to_integer(gdi_idx)*8)
                     <= cd_comm_i(23 downto 16);
                  gdi_idx <= gdi_idx + 1;
               end if;
               sum_last_op <= cd_comm_i(7 downto 0);
               if cd_comm_i(7 downto 0) = x"08" then
                  sum_read_cnt <= sum_read_cnt + 1;
                  -- same slicing cd_bridge's own READ(6) decode uses
                  sum_read_lba <= "000" & cd_comm_i(12 downto 8)
                                  & cd_comm_i(23 downto 16) & cd_comm_i(31 downto 24);
               end if;
            end if;
            -- First two bytes cd_bridge writes back after any GETDIRINFO, and how many it
            -- wrote in total -- 0 would mean the reply never reaches the syscard at all.
            if dirinfo_arm = '1' and cd_data_wr_i = '1' and cd_data_wr_r = '0' then
               if sum_dir_cnt = 0 then sum_dir_b0 <= cd_data_i;
               elsif sum_dir_cnt = 1 then sum_dir_b1 <= cd_data_i; end if;
               sum_dir_cnt <= sum_dir_cnt + 1;
            end if;
            -- startup hold-off (see trace_warmup's declaration comment)
            if trace_warmup < 42860000 then
               trace_warmup <= trace_warmup + 1;
            end if;

            -- trace hold-off timer (see cd_quiet_ct's declaration comment)
            if cd_sector_req_i = '1' or cd_sector_data_valid_i = '1' then
               cd_quiet_ct <= to_unsigned(857140, 20);   -- ~20ms at 42.86MHz
            elsif cd_quiet_ct /= 0 then
               cd_quiet_ct <= cd_quiet_ct - 1;
            end if;

            dbg_hb_cnt <= dbg_hb_cnt + 1;
            -- Re-arm the 0xC9 one-shot on every ROM load. The self-test sweep itself
            -- runs once per power-on, but toc_wr_inrst is per-load evidence, and a
            -- single emit at power-on would only ever describe the first disc.
            if rom_loading(0) = '1' and rom_loading_r = '0' then
               cdv_sent <= '0';
            end if;
            -- Phase-tag slot selector: advanced here, unconditionally, so it keeps
            -- moving regardless of which branch of the emit ladder wins this heartbeat.
            if dbg_hb_cnt = 0 then
               ph_tag <= ph_tag + 1;
            end if;
            -- Video geometry: remember the OR of every BAT-size and VCE-CR value seen,
            -- plus how many times each changed. A mode switch that the display does not
            -- follow shows up as a change count > 0 with a geometry that never moved.
            vdc_screen_seen <= vdc_screen_seen or ("00000" & dbg_vdc_screen_i);
            vce_cr_seen     <= vce_cr_seen or dbg_vce_cr_i;
            if dbg_vdc_screen_i /= vdc_screen_seen(2 downto 0)
               and vdc_screen_chg /= x"FFFF" then
               vdc_screen_chg <= vdc_screen_chg + 1;
            end if;
            if dbg_vce_cr_i /= vce_cr_seen and vce_cr_chg /= x"FFFF" then
               vce_cr_chg <= vce_cr_chg + 1;
            end if;
            -- ~4.2M clk_pce cycles at 42.86MHz = ~100ms between snapshots
            -- 32, not 64: two checksum passes now emit 32 lines before the core is even
            -- released, and the heartbeat comes LAST -- so if the log were ever
            -- truncated it is the VDC count, the more valuable half, that would be lost.
            -- 32+32 keeps total volume at the 64 lines a previous run survived.
            -- Once the trap has fired, spend the next three heartbeat slots emitting the
            -- frozen window (tags 0xE0-0xE2) before resuming the normal heartbeat.
            -- Highest priority: a SCSI command just arrived. These are rare (a boot
            -- issues a handful) and are the whole point of this run, so they must not
            -- lose the channel to the ~100ms heartbeat.
            -- ALWAYS emit, never gated on toc_wr_count: gating the report on the very
            -- quantity being measured makes "count is zero" and "probe never ran"
            -- indistinguishable, which is exactly what happened on the previous run.
            if trace_ready = '0' or cd_link_busy = '1' then
               -- CD sector traffic in flight: stay off the link entirely. Nothing is
               -- dropped, only deferred -- every tag below re-emits on the next
               -- heartbeat, and the pend latches hold until they get the channel.
               null;
            elsif CDREG_STREAM and cdtq_wr /= cdtq_rd then
               -- 0xDB: ONE CD-register access, in order, as it happened.
               -- [63:48] sequence number | [47:40] 1=write 0=read, then the register's
               -- low 7 bits | [39:32] the byte written, or the byte read back
               -- | [31:16] accesses dropped so far | [15:0] 0.
               --
               -- Not gated on dbg_hb_cnt: this is a stream, and the ~100 ms heartbeat
               -- would let the 64-entry ring overflow between frames. It IS gated on
               -- cd_link_busy above, so it never competes with sector delivery -- the
               -- accesses that matter happen between transfers, not during them (the
               -- in-transfer traffic is $1808, which is filtered out at capture).
               dbg_trace_req  <= '1';
               dbg_trace_tag  <= x"DB";
               dbg_trace_data <= std_logic_vector(cdt_seq)
                                 & cdt_mem(to_integer(cdtq_rd(5 downto 0)))
                                 & std_logic_vector(cdt_drops)
                                 & x"0000";
               cdtq_rd <= cdtq_rd + 1;
               cdt_seq <= cdt_seq + 1;
            elsif cdv_sent = '0'
                  and (not CDRAM_SELFTEST or cdt_state = CDT_DONE) then
               -- 0xC9: CD-RAM SELF-TEST RESULT + TOC/reset race evidence. Emitted FIRST,
               -- once per ROM load, before the core is released -- NOT from the rotating
               -- summary ladder below. Emitted even when CDRAM_SELFTEST is off, because
               -- [15:8] is the measurement that has to survive turning the sweep off;
               -- the cdv_* fields simply read zero in that case.
               --
               -- The previous build put it there, behind twelve full A-rotations, and the
               -- run produced zero 0xC tags: the log simply ended before its turn came
               -- (the last rotation in that log is missing its final tag, which is the
               -- async log_task's queue being lost at power-off). The result is known
               -- before any game runs, so there is no reason to queue it behind anything.
               --
               -- [63:48] KiB verified OK | [47:32] BAD bytes | [31:16] first mismatch as
               -- wrote|read | [15:8] TOC_WR pulses that landed during core reset
               -- | [7:0] port-C watchdog fires.
               --
               -- READ IT ONE WAY ONLY. bad /= 0 is conclusive: the sweep runs with the
               -- core halted, so nothing but the memory path itself can have corrupted it.
               -- bad = 0 is NOT "CD-RAM is correct" -- there is no ADPCM traffic on port C,
               -- no ROM port contention and no refresh pressure with the core halted, and
               -- the pattern (idx(7:0) xor idx(15:8) xor idx(17:16)) gives the same byte
               -- for addresses (lo,hi) and (hi,lo), so a swapped-address-bit fault passes.
               cdv_sent       <= '1';
               dbg_trace_req  <= '1';
               dbg_trace_tag  <= x"C9";
               dbg_trace_data <= std_logic_vector(cdv_ok) & std_logic_vector(cdv_bad)
                                 & cdv_first & std_logic_vector(toc_wr_inrst)
                                 & std_logic_vector(dbg_cdr_timeout_cnt);
            elsif dbg_hb_cnt = 0 and ph_tag(1 downto 0) = "00" then
               -- RE-EMITTED FOREVER, never bounded by a total count. The first version
               -- used `ph_tag < 16`, which advances once per ~100 ms heartbeat and so
               -- spent all sixteen emissions in the first 1.6 SECONDS -- before RUN is
               -- pressed and before any CD activity exists. Every field came back zero
               -- and the run was wasted. These are cumulative counters, so the LAST line
               -- in the log is always the current value.
               --
               -- One heartbeat in four, so the 0xA* rotation below is not starved: this
               -- branch sits ABOVE it in the ladder and an unconditional
               -- `dbg_hb_cnt = 0` here would take the channel every single time.
               -- ph_tag is advanced unconditionally next to the heartbeat counter, not
               -- here -- incrementing it inside a branch gated on its own value would
               -- stop it after one step.
               dbg_trace_req <= '1';
               if ph_tag(3 downto 2) = "11" then
                  -- 0xB3: VIDEO GEOMETRY.
                  -- [63:56] every VDC0 SCREEN (BAT size) value seen, OR-ed
                  --         bit2 = 64 rows (else 32), bits1:0 = 32/64/128 columns
                  -- | [55:48] every VCE CR seen, OR-ed (CR(1:0) = DOTCLOCK 256/336/512)
                  -- | [47:32] SCREEN change count | [31:16] CR change count
                  -- | [15:8] SCREEN now | [7:0] CR now.
                  --
                  -- A picture tiled 2x2 is the BAT wrapping at half the display width AND
                  -- half its height, i.e. a 32x32 BAT (SCREEN="000") on a display set up
                  -- for 64x64. If CR changed but SCREEN never left "000", the game's MWR
                  -- write is not reaching the VDC; if SCREEN did change, the tiling is
                  -- downstream of it.
                  dbg_trace_tag  <= x"B3";
                  dbg_trace_data <= vdc_screen_seen & vce_cr_seen
                                    & std_logic_vector(vdc_screen_chg)
                                    & std_logic_vector(vce_cr_chg)
                                    & "00000" & dbg_vdc_screen_i & dbg_vce_cr_i;
               elsif ph_tag(3 downto 2) = "01" then
                  -- 0xB2: CD_DATA_END accounting from cd_bridge.
                  -- [63:48] pulses CONSUMED by a *_WAIT_END state
                  -- | [47:32] pulses LOST (fired while nothing was listening)
                  -- | [31:21] 0 | [20:16] cd_bridge FSM state now | [15:0] 0.
                  --
                  -- CD_DATA_END is a one-cycle pulse with no handshake, and SCSI.vhd
                  -- fires it at ANY sector boundary where the FIFO is empty -- including
                  -- non-final boundaries mid-command, where cd_bridge is still fetching
                  -- and none of the three *_WAIT_END states is active. Those are the
                  -- LOST count and are expected to be nonzero and harmless. What matters
                  -- is the END STATE: if the board is stalled and cd_bridge's state is
                  -- SCSI_READ_WAIT_END (01000) with CONSUMED one short of the number of
                  -- commands, the final pulse was lost and that IS the bug.
                  dbg_trace_tag  <= x"B2";
                  dbg_trace_data <= scsi_dend_i & "00000000000" & cd_dbg_state_i & x"0000";
               elsif ph_tag(3 downto 2) = "10" then
                  -- 0xB0: the last 8 DISTINCT $1800 (SCSI phase) values, oldest first.
                  -- Read against the golden end-of-command walk:
                  --   c8/88 DATA IN (with/without REQ) -> d8 STATUS+REQ -> f8 MSG IN+REQ
                  --   -> 00 BUS FREE -> next command.
                  -- Ending ...c8 88 c8 88 with no d8 means the status walk never starts.
                  dbg_trace_tag  <= x"B0";
                  dbg_trace_data <= ph_ring;
               else
                  -- 0xB1: [63:48] phase changes seen | [47:32] times STATUS+REQ (0xd8)
                  -- | [31:16] times MESSAGE IN+REQ (0xf8) | [15:0] times BUS FREE (0x00).
                  -- d8 = 0 with a nonzero change count is the whole answer.
                  dbg_trace_tag  <= x"B1";
                  dbg_trace_data <= std_logic_vector(ph_chg) & std_logic_vector(ph_d8)
                                    & std_logic_vector(ph_f8) & std_logic_vector(ph_bf);
               end if;
            elsif rdcmd_pend = '1' and rdcmd_cnt < 2 then
               rdcmd_pend    <= '0';
               rdcmd_cnt     <= rdcmd_cnt + 1;
               dbg_trace_req <= '1';
               dbg_trace_tag <= "101010" & std_logic_vector(rdcmd_cnt);  -- 0xA8 / 0xA9
               dbg_trace_data <= rdcmd_data;
            elsif dirinfo_pend = '1' and dirinfo_sent < 2 then
               dirinfo_pend  <= '0';
               dirinfo_sent  <= dirinfo_sent + 1;
               dbg_trace_req <= '1';
               -- 0xD3 / 0xD4. Was "101011" & sent, i.e. 0xAC/0xAD, which shadowed two
               -- live CD tags. This branch is in practice dead -- it only fires once
               -- dirinfo_cnt reaches 7 and no GETDIRINFO reply is longer than 4 bytes --
               -- but a dead branch must still not squat on tags something else uses.
               dbg_trace_tag <= "110100" & std_logic_vector(dirinfo_sent + 3);
               dbg_trace_data <= dirinfo_data;
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 9 then
               sum_alt       <= "0000";
               if cd_rot_left /= 0 then
                  cd_rot_left <= cd_rot_left - 1;   -- one full rotation spent
               end if;
               dbg_trace_req <= '1';
               -- 0xAC: bytes 8-15 the CPU took for GETDIRINFO replies. Reference for
               -- this disc, continuing 0xA7: 00 49 65 04 then zeros.
               dbg_trace_tag <= x"AC";
               dbg_trace_data <= scsi_gdi_i(63 downto 0);
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 8 then
               sum_alt       <= "1001";
               dbg_trace_req <= '1';
               -- 0xA7: the first eight bytes the CPU actually took for GETDIRINFO
               -- replies, appended across all of them. This is the CPU-side view of
               -- the exchange the board diverges on -- the bridge-side counters
               -- structurally cannot show a byte the CPU never collected. Reference
               -- for this disc is 01 34 | 70 15 36 | 00 02 00 (the 13 reply bytes
               -- of the four calls run together, continued in 0xAC).
               dbg_trace_tag <= x"A7";
               dbg_trace_data <= scsi_gdi_i(127 downto 64);
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 7 then
               sum_alt       <= "1000";
               dbg_trace_req <= '1';
               -- 0xAB: CDB[2] (track) of the first eight GETDIRINFOs, reference
               -- ca ca 01 02 -- a fifth entry here is the divergence.
               dbg_trace_tag <= x"AB";
               dbg_trace_data <= gdi_tracks;
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 6 then
               sum_alt       <= "0111";
               dbg_trace_req <= '1';
               -- 0xAA: CDB[1] (mode) of the first eight GETDIRINFOs, reference 00 01 02 02.
               dbg_trace_tag <= x"AA";
               dbg_trace_data <= gdi_modes;
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 5 then
               sum_alt       <= "0110";
               dbg_trace_req <= '1';
               -- 0xA6: opcodes of the first eight commands, oldest first. Reference
               -- sequence captured from beetle-pce-fast on the same disc is
               -- 00 de de de de 08 08 08 -- anything else here is the divergence.
               dbg_trace_tag <= x"A6";
               dbg_trace_data <= op_first8;
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 4 then
               sum_alt       <= "0101";
               dbg_trace_req <= '1';
               -- 0xA5: [63:48] bytes the CPU ACKed in DATA-IN for the current command
               -- | [47:44] SCSI.vhd phase | [43:39] cd_bridge FSM state | 0.
               -- A bridge parked in SCSI_READ_WAIT_END (state 01000) with the SCSI
               -- side back at SP_FREE (0) is "waiting for a CD_DATA_END that already
               -- came and went"; both idle is "the host simply stopped talking".
               dbg_trace_tag <= x"A5";
               -- [63:48] DATA-IN bytes ACKed for the current command | [47:44] SCSI
               -- phase | [43:39] cd_bridge state | [38:23] cumulative FIFO reads.
               -- cd_wr_cnt (tag 0xAF) minus that last figure is what is stranded in
               -- the FIFO -- nonzero means a reply the CPU never collected, which
               -- would shift every byte of the next transfer.
               dbg_trace_data <= std_logic_vector(scsi_datain_cnt_i) & scsi_sp_i
                                 & cd_dbg_state_i & std_logic_vector(scsi_rd_total_i)
                                 & "0000000" & x"0000";
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 3 then
               sum_alt       <= "0100";
               dbg_trace_req <= '1';
               -- 0xA4: the first eight bytes the CPU actually took off the SCSI bus
               -- after the last READ(6). Sector 0 of a PCE CD data track is the Hudson
               -- Shift-JIS copyright block, byte-identical across discs, so a shift or
               -- a stale-FIFO prefix is visible directly here.
               dbg_trace_tag <= x"A4";
               dbg_trace_data <= scsi_first8_i;
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 2 then
               sum_alt       <= "0011";
               dbg_trace_req <= '1';
               dbg_trace_tag <= x"AD";
               -- [63:56] last CD_STAT | [55:48] sense key | [47:40] sense ASC
               -- | [39:24] CHECK CONDITION count | [23:0] 0
               -- [63:56] last CD_STAT | [55:48] sense key | [47:40] sense ASC
               -- | [39:24] CHECK CONDITION count | [23:8] FIFO bytes DROPPED
               -- | [7:0] 0.  Drops were previously invisible: the FIFO silently threw
               -- away any byte written while full, so a short transfer looked identical
               -- to a good one. Nonzero here means the bridge outran the CPU.
               dbg_trace_data <= last_stat & sense_key & sense_asc
                                 & std_logic_vector(chk_cond_cnt)
                                 & std_logic_vector(scsi_fifo_drops_i) & x"00";
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 and sum_alt = 1 then
               sum_alt       <= "0010";
               dbg_trace_req <= '1';
               dbg_trace_tag <= x"AF";
               -- [63:48] SECTOR_DATA_VALID pulses | [47:32] CD_DATA_WR pulses
               -- | [31:16] SECTOR_REQ pulses | [15:0] 0
               -- [15:0] was padding; now DATA IN bursts that ran dry mid-burst. This is
               -- THE number that says whether SCSI.vhd's sector gate works on real
               -- hardware: 0 means every burst was served from a full FIFO, nonzero means
               -- the CPU reread stale bytes and the sector is corrupt. Without it, "the
               -- game still does not boot" and "the gate is not working" look identical.
               dbg_trace_data <= std_logic_vector(sd_valid_cnt)
                                 & std_logic_vector(cd_wr_cnt)
                                 & std_logic_vector(sect_req_cnt)
                                 & std_logic_vector(scsi_underruns_i);
            elsif dbg_hb_cnt = 0 and cd_rot_left /= 0 and toc_sent_cnt = 4 then
               sum_alt <= "0001";
               -- 0xAE, re-emitted every heartbeat so the LAST one in the log is current.
               dbg_trace_req <= '1';
               dbg_trace_tag <= x"AE";
               -- [63:56] commands | [55:48] last opcode | [47:40] READ(6) count
               -- | [39:16] last READ LBA | [15:8] GETDIRINFO reply bytes seen
               -- | [7:0] first reply byte
               dbg_trace_data <= std_logic_vector(sum_cmd_cnt) & sum_last_op
                                 & std_logic_vector(sum_read_cnt) & sum_read_lba
                                 & std_logic_vector(sum_dir_cnt) & sum_dir_b0;
            elsif dbg_hb_cnt = 0 and toc_sent_cnt < 4 then
               toc_sent_cnt  <= toc_sent_cnt + 1;
               dbg_trace_req <= '1';
               dbg_trace_tag <= "10100" & std_logic_vector(toc_sent_cnt);  -- 0xA0-0xA3
               case std_logic_vector(toc_sent_cnt) is
                  -- Order matters: these emit one per ~100ms heartbeat slot, and the
                  -- MCU sends the TOC ~1ms after the core is released. The count went
                  -- first last time and was sampled BEFORE the TOC landed, reading 0
                  -- while a2/a3 in the same run showed the data had in fact arrived.
                  -- 0xA0: track 1 control + LBA
                  when "000" => dbg_trace_data <= x"01" & toc_t1_ctl & toc_t1_lba & x"000000";
                  -- 0xA1: track 2 control + LBA  (the DATA track on this disc)
                  when "001" => dbg_trace_data <= x"02" & toc_t2_ctl & toc_t2_lba & x"000000";
                  -- 0xA2: lead-out LBA
                  when "010" => dbg_trace_data <= x"64" & x"00" & toc_lo_lba & x"000000";
                  -- 0xA3, LAST: TOC_WR count | highest track | mount
                  when others => dbg_trace_data <= std_logic_vector(toc_wr_count) & toc_maxtrack & "0000000" & cd_mounted_i & x"0000000000";
               end case;
            elsif CDCMD_TRACE and cdcmd_pend = '1' and cdcmd_cnt < 40 and cdcmd_gap = 0 then
               cdcmd_pend    <= '0';
               cdcmd_cnt     <= cdcmd_cnt + 1;
               cdcmd_gap     <= to_unsigned(42857, 16);   -- ~1 ms before the next one
               dbg_trace_req <= '1';
               -- 0x40-0x7B: distinct from block checksums (0x00-0x3F), heartbeat (0x80+)
               -- and the trap window (0xE0+).
               -- 0xC0+: 0x40+ collides with the SECOND ROM-checksum pass, which cost a
               -- run: eight checksum lines came back tagged exactly like CD commands.
               dbg_trace_tag <= std_logic_vector(("1011" & cdcmd_cnt(3 downto 0)));
               -- CDB bytes 0..7, little-endian in CD_COMM: byte n = CD_COMM(8n+7:8n).
               -- Byte 0 is the opcode; for READ(6) bytes 1..3 are the LBA and byte 4 the
               -- sector count, per this file's own READ(6) decode.
               dbg_trace_data <= cdcmd_data;
            elsif dbg_hb_cnt = 0 and trap_fired = '1' and trap_sent < 12 then
               trap_sent     <= trap_sent + 1;
               dbg_trace_req <= '1';
               dbg_trace_tag <= x"E" & std_logic_vector(trap_sent);
               case std_logic_vector(trap_sent) is
                  when "0000" => dbg_trace_data <= trap_buf(0) & trap_buf(1) & "0000000000000000";
                  when "0001" => dbg_trace_data <= trap_buf(2) & trap_buf(3) & "0000000000000000";
                  when "0010" => dbg_trace_data <= trap_buf(4) & trap_buf(5) & "0000000000000000";
                  when "0011" => dbg_trace_data <= trap_mpr;   -- MPR7..MPR0, tag 0xE3
                  -- tag 0xE4: TAM_CNT | IR | T | A, all frozen at the trap.
                  when "0100" => dbg_trace_data <= trap_tam & x"00000000";
                  -- 0xE5..0xE8: the four T-loads, newest first. 48 bits used of 64:
                  -- IR | DI | ADDR_BUS(15:0) | A | STATE(4:0) | LOAD_T(2:0), then the
                  -- sticky WAIT_N-ever-low flag in the LSB so it rides along with each.
                  when "0101" => dbg_trace_data <= trap_tload(47 downto 0)    & "000000000000000" & trap_wait_ever;
                  when "0110" => dbg_trace_data <= trap_tload(95 downto 48)   & "000000000000000" & trap_wait_ever;
                  when "0111" => dbg_trace_data <= trap_tload(143 downto 96)  & "000000000000000" & trap_wait_ever;
                  when "1000" => dbg_trace_data <= trap_tload(191 downto 144) & "000000000000000" & trap_wait_ever;
                  -- 0xE9/0xEA: the bridge's own view at the CPU's two most recent T-loads.
                  when "1001" => dbg_trace_data <= trap_bview(0) & x"00000000";
                  when "1010" => dbg_trace_data <= trap_bview(1) & x"00000000";
                  -- 0xEB: MPR_SEL | ADDR_BUS(15:13) | MC.ADDR_BUS | A_OUT(20:13)
                  when others => dbg_trace_data <= "0000000000" & trap_sel & x"00000000";
               end case;
            -- 0xC8 (cdsnoop_idx = 8) is NOT gated on the buffers being full: it carries
            -- the very counters that explain WHY they are not full. Putting the
            -- explanation behind the same gate as the data meant an empty capture
            -- emitted nothing at all and the run was wasted.
            elsif CDRAM_PROBES and dbg_hb_cnt = 0 and cdsnoop_pass < 3
                  and (cdsnoop_idx >= 8 or cdsnoop_cnt = 16) then
               -- Walks 0..8 then 10..14, i.e. tags 0xC0-0xC8 and 0xCA-0xCE. Index 9 is
               -- SKIPPED: 0xC9 belongs to the self-test result emitted once at the head
               -- of the chain, and a second payload on that tag would be a collision of
               -- exactly the kind already paid for twice on this project.
               if cdsnoop_idx = 15 then
                  cdsnoop_idx  <= (others => '0');
                  cdsnoop_pass <= cdsnoop_pass + 1;
               elsif cdsnoop_idx = 8 then
                  cdsnoop_idx <= x"A";
               else
                  cdsnoop_idx <= cdsnoop_idx + 1;
               end if;
               dbg_trace_req <= '1';
               -- CD-RAM snoop, tags 0xC0-0xC8 (0xC is free in this build -- the vfy
               -- ROM dump that owns it only runs before the core is released).
               --   0xC0-0xC3 : first 16 CD-RAM READS in the 0x0100xx window after the
               --               boot's 8th command, as addr(7:0)&data(7:0), oldest first.
               --   0xC4-0xC7 : first 16 CD-RAM WRITES in the same window, same format,
               --               captured from the load itself (NOT gated on command 8).
               --   0xC8      : port-C health and whole-space totals.
               --
               -- Run 1 (v1, reads only) came back every byte 0x00 against a sim
               -- reference of 4C F6 42 4C A8 40 4C 0F. 0x00 is BRK, which vectors the
               -- CPU straight into the syscard's error handler -- the black-palette
               -- loop seen on tags 0xD6/0xD7. The write side decides which bug that is:
               --   writes show the real program, reads show zero -> storage/readback
               --   writes absent entirely                       -> the CPU never stored
               --   both show the program                        -> fault is above memory
               -- 0xC8's cdram_wr_total/cdram_rd_total cover the WHOLE CD-RAM space, so
               -- "the CPU uses a different region" is distinguishable from "no traffic".
               -- Emitted 3 full passes so a dropped frame costs no hardware round trip.
               -- 0xC0-0xC7: the 16 captured CD-RAM READS, two 32-bit entries per frame,
               -- oldest first. Each entry is "000000" & addr(17:0) & data(7:0), so the
               -- full CD-RAM address is readable and the bytes can be diffed against the
               -- sim's [cdram] dump wherever the program actually landed.
               dbg_trace_tag <= x"C" & std_logic_vector(cdsnoop_idx);
               case cdsnoop_idx is
                  when x"0" => dbg_trace_data <= cdsnoop_buf(511 downto 448);
                  when x"1" => dbg_trace_data <= cdsnoop_buf(447 downto 384);
                  when x"2" => dbg_trace_data <= cdsnoop_buf(383 downto 320);
                  when x"3" => dbg_trace_data <= cdsnoop_buf(319 downto 256);
                  when x"4" => dbg_trace_data <= cdsnoop_buf(255 downto 192);
                  when x"5" => dbg_trace_data <= cdsnoop_buf(191 downto 128);
                  when x"6" => dbg_trace_data <= cdsnoop_buf(127 downto 64);
                  when x"7" => dbg_trace_data <= cdsnoop_buf(63 downto 0);
                  -- 0xCA-0xCD: the LAST 8 CD-RAM WRITES, same 32-bit entry format as the
                  -- reads above ("000000" & addr(17:0) & data(7:0)), oldest first. These
                  -- were captured and thrown away on every previous run.
                  when x"A" => dbg_trace_data <= cdsnoop_wbuf(255 downto 192);
                  when x"B" => dbg_trace_data <= cdsnoop_wbuf(191 downto 128);
                  when x"C" => dbg_trace_data <= cdsnoop_wbuf(127 downto 64);
                  when x"D" => dbg_trace_data <= cdsnoop_wbuf(63 downto 0);
                  when x"E" =>
                     -- 0xCE: THE DISCRIMINATOR.
                     -- [63:46] lowest CD-RAM address written | [45:28] highest written
                     -- | [27:10] 0 | [9:0] 0.
                     -- Read it against the read addresses on 0xC0-0xC7. If a read that
                     -- returned 0x00 falls INSIDE [lo,hi], the byte was written and the
                     -- memory lost it under real load -- which the core-halted 256 KiB
                     -- sweep (0 bad) cannot detect, because it runs with no ADPCM port-C
                     -- traffic, no ROM contention and no refresh pressure. If it falls
                     -- OUTSIDE, nothing ever wrote there and the CPU is executing from a
                     -- region that was never loaded: a mapping or bad-jump bug, not RAM.
                     -- lo = 0x3FFFF with hi = 0 means no CD-RAM write happened at all.
                     dbg_trace_data <= std_logic_vector(cdram_wr_lo)
                                       & std_logic_vector(cdram_wr_hi)
                                       & "0000000000" & "0000000000" & "00000000";
                  when x"F" =>
                     -- 0xCF: THE PAGE WATCH, and the real discriminator (0xCE's span was
                     -- too weak -- see the capture site).
                     -- [63:48] writes to page 0x137xx | [47:40] low byte of the last
                     -- address written there | [39:32] data of that last write
                     -- | [31:24] data of the FIRST write to 0x13720 exactly
                     -- | [23:16] 1 if 0x13720 was ever written at all | [15:0] 0.
                     dbg_trace_data <= std_logic_vector(wr137_cnt)
                                       & wr137_last_a & wr137_last_d & wr137_first20
                                       & "0000000" & wr137_hit20 & x"0000";
                  -- NOTE: no `when x"9"` here any more. The self-test result used to be
                  -- emitted from this ladder as 0xC9 and never reached the log once,
                  -- because this branch sits behind twelve full summary rotations. It is
                  -- now emitted once, up front, from its own branch at the head of the
                  -- emit chain; two sources for one tag would be a collision of exactly
                  -- the kind already paid for twice on this project.
                  when others =>
                     -- 0xC8: [63:56] port-C watchdog fires (cdr_timeouts -- the arbiter
                     -- releasing WHATEVER DATA IS PRESENT rather than hanging; this was
                     -- incremented and read nowhere before) | [55:48] reads captured
                     -- | [47:40] writes captured | [39:24] CD-RAM writes seen anywhere
                     -- | [23:8] CD-RAM reads seen anywhere | [7:0] 0.
                     dbg_trace_data <= std_logic_vector(dbg_cdr_timeout_cnt)
                                       & "000" & std_logic_vector(cdsnoop_cnt)
                                       & "000" & std_logic_vector(cdsnoop_wcnt)
                                       & std_logic_vector(cdram_wr_total)
                                       & std_logic_vector(cdram_rd_total)
                                       -- [7:2] core resets since FPGA load | [1] trap
                                       -- fired ever | [0] bank_bad ever.
                                       & std_logic_vector(core_rst_cnt)
                                       & trap_sticky & bank_sticky;
               end case;
            elsif dbg_hb_cnt = 0 and cdv_tag_cnt < 24 then
               cdv_tag_cnt <= cdv_tag_cnt + 1;
               dbg_trace_req <= '1';
               -- 0xD5: repurposed now the CD-RAM sweep has answered (256 KiB, 0 bad).
               -- [63:48] CD interrupt (IRQ2) assertions | [47:32] VBlank (IRQ1)
               -- assertions | [31:16] CD-RAM self-test KiB verified (0 when disabled)
               -- | [15:0] 0.
               -- IRQ2 flat at zero while IRQ1 climbs means the CD never interrupts the
               -- CPU -- exactly what a game stuck waiting on a CD transfer looks like
               -- from outside, and the next suspect now that the data path and CD-RAM
               -- are both verified good.
               dbg_trace_tag  <= x"D5";
               dbg_trace_data <= std_logic_vector(dbg_irq2_cnt)
                                 & std_logic_vector(dbg_irq1_cnt)
                                 & std_logic_vector(adpcm_play_cnt)
                                 & std_logic_vector(adpcm_end_cnt);
            elsif dbg_hb_cnt = 0 and da_tag_cnt < 24 then
               da_tag_cnt <= da_tag_cnt + 1;
               dbg_trace_req <= '1';
               -- 0xDA: [63:48] SELECT count | [47:44] COMM_POS | [43:36] COMM(0)
               -- | [35:28] COMM(1) | [27:12] commands completed | [11:0] 0.
               -- SELECT count far above the command count means selections are being
               -- started that never become commands -- i.e. phantom selects from the
               -- register-clear sweep, not real commands that stall.
               dbg_trace_tag  <= x"DA";
               dbg_trace_data <= std_logic_vector(scsi_sel_cnt_i)
                                 & std_logic_vector(scsi_comm_pos_i)
                                 & scsi_comm0_i & scsi_comm1_i
                                 & std_logic_vector(sum_cmd_cnt) & x"00000";
            elsif dbg_hb_cnt = 0 and d7_tag_cnt < 24 then
               d7_tag_cnt <= d7_tag_cnt + 1;
               dbg_trace_req <= '1';
               -- 0xD7: the last FOUR CD-register accesses, oldest first. Each 16 bits:
               -- [15] 1=write 0=read | [14:8] register low bits | [7:0] data.
               -- A game stuck polling shows the same register repeating here, which
               -- names what it is waiting on.
               -- 0xD7/0xD8/0xD9: the first twelve CD-register accesses after the last
               -- SCSI command, oldest first, four per tag. Each 16 bits:
               -- [15] 1=write 0=read | [14:8] register low bits | [7:0] data.
               case d7_tag_cnt(1 downto 0) is
                  when "00" =>
                     dbg_trace_tag  <= x"D7";
                     dbg_trace_data <= cdreg_shot(191 downto 128);
                  when "01" =>
                     dbg_trace_tag  <= x"D8";
                     dbg_trace_data <= cdreg_shot(127 downto 64);
                  when others =>
                     dbg_trace_tag  <= x"D9";
                     dbg_trace_data <= cdreg_shot(63 downto 0);
               end case;
            elsif dbg_hb_cnt = 0 and d6_tag_cnt < 24 then
               d6_tag_cnt <= d6_tag_cnt + 1;
               dbg_trace_req <= '1';
               -- 0xD6: ADPCM detail. Its own counter, NOT cdv_tag_cnt -- sharing one
               -- meant 0xD5 consumed the whole budget and 0xD6 never emitted a single
               -- frame. Same elsif-chain starvation that silenced the CPU/video probes
               -- earlier; budget every tag block separately.
               -- [63:48] ADPCM RAM requests | [47:45] live PLAY/END/HALF
               -- | [44:29] CD-RAM self-test KiB | [28:0] 0.
               -- PLAY starts with no END following is a game waiting on an ADPCM
               -- completion that never arrives -- it keeps rendering while issuing no
               -- further CD command, which is what DE2 does here.
               -- 0xD6: [63:48] VCE (palette) writes | [47:32] of those, writes with a
               -- NONZERO value | [31:24] last byte written | [23:8] ADPCM RAM requests
               -- | [7:5] live ADPCM PLAY/END/HALF | [4:0] 0.
               -- vce=0 means the palette is never programmed at all; vce>0 with
               -- nonzero=0 means it is programmed entirely to black. Those are different
               -- bugs and the screen looks identical for both.
               dbg_trace_tag  <= x"D6";
               dbg_trace_data <= std_logic_vector(vce_wr_cnt)
                                 & std_logic_vector(vce_nonzero_cnt)
                                 & vce_last & std_logic_vector(adpcm_req_cnt)
                                 & adpcm_dbg_i & "00000";
            elsif dbg_hb_cnt = 0 and hb_alt = '0' and cpu_tag_cnt < 64 then
               hb_alt      <= '1';
               cpu_tag_cnt <= cpu_tag_cnt + 1;
               dbg_trace_req <= '1';
               -- 0xD2: is the CPU still executing, and did it fault? The video heartbeat
               -- (0x80+) answers "is the VDC being programmed"; this answers the half
               -- that matters once a game has been handed control and the screen goes
               -- dark -- CPU_CE still advancing means running, flat means wedged, and
               -- trap_fired/bank_bad means it jumped into an unmapped bank (the exact
               -- fault signature that was chased to 777ba38 on the HuCard path).
               -- [63:48] CPU_CE count | [47:32] VDC writes | [31:16] IRQ1 assertions
               -- | [15] trap_fired | [14] bank_bad | [13] vdc_stall | [12] IRQ1_N
               -- | [11] IRQ2_N | [10:6] cd_bridge state | [5:0] 0
               -- Source frames gave up their slot to the IRQ1 count -- the 0x8x video
               -- heartbeat already carries frames, and the open question now is whether
               -- the VDC ever interrupts the CPU, which a level bit cannot answer.
               dbg_trace_tag  <= x"D2";
               dbg_trace_data <= std_logic_vector(dbg_cpu_cyc)
                                 & std_logic_vector(dbg_vdc_cnt(15 downto 0))
                                 & std_logic_vector(dbg_irq1_cnt)
                                 & trap_fired & bank_bad & dbg_vdc_stall
                                 & dbg_irq1_n & dbg_irq2_n
                                 & cd_dbg_state_i & "000000";
            elsif dbg_hb_cnt = 0 and dbg_fetch_cnt < 64 then
               hb_alt        <= '0';
               dbg_fetch_cnt <= dbg_fetch_cnt + 1;
               -- 0x80+ so heartbeat tags can never be confused with a block checksum.
               -- Mask to 5 bits BEFORE the 0x80: the tag is only a sample index, but
               -- dbg_fetch_cnt now runs to 64 and "cnt or 0x80" would emit 0xA0-0xBF,
               -- colliding with the whole CD tag block. That happened (2026-09-11) and
               -- produced video heartbeats wearing CD tags, which read as live CD
               -- counters. Tags repeat every 32 samples now; the index is cosmetic.
               dbg_trace_tag <= std_logic_vector(("000" & dbg_fetch_cnt(4 downto 0)) or x"80");
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
               -- 2026-09-09 repurpose: the ROM/CPU fault this payload was built for is
               -- fixed (777ba38), so CPU_A and CPU_CE give up their bits to the video
               -- path, which is the live fault. What this answers in ONE run:
               --   VDC writes climbing  -> the CPU is programming the VDC
               --   src frames climbing  -> the core is really emitting frames, and the
               --                           servo's reference edge exists
               --   out frames climbing  -> the output raster is running
               --   out/src ratio        -> the REAL rate mismatch, measured rather than
               --                           derived from an assumed 262-line frame
               --   vs_cy                -> the servo's phase; should settle near 2 and
               --                           stay there. Wandering = not locked.
               --   vtotal_extra         -> what the servo is actually asking for. A
               --                           stable small number means the loop is sane and
               --                           a black screen is the sink rejecting VTOTAL
               --                           modulation; a thrashing or pegged number means
               --                           the loop itself is the bug.
               -- [63:48] VDC writes | [47:32] output frames | [31:16] source frames
               -- | [15:6] vs_cy | [5:0] vtotal_extra(5:0)
               dbg_trace_data <= std_logic_vector(dbg_vdc_cnt(15 downto 0))
                                 & std_logic_vector(vid_out_frames)
                                 & std_logic_vector(vid_src_frames)
                                 & vid_vs_cy
                                 & vid_vtotal_extra(5 downto 0);
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
            if trap_fired = '0' and dbg_tload_stb = '1' then
               -- rom_a is what pce_top is ASKING for right now; rom_do_i is what the
               -- bridge is HANDING BACK; rom_rdy_i is whether it claims to be ready.
               bview(0) <= "000" & rom_a(20 downto 0) & rom_do_i;
               bview(1) <= bview(0);
            end if;
            if trap_fired = '0' and bank_bad = '1' then
               trap_fired <= '1';   -- CPU just entered a nonexistent bank: freeze
               trap_mpr   <= dbg_mpr;
               trap_tam   <= dbg_tam;
               trap_tload <= dbg_tload;
               trap_bview <= bview;
               trap_sel   <= dbg_sel;
               trap_wait_ever <= dbg_wait_ever;
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
            dbg_irq1_cnt <= (others => '0');
            dbg_irq2_cnt <= (others => '0');
         else
            if dbg_vdc_wr = '1' then
               dbg_vdc_cnt <= dbg_vdc_cnt + 1;
            end if;
            -- CD-register access ring (see cdreg_ring's declaration comment). The CD page
            -- is PHYSICAL 0x1FF800: the PCE I/O page is bank $FF (0x1FE000-0x1FFFFF) and
            -- the CD block sits at $1800 within it. Decoding the LOGICAL $1800 instead is
            -- a mistake already made once in the GHDL testbench, where the probe then
            -- printed nothing at all.
            -- Re-arm on every new SCSI command, detected HERE rather than in the command
            -- process: cdreg_idx must have exactly one driver, and driving it from both
            -- places is a multiple-driver error (EX2000), which this file has hit before.
            -- The capture then always holds what followed the LAST command issued.
            cdreg_cmd_r <= sum_cmd_cnt;
            if sum_cmd_cnt /= cdreg_cmd_r then
               cdreg_armed <= '1';
               cdreg_idx   <= (others => '0');
            -- WRITES ONLY. The first version captured reads too and filled all twelve
            -- slots with the same poll (RD $1800 => 80), which is just the normal ~40us
            -- SP_COMM_BEFOREREQ delay -- the opening of the handshake, not its failure.
            -- The signal is in the writes: $1800 selects the drive, $1801 carries each
            -- command byte, $1802 bit 7 is ACK. Twelve writes span a whole command.
            elsif cdreg_acc_r = '0' and dbg_cpu_ce = '1'
                  and dbg_cpu_a(20 downto 10) = "11111111110"
                  and dbg_cpu_wr_n = '0'
                  and cdreg_armed = '1' and cdreg_idx < 12 then
               cdreg_shot(191 - to_integer(cdreg_idx)*16
                          downto 176 - to_integer(cdreg_idx)*16)
                  <= (not dbg_cpu_wr_n) & dbg_cpu_a(6 downto 0) & cdreg_data;
               cdreg_idx <= cdreg_idx + 1;
            end if;

            cdreg_acc_r <= dbg_cpu_ce;
            if dbg_cpu_ce = '1' and cdreg_acc_r = '0'
               and dbg_cpu_a(20 downto 10) = "11111111110"
               and (dbg_cpu_wr_n = '0' or dbg_cpu_rd_n = '0') then
               -- SCSI PHASE TRANSITIONS (2026-09-14). $1800 read is the phase register
               -- in BOTH this design and mednafen, bit-identical: 0x80 BSY, 0x40 REQ,
               -- 0x20 MSG, 0x10 CD, 0x08 IO. What matters is the SEQUENCE of DISTINCT
               -- values, not the polls -- the reference polls $1800 430047 times in one
               -- boot but only changes value about ten times per command, so recording
               -- only changes is bounded by construction and cannot flood the link.
               --
               -- This exists because streaming every access (CDREG_STREAM/0xDB) DOES
               -- flood it: trace frames block the BL616's polled UART RX, sector requests
               -- are eaten, and the run dies at the first READ(6) with 0 sectors served.
               -- Aggregate in RTL, report periodically -- never stream.
               --
               -- The values being hunted, from the golden trace's end-of-command walk:
               --   0xC8 DATA IN + REQ     0x88 DATA IN, REQ low (the inter-sector poll)
               --   0xD8 STATUS + REQ      0xF8 MESSAGE IN + REQ      0x00 BUS FREE
               -- A board that never shows 0xD8 never started the status walk at all.
               if dbg_cpu_a(9 downto 0) = "0000000000" and dbg_cpu_wr_n = '1'
                  and cdreg_data /= ph_last then
                  ph_last <= cdreg_data;
                  ph_ring <= ph_ring(55 downto 0) & cdreg_data;
                  if ph_chg /= x"FFFF" then ph_chg <= ph_chg + 1; end if;
                  if cdreg_data = x"D8" and ph_d8 /= x"FFFF" then ph_d8 <= ph_d8 + 1; end if;
                  if cdreg_data = x"F8" and ph_f8 /= x"FFFF" then ph_f8 <= ph_f8 + 1; end if;
                  if cdreg_data = x"00" and ph_bf /= x"FFFF" then ph_bf <= ph_bf + 1; end if;
               end if;

               -- entry = [15] 1=write 0=read | [14:8] register low bits | [7:0] data
               -- (what was written, or what was read back)
               cdreg_ring <= cdreg_ring(47 downto 0)
                             & (not dbg_cpu_wr_n) & dbg_cpu_a(6 downto 0)
                             & cdreg_data;
               cdreg_cnt <= cdreg_cnt + 1;

               -- Same access, also pushed to the 0xDB stream ring -- MINUS the two
               -- high-volume accesses the reference trace is filtered on, so both sides
               -- of the diff drop exactly the same thing:
               --   RD $1800  the busy poll, 94477 of golden's 158645 accesses
               --   $1808     the sector payload, 2048 reads per sector
               -- Decoded on a(9:0) so it is the register itself, not a mirror of it
               -- elsewhere in the 1 KiB page this ring already decodes.
               if CDREG_STREAM
                  and dbg_cpu_a(9 downto 0) /= "0000001000"                        -- $1808
                  and not (dbg_cpu_a(9 downto 0) = "0000000000"
                           and dbg_cpu_wr_n = '1') then                            -- RD $1800
                  if (cdtq_wr - cdtq_rd) /= 64 then
                     cdt_mem(to_integer(cdtq_wr(5 downto 0)))
                        <= (not dbg_cpu_wr_n) & dbg_cpu_a(6 downto 0) & cdreg_data;
                     cdtq_wr <= cdtq_wr + 1;
                  else
                     -- Ring full: the link was busy longer than 64 accesses. Counted, and
                     -- reported in every frame, because a dropped access silently shifts
                     -- the diff and would make a correct stream look divergent.
                     cdt_drops <= cdt_drops + 1;
                  end if;
               end if;
            end if;

            if dbg_vce_wr = '1' then
               vce_wr_cnt <= vce_wr_cnt + 1;
               vce_last   <= dbg_vce_do;
               if dbg_vce_do /= x"00" then
                  vce_nonzero_cnt <= vce_nonzero_cnt + 1;
               end if;
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
            dbg_irq2_r <= dbg_irq2_n;
            if dbg_irq2_n = '0' and dbg_irq2_r = '1' then
               dbg_irq2_cnt <= dbg_irq2_cnt + 1;
            end if;
            -- ADPCM activity (see adpcm_dbg_i's declaration comment)
            adpcm_play_r <= adpcm_dbg_i(2);
            adpcm_end_r  <= adpcm_dbg_i(1);
            adpcm_req_r  <= adpcm_ram_req_i;
            if adpcm_dbg_i(2) = '1' and adpcm_play_r = '0' then
               adpcm_play_cnt <= adpcm_play_cnt + 1;
            end if;
            if adpcm_dbg_i(1) = '1' and adpcm_end_r = '0' then
               adpcm_end_cnt <= adpcm_end_cnt + 1;
            end if;
            if adpcm_ram_req_i = '1' and adpcm_req_r = '0' then
               adpcm_req_cnt <= adpcm_req_cnt + 1;
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
      tmds_d_n => tmds_d_n, tmds_d_p => tmds_d_p,
      dbg_out_frame_tog => vid_out_frame_tog,
      dbg_vs_cy         => vid_vs_cy,
      dbg_vtotal_extra  => vid_vtotal_extra
   );

   leds_n(0) <= not (pll_lock and hdmi_pll_lock);
   leds_n(1) <= not rom_loading(0);

end architecture;
