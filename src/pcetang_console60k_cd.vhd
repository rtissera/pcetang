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
         LOADING_STATE : std_logic_vector(7 downto 0) := (others => '0')
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

   signal romb_addr : std_logic_vector(24 downto 0);
   signal romb_req  : std_logic := '0';
   signal romb_we   : std_logic := '0';
   signal romb_di   : std_logic_vector(7 downto 0);
   signal romb_do   : std_logic_vector(7 downto 0);
   signal romb_wait : std_logic;

   type romb_state_t is (RB_IDLE, RB_SETTLE, RB_WAIT);

   signal rd_state       : romb_state_t := RB_IDLE;
   signal rd_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal rd_req         : std_logic := '0';
   signal rd_addr        : std_logic_vector(24 downto 0);

   signal wr_state       : romb_state_t := RB_IDLE;
   signal wr_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal wr_req         : std_logic := '0';
   signal wr_addr        : std_logic_vector(24 downto 0);
   signal wr_data        : std_logic_vector(7 downto 0);

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
   signal cdr_wait : std_logic;

   type cdr_state_t is (CDR_IDLE, CDR_SETTLE, CDR_HOLD);
   signal cdr_state      : cdr_state_t := CDR_IDLE;
   signal cdr_settle_cnt : unsigned(2 downto 0) := (others => '0');
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
      LOADING_STATE => x"00"
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

         if reset_n = '0' then
            core_resetn <= '0';
         elsif rom_loading(0) = '1' and rom_loading_r = '0' then
            core_resetn <= '0';
         elsif rom_loading(0) = '0' and rom_loading_r = '1' then
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
   romb_addr <= wr_addr when rom_loading_r = '1' else rd_addr;
   romb_we   <= '1'     when rom_loading_r = '1' else '0';
   romb_di   <= wr_data;

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
   romb_req  <= wr_req xor rd_req;

   -- ROM write bridge: one iosys_bl616 byte becomes one real SDRAM write via port B.
   -- Same pattern as pcetang_console60k.vhd's ROM write bridge.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case wr_state is
            when RB_IDLE =>
               if rom_do_valid = '1' then
                  wr_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(rom_wr_addr, 25));
                  wr_data <= rom_do;
                  wr_req  <= not wr_req;
                  wr_settle_cnt <= (others => '0');
                  wr_state <= RB_SETTLE;
               end if;

            when RB_SETTLE =>
               if wr_settle_cnt = "100" then
                  if romb_wait = '1' then
                     wr_state <= RB_WAIT;
                  else
                     wr_state <= RB_IDLE;
                  end if;
               else
                  wr_settle_cnt <= wr_settle_cnt + 1;
               end if;

            when RB_WAIT =>
               if romb_wait = '0' then
                  wr_state <= RB_IDLE;
               end if;
         end case;
      end if;
   end process;

   -- ROM read bridge: one pce_top ROM_RD per CPU cart-ROM byte access becomes one real
   -- SDRAM read via port B. Same pattern as pcetang_console60k.vhd's ROM read bridge.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case rd_state is
            when RB_IDLE =>
               rom_rdy_i <= '1';
               if rom_rd_i = '1' then
                  rd_addr <= std_logic_vector(ROM_SDRAM_BASE +
                             resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 25));
                  rom_rdy_i <= '0';
                  rd_req <= not rd_req;
                  rd_settle_cnt <= (others => '0');
                  rd_state <= RB_SETTLE;
               end if;

            when RB_SETTLE =>
               if rd_settle_cnt = "100" then
                  if romb_wait = '1' then
                     rd_state <= RB_WAIT;
                  else
                     rom_do_i <= romb_do;
                     rom_rdy_i <= '1';
                     rd_state <= RB_IDLE;
                  end if;
               else
                  rd_settle_cnt <= rd_settle_cnt + 1;
               end if;

            when RB_WAIT =>
               if romb_wait = '0' then
                  rom_do_i <= romb_do;
                  rom_rdy_i <= '1';
                  rd_state <= RB_IDLE;
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
                  cdr_state <= CDR_SETTLE;
               end if;

            when CDR_SETTLE =>
               cdr_req <= '1';
               if cdr_settle_cnt = "100" then
                  if cdr_wait = '1' then
                     cdr_state <= CDR_HOLD;
                  else
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
               else
                  cdr_settle_cnt <= cdr_settle_cnt + 1;
               end if;

            when CDR_HOLD =>
               cdr_req <= '1';
               if cdr_wait = '0' then
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
      RAM_B_WAIT => romb_wait,
      RAM_C_ADDR => cdr_addr,
      RAM_C_REQ  => cdr_req,
      RAM_C_RD_n => cdr_rd_n,
      RAM_C_DI   => cdr_di,
      RAM_C_DO   => cdr_do,
      RAM_C_WAIT => cdr_wait,
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
   generic map (LITE => 0, EXT_VRAM0 => 0, NO_CD => 0)
   port map (
      RESET      => not core_resetn,
      COLD_RESET => not core_resetn,
      CLK        => clk_pce,

      VRAM0_RAM_A_ADDR => open, VRAM0_RAM_A_REQ => open, VRAM0_RAM_A_RD_N => open,
      VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0'),
      VRAM0_RAM_A_WAIT => '0',
      DBG_DEADLINE_MISS => open, DBG_FIFO_OVERFLOW => open,
      VRAM0_RAM_A_LINE_REFILL => open, VRAM0_RAM_A_LINE_DO => (others => '0'),

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

      CD_EN => '1', CD_RAM_A => cd_ram_a, CD_RAM_DO => cd_ram_do,
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

   -- 2026-09-06: 720p60 output (see hdmi_pll instance above). Vertical
   -- scale stays the existing fixed 2x line-double (pce2hdmi_sd.sv's own cy[0]==0
   -- check) -- fills roughly the top 484 of 720 active lines, real picture but
   -- letterboxed, not a full-height scale. Horizontal fill is automatic (the
   -- module's Bresenham stretch already targets SCREEN_WIDTH generically).
   hdmi_out: pce2hdmi_sd
   generic map (
      VIDEOID       => 4,        -- CEA-861 1280x720p60
      CLKFRQ        => 73750,    -- kHz, matches the real 720p PLL's actual clk_pixel
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
