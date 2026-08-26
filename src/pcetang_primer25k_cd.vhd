-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Phase 2 CD attempt, Tang Primer 25K, TangCore-integrated (iosys_bl616: ROM
-- load, joypad, OSD via pce2hdmi_sd's scandoubler), NO_CD=>0, EXT_VRAM0=>1 (required --
-- Primer 25K's whole engine does not fit on-chip). CURRENT REAL STATUS: FAILS,
-- ERROR (RP0006) LUT overflow (60649/23040 default, 49449/23040 with a
-- direct-GowinSynthesis `-ram_rw_check 0` invocation gw_sh's own `set_option` cannot
-- express) -- see docs/ARCHITECTURE.md's "Goal revised" section for the full real
-- investigation. Root cause, directly confirmed (not inferred): BSRAM exhaustion
-- cascading into LUT fallback -- every sub-piece (bare CD engine, iosys alone, video
-- alone) independently drives Primer 25K's 56-block BSRAM ceiling to 54-56/56, and
-- combined real demand exceeds it. Confirmed by measurement: shrinking the on-chip
-- cart ROM buffer (line ~206, `ROM_ABITS`) from 15 (32KB, 16 real blocks) to 11 (2KB)
-- alone drops the result to a clean `Logic 18230/23040 (80%), BSRAM 56/56 (100%)`, CD's
-- full 64KB `ADPCM_DRAM` confirmed still live (not swept) -- the capacity thesis is
-- measured, not a plan. Real fix path (not yet built): move cart ROM off-chip through
-- `sdram.sv`'s existing, already-built but never-wired port B -- two real open design
-- questions (bank-0 addressing collision with Phase 3's own future needs; whether the
-- HuC6280 CPU can tolerate `WAIT_N`'s stall duration for a real SDRAM round trip) need
-- answers before that bridge gets written, per the same document section.
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

   signal clk_pce, clk_sdram, clk_pixel, clk_5x_pixel : std_logic;
   signal pll_lock, hdmi_pll_lock, reset_n : std_logic;
   signal sdram_init : std_logic;

   signal vram0_ram_a_addr : std_logic_vector(20 downto 0);
   signal vram0_ram_a_req  : std_logic;
   signal vram0_ram_a_rd_n : std_logic;
   signal vram0_ram_a_di   : std_logic_vector(7 downto 0);
   signal vram0_ram_a_do   : std_logic_vector(7 downto 0);
   signal vram0_ram_a_wait : std_logic;
   signal ram_b_wait_nc    : std_logic;

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

   -- 32K, same proven-safe depth as Console 60K's Phase 1 -- see that file's header for
   -- why (real gw_sh measurement, not guessed).
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
      RAM_B_ADDR => (others => '0'),
      RAM_B_REQ  => '0',
      RAM_B_DO   => open,
      RAM_B_WAIT => ram_b_wait_nc
   );

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

      ROM_RD    => open,
      ROM_RDY   => '1',
      ROM_A     => rom_a,
      ROM_DO    => rom_do_core,
      ROM_SZ    => x"008",
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
