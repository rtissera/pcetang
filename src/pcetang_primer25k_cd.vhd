-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Phase 2 CD, Tang Primer 25K, TangCore-integrated (iosys_bl616: ROM
-- load, joypad, OSD via pce2hdmi_sd's scandoubler), NO_CD=>0, EXT_VRAM0=>1 (required --
-- Primer 25K's whole engine does not fit on-chip). SOLE Primer 25K build as of
-- 2026-08-30 -- the plain, HuCard-only variant (pcetang_primer25k.vhd/
-- build_primer25k.tcl) is retired, same shape as Console 60K's and Nano 20K's own
-- plain->combo unification: a real PCE-CD unit boots plain HuCards fine with no CD
-- inserted, this build's port list and pin file (pcetang_primer25k.cst, which stays,
-- genuinely shared) are identical to the plain board's, and the real resource cost of
-- keeping CD is +1 BSRAM block for a full functional superset.
--
-- PRIOR REAL STATUS (superseded by the change below): FAILED, ERROR (RP0006) LUT overflow
-- (60649/23040 default, 49449/23040 with a direct-GowinSynthesis `-ram_rw_check 0`
-- invocation gw_sh's own `set_option` cannot express). Root cause, directly confirmed (not
-- inferred): BSRAM exhaustion cascading into LUT fallback -- every sub-piece (bare CD
-- engine, iosys alone, video alone) independently drove Primer 25K's 56-block BSRAM
-- ceiling to 54-56/56, and combined real demand exceeded it. Confirmed by measurement:
-- shrinking the on-chip cart ROM buffer alone (it was a dpram, see below) dropped the
-- result to a clean `Logic 18230/23040 (80%), BSRAM 56/56 (100%)` -- the capacity thesis
-- was measured, not a plan. See docs/ARCHITECTURE.md's "Goal revised" section for the
-- full investigation.
--
-- REAL gw_sh-VERIFIED (2026-08-26): the on-chip cart/syscard ROM buffer (a dpram, one of
-- the two BSRAM-heavy pieces above) was replaced by a bridge to `sdram.sv`'s port B,
-- which was already built but never wired to anything. Port B was given a real write
-- side (`RAM_B_WE`/`RAM_B_DI`, added to sdram.sv itself -- authorized surgery per the
-- active goal) so the same port serves both ROM loading (write, from iosys_bl616) and
-- gameplay fetch (read, from pce_top's ROM_RD/ROM_A/ROM_DO/ROM_RDY) -- the two never
-- overlap in time, so no arbitration is needed, just a static mux on rom_loading_r. Both
-- directions use the same small settle-then-wait bridge FSM (see rd_state/wr_state
-- below). Full `gw_sh` PnR: `Logic 14031/23040 (61%), BSRAM 56/56 (100%)`, 0 setup/hold
-- violations across 28953 endpoints, every clock's Fmax beats its constraint. See
-- docs/ARCHITECTURE.md's "Goal revised" section for the full result.
--
-- REAL gw_sh-VERIFIED (2026-08-27): `ROM_SZ` changed from `x"008"` (32K HuCard decode) to
-- `x"040"` (256K, the real syscard3.pce size) so the CPU actually addresses the full
-- syscard rather than a 32KB mirror of it. Address map re-split 3 ways (VRAM0 at
-- 0x000000, CD-RAM at 0x010000, ROM at 0x050000 -- see the constants' own comments).
-- `Logic 14002/23040 (61%), BSRAM 56/56 (100%)`, 0 setup/hold violations across 28935
-- endpoints. See docs/ARCHITECTURE.md's "Real syscard boot" Part 1 section.
--
-- CURRENT CHANGE (2026-08-27, NOT YET gw_sh-VERIFIED): CD-RAM given real backing. `CD_EN`
-- was still `'0'` and `CD_RAM_*` still open/stubbed after the ROM fix above -- with
-- `CD_EN` low, `pce_top.vhd`'s CD subsystem was inert, and syscard code that issues any
-- SCSI command (real syscard BIOS does almost immediately) would get no response. This
-- change: `CD_EN => '1'`, and `CD_RAM_A/DO/DI/RD/WR` bridged through a new third SDRAM
-- port (`sdram.sv`'s port C, added for this -- see that file's header) instead of the
-- on-chip dpram the donor assumes -- CD-RAM's decode window is 256KB (`cd.vhd`'s own
-- `RAM_SEL`, `0x68`-`0x87` in 8KB units, confirmed from source), too big for any
-- remaining BSRAM (0 free blocks). Unlike ROM, CD-RAM has no wait-state path of its own
-- in the donor (`CD_RAM_DI` muxes into the CPU read path combinationally) and genuinely
-- overlaps VRAM0/ROM traffic in time (accessed live during gameplay, not just once at
-- load) -- so this needed a real new `CD_RAM_RDY` port on `pce_top.vhd` (ANDed into
-- `WAIT_N` alongside `ROM_RDY`) and a real arbitrated third SDRAM client, not another
-- static mux like the ROM bridge. See `sdram.sv`'s header for the arbitration priority
-- (A > B > C > refresh) and a flagged, not-yet-measured refresh-starvation risk.
--
-- CD_BRIDGE (2026-08-31): the real SCSI target is now `cd_bridge.vhd` (shared across all
-- 3 boards) -- see that file's own header for the full command decode/protocol trace
-- (TEST UNIT READY, REQUEST SENSE, and a real READ(6) data path, verified against
-- Mednafen's pce_fast/pcecd_drive.cpp). No MCU-side mount/TOC/sector protocol exists yet
-- (see pcetang_cd_scsi_plan.md), so DISC_MOUNTED stays '0' here and READ(6) is real but
-- inert until that lands. What IS real: `gw_sh` confirms this closes timing and fits,
-- which is the first checkable fact about it.
--
-- AUDIO (2026-08-27): PSG_SL/PSG_SR/CDDA_SL/CDDA_SR/ADPCM_S wired real (previously
-- open) into pce2hdmi_sd's already-existing psg_sl/psg_sr/cdda_sl/cdda_sr/adpcm_s
-- ports -- same pattern as pcetang_console60k_cd.vhd (that file's header has the real
-- caveats: summed only, no resampling, no CDC synchronizer across clk_pce/clk_audio,
-- audio correctness itself unstarted). Every prior margin number in this file's
-- header predates this and excluded PSG's real measured cost.
--
-- HDMI/UART pins reused directly from nand2mario's own nestang primer25k.cst (this
-- board, his own working config) rather than adapted from a different board/protocol
-- like Console 60K's guess -- higher confidence, still not hardware-verified here.
--
-- NOT VERIFIED ON HARDWARE. See docs/ARCHITECTURE.md's status note.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_primer25k_cd is
   port (
      clk           : in    std_logic;                      -- 50 MHz crystal
      key_reset_n   : in    std_logic;                       -- H11/S1, active HIGH while held (name is a misnomer, see reset_n below)

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

      tmds_clk_n  : out   std_logic;
      tmds_clk_p  : out   std_logic;
      tmds_d_n    : out   std_logic_vector(2 downto 0);
      tmds_d_p    : out   std_logic_vector(2 downto 0);

      uart_rxd    : in    std_logic;
      uart_txd    : out   std_logic;

      leds_n      : out   std_logic_vector(1 downto 0)
   );
end entity;

architecture rtl of pcetang_primer25k_cd is

   component console60k_pll is
      port (
         clkin     : in  std_logic;
         reset     : in  std_logic;
         clk_pce   : out std_logic;
         clk_sdram : out std_logic;
         lock      : out std_logic
      );
   end component;

   component pcetang_console60k_hdmi_pll_480p is
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
         -- PCE PORT (2026-08-28): 4-word VRAM0 line-refill -- see sdram.sv's own header
         -- and pcetang_primer25k.vhd's identical note. Tied off here too (not yet wired
         -- end-to-end on this board either).
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
         -- client (VRAM1/SGX, not used on this board) -- see sdram.sv's own header. Tied
         -- off explicitly below, same mixed-language-boundary rationale as every other
         -- RAM_C_*/RAM_A_LINE_REFILL tie-off in this file (real EX4232 error otherwise).
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

   signal vram0_ram_a_addr : std_logic_vector(20 downto 0);
   signal vram0_ram_a_req  : std_logic;
   signal vram0_ram_a_rd_n : std_logic;
   signal vram0_ram_a_di   : std_logic_vector(15 downto 0);
   signal vram0_ram_a_do   : std_logic_vector(15 downto 0);
   signal vram0_ram_a_wait : std_logic;

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
   signal rom_loading_r : std_logic := '0';

   -- Cart/syscard ROM now lives off-chip in SDRAM via sdram.sv's port B (was an on-chip
   -- dpram -- that BSRAM was one of the two blocks pushing this build's combined BSRAM
   -- demand to 56/56, cascading into the RP0006 LUT overflow; see docs/ARCHITECTURE.md's
   -- "Goal revised" section for the measured root cause). NOT YET gw_sh-verified -- see
   -- this file's header.
   --
   -- PCE PORT (2026-08-29): "Phase 3" arrived -- sdram.sv's address bus is now 25 bits
   -- (32MB), not 21 (2MB), real chip capacity confirmed (Winbond W9825G6KH-6, 256Mbit,
   -- 4 banks -- see that file's own header). The 4-way split below keeps the original
   -- three regions at their ORIGINAL offsets (still well inside the first 2MB, no reason
   -- to move them) and adds Arcade Card RAM as a real, separate, non-overlapping 2MB
   -- window rather than the aliasing hack this comment used to flag as a future problem.
   --   0x000000-0x00FFFF (64KB):  VRAM0 (port A). Real footprint, not a guess -- traced
   --                              to vram0_cache.vhd's own seq_addr (15-bit word address,
   --                              15+1=16 address bits = 64KB), matching real PCE VRAM0
   --                              (32K x 16-bit).
   --   0x010000-0x04FFFF (256KB): CD-RAM (pce_top's CD_RAM_A window, "1000"&CPU_A(17:0)).
   --                              Now wired via sdram.sv's third port (C), see the cd_ram_*/
   --                              cdr_* signals below. 256KB confirmed against cd.vhd's own
   --                              RAM_SEL decode (0x68-0x87 in 8KB units = 256KB), not just
   --                              pce_top's own window width.
   --   0x090000-0x0AFFFF (128KB): ADPCM RAM (see ADPCM_SDRAM_BASE below).
   --   0x200000-0x3FFFFF (2MB):   Arcade Card RAM (AC_SDRAM_BASE below) -- placed at the
   --                              2MB boundary, well past the ~448KB the other three
   --                              regions use combined, real headroom either side.
   --   0x400000-0x7FFFFF (4MB):   cart/syscard ROM (this constant, used below).
   --                              MOVED + WIDENED AGAIN 2026-08-30 (real lever 19 fix,
   --                              was a 1MB window at 0x0B0000 from lever 17): Street
   --                              Fighter II' Champion Edition is a genuine 2560KB
   --                              HuCard using pce_top.vhd's own already-real bank-
   --                              switch mapper (rombank, rom_sz=X"280" -- verified real,
   --                              latches on writes to ROM offset 0x1FF0, matches real
   --                              SF2' cartridge hardware, zero RTL change needed there).
   --                              The old 1MB window/counter couldn't even COUNT past
   --                              1MB during load. Moved past Arcade Card RAM's own 2MB
   --                              window (the old gap before it was only ~1.4MB, too
   --                              small for 4MB) -- this chip is the real 32MB Winbond
   --                              W9825G6KH-6, trivial capacity margin here.
   constant CDRAM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#010000#, 25);
   constant ROM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#400000#, 25);
   constant ROM_SDRAM_ABITS : integer := 22;  -- 4MB, real SF2' ceiling (dynamic, see rom_sz_r)
   -- ADPCM RAM offload (2026-08-27): one nibble per SDRAM byte (avoids read-modify-write,
   -- which would double port-C's transaction count and interleave badly with CD-RAM
   -- sharing the same port -- see cd.vhd's ADPCM_RAM_* header). 128KB region, doubling
   -- the real 64KB (128Kx4) ADPCM_DRAM capacity.
   constant ADPCM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#090000#, 25);
   -- PCE PORT (2026-08-29): real Arcade Card RAM window -- see the header comment above
   -- and AC_RAM_A/AC_EN below. AC_RAM_A (arcade.sv) is 21 bits (2MB), fits exactly.
   constant AC_SDRAM_BASE     : unsigned(24 downto 0) := to_unsigned(16#200000#, 25);

   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal rom_sz_r    : std_logic_vector(11 downto 0) := x"040";
   -- Core reset gated on rom_loading (2026-08-30, real lever 17 fix -- same fix as
   -- Nano 20K CD's/Console 60K CD's own core_resetn). Previously this board's `RESET`
   -- was tied only to `reset_n` (power-on/manual reset), NOT gated during ROM load --
   -- a real latent gap the file's own stale comment near the port-B mux falsely
   -- claimed was already handled. Harmless at a fixed, fast 256K load; not safe once
   -- ROM_SZ is genuinely dynamic and the core must not see a mid-load size. Held in
   -- reset through the whole load, released exactly on loading's falling edge, same as
   -- the other two boards.
   signal core_resetn : std_logic := '0';

   -- Shared SDRAM port-B request/response, muxed between the read bridge (gameplay,
   -- pce_top's ROM_RD/ROM_A/ROM_DO/ROM_RDY) and the write bridge (loading, iosys_bl616's
   -- rom_do/rom_do_valid). The two never run concurrently -- the core sits in reset for
   -- the whole load -- so there is no real arbitration, just a static mux on rom_loading_r.
   signal romb_addr : std_logic_vector(24 downto 0);
   signal romb_req  : std_logic := '0';
   signal romb_we   : std_logic := '0';
   signal romb_di   : std_logic_vector(7 downto 0);
   signal romb_do   : std_logic_vector(7 downto 0);
   signal romb_wait : std_logic;

   type romb_state_t is (RB_IDLE, RB_SETTLE, RB_WAIT);

   -- Read side (gameplay fetch, one pce_top ROM_RD per byte)
   signal rd_state       : romb_state_t := RB_IDLE;
   signal rd_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal rd_req         : std_logic := '0';
   signal rd_addr        : std_logic_vector(24 downto 0);

   -- Write side (ROM load, one rom_do_valid pulse per byte)
   signal wr_state       : romb_state_t := RB_IDLE;
   signal wr_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal wr_req         : std_logic := '0';
   signal wr_addr        : std_logic_vector(24 downto 0);
   signal wr_data        : std_logic_vector(7 downto 0);

   -- CD-RAM bridge: pce_top's CD_RAM_A/CD_RAM_DO/CD_RAM_DI/CD_RAM_RD/CD_RAM_WR through
   -- sdram.sv's new third port (C). Unlike the ROM bridge (port B, toggle-per-request),
   -- port C is level-held like port A -- assert and hold RAM_C_REQ through the whole
   -- transaction, drop it once done -- see sdram.sv's header for why. CD_RAM has no wait
   -- path of its own in the donor (pce_top.vhd's CD_RAM_DI muxes in combinationally), so
   -- this bridge's "ready" signal (cd_ram_rdy) is wired to pce_top's new CD_RAM_RDY input,
   -- which now contributes to WAIT_N the same way ROM_RDY already does.
   signal cd_ram_a     : std_logic_vector(21 downto 0);
   signal cd_ram_do    : std_logic_vector(7 downto 0);  -- pce_top's CD_RAM_DO (out of pce_top): write data
   signal cd_ram_di_i  : std_logic_vector(7 downto 0) := (others => '0');  -- into pce_top's CD_RAM_DI: read data
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

   -- ADPCM RAM bridge: shares this same port-C hardware/FSM with CD-RAM above (Opus-
   -- agent-recommended design -- see docs/ARCHITECTURE.md -- arbitrating here in the
   -- clk_pce-domain bridge, NOT inside sdram.sv's own arbiter, keeps clk_sdram's
   -- timing-critical STATE_IDLE chain untouched). CD-RAM wins ties: it directly stalls
   -- the CPU via CD_RAM_RDY/WAIT_N, while ADPCM's own DRAM_CLKEN wait-gate (cd.vhd)
   -- tolerates real slack (~420ns/slot budget vs ~83ns SDRAM round trip). Both share
   -- port C's single cache line (last_a[2] in sdram.sv) -- a bandwidth question only
   -- (a miss just refetches), not a correctness one; no prefetch/anti-thrash buffer
   -- added yet -- measure real contention before adding one.
   signal adpcm_ram_a_i     : std_logic_vector(16 downto 0);
   signal adpcm_ram_do_i    : std_logic_vector(3 downto 0);
   signal adpcm_ram_we_i    : std_logic;
   signal adpcm_ram_req_i   : std_logic;
   signal adpcm_ram_slot_cnt_i : std_logic_vector(1 downto 0);
   signal adpcm_ram_di_i    : std_logic_vector(3 downto 0) := (others => '0');
   signal adpcm_ram_ready_i : std_logic := '1';
   -- Edge basis is ADPCM_RAM_SLOT_CNT changing, NOT ADPCM_RAM_REQ's own level -- a byte
   -- write spans two consecutive WRITE slots at two different addresses, and REQ (a
   -- level, "does the current slot need real work") never drops between them, so
   -- edge-detecting REQ itself would launch the first nibble's write and silently drop
   -- the second. DRAM_SLOT_CNT changes on every slot boundary regardless of decoded
   -- slot type -- see cd.vhd's ADPCM_RAM_SLOT_CNT comment for the full trace.
   signal adpcm_slot_cnt_r  : std_logic_vector(1 downto 0) := (others => '0');

   type cdr_owner_t is (OWNER_NONE, OWNER_CDRAM, OWNER_ADPCM);
   signal cdr_owner : cdr_owner_t := OWNER_NONE;
   signal cd_pend, adpcm_pend : std_logic := '0';

   -- Real SCSI target (cd_bridge.vhd, shared across all 3 boards, 2026-08-31) -- see that
   -- file's own header for the full command decode/protocol trace. cd.vhd/SCSI.vhd
   -- (unmodified from the donor) own the real SCSI bus phase timing; cd_bridge just
   -- answers CD_COMM_SEND with a response, same clk_pce domain, no CDC needed (SCSI.vhd
   -- lives inside pce_top, same CLK).
   signal cd_stat_i      : std_logic_vector(7 downto 0);
   signal cd_msg_i       : std_logic_vector(7 downto 0);
   signal cd_stat_get_i  : std_logic;
   signal cd_comm_i      : std_logic_vector(95 downto 0);
   signal cd_comm_send_i : std_logic;
   signal cd_data_i      : std_logic_vector(7 downto 0);
   signal cd_data_wr_i   : std_logic;
   signal cd_data_end_i  : std_logic;

   -- MEASUREMENT ONLY (2026-08-30), NOT A REAL FEATURE -- do not build on this.
   -- Same real toggling signal as Console 60K CD's own (see that file's identical
   -- comment) to force CD_AUDIO_WR non-constant so CDDA_FIFO can't be swept dead --
   -- measuring THIS device's (GW5A) real BSRAM/LUT cost of a live CDDA_FIFO (now
   -- shrunk 4096->2048/512->256, see cd_fifos.vhd) before any real design decision.
   -- Leave in place until a real decision is made; do not revert without being asked.
   signal meas_cdda_toggle : std_logic := '0';

   signal video_r, video_g, video_b : std_logic_vector(2 downto 0);
   signal video_ce, video_hs, video_vs, video_hbl, video_vbl : std_logic;

   signal joy_out : std_logic_vector(1 downto 0);
   signal joy_in  : std_logic_vector(3 downto 0);

   signal psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s : signed(15 downto 0);

   -- Sticky latches (2026-08-27, per an independent Fable-model audit's P3) -- see
   -- pcetang_nano20k.vhd's identical comment for why (raw pce_top pulses are invisible
   -- on a real LED at clk_pce rate).
   signal dbg_deadline_miss   : std_logic;
   signal dbg_fifo_overflow   : std_logic;
   signal dbg_deadline_miss_r : std_logic := '0';
   signal dbg_fifo_overflow_r : std_logic := '0';

   signal brm_a  : std_logic_vector(10 downto 0);
   signal brm_di : std_logic_vector(7 downto 0);
   signal brm_do : std_logic_vector(7 downto 0);
   signal brm_we : std_logic;

begin

   -- key_reset_n is misnamed: same H11/PULL_MODE=DOWN pin as pcetang_primer25k.vhd
   -- (shares its .cst), so the raw pin is active-HIGH-while-pressed. See that file's
   -- matching comment for the real schematic/hardware confirmation.
   reset_n <= (not key_reset_n) and pll_lock and hdmi_pll_lock;

   pll: console60k_pll
   port map (clkin => clk, reset => key_reset_n, clk_pce => clk_pce,
             clk_sdram => clk_sdram, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll_480p
   port map (clkin => clk, reset => key_reset_n, clk_pixel => clk_pixel,
             clk_5x_pixel => clk_5x_pixel, lock => hdmi_pll_lock);

   -- Same init-hold shape as NECTang's own primer25k_core_test.vhd.
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
      -- PCE PORT (2026-08-29): zero-extended, not widened -- VRAM0 stays within the
      -- first 2MB (bank 0) -- see sdram.sv's own port widening note.
      RAM_A_ADDR => "0000" & vram0_ram_a_addr,
      RAM_A_REQ  => vram0_ram_a_req,
      RAM_A_RD_n => vram0_ram_a_rd_n,
      RAM_A_DI   => vram0_ram_a_di,
      RAM_A_DO   => vram0_ram_a_do,
      RAM_A_WAIT => vram0_ram_a_wait,
      RAM_A_LINE_REFILL => '0', RAM_A_LINE_DO => open,
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

   -- Static mux: write bridge (load) owns port B while rom_loading_r is set, read bridge
   -- (gameplay fetch) owns it otherwise. The two are never both active -- pce_top's CLK is
   -- held in core_resetn's reset for the entire load, so ROM_RD cannot fire during it.
   romb_addr <= wr_addr when rom_loading_r = '1' else rd_addr;
   romb_req  <= wr_req  when rom_loading_r = '1' else rd_req;
   romb_we   <= '1'     when rom_loading_r = '1' else '0';
   romb_di   <= wr_data;

   joy1_ds2 <= (others => '0');
   joy1     <= joy1_ds2 or hid1(11 downto 0);
   joy2     <= hid2(11 downto 0);

   sys_inst: iosys_bl616
   generic map (
      FREQ => 42_857_000,
      COLOR_LOGO => "011000000001000",
      CORE_ID => x"0003",
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
         -- core_resetn's reset (above), so pce_top never sees a mid-load ROM_SZ.
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

   -- ROM write bridge: one iosys_bl616 byte (rom_do/rom_do_valid, arriving at UART rate --
   -- far slower than this FSM's few-cycle turnaround, confirmed by reading
   -- src/iosys/iosys_bl616.v directly rather than assumed) becomes one real SDRAM write via
   -- port B. See romb_* mux above and the read bridge below for the shared settle-window
   -- rationale (both are the same pattern, read and write).
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
               -- clk_sdram (120 MHz) is ~2.8x clk_pce (42.857 MHz); 4 clk_pce cycles is
               -- >10x margin for sdram.sv to either latch a cache hit or start asserting
               -- romb_wait for a real fetch -- see docs/ARCHITECTURE.md.
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
   -- SDRAM read via port B (which has its own small line cache in sdram.sv, so sequential
   -- fetches -- the common case -- mostly hit there rather than round-tripping SDRAM every
   -- byte). ROM_RDY is held low (stalling the CPU via pce_top's WAIT_N path -- see
   -- HUC6280.vhd's WAIT_N handling, no timeout, verified architecturally sound) until the
   -- byte is ready.
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

   -- CD-RAM + ADPCM RAM bridge: pce_top's CD_RAM_RD/CD_RAM_WR (raw bus-decode signals,
   -- level-held for the duration of a real CPU access) and ADPCM_RAM_REQ (level-held for
   -- one DRAM_CLKEN slot, ~420ns, see cd.vhd) both become SDRAM accesses via the same
   -- shared port C, one at a time, CD-RAM winning ties. Edge-detected (cdram_rd_r/
   -- cdram_wr_r/adpcm_req_r) rather than level-checked, to avoid re-triggering a second
   -- transaction while the request signal is still held through the wait this bridge
   -- itself introduces. A request that arrives while the other owner is mid-transaction
   -- latches into cd_pend/adpcm_pend (state-independent, set the same cycle as the edge
   -- regardless of what cdr_state/cdr_owner currently is) and is served as soon as
   -- cdr_owner returns to OWNER_NONE. cd_ram_rdy_i/adpcm_ram_ready_i drop to '0' in that
   -- same state-independent block -- not only when the FSM actually launches the
   -- transaction -- so a request queued behind the other owner correctly stalls its
   -- caller for the full wait, not just from the moment it happens to reach the front.
   -- RAM_C is level-held/assert-and-hold (port A's convention), not port B's
   -- toggle-per-request one -- see sdram.sv's header.
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
                  -- PCE PORT (2026-08-29): real Arcade Card RAM support -- see
                  -- pcetang_console60k_cd.vhd's identical comment (copied, not
                  -- re-derived) for the full decode rationale: cd_ram_a's own bit 21
                  -- distinguishes AC ('0', pce_top.vhd's `'0' & AC_RAM_A`) from real
                  -- CD-RAM/backup-RAM ('1', `"1000" & CPU_A(17:0)`).
                  if cd_ram_a(21) = '0' then
                     cdr_addr <= std_logic_vector(AC_SDRAM_BASE +
                                 resize(unsigned(cd_ram_a(20 downto 0)), 25));
                  else
                     cdr_addr <= std_logic_vector(CDRAM_SDRAM_BASE +
                                 resize(unsigned(cd_ram_a(17 downto 0)), 25));
                  end if;
                  cdr_rd_n <= not cd_ram_wr;   -- '0' read, '1' write -- matches RAM_x_RD_n
                  cdr_di   <= cd_ram_do;       -- pce_top's CD_RAM_DO: the byte it's writing
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

   -- Real SCSI target -- see cd_bridge.vhd's own header for the full command decode/
   -- protocol trace. DISC_MOUNTED/SECTOR_* left at their real default -- no MCU-side
   -- mount/TOC/sector protocol exists yet (see pcetang_cd_scsi_plan.md).
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
      CD_DATA_END  => cd_data_end_i
   );

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   -- PCE PORT (2026-08-29): VRAM0_CG_PREFETCH => 1, same as Primer 25K plain -- see
   -- pcetang_primer25k.vhd's own comment and vram0_prefetch.vhd's header for the
   -- design/verification. Not yet gw_sh-measured on THIS board specifically before
   -- this port (CD's SCSI/ADPCM/CD-RAM SDRAM port-C traffic differs from plain's) --
   -- see this session's own build log for the real result.
   core: entity work.pce_top
   generic map (LITE => 1, EXT_VRAM0 => 1, NO_CD => 0, VRAM0_LINE_REFILL => 1,
                VRAM0_PREFETCH => 1, VRAM0_CG_PREFETCH => 1)
   port map (
      RESET      => not core_resetn,
      COLD_RESET => not core_resetn,
      CLK        => clk_pce,

      VRAM0_RAM_A_ADDR => vram0_ram_a_addr,
      VRAM0_RAM_A_REQ  => vram0_ram_a_req,
      VRAM0_RAM_A_RD_N => vram0_ram_a_rd_n,
      VRAM0_RAM_A_DI   => vram0_ram_a_di,
      VRAM0_RAM_A_DO   => vram0_ram_a_do,
      VRAM0_RAM_A_WAIT => vram0_ram_a_wait,
      DBG_DEADLINE_MISS => dbg_deadline_miss, DBG_FIFO_OVERFLOW => dbg_fifo_overflow,
      -- PCE PORT (2026-08-28): 4-word VRAM0 line-refill -- not enabled on this build
      -- yet (out of the goal this was built for: plain PCE, no CD); tied off, same
      -- pattern as every other board that hasn't opted in.
      VRAM0_RAM_A_LINE_REFILL => open, VRAM0_RAM_A_LINE_DO => (others => '0'),

      ROM_RD    => rom_rd_i,
      ROM_RDY   => rom_rdy_i,
      ROM_A     => rom_a,
      ROM_DO    => rom_do_i,
      ROM_SZ    => rom_sz_r,  -- dynamic 128K-1MB real HuCard bucket, see rom_sz_r above
      ROM_POP   => '0',
      ROM_CLKEN => open,

      BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => brm_do, BRM_WE => brm_we,

      GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

      SP64 => '0', SGX => '0',

      JOY_OUT => joy_out, JOY_IN => joy_in,

      CD_EN => '1', CD_RAM_A => cd_ram_a, CD_RAM_DO => cd_ram_do,
      CD_RAM_DI => cd_ram_di_i, CD_RAM_RD => cd_ram_rd, CD_RAM_WR => cd_ram_wr,
      CD_RAM_RDY => cd_ram_rdy_i,

      ADPCM_RAM_A => adpcm_ram_a_i, ADPCM_RAM_DO => adpcm_ram_do_i,
      ADPCM_RAM_WE => adpcm_ram_we_i, ADPCM_RAM_REQ => adpcm_ram_req_i,
      ADPCM_RAM_SLOT_CNT => adpcm_ram_slot_cnt_i,
      ADPCM_RAM_DI => adpcm_ram_di_i, ADPCM_RAM_READY => adpcm_ram_ready_i,
      -- PCE PORT (2026-08-29): '0'->'1' -- real, non-aliasing 2MB SDRAM window now
      -- exists (AC_SDRAM_BASE, see that constant's own comment).
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
      CD_DATA => cd_data_i, CD_DATA_WR => cd_data_wr_i, CD_AUDIO_WR => meas_cdda_toggle,
      CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end_i, CD_DM => '0',

      CDDA_SL => cdda_sl, CDDA_SR => cdda_sr, ADPCM_S => adpcm_s, PSG_SL => psg_sl, PSG_SR => psg_sr,

      BG_EN => '1', SPR_EN => '1', GRID_EN => (others => '0'), CPU_PAUSE_EN => '0',

      BORDER_EN => '0', ReducedVBL => '0',
      VIDEO_R => video_r, VIDEO_G => video_g, VIDEO_B => video_b,
      VIDEO_BW => open, VIDEO_CE => video_ce, VIDEO_CE_FS => open,
      VIDEO_VS => video_vs, VIDEO_HS => video_hs,
      VIDEO_HBL => video_hbl, VIDEO_VBL => video_vbl
   );

   -- Reads from joy_active (real per-player mux, see its own header comment
   -- above), not directly from joy1 -- joy_port selects which real player's
   -- HID state is currently active.
   joy_in <= joy_active(4) & joy_active(5) & joy_active(11) & joy_active(10) when joy_out(0) = '1' else
             joy_active(3) & joy_active(2) & joy_active(1)  & joy_active(0);

   hdmi_out: pce2hdmi_sd
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

   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         dbg_deadline_miss_r <= dbg_deadline_miss_r or dbg_deadline_miss;
         dbg_fifo_overflow_r <= dbg_fifo_overflow_r or dbg_fifo_overflow;
      end if;
   end process;

   leds_n(0) <= not dbg_deadline_miss_r;
   leds_n(1) <= not dbg_fifo_overflow_r;

   -- MEASUREMENT ONLY -- see meas_cdda_toggle's own declaration comment above.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         meas_cdda_toggle <= not meas_cdda_toggle;
      end if;
   end process;

end architecture;
