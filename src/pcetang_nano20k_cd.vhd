-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- pcetang Phase 1: Tang Nano 20K, TangCore-integrated (iosys_bl616: ROM load, joypad,
-- OSD), full PCE+PCE-CD combo (NO_CD=>0), EXT_VRAM0=>1 (Nano 20K's whole engine does
-- not fit on-chip). SOLE Nano 20K build as of 2026-08-30 -- the plain, HuCard-only
-- variant (pcetang_nano20k.vhd/build_nano20k.tcl) is retired now that this file has
-- real feature parity plus CD, mirroring Console 60K's own plain->combo unification
-- (`2108d6b`). ROM, CD-RAM, ADPCM RAM, and Arcade Card RAM are all offloaded to the
-- on-package SDRAM (sdram32.sv), scandoubler HDMI (pce2hdmi_sd.sv, same -11-BSRAM-block
-- swap already banked on Primer 25K plain, commit 0db5950).
--
-- Real history, not reference-only: the FIRST attempt at this file (see
-- pcetang_nano20k_cd_attempt.md) hit two real walls -- touching sdram32.sv at all broke
-- plain Nano 20K's BAT+CG margin via placement noise, and the CD build itself hit a hard
-- BSRAM ceiling (46/46) plus a real -9.7% clk_pce timing miss even with BAT/CG disabled
-- -- and was reverted. Retried successfully 2026-08-30 (`0c3aec0`) once two things
-- changed: the alternate PnR algorithm (place_option 2/route_option 1, see
-- pcetang_status_matrix.md lever 13) recovered real margin project-wide, and ROM also
-- moved off on-chip BRAM onto SDRAM (own owner in the port-B arbiter below), freeing the
-- same ~13 real BSRAM blocks the plain board's own ROM move freed. BAT+CG0/CG1 enabled
-- and fits too (`afe0b90`), closing the same VRAM0 deadline-miss gap the plain board had
-- (on-package SDRAM has the same real ACTIVE/CAS/precharge latency class as off-chip
-- SDRAM -- confirmed by this exact bug already existing on Nano 20K plain pre-dating
-- either CD attempt, not assumed).
--
-- REAL, NAMED SCOPE (2026-08-29): sdram32.sv widened 21->23 bits (2MB->8MB, real chip
-- confirmed 8MB die from that file's own header, an existing ZX Next port fact, not
-- newly researched this session) and given a real bank register (was hardcoded 2'b00)
-- plus write support on port B (was read-only) -- see sdram32.sv's own header for the
-- full rationale and the line-refill/bank-interleaving safety argument. CD-RAM, ADPCM
-- RAM, and Arcade Card RAM are all bridged through that one newly-write-capable port B,
-- arbitrated at the board level below (mirrors Primer 25K CD's own port-C arbiter
-- design, adapted to port B's toggle-per-request protocol instead of assert-and-hold --
-- see the b_owner_t process below).
--
-- Real, explicit exclusions, not oversights:
--   - ROM: moved to SDRAM (2026-08-30, was on-chip in the first attempt) -- same bridge
--     pattern as pcetang_nano20k.vhd's own ROM-to-SDRAM move, own base address
--     (ROM_SDRAM_BASE below) chosen to not collide with CD-RAM/ADPCM/Arcade-Card's own
--     bases. A real syscard (256KB) now fits capacity-wise; CD boot itself is still
--     untested (SCSI stub never run against a real syscard BIOS, same as every other
--     board).
--   - SGX/VRAM1: out of scope -- see the Nano 20K CD/SGX feasibility note in
--     pcetang_status_matrix.md (SGX fails on BSRAM+CLS even before this board's own
--     margin is considered). LITE=>1, SGX=>'0'.
--   - CDDA_FIFO/CDSUBC_FIFO: kept dead-stubbed (CD_AUDIO_WR/CD_SUBCD_WR => '0'), per
--     direct user instruction -- same state as every other board today. 128Kbit/4Kbit,
--     unpriced, deferred.
--   - BAT+CG0/CG1 prefetch (VRAM0_PREFETCH/VRAM0_CG_PREFETCH): ON (2026-08-30), retried
--     after being off in the first attempt (saturated the device then: 100% CLS, 100%
--     BSRAM, 223 unplaced registers, before real place-and-route even completed). See
--     the `core: entity work.pce_top` generic map's own comment below for why this is
--     being retried now and what real precedent it rests on.
--   - SCSI target stub: copied verbatim from Primer 25K CD (same spec-verified design,
--     Mednafen-checked sense data) even though no syscard can load yet -- costs nothing
--     extra to wire now, and makes a future ROM-offload addition immediately usable.
--
-- Video: `pce2hdmi_sd.sv` runs VIDEOID=>2/CLKFRQ=>27000/SCREEN_WIDTH=>720/
-- SCREEN_HEIGHT=>480 -- 480p60, using the SAME clk_27/clk_135 pair the retired plain
-- board already generated (confirmed by reading src/pce/common/pll/nano20k_pll.vhd
-- directly: clk_sdram <= clk_135_i, the SAME net as HDMI's clk_135 -- GW2AR-18C has
-- exactly 2 PLL resources, both spent, no separate 720p pixel clock ever existed here
-- to move away from the way Console 60K's plain/CD swap had to).
--
-- NOT VERIFIED ON HARDWARE.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_nano20k_cd is
   port (
      clk           : in    std_logic;                      -- 27 MHz crystal
      reset         : in    std_logic;                       -- S1, active low

      O_sdram_clk   : out   std_logic;
      O_sdram_cke   : out   std_logic;
      O_sdram_cs_n  : out   std_logic;
      O_sdram_cas_n : out   std_logic;
      O_sdram_ras_n : out   std_logic;
      O_sdram_wen_n : out   std_logic;
      O_sdram_dqm   : out   std_logic_vector(3 downto 0);
      O_sdram_addr  : out   std_logic_vector(10 downto 0);
      O_sdram_ba    : out   std_logic_vector(1 downto 0);
      IO_sdram_dq   : inout std_logic_vector(31 downto 0);

      -- DualShock 2 pads. Pin assignment taken verbatim from nand2mario's own
      -- monitor/src/boards/nano20k.cst. Nano 20K has no PMOD connector -- these are raw
      -- GPIO header pins (17/18/19/20 for pad 1, 52/53/71/72 for pad 2), which is how
      -- the whole TangCore ecosystem wires pads on this board.
      ds_cs       : out   std_logic;                      -- pin 18
      ds_mosi     : out   std_logic;                      -- pin 20
      ds_miso     : in    std_logic;                      -- pin 19
      ds_clk      : out   std_logic;                      -- pin 17
      ds_cs2      : out   std_logic;                      -- pin 72
      ds_mosi2    : out   std_logic;                      -- pin 53
      ds_miso2    : in    std_logic;                      -- pin 71
      ds_clk2     : out   std_logic;                      -- pin 52
      tmds_clk_n  : out   std_logic;
      tmds_clk_p  : out   std_logic;
      tmds_d_n    : out   std_logic_vector(2 downto 0);
      tmds_d_p    : out   std_logic_vector(2 downto 0);

      uart_rxd    : in    std_logic;
      uart_txd    : out   std_logic;

      leds_n      : out   std_logic_vector(1 downto 0)
   );
end entity;

architecture rtl of pcetang_nano20k_cd is

   component nano20k_pll is
      port (
         clkin      : in  std_logic;
         clk_pce    : out std_logic;
         clk_pce_d2 : out std_logic;
         clk_sdram  : out std_logic;
         clk_135    : out std_logic;
         clk_27     : out std_logic;
         lock       : out std_logic
      );
   end component;

   -- PCE PORT (2026-08-29): widened 21->23 bits, real bank, port B write support -- see
   -- sdram32.sv's own header.
   component sdram32 is
      generic ( SAMPLE_SKEW : integer := 3 );
      port (
         clk        : in    std_logic;
         init       : in    std_logic;
         SDRAM_A    : out   std_logic_vector(10 downto 0);
         SDRAM_DQ   : inout std_logic_vector(31 downto 0);
         SDRAM_BA   : out   std_logic_vector(1 downto 0);
         SDRAM_DQM  : out   std_logic_vector(3 downto 0);
         SDRAM_nWE  : out   std_logic;
         SDRAM_nCAS : out   std_logic;
         SDRAM_nRAS : out   std_logic;
         SDRAM_nCS  : out   std_logic;
         SDRAM_CKE  : out   std_logic;
         SDRAM_CLK  : out   std_logic;
         RAM_A_ADDR : in    std_logic_vector(22 downto 0);
         RAM_A_REQ  : in    std_logic;
         RAM_A_RD_n : in    std_logic;
         RAM_A_DI   : in    std_logic_vector(15 downto 0);
         RAM_A_DO   : out   std_logic_vector(15 downto 0);
         RAM_A_WAIT : out   std_logic;
         RAM_A_LINE_REFILL : in    std_logic := '0';
         RAM_A_LINE_DO     : out   std_logic_vector(63 downto 0);
         RAM_B_ADDR : in    std_logic_vector(22 downto 0);
         RAM_B_REQ  : in    std_logic;
         RAM_B_WE   : in    std_logic;
         RAM_B_DI   : in    std_logic_vector(7 downto 0);
         RAM_B_DO   : out   std_logic_vector(7 downto 0);
         RAM_B_WAIT : out   std_logic
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
         -- TEMP DEBUG (2026-09-06): RTL debug-trace channel, tied off on this board --
         -- see iosys_bl616.v's own port comment.
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

   signal clk_pce, clk_pce_d2, clk_sdram, clk_135, clk_27, pll_lock, reset_n : std_logic;
   signal sdram_init : std_logic;

   signal vram0_ram_a_addr : std_logic_vector(20 downto 0);
   signal vram0_ram_a_req  : std_logic;
   signal vram0_ram_a_rd_n : std_logic;
   signal vram0_ram_a_di   : std_logic_vector(15 downto 0);
   signal vram0_ram_a_do   : std_logic_vector(15 downto 0);
   signal vram0_ram_a_wait : std_logic;
   signal vram0_ram_a_line_refill : std_logic;
   signal vram0_ram_a_line_do     : std_logic_vector(63 downto 0);

   signal dbg_deadline_miss   : std_logic;
   signal dbg_fifo_overflow   : std_logic;
   signal dbg_deadline_miss_r : std_logic := '0';
   signal dbg_fifo_overflow_r : std_logic := '0';

   signal overlay       : std_logic;
   signal overlay_x     : std_logic_vector(7 downto 0);
   signal overlay_y     : std_logic_vector(7 downto 0);
   signal overlay_color : std_logic_vector(14 downto 0);
   -- Real DS2 pad reader, vendored from nand2mario's monitor core. Without this the
   -- joypad signals were tied to zero and NOTHING read the pads at all -- the menus
   -- only ever worked because monitor.bin is a different bitstream with its own reader.
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
   signal joy2_ds2      : std_logic_vector(11 downto 0);
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

   -- CD-RAM/ADPCM/Arcade-Card/ROM bridge base addresses -- declared here, ahead of the
   -- ROM signal block below that needs ROM_SDRAM_ABITS, and ahead of the arbiter signal
   -- block further down that needs the others. See that block's own comment for the
   -- full address-map rationale (VHDL requires declaration before use, unlike the
   -- purely-visual ordering this previously had).
   constant CDRAM_SDRAM_BASE : unsigned(22 downto 0) := to_unsigned(16#010000#, 23);
   constant ADPCM_SDRAM_BASE : unsigned(22 downto 0) := to_unsigned(16#090000#, 23);
   constant AC_SDRAM_BASE    : unsigned(22 downto 0) := to_unsigned(16#200000#, 23);
   -- ROM (2026-08-30, real SF2' mapper support, lever 19): moved 0x0C0000->0x400000 and
   -- widened 1MB->4MB (20->22 bits). Real reason: Street Fighter II' Champion Edition is
   -- a genuine 2560KB (2.5MB) HuCard using pce_top.vhd's own already-real bank-switch
   -- mapper (rombank, rom_sz=X"280" -- verified real, latches on writes to ROM offset
   -- 0x1FF0, matches real SF2' cartridge hardware, zero RTL change needed there). The old
   -- 1MB window/counter couldn't even COUNT past 1MB during load, let alone address it.
   -- Placed right after AC_SDRAM_BASE's own 2MB window (was in the gap BEFORE it, too
   -- small for 4MB) -- lands at 0x400000-0x7FFFFF, exactly the top 4MB of this board's
   -- real 8MB chip (sdram32.sv's RAM_B_ADDR is 23 bits = 8MB total), zero slack past the
   -- edge but a real, checked fit, not a guess.
   constant ROM_SDRAM_BASE   : unsigned(22 downto 0) := to_unsigned(16#400000#, 23);
   constant ROM_SDRAM_ABITS  : integer := 22;

   -- ROM: moved to SDRAM, own owner in the port-B arbiter below -- see header's "real,
   -- explicit exclusions" and the address-map comment above.
   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_rd_r    : std_logic := '0';
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal rom_loading_r : std_logic := '0';
   signal rom_sz_r    : std_logic_vector(11 downto 0) := x"040";
   signal core_resetn : std_logic := '0';
   signal rom_pend, rom_pend_we : std_logic := '0';
   signal rom_pend_addr : std_logic_vector(22 downto 0);
   signal rom_pend_di   : std_logic_vector(7 downto 0);

   -- CD-RAM/ADPCM/Arcade-Card bridge, all sharing sdram32.sv's port B (now write-capable)
   -- through a single toggle-per-request arbiter -- mirrors Primer 25K CD's cdr_owner_t
   -- port-C design, adapted to port B's protocol (toggle req/wait, not assert-and-hold).
   -- Address map, within the real 8MB port B now reaches (word_a bank/row/col, see
   -- sdram32.sv's header):
   --   0x000000-0x00FFFF (64KB):  VRAM0 (port A only -- never reaches port B at all).
   --   0x010000-0x04FFFF (256KB): CD-RAM (same base as every GW5A CD board, for
   --                              consistency -- cd.vhd's own RAM_SEL decode, unchanged
   --                              across boards).
   --   0x090000-0x0AFFFF (128KB): ADPCM RAM (one nibble per SDRAM byte, same convention
   --                              as the GW5A CD boards -- see cd.vhd's ADPCM_RAM_* note).
   --   0x0C0000-0x1BFFFF (1MB):   ROM (2026-08-30) -- real HuCard sizes 128K-1MB, same
   --                              dynamic ROM_SZ bucket rounding as pcetang_nano20k.vhd's
   --                              own bridge. Sits in the free gap between ADPCM's own
   --                              end (0x0AFFFF) and bank 1's start (0x200000), with a
   --                              real 256KB safety margin below AC_SDRAM_BASE, not
   --                              flush against it.
   --   0x200000-0x3FFFFF (2MB):   Arcade Card RAM -- lands exactly at the start of bank 1
   --                              (byte address bit 21 = word_a bit 19 = bank[0]), same
   --                              constant value as the GW5A boards' AC_SDRAM_BASE by
   --                              construction, not coincidence.
   -- (base-address constants declared earlier, ahead of the ROM signal block that needs
   -- ROM_SDRAM_ABITS -- see that block's own comment.)

   signal ram_b_addr : std_logic_vector(22 downto 0) := (others => '0');
   signal ram_b_req  : std_logic := '0';
   signal ram_b_we   : std_logic := '0';
   signal ram_b_di   : std_logic_vector(7 downto 0) := (others => '0');
   signal ram_b_do   : std_logic_vector(7 downto 0);
   signal ram_b_wait : std_logic;

   signal cd_ram_a     : std_logic_vector(21 downto 0);
   signal cd_ram_do    : std_logic_vector(7 downto 0);
   signal cd_ram_di_i  : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_ram_rd    : std_logic;
   signal cd_ram_wr    : std_logic;
   signal cd_ram_rdy_i : std_logic := '1';

   signal adpcm_ram_a_i     : std_logic_vector(16 downto 0);
   signal adpcm_ram_do_i    : std_logic_vector(3 downto 0);
   signal adpcm_ram_we_i    : std_logic;
   signal adpcm_ram_req_i   : std_logic;
   signal adpcm_ram_slot_cnt_i : std_logic_vector(1 downto 0);
   signal adpcm_ram_di_i    : std_logic_vector(3 downto 0) := (others => '0');
   signal adpcm_ram_ready_i : std_logic := '1';
   signal adpcm_slot_cnt_r  : std_logic_vector(1 downto 0) := (others => '0');
   signal cdram_rd_r, cdram_wr_r : std_logic := '0';

   type b_owner_t is (OWNER_NONE, OWNER_CDRAM, OWNER_ADPCM, OWNER_ROM);
   signal b_owner : b_owner_t := OWNER_NONE;
   signal cd_pend, adpcm_pend : std_logic := '0';

   type b_state_t is (B_IDLE, B_SETTLE, B_WAIT);
   signal b_state      : b_state_t := B_IDLE;
   signal b_settle_cnt : unsigned(2 downto 0) := (others => '0');

   -- Real SCSI target -- cd_bridge.vhd (shared across all 3 boards, 2026-08-31), replaces
   -- the old per-board hand-written stub. No syscard can load here yet (ROM stays on-chip,
   -- see header), so this cannot be exercised for real until that changes -- wired now
   -- anyway so the rest of the plumbing needs no further change later.
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

   signal psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s : signed(15 downto 0);

   signal brm_a  : std_logic_vector(10 downto 0);
   signal brm_di : std_logic_vector(7 downto 0);
   signal brm_do : std_logic_vector(7 downto 0);
   signal brm_we : std_logic;

begin

   pll: nano20k_pll
   port map (clkin => clk, clk_pce => clk_pce, clk_pce_d2 => clk_pce_d2,
             clk_sdram => clk_sdram, clk_135 => clk_135, clk_27 => clk_27,
             lock => pll_lock);

   reset_n <= reset and pll_lock;

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

   sdram_inst: sdram32
   generic map (SAMPLE_SKEW => 3)
   port map (
      clk        => clk_sdram,
      init       => sdram_init,
      SDRAM_A    => O_sdram_addr,
      SDRAM_DQ   => IO_sdram_dq,
      SDRAM_BA   => O_sdram_ba,
      SDRAM_DQM  => O_sdram_dqm,
      SDRAM_nWE  => O_sdram_wen_n,
      SDRAM_nCAS => O_sdram_cas_n,
      SDRAM_nRAS => O_sdram_ras_n,
      SDRAM_nCS  => O_sdram_cs_n,
      SDRAM_CKE  => O_sdram_cke,
      SDRAM_CLK  => O_sdram_clk,
      -- Zero-extended, not widened -- VRAM0 stays entirely within bank 0 (real footprint
      -- 64KB), same convention as the GW5A boards' own port-A zero-extension.
      RAM_A_ADDR => "00" & vram0_ram_a_addr,
      RAM_A_REQ  => vram0_ram_a_req,
      RAM_A_RD_n => vram0_ram_a_rd_n,
      RAM_A_DI   => vram0_ram_a_di,
      RAM_A_DO   => vram0_ram_a_do,
      RAM_A_WAIT => vram0_ram_a_wait,
      RAM_A_LINE_REFILL => vram0_ram_a_line_refill,
      RAM_A_LINE_DO     => vram0_ram_a_line_do,
      RAM_B_ADDR => ram_b_addr,
      RAM_B_REQ  => ram_b_req,
      RAM_B_WE   => ram_b_we,
      RAM_B_DI   => ram_b_di,
      RAM_B_DO   => ram_b_do,
      RAM_B_WAIT => ram_b_wait
   );

   ds2_p1 : controller_ds2
      generic map ( FREQ => 43_200_000 )      -- clk_pce
      port map ( clk => clk_pce, snes_buttons => joy1_ds2,
                 ds_clk => ds_clk, ds_miso => ds_miso, ds_mosi => ds_mosi, ds_cs => ds_cs );

   ds2_p2 : controller_ds2
      generic map ( FREQ => 43_200_000 )
      port map ( clk => clk_pce, snes_buttons => joy2_ds2,
                 ds_clk => ds_clk2, ds_miso => ds_miso2, ds_mosi => ds_mosi2, ds_cs => ds_cs2 );

   -- OR'd with the MCU's HID report so a USB pad and a DS2 pad both work.
   joy1     <= joy1_ds2 or hid1(11 downto 0);
   joy2     <= joy2_ds2 or hid2(11 downto 0);

   sys_inst: iosys_bl616
   generic map (
      FREQ => 43_200_000,
      COLOR_LOGO => "011000000001000",
      CORE_ID => x"0008",                -- must match firmware-bl616 cores.cpp id 8 ("PC Engine CD")
      LOADING_STATE => x"00"
   )
   port map (
      clk => clk_pce, hclk => clk_27, resetn => reset_n,

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
      dbg_trace_req => '0',
      dbg_trace_tag => (others => '0'),
      dbg_trace_data => (others => '0'),

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

   -- ROM load bookkeeping: dynamic ROM_SZ + core_resetn gate, same pattern as
   -- pcetang_nano20k.vhd's own ROM-to-SDRAM bridge -- see that file for the full
   -- rationale (real HuCard bucket rounding, why the core must stay held in reset for
   -- the whole load).
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
               -- tier is real SF2', not a guess. rom_sz=X"280" routes pce_top.vhd's
               -- already-real rombank mapper (see ROM_SDRAM_ABITS/BASE widening above).
               rom_sz_r <= x"280"; -- >1MB, real SF2' bank-switched mapping
            end if;
         end if;
      end if;
   end process;

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   -- CD-RAM + ADPCM RAM + Arcade Card RAM bridge -- see the signal block's header comment
   -- above for the design (mirrors Primer 25K CD's port-C arbiter, adapted to port B's
   -- toggle-per-request protocol). One owner in flight at a time, CD-RAM (which includes
   -- Arcade Card via cd_ram_a's own bit 21 decode, same as every GW5A CD board) winning
   -- ties over ADPCM -- same priority reasoning as the GW5A boards: CD-RAM directly stalls
   -- the CPU via CD_RAM_RDY/WAIT_N, ADPCM's own DRAM_CLKEN wait-gate tolerates real slack.
   process (clk_pce)
      variable cd_new, adpcm_new, rom_rd_new : std_logic;
   begin
      if rising_edge(clk_pce) then
         cdram_rd_r       <= cd_ram_rd;
         cdram_wr_r       <= cd_ram_wr;
         adpcm_slot_cnt_r <= adpcm_ram_slot_cnt_i;
         rom_rd_r         <= rom_rd_i;

         cd_new := (cd_ram_rd and not cdram_rd_r) or (cd_ram_wr and not cdram_wr_r);
         if adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r then
            adpcm_new := adpcm_ram_req_i;
         else
            adpcm_new := '0';
         end if;
         -- ROM_RD is level-held by pce_top until ROM_RDY returns (same protocol every
         -- other board's ROM bridge relies on) -- edge-detect it here rather than
         -- reusing it directly, so a still-asserted request from an in-flight
         -- transaction never re-triggers a second launch.
         rom_rd_new := rom_rd_i and not rom_rd_r;

         if cd_new = '1' then
            cd_pend      <= '1';
            cd_ram_rdy_i <= '0';
         end if;
         if adpcm_new = '1' then
            adpcm_pend        <= '1';
            adpcm_ram_ready_i <= '0';
         end if;
         -- ROM: unlike CD-RAM/ADPCM above, latched fully at pend-set time rather than
         -- read live at launch -- rom_do_valid (the write trigger) is a genuine
         -- ONE-CYCLE pulse from iosys_bl616, and rom_wr_addr free-runs on it, so the
         -- exact address+byte pair must be captured the instant it fires, not read back
         -- later if the arbiter happens to be busy with CD-RAM/ADPCM that same cycle.
         -- Real reason a read/write pend collision can never happen: pce_top's ROM_RD
         -- only asserts once the core is out of reset, and core_resetn (below) holds the
         -- core in reset for the WHOLE load -- the two phases never overlap in time.
         if rom_rd_new = '1' then
            rom_pend      <= '1';
            rom_pend_we   <= '0';
            rom_pend_addr <= std_logic_vector(ROM_SDRAM_BASE +
                              resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 23));
            rom_rdy_i     <= '0';
         end if;
         if rom_do_valid = '1' then
            rom_pend      <= '1';
            rom_pend_we   <= '1';
            rom_pend_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(rom_wr_addr, 23));
            rom_pend_di   <= rom_do;
         end if;

         case b_state is
            when B_IDLE =>
               if cd_pend = '1' or cd_new = '1' then
                  if cd_ram_a(21) = '0' then
                     ram_b_addr <= std_logic_vector(AC_SDRAM_BASE +
                                   resize(unsigned(cd_ram_a(20 downto 0)), 23));
                  else
                     ram_b_addr <= std_logic_vector(CDRAM_SDRAM_BASE +
                                   resize(unsigned(cd_ram_a(17 downto 0)), 23));
                  end if;
                  ram_b_we  <= cd_ram_wr;
                  ram_b_di  <= cd_ram_do;
                  ram_b_req <= not ram_b_req;
                  b_owner   <= OWNER_CDRAM;
                  cd_pend   <= '0';
                  b_settle_cnt <= (others => '0');
                  b_state   <= B_SETTLE;
               elsif rom_pend = '1' then
                  ram_b_addr <= rom_pend_addr;
                  ram_b_we   <= rom_pend_we;
                  ram_b_di   <= rom_pend_di;
                  ram_b_req  <= not ram_b_req;
                  b_owner    <= OWNER_ROM;
                  rom_pend   <= '0';
                  b_settle_cnt <= (others => '0');
                  b_state    <= B_SETTLE;
               elsif adpcm_pend = '1' or adpcm_new = '1' then
                  ram_b_addr <= std_logic_vector(ADPCM_SDRAM_BASE +
                                resize(unsigned(adpcm_ram_a_i), 23));
                  ram_b_we  <= adpcm_ram_we_i;
                  ram_b_di  <= "0000" & adpcm_ram_do_i;
                  ram_b_req <= not ram_b_req;
                  b_owner   <= OWNER_ADPCM;
                  adpcm_pend <= '0';
                  b_settle_cnt <= (others => '0');
                  b_state   <= B_SETTLE;
               end if;

            when B_SETTLE =>
               -- clk_sdram (135 MHz) is ~3.1x clk_pce (43.2 MHz); 4 clk_pce cycles is
               -- ample margin for sdram32.sv to either free-hit or start asserting
               -- ram_b_wait for a real fetch -- same margin reasoning as the GW5A
               -- boards' own romb/cdr bridges.
               if b_settle_cnt = "100" then
                  if ram_b_wait = '1' then
                     b_state <= B_WAIT;
                  else
                     if b_owner = OWNER_CDRAM then
                        cd_ram_di_i  <= ram_b_do;
                        cd_ram_rdy_i <= '1';
                     elsif b_owner = OWNER_ADPCM then
                        adpcm_ram_di_i    <= ram_b_do(3 downto 0);
                        adpcm_ram_ready_i <= '1';
                     else -- OWNER_ROM
                        -- Write completion needs no action -- nothing reads ROM back
                        -- during a load (core held in reset the whole time).
                        if ram_b_we = '0' then
                           rom_do_i  <= ram_b_do;
                           rom_rdy_i <= '1';
                        end if;
                     end if;
                     b_owner <= OWNER_NONE;
                     b_state <= B_IDLE;
                  end if;
               else
                  b_settle_cnt <= b_settle_cnt + 1;
               end if;

            when B_WAIT =>
               if ram_b_wait = '0' then
                  if b_owner = OWNER_CDRAM then
                     cd_ram_di_i  <= ram_b_do;
                     cd_ram_rdy_i <= '1';
                  elsif b_owner = OWNER_ADPCM then
                     adpcm_ram_di_i    <= ram_b_do(3 downto 0);
                     adpcm_ram_ready_i <= '1';
                  else -- OWNER_ROM
                     if ram_b_we = '0' then
                        rom_do_i  <= ram_b_do;
                        rom_rdy_i <= '1';
                     end if;
                  end if;
                  b_owner <= OWNER_NONE;
                  b_state <= B_IDLE;
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

   -- PCE PORT (2026-08-30): VRAM0_PREFETCH/VRAM0_CG_PREFETCH => 1 (BAT+CG0/CG1 enabled),
   -- retried after being OFF since this file's first attempt. Real reason it was off
   -- before: this board's first CD attempt combined with them saturated the device
   -- (100% CLS, 100% BSRAM, 223 unplaced registers) before the CD-RAM/ADPCM/Arcade-Card
   -- bridge itself was even the limiting factor -- but that measurement predates ROM
   -- also moving to SDRAM (frees ~13 BSRAM blocks, see pcetang_status_matrix.md lever
   -- 14) and the alternate PnR algorithm (place_option 2/route_option 1, lever 13),
   -- both of which changed this board's real resource/margin picture since. Also no
   -- longer true that no board has ever run CD with a REAL BAT+CG: Primer 25K CD's own
   -- black-boxed-prefetch bug (VRAM0_PREFETCH=>1 but vram0_prefetch.vhd never compiled)
   -- is FIXED as of `6c547d2` -- that board's real combined CD+BAT+CG numbers
   -- (clk_pce +0.331%, later +14.2% post-PnR-flag) are genuine precedent now, not a
   -- false one. build_nano20k_cd.tcl now compiles vram0_prefetch.vhd -- see that file's
   -- own history for why setting this generic without it would silently black-box the
   -- feature instead of enabling it (the exact bug just described). VRAM0_LINE_REFILL
   -- stays on regardless -- implemented directly in vram0_cache.vhd/sdram32.sv, not
   -- vram0_prefetch.vhd, so it was never affected either way.
   core: entity work.pce_top
   generic map (LITE => 1, EXT_VRAM0 => 1, NO_CD => 0, VRAM0_LINE_REFILL => 1,
                VRAM0_PREFETCH => 1, VRAM0_CG_PREFETCH => 1,
                -- Real, verified exception (2026-08-31, lever 19/20): SF2'
                -- widening + PSG Path A each pass clean alone on THIS board,
                -- but their combination real-fails timing (64 setup
                -- violations). Direct user choice: keep SF2', drop back to
                -- the old BRAM-based VT here instead. See psg.vhd's own
                -- VT_PATH_A generic header and pcetang_status_matrix.md.
                VT_PATH_A => 0,
                -- 2026-09-09, direct user decision: the Arcade Card is not a priority
                -- until HuCard is right on all three boards, so it comes out here. It
                -- was not free -- all 4 of this board's setup violations ended at
                -- core/gen_ac.AC/port[N].base_22 (worst -0.141 ns), on the MCODE -> AC
                -- MPR path that 8dc83df already identified as the one the Arcade Card
                -- owns. Console 60K dropped it for the same reason.
                AC_BUILD => 0)
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
      VRAM0_RAM_A_LINE_REFILL => vram0_ram_a_line_refill,
      VRAM0_RAM_A_LINE_DO     => vram0_ram_a_line_do,

      -- TEMP DEBUG (2026-09-06): Console 60K-only debug taps (see pce_top.vhd's own
      -- port comments). Explicitly `open` here rather than omitted, matching this
      -- file's style for every other unused pce_top output.
      DBG_CPU_A => open, DBG_VDC_WR => open, DBG_VDC_RDY => open,
      DBG_CPU_CE => open, DBG_IRQ1_N => open, DBG_IRQ2_N => open,
      RAMTEST_EN => '0', RAMTEST_Q => open, DBG_MPR => open, DBG_TAM => open, DBG_TLOAD => open, DBG_TLOAD_STB => open, DBG_SEL => open, DBG_WAIT_EVER => open,

      ROM_RD    => rom_rd_i,
      ROM_RDY   => rom_rdy_i,
      ROM_A     => rom_a,
      ROM_DO    => rom_do_i,
      ROM_SZ    => rom_sz_r,
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

   -- Reads from joy_active (real per-player mux, see its own header comment
   -- above), not directly from joy1 -- joy_port selects which real player's
   -- HID state is currently active.
   -- PCE PORT (2026-09-09), ported from Console 60K where it was proven on hardware.
   -- Two real bugs in the line this replaces:
   --   1. Missing inversion. iosys_bl616's joy1/joy2 are active HIGH; the PCE pad
   --      protocol is active LOW (pce_top defaults joy_in to 16#0FFF#). Without the
   --      `not`, every button read as permanently pressed.
   --   2. Wrong d-pad bits. joy1[11:0] is (R L X A RT LT DN UP START SELECT Y B), so
   --      the d-pad is bits 4/5/6/7 -- bits 10/11 are the SHOULDER buttons, which is
   --      what the old code was reading for left/right.
   -- I/II also accept either face-button pair (A or B, X or Y), so the pad's natural
   -- two-button cluster works whichever way round the user holds it.
   joy_in <= not (joy_active(6) & joy_active(5) & joy_active(7) & joy_active(4))
                when joy_out(0) = '1'
             else not (joy_active(3)
                       & joy_active(2)
                       & (joy_active(9) or joy_active(1))    -- II  <- X or Y
                       & (joy_active(8) or joy_active(0)));  -- I   <- A or B

   hdmi_out: pce2hdmi_sd
   port map (
      clk => clk_pce, resetn => reset_n,
      video_r => video_r, video_g => video_g, video_b => video_b,
      video_ce => video_ce, video_hs => video_hs, video_vs => video_vs,
      video_hbl => video_hbl, video_vbl => video_vbl,
      overlay => overlay, overlay_x => overlay_x, overlay_y => overlay_y,
      overlay_color => overlay_color,
      clk_pixel => clk_27, clk_5x_pixel => clk_135,
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

end architecture;
