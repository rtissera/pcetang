-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Phase 1: Tang Console 60K, TangCore-integrated (iosys_bl616: ROM load,
-- joypad, OSD), HuCard-only -- no CD (NO_CD=>1), no SGX (LITE=>1), no Arcade Card
-- (AC_EN='0'). Matches NECTang's own proven Console 60K config for those generics.
--
-- CD (NO_CD=>0) was tried on top of this same file, twice, real gw_sh: does not fit
-- (BSRAM 118/118 or 119 depending on tool pass, routing fails outright) -- see
-- docs/ARCHITECTURE.md's "Phase 2" section for the full real result and the root
-- cause found for why forcing a fit here would misrepresent, not solve, the problem
-- (CD's audio pipeline is currently dead-code-eliminated since nothing wires PSG/
-- CDDA/ADPCM outputs to anything -- real audio would make the fit worse, not better).
-- Reverted to NO_CD=>1 here so this file stays a real, clean, buildable Phase 1
-- reference; the
-- new parts here are ROM loading via iosys_bl616 instead of a fixed test pattern, real
-- joypad input, and HDMI output via pce2hdmi.sv -- none of that exists in NECTang's own
-- bring-ups, which use a fixed BRAM pattern and no video/joypad wiring at all.
--
-- NOT VERIFIED ON HARDWARE. First real gw_sh attempt for this repo -- see
-- docs/ARCHITECTURE.md's status note. Joypad button mapping (iosys_bl616's DS2/SNES-
-- shaped joy1[11:0] onto pce_top's 2-select-bit/4-data-bit protocol) is a reasonable
-- first guess, not verified against real PCE controller protocol documentation --
-- doesn't block a real synthesis attempt (any 4-bit signal wires fine), does need a
-- real check before this is trusted to control an actual game.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_console60k is
   port (
      clk         : in    std_logic;                      -- 50 MHz crystal
      key_reset_n : in    std_logic;                       -- S2, active low
      leds_n      : out   std_logic_vector(1 downto 0);

      -- HDMI
      tmds_clk_n  : out   std_logic;
      tmds_clk_p  : out   std_logic;
      tmds_d_n    : out   std_logic_vector(2 downto 0);
      tmds_d_p    : out   std_logic_vector(2 downto 0);

      -- BL616 UART link. Pin assignment NOT YET CONFIRMED against a real Console 60K
      -- schematic for TangCore's specific firmware -- see docs/ARCHITECTURE.md.
      uart_rxd    : in    std_logic;
      uart_txd    : out   std_logic
   );
end entity;

