-- SPDX-License-Identifier: GPL-3.0-or-later

-- HDMI PLL for pcetang on Tang Console 60K (GW5AT-60B). Separate PLLA instance from
-- NECTang's own console60k_pll.vhd (which stays unchanged, still provides clk_pce) --
-- GW5A has multiple independent PLLA blocks, unlike GW2AR-18C's 2-PLL ceiling noted in
-- that project's nano20k_pll.vhd. NOT YET CONFIRMED against a real GW5AT-60B datasheet
-- or gw_sh run -- see docs/ARCHITECTURE.md, this is this repo's first PLL attempt.
--
-- Target: as close as achievable to 74.25 MHz pixel clock + 371.25 MHz (5x) TMDS
-- serializer clock, the standard HDMI 720p60 pair. Three real gw_sh measurements got
-- here, not guessed:
--   1. MDIV_SEL=297 (IDIV_SEL=10, exact 1485 MHz FVCO) -> `WARN (EX0205): parameter
--      "MDIV_SEL" value invalid, replaced by default value "8"` -- silently built the
--      WRONG PLL, not a rejected build.
--   2. MDIV_SEL=30/IDIV_SEL=1 (FVCO=1500 MHz) -> accepted as a PARAMETER (confirms
--      MDIV_SEL=30 itself is valid), but `WARN (PA1019): Invalid VCO frequency ...
--      suitable range is from 700MHz to 1400MHz` -- 1500 is just above the ceiling.
--   3. IDIV_SEL=4/MDIV_SEL=89 (FVCO=1112.5, inside the VCO range) -> `ERROR (PA2078):
--      Invalid PFD frequency 'FCLKIN/IDIV_SEL' ... suitable range is from 19MHz to
--      87.5MHz` -- PFD=50/4=12.5 MHz, below the floor. A second, independent
--      constraint on IDIV_SEL alone, separate from the VCO range check on the
--      resulting FVCO -- from FCLKIN=50, only IDIV_SEL=1 (PFD 50) or 2 (PFD 25) clear
--      19 MHz; IDIV_SEL>=3 never will.
-- Corrected to IDIV_SEL=2 with the ALREADY-PARAMETER-CONFIRMED MDIV_SEL=30 (measurement
-- 2 above), giving FVCO=25*30=750 MHz -- inside 700-1400, and reusing a value already
-- known to parse rather than guessing a fourth number. ODIV0_SEL=10 -> 75.000 MHz
-- (+1.01% vs 74.25), ODIV1_SEL=2 -> 375.000 MHz (+1.01%) -- exact 5x ratio preserved.
-- Not verified on real hardware.

library ieee;
use ieee.std_logic_1164.all;

entity pcetang_console60k_hdmi_pll is
   port (
      clkin        : in  std_logic;    -- 50 MHz crystal, same source as console60k_pll
      reset        : in  std_logic;
      clk_pixel    : out std_logic;    -- 74.25 MHz
      clk_5x_pixel : out std_logic;    -- 371.25 MHz
      lock         : out std_logic
   );
end entity;

architecture rtl of pcetang_console60k_hdmi_pll is

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
         IDIV_SEL   => 2,     -- /2 -> PFD 25 MHz (within the measured 19-87.5 MHz range)
         FBDIV_SEL  => 1,
         MDIV_SEL   => 30,    -- x30 -> FVCO 750 MHz (50/2*30, within 700-1400)
         ODIV0_SEL  => 10,    -- 750/10 = 75.000 MHz (clk_pixel, +1.01% vs 74.25)
         ODIV1_SEL  => 2,     -- 750/2  = 375.000 MHz (clk_5x_pixel, +1.01% vs 371.25)
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
