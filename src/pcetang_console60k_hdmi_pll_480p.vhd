-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- 480p60 HDMI PLL for pcetang's Console 60K CD-capable scandoubler path
-- (pcetang_console60k_cd.vhd + pce2hdmi_sd.sv, see docs/OVERHEAD.md sections 5-7).
-- Separate PLLA instance from both console60k_pll.vhd (clk_pce) and
-- pcetang_console60k_hdmi_pll.vhd (the 720p pair used by the Phase 1, full-frame-
-- capture video path) -- GW5A has PLL headroom for a third instance (already proven:
-- this repo runs two PLLA instances simultaneously on Console 60K today).
--
-- Target: 27.027 MHz pixel clock + 135.135 MHz (5x) TMDS serializer clock -- the
-- standard CEA-861 VIDEO_ID_CODE=2 (720x480p60) pair, same code Nano 20K's own HDMI
-- path already uses (nano20k_pll.vhd's clk_27/clk_135, a different physical PLL on a
-- different chip family, but the same target frequencies).
--
-- Computed from this repo's own already-measured real PLLA constraints (see
-- pcetang_console60k_hdmi_pll.vhd's header for the 3 real gw_sh measurements that
-- found them): PFD = FCLKIN/IDIV_SEL must be 19-87.5 MHz, FVCO = PFD*MDIV_SEL must be
-- 700-1400 MHz. IDIV_SEL=1 (PFD=50, inside range), MDIV_SEL=27 -> FVCO=1350 MHz
-- (inside 700-1400). ODIV0_SEL=50 -> 1350/50 = 27.000 MHz (clk_pixel, -0.0999% vs
-- 27.027 -- the identical real deviation this repo's own nano20k_pll.vhd clk_27
-- already carries and that build measured clean, 0/0 violations). ODIV1_SEL=10 ->
-- 1350/10 = 135.000 MHz (clk_5x_pixel, same -0.0999%, exact 5x ratio preserved).
--
-- NOT YET CONFIRMED against a real gw_sh run -- ODIV0_SEL=50 in particular hasn't been
-- used anywhere else in this repo (the working 720p PLL uses ODIV0_SEL=10, ODIV1_SEL=2)
-- so it's not yet known whether 50 is a value Gowin's PLLA accepts as given or silently
-- substitutes (this repo's own header comment above documents exactly that failure mode
-- happening for a different parameter, MDIV_SEL=297, on the 720p PLL's first attempt) --
-- first real gw_sh attempt for this file will confirm or find the same class of issue.

library ieee;
use ieee.std_logic_1164.all;

entity pcetang_console60k_hdmi_pll_480p is
   port (
      clkin        : in  std_logic;    -- 50 MHz crystal, same source as console60k_pll
      reset        : in  std_logic;
      clk_pixel    : out std_logic;    -- 27.000 MHz target 27.027
      clk_5x_pixel : out std_logic;    -- 135.000 MHz target 135.135
      lock         : out std_logic
   );
end entity;

architecture rtl of pcetang_console60k_hdmi_pll_480p is

   signal gw_gnd : std_logic;
   signal mdrdo  : std_logic_vector(7 downto 0);

   component PLLA is
      generic (
         FCLKIN: string := "100";
         IDIV_SEL: integer := 0;
         FBDIV_SEL: integer := 0;
         MDIV_SEL: integer := 2;
         MDIV_FRAC_SEL: integer := 0;
         ODIV0_SEL: integer := 8;
         ODIV0_FRAC_SEL: integer := 0;
         ODIV1_SEL: integer := 8;
         ODIV2_SEL: integer := 8;
         ODIV3_SEL: integer := 8;
         ODIV4_SEL: integer := 8;
         ODIV5_SEL: integer := 8;
         ODIV6_SEL: integer := 8;
         CLKOUT0_EN: string := "FALSE";
         CLKOUT1_EN: string := "FALSE";
         CLKOUT2_EN: string := "FALSE";
         CLKOUT3_EN: string := "FALSE";
         CLKOUT4_EN: string := "FALSE";
         CLKOUT5_EN: string := "FALSE";
         CLKOUT6_EN: string := "FALSE";
         CLKFB_SEL: string := "INTERNAL";
         CLKOUT0_DT_DIR: bit := '1';
         CLKOUT1_DT_DIR: bit := '1';
         CLKOUT2_DT_DIR: bit := '1';
         CLKOUT3_DT_DIR: bit := '1';
         CLKOUT0_DT_STEP: integer := 0;
         CLKOUT1_DT_STEP: integer := 0;
         CLKOUT2_DT_STEP: integer := 0;
         CLKOUT3_DT_STEP: integer := 0;
         CLK0_IN_SEL: bit := '0';
         CLK0_OUT_SEL: bit := '0';
         CLK1_IN_SEL: bit := '0';
         CLK1_OUT_SEL: bit := '0';
         CLK2_IN_SEL: bit := '0';
         CLK2_OUT_SEL: bit := '0';
         CLK3_IN_SEL: bit := '0';
         CLK3_OUT_SEL: bit := '0';
         CLK4_IN_SEL: bit_vector := "00";
         CLK4_OUT_SEL: bit := '0';
         CLK5_IN_SEL: bit := '0';
         CLK5_OUT_SEL: bit := '0';
         CLK6_IN_SEL: bit := '0';
         CLK6_OUT_SEL: bit := '0';
         CLKOUT0_PE_COARSE: integer := 0;
         CLKOUT0_PE_FINE: integer := 0;
         CLKOUT1_PE_COARSE: integer := 0;
         CLKOUT1_PE_FINE: integer := 0;
         CLKOUT2_PE_COARSE: integer := 0;
         CLKOUT2_PE_FINE: integer := 0;
         CLKOUT3_PE_COARSE: integer := 0;
         CLKOUT3_PE_FINE: integer := 0;
         CLKOUT4_PE_COARSE: integer := 0;
         CLKOUT4_PE_FINE: integer := 0;
         CLKOUT5_PE_COARSE: integer := 0;
         CLKOUT5_PE_FINE: integer := 0;
         CLKOUT6_PE_COARSE: integer := 0;
         CLKOUT6_PE_FINE: integer := 0;
         DE0_EN: string := "FALSE";
         DE1_EN: string := "FALSE";
         DE2_EN: string := "FALSE";
         DE3_EN: string := "FALSE";
         DE4_EN: string := "FALSE";
         DE5_EN: string := "FALSE";
         DE6_EN: string := "FALSE";
         DYN_DPA_EN: string := "FALSE";
         DYN_PE0_SEL: string := "FALSE";
         DYN_PE1_SEL: string := "FALSE";
         DYN_PE2_SEL: string := "FALSE";
         DYN_PE3_SEL: string := "FALSE";
         DYN_PE4_SEL: string := "FALSE";
         DYN_PE5_SEL: string := "FALSE";
         DYN_PE6_SEL: string := "FALSE";
         ICP_SEL : std_logic_vector(5 downto 0) := "XXXXXX";
         LPF_RES : std_logic_vector(2 downto 0) := "XXX";
         LPF_CAP: bit_vector := "00";
         RESET_I_EN: string := "FALSE";
         RESET_O_EN: string := "FALSE";
         SSC_EN: string := "FALSE"
      );
      port (
         LOCK: out std_logic;
         CLKOUT0: out std_logic;
         CLKOUT1: out std_logic;
         CLKOUT2: out std_logic;
         CLKOUT3: out std_logic;
         CLKOUT4: out std_logic;
         CLKOUT5: out std_logic;
         CLKOUT6: out std_logic;
         CLKFBOUT: out std_logic;
         MDRDO: out std_logic_vector(7 downto 0);
         CLKIN: in std_logic;
         CLKFB: in std_logic;
         RESET: in std_logic;
         PLLPWD: in std_logic;
         RESET_I: in std_logic;
         RESET_O: in std_logic;
         PSSEL: in std_logic_vector(2 downto 0);
         PSDIR: in std_logic;
         PSPULSE: in std_logic;
         SSCPOL: in std_logic;
         SSCON: in std_logic;
         SSCMDSEL: in std_logic_vector(6 downto 0);
         SSCMDSEL_FRAC: in std_logic_vector(2 downto 0);
         MDCLK: in std_logic;
         MDOPC: in std_logic_vector(1 downto 0);
         MDAINC: in std_logic;
         MDWDI: in std_logic_vector(7 downto 0)
      );
   end component;

begin

   gw_gnd <= '0';

   PLLA_inst: PLLA
      generic map (
         FCLKIN     => "50",
         IDIV_SEL   => 1,     -- /1 -> PFD 50 MHz (within 19-87.5 MHz)
         FBDIV_SEL  => 1,
         MDIV_SEL   => 27,    -- x27 -> FVCO 1350 MHz (50*27, within 700-1400)
         ODIV0_SEL  => 50,    -- 1350/50 = 27.000 MHz (clk_pixel, -0.0999% vs 27.027)
         ODIV1_SEL  => 10,    -- 1350/10 = 135.000 MHz (clk_5x_pixel, -0.0999%)
         CLKOUT0_EN => "TRUE",
         CLKOUT1_EN => "TRUE"
      )
      port map (
         LOCK     => lock,
         CLKOUT0  => clk_pixel,
         CLKOUT1  => clk_5x_pixel,
         CLKOUT2  => open,
         CLKOUT3  => open,
         CLKOUT4  => open,
         CLKOUT5  => open,
         CLKOUT6  => open,
         CLKFBOUT => open,
         MDRDO    => mdrdo,
         CLKIN    => clkin,
         CLKFB    => gw_gnd,
         RESET    => reset,
         PLLPWD   => gw_gnd,
         RESET_I  => gw_gnd,
         RESET_O  => gw_gnd,
         PSSEL    => (others => '0'),
         PSDIR    => gw_gnd,
         PSPULSE  => gw_gnd,
         SSCPOL   => gw_gnd,
         SSCON    => gw_gnd,
         SSCMDSEL => (others => '0'),
         SSCMDSEL_FRAC => (others => '0'),
         MDCLK    => gw_gnd,
         MDOPC    => (others => '0'),
         MDAINC   => gw_gnd,
         MDWDI    => (others => '0')
      );

end architecture;