architecture rtl of pcetang_console60k is

   component console60k_pll is
      port (
         clkin     : in  std_logic;
         reset     : in  std_logic;
         clk_pce   : out std_logic;
         clk_sdram : out std_logic;
         lock      : out std_logic
      );
   end component;

   component pcetang_console60k_hdmi_pll is
      port (
         clkin        : in  std_logic;
         reset        : in  std_logic;
         clk_pixel    : out std_logic;
         clk_5x_pixel : out std_logic;
         lock         : out std_logic
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

   component pce2hdmi is
      generic (
         CAP_WIDTH  : integer := 256;
         CAP_HEIGHT : integer := 224;
         COLOR_BITS : integer := 3
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

         tmds_clk_n : out std_logic;
         tmds_clk_p : out std_logic;
         tmds_d_n   : out std_logic_vector(2 downto 0);
         tmds_d_p   : out std_logic_vector(2 downto 0)
      );
   end component;

   signal clk_pce, clk_pixel, clk_5x_pixel : std_logic;
   signal pll_lock, hdmi_pll_lock, reset_n : std_logic;

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

   -- ROM: on-chip only for Phase 1 (Console 60K's whole engine fits on-chip per
   -- NECTang's own real numbers -- no external memory needed here). First attempt used
   -- addr_width=19 (512K) -- real gw_sh measured that as needing 3,518,715 DFF total
   -- (ERROR (RP0001), limit 60780): this single dual-port memory alone (512K x8 =
   -- 4Mbit) is bigger than Console 60K's ENTIRE on-chip BSRAM capacity (118 blocks x
   -- 18Kbit =~ 2.1Mbit total), let alone the ~30% of it NECTang's own real measurements
   -- show still free after the base engine (82/118 blocks already spent). Not an
   -- inference bug -- a real sizing mistake, corrected to 32K (addr_width=15), the same
   -- proven-safe depth class PRAM/RAM/VRAM0/VRAM1 already use successfully throughout
   -- this codebase. Real HuCards range far larger; this is a first-cut ceiling for
   -- proving the integration builds at all, not a spec -- external memory for real
   -- cartridge sizes is separate, unstarted work.
   constant ROM_ABITS : integer := 15;
   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_core : std_logic_vector(7 downto 0);
   signal rom_wr_addr : unsigned(ROM_ABITS-1 downto 0) := (others => '0');
   signal rom_loading_r : std_logic := '0';

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
             clk_sdram => open, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll
   port map (clkin => clk, reset => not key_reset_n, clk_pixel => clk_pixel,
             clk_5x_pixel => clk_5x_pixel, lock => hdmi_pll_lock);

   -- DS2/SNES-shaped bit order per iosys_bl616.v's own comment: R L X A RT LT DN UP
   -- START SELECT Y B. Not wired to a real controller in this first cut -- tied
   -- inactive (all 1, active-low-style unpressed per that convention) so iosys_bl616
   -- still has something well-formed to poll.
   joy1_ds2 <= (others => '0');
   joy1     <= joy1_ds2 or hid1(11 downto 0);

   sys_inst: iosys_bl616
   generic map (
      FREQ => 42_857_000,     -- matches clk_pce below, not the AUDIO/hclk domain
      COLOR_LOGO => "011000000001000",   -- purple-ish, arbitrary first-cut choice
      CORE_ID => x"0003",                -- 1=nestang, 2=snestang (their scheme) -- 3
                                          -- picked here as unclaimed; real ID scheme
                                          -- coordination with nand2mario not done
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

   -- ROM loader: rom_loading[0] pulses 0->1 at load start (per iosys_bl616.v's UART
   -- protocol comment) -- reset the write-address counter on that edge, then just
   -- count up one byte per rom_do_valid pulse. No iNES-style header parsing needed --
   -- ROM_SZ/ROM_POP are pce_top.vhd generics/ports already handling PCE-side metadata,
   -- separate from this byte stream.
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

   rom_mem: entity work.dpram
   generic map (addr_width => ROM_ABITS, data_width => 8)
   port map (
      clock    => clk_pce,
      address_a => rom_a(ROM_ABITS-1 downto 0),
      data_a    => (others => '0'),
      wren_a    => '0',
      q_a       => rom_do_core,

      address_b => std_logic_vector(rom_wr_addr),
      data_b    => rom_do,
      wren_b    => rom_do_valid
   );

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   core: entity work.pce_top
   generic map (LITE => 1, EXT_VRAM0 => 0, NO_CD => 1)
   port map (
      RESET      => not reset_n,
      COLD_RESET => not reset_n,
      CLK        => clk_pce,

      VRAM0_RAM_A_ADDR => open, VRAM0_RAM_A_REQ => open, VRAM0_RAM_A_RD_N => open,
      VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0'),
      VRAM0_RAM_A_WAIT => '0',

      ROM_RD    => open,
      ROM_RDY   => '1',            -- no wait-state support in this first cut
      ROM_A     => rom_a,
      ROM_DO    => rom_do_core,
      ROM_SZ    => x"008",         -- placeholder, same as NECTang's own bring-ups
      ROM_POP   => '0',
      ROM_CLKEN => open,

      BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => brm_do, BRM_WE => brm_we,

      GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

      SP64 => '0', SGX => '0',

      JOY_OUT => joy_out, JOY_IN => joy_in,

      CD_EN => '0', CD_RAM_A => open, CD_RAM_DO => open,
      CD_RAM_DI => (others => '0'), CD_RAM_RD => open, CD_RAM_WR => open,
      AC_EN => '0',

      CD_STAT => (others => '0'), CD_MSG => (others => '0'), CD_STAT_GET => '0',
      CD_COMM => open, CD_COMM_SEND => open,
      CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
      CD_REGION => '0', CD_RESET => open,
      CD_DATA => (others => '0'), CD_DATA_WR => '0', CD_AUDIO_WR => '0',
      CD_SUBCD_WR => '0', CD_DATA_END => open, CD_DM => '0',

      CDDA_SL => open, CDDA_SR => open, ADPCM_S => open, PSG_SL => open, PSG_SR => open,

      BG_EN => '1', SPR_EN => '1', GRID_EN => (others => '0'), CPU_PAUSE_EN => '0',

      BORDER_EN => '0', ReducedVBL => '0',
      VIDEO_R => video_r, VIDEO_G => video_g, VIDEO_B => video_b,
      VIDEO_BW => open, VIDEO_CE => video_ce, VIDEO_CE_FS => open,
      VIDEO_VS => video_vs, VIDEO_HS => video_hs,
      VIDEO_HBL => video_hbl, VIDEO_VBL => video_vbl
   );

   -- PCE joypad protocol (pce_top.vhd:335,344): JOY_OUT(0) selects which 4-bit nibble
   -- JOY_IN returns. First-cut mapping, not verified against real PCE controller docs
   -- -- see this file's header.
   joy_in <= joy1(4) & joy1(5) & joy1(11) & joy1(10) when joy_out(0) = '1' else
             joy1(3) & joy1(2) & joy1(1)  & joy1(0);

   hdmi_out: pce2hdmi
   port map (
      clk => clk_pce, resetn => reset_n,
      video_r => video_r, video_g => video_g, video_b => video_b,
      video_ce => video_ce, video_hs => video_hs, video_vs => video_vs,
      video_hbl => video_hbl, video_vbl => video_vbl,
      overlay => overlay, overlay_x => overlay_x, overlay_y => overlay_y,
      overlay_color => overlay_color,
      clk_pixel => clk_pixel, clk_5x_pixel => clk_5x_pixel,
      tmds_clk_n => tmds_clk_n, tmds_clk_p => tmds_clk_p,
      tmds_d_n => tmds_d_n, tmds_d_p => tmds_d_p
   );

   leds_n(0) <= not (pll_lock and hdmi_pll_lock);
   leds_n(1) <= not rom_loading(0);

end architecture;
