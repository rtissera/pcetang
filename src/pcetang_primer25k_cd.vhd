-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Phase 2 CD attempt, Tang Primer 25K, TangCore-integrated (iosys_bl616: ROM
-- load, joypad, OSD via pce2hdmi_sd's scandoubler), NO_CD=>0, EXT_VRAM0=>1 (required --
-- Primer 25K's whole engine does not fit on-chip).
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
-- CURRENT CHANGE (2026-08-27, NOT YET gw_sh-VERIFIED): a minimal SCSI target stub now
-- answers `CD_COMM_SEND` -- any command other than REQUEST SENSE gets CHECK CONDITION; REQUEST
-- SENSE gets real SCSI-2 fixed-format sense data (NOT READY / MEDIUM NOT PRESENT) pushed
-- through `CD_DATA`/`CD_DATA_WR` into SCSI.vhd's own DATA-IN FIFO. See the `cd_stat_i`/
-- `cd_comm_i` signal block below for the full protocol trace and docs/ARCHITECTURE.md's
-- "Real syscard boot" Part 2 section for why this specific pair of commands is the real
-- minimum (a syscard with no disc polls TEST UNIT READY, gets CHECK CONDITION, then asks
-- REQUEST SENSE why). Whether this is enough for a real syscard to actually reach a boot
-- screen, versus needing more of the command set, is not yet known -- no hardware test,
-- no simulation testbench for this responder exists. What IS real: `gw_sh` will confirm
-- whether this closes timing and fits, which is the first checkable fact about it.
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
      key_reset_n   : in    std_logic;                       -- S2, active low

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
      uart_txd    : out   std_logic
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
         RAM_A_ADDR : in    std_logic_vector(20 downto 0);
         RAM_A_REQ  : in    std_logic;
         RAM_A_RD_n : in    std_logic;
         RAM_A_DI   : in    std_logic_vector(7 downto 0);
         RAM_A_DO   : out   std_logic_vector(7 downto 0);
         RAM_A_WAIT : out   std_logic;
         RAM_B_ADDR : in    std_logic_vector(20 downto 0);
         RAM_B_REQ  : in    std_logic;
         RAM_B_WE   : in    std_logic;
         RAM_B_DI   : in    std_logic_vector(7 downto 0);
         RAM_B_DO   : out   std_logic_vector(7 downto 0);
         RAM_B_WAIT : out   std_logic;
         RAM_C_ADDR : in    std_logic_vector(20 downto 0);
         RAM_C_REQ  : in    std_logic;
         RAM_C_RD_n : in    std_logic;
         RAM_C_DI   : in    std_logic_vector(7 downto 0);
         RAM_C_DO   : out   std_logic_vector(7 downto 0);
         RAM_C_WAIT : out   std_logic
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
   signal vram0_ram_a_di   : std_logic_vector(7 downto 0);
   signal vram0_ram_a_do   : std_logic_vector(7 downto 0);
   signal vram0_ram_a_wait : std_logic;

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
   signal rom_loading_r : std_logic := '0';

   -- Cart/syscard ROM now lives off-chip in SDRAM via sdram.sv's port B (was an on-chip
   -- dpram -- that BSRAM was one of the two blocks pushing this build's combined BSRAM
   -- demand to 56/56, cascading into the RP0006 LUT overflow; see docs/ARCHITECTURE.md's
   -- "Goal revised" section for the measured root cause). NOT YET gw_sh-verified -- see
   -- this file's header.
   --
   -- Provisional 3-way split of bank 0's 2MB SDRAM window (see docs/ARCHITECTURE.md's
   -- "Real syscard boot" section). Revisit when sdram.sv's bank-0 addressing itself gets
   -- widened for Phase 3 (Arcade Card) -- that work supersedes this layout anyway, so
   -- none of these constants are meant to be permanent.
   --   0x000000-0x00FFFF (64KB):  VRAM0 (port A). Real footprint, not a guess -- traced
   --                              to vram0_cache.vhd's own seq_addr (15-bit word address,
   --                              15+1=16 address bits = 64KB), matching real PCE VRAM0
   --                              (32K x 16-bit).
   --   0x010000-0x04FFFF (256KB): CD-RAM (pce_top's CD_RAM_A window, "1000"&CPU_A(17:0)).
   --                              Now wired via sdram.sv's third port (C), see the cd_ram_*/
   --                              cdr_* signals below. 256KB confirmed against cd.vhd's own
   --                              RAM_SEL decode (0x68-0x87 in 8KB units = 256KB), not just
   --                              pce_top's own window width.
   --   0x050000-0x08FFFF (256KB): cart/syscard ROM (this constant, used below). A real
   --                              syscard (syscard3.pce) is exactly 256KB -- ROM_SZ=>x"040"
   --                              below decodes exactly this size, no slack needed.
   constant CDRAM_SDRAM_BASE : unsigned(20 downto 0) := to_unsigned(16#010000#, 21);
   constant ROM_SDRAM_BASE : unsigned(20 downto 0) := to_unsigned(16#050000#, 21);
   constant ROM_SDRAM_ABITS : integer := 18;  -- 256KB, exact real syscard size

   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');

   -- Shared SDRAM port-B request/response, muxed between the read bridge (gameplay,
   -- pce_top's ROM_RD/ROM_A/ROM_DO/ROM_RDY) and the write bridge (loading, iosys_bl616's
   -- rom_do/rom_do_valid). The two never run concurrently -- the core sits in reset for
   -- the whole load -- so there is no real arbitration, just a static mux on rom_loading_r.
   signal romb_addr : std_logic_vector(20 downto 0);
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
   signal rd_addr        : std_logic_vector(20 downto 0);

   -- Write side (ROM load, one rom_do_valid pulse per byte)
   signal wr_state       : romb_state_t := RB_IDLE;
   signal wr_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal wr_req         : std_logic := '0';
   signal wr_addr        : std_logic_vector(20 downto 0);
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

   signal cdr_addr : std_logic_vector(20 downto 0);
   signal cdr_req  : std_logic := '0';
   signal cdr_rd_n : std_logic := '0';
   signal cdr_di   : std_logic_vector(7 downto 0);
   signal cdr_do   : std_logic_vector(7 downto 0);
   signal cdr_wait : std_logic;

   type cdr_state_t is (CDR_IDLE, CDR_SETTLE, CDR_HOLD);
   signal cdr_state      : cdr_state_t := CDR_IDLE;
   signal cdr_settle_cnt : unsigned(2 downto 0) := (others => '0');
   signal cdram_rd_r, cdram_wr_r : std_logic := '0';

   -- Minimal SCSI target stub. cd.vhd/SCSI.vhd (unmodified from the donor) own the real
   -- SCSI bus phase timing; this just answers CD_COMM_SEND with a response, same clk_pce
   -- domain, no CDC needed (SCSI.vhd lives inside pce_top, same CLK). Traced directly from
   -- SCSI.vhd's source, not inferred from the SCSI spec: CD_COMM's LOWEST byte
   -- (CD_COMM(7 downto 0)) is the opcode -- COMM_POS starts at 0 and the first byte
   -- received (the opcode) lands in COMM(0), which is the LSB of the concatenation that
   -- becomes CD_COMM. Any command other than REQUEST SENSE (0x03) gets CHECK CONDITION;
   -- REQUEST SENSE gets real SCSI-2 fixed-format sense data (NOT READY / MEDIUM NOT
   -- PRESENT -- the honest answer for "no disc") pushed one byte at a time through
   -- CD_DATA/CD_DATA_WR into SCSI.vhd's own DATA-IN FIFO (a plain byte FIFO, 4096 deep,
   -- edge-detected per byte -- not cd.vhd's separate 4-byte-packed CDDA_FIFO, which is
   -- audio-only via CD_AUDIO_WR and irrelevant here), followed by a GOOD status once
   -- CD_DATA_END confirms the transfer drained. See docs/ARCHITECTURE.md's "Real syscard
   -- boot" Part 2 section for the full protocol trace and what this deliberately doesn't
   -- implement (TEST UNIT READY gets the same CHECK CONDITION as everything else -- there
   -- is no special-case, REQUEST SENSE is what tells the caller why).
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

   -- Fixed-format sense data, SCSI-2 standard constants (not project-specific): Error
   -- Code 0x70 (current error), Sense Key 0x02 (NOT READY), Additional Sense Length 0x0A
   -- (10 bytes follow), ASC 0x3A / ASCQ 0x00 (MEDIUM NOT PRESENT). 18 bytes total.
   type sense_data_t is array (0 to 17) of std_logic_vector(7 downto 0);
   constant SENSE_NOT_READY : sense_data_t := (
      x"70", x"00", x"02", x"00", x"00", x"00", x"00", x"0A",
      x"00", x"00", x"00", x"00", x"3A", x"00", x"00", x"00", x"00", x"00"
   );

   type scsi_state_t is (SCSI_IDLE, SCSI_SENSE_PULSE, SCSI_SENSE_GAP, SCSI_SENSE_WAIT_END);
   signal scsi_state : scsi_state_t := SCSI_IDLE;
   signal sense_idx  : integer range 0 to 17 := 0;

   signal video_r, video_g, video_b : std_logic_vector(2 downto 0);
   signal video_ce, video_hs, video_vs, video_hbl, video_vbl : std_logic;

   signal joy_out : std_logic_vector(1 downto 0);
   signal joy_in  : std_logic_vector(3 downto 0);

   signal brm_a  : std_logic_vector(10 downto 0);
   signal brm_di : std_logic_vector(7 downto 0);
   signal brm_do : std_logic_vector(7 downto 0);
   signal brm_we : std_logic;

begin

   reset_n <= key_reset_n and pll_lock and hdmi_pll_lock;

   pll: console60k_pll
   port map (clkin => clk, reset => not key_reset_n, clk_pce => clk_pce,
             clk_sdram => clk_sdram, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll_480p
   port map (clkin => clk, reset => not key_reset_n, clk_pixel => clk_pixel,
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
      RAM_A_ADDR => vram0_ram_a_addr,
      RAM_A_REQ  => vram0_ram_a_req,
      RAM_A_RD_n => vram0_ram_a_rd_n,
      RAM_A_DI   => vram0_ram_a_di,
      RAM_A_DO   => vram0_ram_a_do,
      RAM_A_WAIT => vram0_ram_a_wait,
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
      RAM_C_WAIT => cdr_wait
   );

   -- Static mux: write bridge (load) owns port B while rom_loading_r is set, read bridge
   -- (gameplay fetch) owns it otherwise. The two are never both active -- pce_top's CLK is
   -- held in reset for the entire load (see reset_n), so ROM_RD cannot fire during it.
   romb_addr <= wr_addr when rom_loading_r = '1' else rd_addr;
   romb_req  <= wr_req  when rom_loading_r = '1' else rd_req;
   romb_we   <= '1'     when rom_loading_r = '1' else '0';
   romb_di   <= wr_data;

   joy1_ds2 <= (others => '0');
   joy1     <= joy1_ds2 or hid1(11 downto 0);

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
      core_config => open,

      uart_rx => uart_rxd, uart_tx => uart_txd
   );

   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         rom_loading_r <= rom_loading(0);
         if rom_loading(0) = '1' and rom_loading_r = '0' then
            rom_wr_addr <= (others => '0');
         elsif rom_do_valid = '1' then
            rom_wr_addr <= rom_wr_addr + 1;
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
                  wr_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(rom_wr_addr, 21));
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
                             resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 21));
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

   -- CD-RAM bridge: pce_top's CD_RAM_RD/CD_RAM_WR (raw bus-decode signals, level-held for
   -- the duration of a real CPU access, not a dedicated request pulse) become one real
   -- SDRAM access via port C. Edge-detected (cdram_rd_r/cdram_wr_r) rather than
   -- level-checked like the ROM bridge above, specifically to avoid re-triggering a second
   -- transaction on the same byte while CD_RAM_RD/WR is still held high through the wait
   -- this bridge itself introduces -- CD_RAM_RD/WR only drop once the CPU's own bus cycle
   -- advances, which (via CD_RAM_RDY -> WAIT_N) can't happen until this FSM returns to
   -- CDR_IDLE and raises cd_ram_rdy_i. RAM_C is level-held/assert-and-hold (port A's
   -- convention), not port B's toggle-per-request one -- see sdram.sv's header.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         cdram_rd_r <= cd_ram_rd;
         cdram_wr_r <= cd_ram_wr;

         case cdr_state is
            when CDR_IDLE =>
               cd_ram_rdy_i <= '1';
               cdr_req <= '0';
               if (cd_ram_rd = '1' and cdram_rd_r = '0') or
                  (cd_ram_wr = '1' and cdram_wr_r = '0') then
                  cdr_addr <= std_logic_vector(CDRAM_SDRAM_BASE +
                              resize(unsigned(cd_ram_a(17 downto 0)), 21));
                  cdr_rd_n <= not cd_ram_wr;   -- '0' read, '1' write -- matches RAM_x_RD_n
                  cdr_di   <= cd_ram_do;       -- pce_top's CD_RAM_DO: the byte it's writing
                  cd_ram_rdy_i <= '0';
                  cdr_req <= '1';
                  cdr_settle_cnt <= (others => '0');
                  cdr_state <= CDR_SETTLE;
               end if;

            when CDR_SETTLE =>
               cdr_req <= '1';
               if cdr_settle_cnt = "100" then
                  if cdr_wait = '1' then
                     cdr_state <= CDR_HOLD;
                  else
                     cd_ram_di_i <= cdr_do;
                     cd_ram_rdy_i <= '1';
                     cdr_req <= '0';
                     cdr_state <= CDR_IDLE;
                  end if;
               else
                  cdr_settle_cnt <= cdr_settle_cnt + 1;
               end if;

            when CDR_HOLD =>
               cdr_req <= '1';
               if cdr_wait = '0' then
                  cd_ram_di_i <= cdr_do;
                  cd_ram_rdy_i <= '1';
                  cdr_req <= '0';
                  cdr_state <= CDR_IDLE;
               end if;
         end case;
      end if;
   end process;

   -- Minimal SCSI target stub -- see the cd_stat_i/cd_comm_i signal block's header
   -- comment for the real protocol trace this implements.
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

            -- One idle cycle between bytes: SCSI.vhd's own push logic edge-detects
            -- CD_DATA_WR (CD_WR_OLD/CD_WR), so a byte held high back-to-back into the
            -- next byte would only register once.
            when SCSI_SENSE_GAP =>
               if sense_idx = 17 then
                  scsi_state <= SCSI_SENSE_WAIT_END;
               else
                  sense_idx  <= sense_idx + 1;
                  scsi_state <= SCSI_SENSE_PULSE;
               end if;

            when SCSI_SENSE_WAIT_END =>
               if cd_data_end_i = '1' then
                  cd_stat_i     <= x"00";  -- GOOD -- REQUEST SENSE itself succeeded
                  cd_msg_i      <= x"00";
                  cd_stat_get_i <= '1';
                  scsi_state    <= SCSI_IDLE;
               end if;
         end case;
      end if;
   end process;

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   core: entity work.pce_top
   generic map (LITE => 1, EXT_VRAM0 => 1, NO_CD => 0)
   port map (
      RESET      => not reset_n,
      COLD_RESET => not reset_n,
      CLK        => clk_pce,

      VRAM0_RAM_A_ADDR => vram0_ram_a_addr,
      VRAM0_RAM_A_REQ  => vram0_ram_a_req,
      VRAM0_RAM_A_RD_N => vram0_ram_a_rd_n,
      VRAM0_RAM_A_DI   => vram0_ram_a_di,
      VRAM0_RAM_A_DO   => vram0_ram_a_do,
      VRAM0_RAM_A_WAIT => vram0_ram_a_wait,

      ROM_RD    => rom_rd_i,
      ROM_RDY   => rom_rdy_i,
      ROM_A     => rom_a,
      ROM_DO    => rom_do_i,
      ROM_SZ    => x"040",  -- 256K real syscard decode (was x"008"/32K HuCard, see header)
      ROM_POP   => '0',
      ROM_CLKEN => open,

      BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => brm_do, BRM_WE => brm_we,

      GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

      SP64 => '0', SGX => '0',

      JOY_OUT => joy_out, JOY_IN => joy_in,

      CD_EN => '1', CD_RAM_A => cd_ram_a, CD_RAM_DO => cd_ram_do,
      CD_RAM_DI => cd_ram_di_i, CD_RAM_RD => cd_ram_rd, CD_RAM_WR => cd_ram_wr,
      CD_RAM_RDY => cd_ram_rdy_i,
      AC_EN => '0',

      CD_STAT => cd_stat_i, CD_MSG => cd_msg_i, CD_STAT_GET => cd_stat_get_i,
      CD_COMM => cd_comm_i, CD_COMM_SEND => cd_comm_send_i,
      CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
      CD_REGION => '0', CD_RESET => open,
      CD_DATA => cd_data_i, CD_DATA_WR => cd_data_wr_i, CD_AUDIO_WR => '0',
      CD_SUBCD_WR => '0', CD_DATA_END => cd_data_end_i, CD_DM => '0',

      CDDA_SL => open, CDDA_SR => open, ADPCM_S => open, PSG_SL => open, PSG_SR => open,

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
      clk_pixel => clk_pixel, clk_5x_pixel => clk_5x_pixel,
      psg_sl => (others => '0'), psg_sr => (others => '0'),
      cdda_sl => (others => '0'), cdda_sr => (others => '0'), adpcm_s => (others => '0'),
      tmds_clk_n => tmds_clk_n, tmds_clk_p => tmds_clk_p,
      tmds_d_n => tmds_d_n, tmds_d_p => tmds_d_p
   );

end architecture;
