-- SPDX-License-Identifier: GPL-3.0-or-later

-- Clock generation for the Tang Console 60K (GW5AT-60B), PCE/SGX/TG16 core.
--
-- PLLA component declaration/port list structure reused from the ZX Spectrum Next port's
-- own GW5A PLL wrapper (../TangNano60K/src/common/pll/zxnext_pll_mod.vhd), same author,
-- same GPL-3.0 -- see THIRD_PARTY_LICENSES.md. That file's actual generic VALUES are
-- Z80-core-specific (28.000 MHz exactly, from a 1400 MHz VCO) and NOT reused here -- this
-- is a fresh, independent PLLA instance for PCE's own ~42.9545 MHz core master clock
-- requirement (see docs/PORTING.md's Clocking section), not a shared/retuned instance.
--
-- PLLA formula, reverse-derived from that proven file (not from Gowin documentation this
-- session had access to -- confirm independently if this doesn't match a datasheet):
--   FVCO   = FCLKIN / IDIV_SEL * MDIV_SEL      (direct integer divide/multiply, unlike
--                                                rPLL's IDIV_SEL+1/FBDIV_SEL+1 convention)
--   CLKOUTn = FVCO / ODIVn_SEL
-- Cross-checked against that file's own claim ("lands on exactly 28.000 MHz" from a 50 MHz
-- crystal): FCLKIN=50, IDIV_SEL=1, MDIV_SEL=28 -> FVCO=1400 MHz; ODIV=50 -> 1400/50=28.000
-- MHz exactly, matching. Confidence: derived and cross-checked against one known-good
-- data point, not confirmed against Gowin's own PLLA datasheet -- verify independently
-- before trusting the formula for a third, unrelated frequency target.
--
-- Core master: FCLKIN=50, IDIV_SEL=1, MDIV_SEL=24 -> FVCO=1200 MHz; ODIV0_SEL=28 ->
-- 1200/28 = 42.857142857 MHz, -0.227% versus the exact 42.9545 MHz target -- same class
-- of small compromise as the Nano 20K solve's +0.57%. FVCO=1200 MHz is comfortably inside
-- the range the sibling file already proved valid (1400 MHz), so lower risk than it looks.
--
-- No HDMI stage in this file -- this PLL exists only to get a first core resource/timing
-- data point (docs/PORTING.md), same scope as nano20k_core_test.vhd's Nano 20K build.
-- Add an HDMI PLLA (a second instance, or a second tap on this one) when video output
-- work starts.
--
-- clk_sdram: Primer 25K only (src/common/mem/sdram.sv, the physical Tang SDRAM V1.3 PMOD
-- module -- Console 60K's own engine fits entirely on-chip, this output stays unconnected
-- there and costs nothing). PLLA has 7 independent CLKOUTn taps off the SAME FVCO -- no
-- second PLL primitive needed, unlike the GW2AR-18C 2-PLL limit nano20k_pll.vhd hit.
-- ODIV1_SEL=10 -> 1200/10 = 120.000 MHz. Chosen over a closer match to the proven
-- ../TangNano60K sibling's 140 MHz (not reachable as a clean integer divisor of this
-- FVCO) for a bit of extra timing margin on this board+chip-family pairing, which that
-- sibling never tested (it only proved 140 MHz on GW5AT-60B/Console 60K, not GW5A-25A/
-- Primer 25K) -- re-tune RASCAS_DELAY/CAS_LATENCY in sdram.sv if a real gw_sh timing
-- report doesn't close at this rate.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity console60k_pll is
   port (
      clkin   : in  std_logic;    -- 50 MHz crystal
      reset   : in  std_logic;    -- active-high reset input
      clk_pce   : out std_logic;    -- 42.857 MHz -- PCE/SGX/TG16 core master clock
      clk_sdram : out std_logic;    -- 120 MHz -- Primer 25K's sdram.sv only, see above
      lock      : out std_logic
   );
end entity;

architecture rtl of console60k_pll is

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
         IDIV_SEL   => 1,     -- /1
         FBDIV_SEL  => 1,     -- required field, GW0205 warned it was left at an invalid
                               -- default when omitted; 1 matches the proven sibling config
         MDIV_SEL   => 24,    -- x24 -> FVCO 1200 MHz
         ODIV0_SEL  => 28,    -- 1200/28 = 42.857 MHz
         ODIV1_SEL  => 10,    -- 1200/10 = 120.000 MHz (clk_sdram)
         CLKOUT0_EN => "TRUE",
         CLKOUT1_EN => "TRUE"
      )
      port map (
         LOCK     => lock,
         CLKOUT0  => clk_pce,
         CLKOUT1  => clk_sdram,
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
