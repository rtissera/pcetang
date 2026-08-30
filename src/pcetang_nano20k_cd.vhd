-- SPDX-License-Identifier: GPL-3.0-or-later

-- RETRY 2026-08-30 (real, not reference-only): the FIRST attempt at this file (see
-- pcetang_nano20k_cd_attempt.md) hit two real walls: touching sdram32.sv at all broke
-- plain Nano 20K's BAT+CG margin via placement noise, and the CD build itself hit a hard
-- BSRAM ceiling (46/46) plus a real -9.7% clk_pce timing miss even with BAT/CG disabled.
-- Retried now because two things changed since: (1) the alternate PnR algorithm
-- (place_option 2/route_option 1, see pcetang_status_matrix.md lever 13) recovered real
-- margin project-wide on every board it's been tried on, including this one's plain
-- build after ITS OWN sdram32.sv touch (ROM-to-SDRAM, +0.019%->+1.85%); (2) ROM also
-- moved off on-chip BRAM onto SDRAM here (see the ROM section below), freeing the same
-- ~13 real BSRAM blocks the plain board freed, on top of whatever this file's own
-- CD-RAM/ADPCM/Arcade-Card offload already needed. Real regression re-check on the plain
-- board (not just this file) is mandatory before trusting either result -- see this
-- session's own build log, not assumed fixed by the reasoning above alone.
--
-- pcetang Nano 20K CD attempt: TangCore-integrated (iosys_bl616), NO_CD=>0, EXT_VRAM0=>1
-- (Nano 20K's whole engine does not fit on-chip), CD-RAM/ADPCM RAM/Arcade Card RAM all
-- offloaded to the on-package SDRAM (sdram32.sv), scandoubler HDMI (pce2hdmi_sd.sv,
-- same -11-BSRAM-block swap already banked on Primer 25K plain, commit 0db5950).
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
--     razor-thin clk_pce margin is considered). LITE=>1, SGX=>'0', unchanged from plain.
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
-- Video: pce2hdmi.sv on plain Nano 20K already runs VIDEOID=>2/CLKFRQ=>27000/
-- SCREEN_WIDTH=>720/SCREEN_HEIGHT=>480 (see pcetang_nano20k.vhd's own header/generic
-- map) -- i.e. already 480p60, same clk_27/clk_135 pair pce2hdmi_sd.sv needs. This swap
-- is therefore a real zero-clock-change, ~pure-BSRAM-win substitution on this board
-- specifically (confirmed by reading src/pce/common/pll/nano20k_pll.vhd directly:
-- clk_sdram <= clk_135_i, the SAME net as HDMI's clk_135 -- GW2AR-18C has exactly 2 PLL
-- resources, both spent, no separate 720p pixel clock ever existed here to move away
-- from the way Console 60K's plain/CD swap had to).
--
-- NOT VERIFIED ON HARDWARE. NOT YET gw_sh-VERIFIED either -- see this session's own
-- build log for the first real result.

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
   signal joy1_ds2      : std_logic_vector(11 downto 0);
   signal hid1, hid2    : std_logic_vector(15 downto 0);
   signal joy1          : std_logic_vector(11 downto 0);

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
   constant ROM_SDRAM_BASE   : unsigned(22 downto 0) := to_unsigned(16#0C0000#, 23);
   constant ROM_SDRAM_ABITS  : integer := 20;
   constant AC_SDRAM_BASE    : unsigned(22 downto 0) := to_unsigned(16#200000#, 23);

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

   -- Minimal SCSI target stub -- copied verbatim from Primer 25K CD, see that file for
   -- the full protocol trace/Mednafen verification. No syscard can load here yet (ROM
   -- stays on-chip, see header), so this cannot be exercised for real until that changes
   -- -- wired now anyway so the rest of the plumbing needs no further change later.
   signal cd_stat_i     : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_msg_i      : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_stat_get_i : std_logic := '0';
   signal cd_comm_i      : std_logic_vector(95 downto 0);
   signal cd_comm_send_i : std_logic;
   signal cd_comm_send_r : std_logic := '0';
   signal cd_data_i     : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_data_wr_i  : std_logic := '0';
   signal cd_data_end_i : std_logic;

   constant SCSI_OP_REQUEST_SENSE : std_logic_vector(7 downto 0) := x"03";

   type sense_data_t is array (0 to 17) of std_logic_vector(7 downto 0);
   constant SENSE_NOT_READY : sense_data_t := (
      x"70", x"00", x"02", x"00", x"00", x"00", x"00", x"0A",
      x"00", x"00", x"00", x"00", x"0B", x"00", x"00", x"00", x"00", x"00"
   );

   type scsi_state_t is (SCSI_IDLE, SCSI_SENSE_PULSE, SCSI_SENSE_GAP, SCSI_SENSE_WAIT_END);
   signal scsi_state : scsi_state_t := SCSI_IDLE;
   signal sense_idx  : integer range 0 to 17 := 0;

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

   joy1_ds2 <= (others => '0');
   joy1     <= joy1_ds2 or hid1(11 downto 0);

   sys_inst: iosys_bl616
   generic map (
      FREQ => 43_200_000,
      COLOR_LOGO => "011000000001000",
      CORE_ID => x"0003",
      LOADING_STATE => x"00"
   )
   port map (
      clk => clk_pce, hclk => clk_27, resetn => reset_n,

      overlay => overlay, overlay_x => overlay_x, overlay_y => overlay_y,
      overlay_color => overlay_color,
      joy1 => joy1, joy2 => (others => '0'),
      hid1 => hid1, hid2 => hid2,

      rom_loading => rom_loading, rom_do => rom_do, rom_do_valid => rom_do_valid,

      mgmt_address => open, mgmt_read => open, mgmt_readdata => (others => '0'),
      mgmt_write => open, mgmt_writedata => open, fdd_request => "00",

      kbd_data => open, kbd_data_valid => open,
      core_config => open,

      uart_rx => uart_rxd, uart_tx => uart_txd
   );

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
            else
               rom_sz_r <= x"000"; -- >768K, straight 1MB mapping
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

   -- Minimal SCSI target stub -- see header for why this can't be exercised for real yet.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         cd_comm_send_r <= cd_comm_send_i;
         cd_stat_get_i  <= '0';
         cd_data_wr_i   <= '0';

         case scsi_state is
            when SCSI_IDLE =>
               if cd_comm_send_i = '1' and cd_comm_send_r = '0' then
                  if cd_comm_i(7 downto 0) = SCSI_OP_REQUEST_SENSE then
                     sense_idx  <= 0;
                     scsi_state <= SCSI_SENSE_PULSE;
                  else
                     cd_stat_i     <= x"02";  -- CHECK CONDITION
                     cd_msg_i      <= x"00";  -- COMMAND COMPLETE
                     cd_stat_get_i <= '1';
                  end if;
               end if;

            when SCSI_SENSE_PULSE =>
               cd_data_i    <= SENSE_NOT_READY(sense_idx);
               cd_data_wr_i <= '1';
               scsi_state   <= SCSI_SENSE_GAP;

            when SCSI_SENSE_GAP =>
               if sense_idx = 17 then
                  scsi_state <= SCSI_SENSE_WAIT_END;
               else
                  sense_idx  <= sense_idx + 1;
                  scsi_state <= SCSI_SENSE_PULSE;
               end if;

            when SCSI_SENSE_WAIT_END =>
               if cd_data_end_i = '1' then
                  cd_stat_i     <= x"00";  -- GOOD
                  cd_msg_i      <= x"00";
                  cd_stat_get_i <= '1';
                  scsi_state    <= SCSI_IDLE;
               end if;
         end case;
      end if;
   end process;

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
      VRAM0_RAM_A_LINE_REFILL => vram0_ram_a_line_refill,
      VRAM0_RAM_A_LINE_DO     => vram0_ram_a_line_do,

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
      CD_REGION => '0', CD_RESET => open,
      CD_DATA => cd_data_i, CD_DATA_WR => cd_data_wr_i, CD_AUDIO_WR => '0',
      CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end_i, CD_DM => '0',

      CDDA_SL => cdda_sl, CDDA_SR => cdda_sr, ADPCM_S => adpcm_s, PSG_SL => psg_sl, PSG_SR => psg_sr,

      BG_EN => '1', SPR_EN => '1', GRID_EN => (others => '0'), CPU_PAUSE_EN => '0',

      BORDER_EN => '0', ReducedVBL => '0',
      VIDEO_R => video_r, VIDEO_G => video_g, VIDEO_B => video_b,
      VIDEO_BW => open, VIDEO_CE => video_ce, VIDEO_CE_FS => open,
      VIDEO_VS => video_vs, VIDEO_HS => video_hs,
      VIDEO_HBL => video_hbl, VIDEO_VBL => video_vbl
   );

   joy_in <= joy1(4) & joy1(5) & joy1(11) & joy1(10) when joy_out(0) = '1' else
             joy1(3) & joy1(2) & joy1(1)  & joy1(0);

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
