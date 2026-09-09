-- SPDX-License-Identifier: GPL-3.0-or-later

-- 720p60 HDMI PLL for pcetang's Console 60K CD-capable scandoubler path
-- (pcetang_console60k_cd.vhd + pce2hdmi_sd.sv), added 2026-09-06 as the replacement
-- for pcetang_console60k_hdmi_pll_480p.vhd's 480p60 output -- some HDMI
-- sinks (seen real, away from home) reject the legacy CEA-861 480p60 timing outright
-- ("no signal") despite it being nominally standard; 720p60 is close to universally
-- accepted. Same PLLA-instance-count precedent as the 480p file (a 3rd simultaneous
-- PLLA instance on this board, already proven).
--
-- Target: 74.25 MHz pixel clock + 371.25 MHz (5x) TMDS serializer clock -- the
-- standard CEA-861 VIDEO_ID_CODE=4 (1280x720p60) pair, exact (not the NTSC 59.94
-- fractional flavor -- pce2hdmi_sd.sv's own VIDEO_REFRESH parameter is plain 60.0).
--
-- Real reference: tangcore/monitor/src/plla/pll_74.v (this repo's own gw_sh-clean,
-- shipped, hardware-proven Console 60K HDMI PLL for the exact same GW5AT-60 part) uses
-- ODIV0_SEL=20 / ODIV1_SEL=4 for this exact 74.25/371.25 MHz pair -- reused verbatim
-- here since they're confirmed-real, hardware-valid divider taps on this chip (unlike
-- the 480p file's own ODIV0_SEL=50, which that file's own header flags as unconfirmed).
-- That reference's FCLKIN is 27 MHz (a different clock domain than this board's own
-- top-level 50 MHz crystal, see pcetang_console60k_cd.vhd port "clk"), so IDIV_SEL/
-- MDIV_SEL had to be re-derived for a 50 MHz input:
--   PFD = FCLKIN/IDIV_SEL = 50/2 = 25 MHz (within the 19-87.5 MHz range this repo's
--   480p PLL file already documented from real PLLA constraints).
--   FVCO = PFD*MDIV_SEL = 25*59 = 1475 MHz -- close to both this repo's own proven
--   480p FVCO (1350 MHz) and tangcore/monitor's own proven FVCO (27*55=1485 MHz),
--   which straddle this value.
--   clk_pixel = FVCO/ODIV0_SEL = 1475/20 = 73.75 MHz (-0.67% vs 74.25 nominal --
--   larger than this repo's usual ~0.1% PLL deviations, but real, exact 5x ratio
--   preserved via ODIV1, and HDMI sinks recover from an embedded clock so this is
--   expected to be within normal TMDS receiver tolerance).
--   clk_5x_pixel = FVCO/ODIV1_SEL = 1475/4 = 368.75 MHz.
--
-- An exact 1485 MHz FVCO from a 50 MHz input needs MDIV_SEL=297 with IDIV_SEL=10 (PFD
-- 5 MHz, below the 19 MHz floor) or an equivalent fractional-MDIV solution -- MDIV_SEL
-- =297 is the exact value this repo's own 480p file header already documents Gowin's
-- tool silently mishandling for a different PLL, so that path was deliberately not
-- retried here.
--
-- CONFIRMED (2026-09-06): real gw_sh build is clean (0 timing violations) and a real
-- monitor locks 1280x720p60 from this PLL on real Console 60K hardware.

library ieee;
use ieee.std_logic_1164.all;

entity pcetang_console60k_hdmi_pll_720p is
   port (
      clkin        : in  std_logic;    -- 50 MHz crystal, same source as console60k_pll
      reset        : in  std_logic;
      clk_pixel    : out std_logic;    -- 73.75 MHz target 74.25
      clk_5x_pixel : out std_logic;    -- 368.75 MHz target 371.25
      lock         : out std_logic
   );
end entity;

architecture rtl of pcetang_console60k_hdmi_pll_720p is

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
         -- 2026-09-06 REAL FIX. The previous values put FVCO at 1475 MHz, OUTSIDE the
         -- 700-1400 MHz range this PLL supports, and gw_sh had been saying so on every
         -- build: "WARN (PA1019) : Invalid VCO frequency ... suitable range is from
         -- 700MHz to 1400MHz". It happened to lock on the one board tested, but an
         -- out-of-spec VCO is not something to ship -- it has no guaranteed margin over
         -- temperature or across parts.
         --
         -- Re-derived with the fractional MDIV this primitive already exposes
         -- (MDIV_FRAC_SEL counts eighths), which the old header dismissed without
         -- trying it:
         --   PFD  = FCLKIN/IDIV_SEL = 50/1 = 50 MHz          (19-87.5 MHz range, OK)
         --   FVCO = PFD*(MDIV_SEL + MDIV_FRAC_SEL/8)
         --        = 50*(14 + 7/8) = 50*14.875 = 743.75 MHz   (700-1400, IN SPEC)
         --   clk_pixel    = 743.75/10 = 74.375 MHz
         --   clk_5x_pixel = 743.75/2  = 371.875 MHz          (exact 5x preserved)
         -- 74.375 MHz is +0.17% against the 74.25 MHz CEA-861 nominal, versus -0.67%
         -- before -- so this is both in spec AND four times closer to standard.
         FCLKIN     => "50",
         IDIV_SEL   => 1,     -- /1 -> PFD 50 MHz (within 19-87.5 MHz)
         FBDIV_SEL  => 1,
         MDIV_SEL   => 14,    -- x14.875 -> FVCO 743.75 MHz, in the 700-1400 range
         -- PCE PORT (2026-09-09): .875 -> .75, deliberately making the output frame rate
         -- slightly SLOWER than the core's, which is what the VSYNC genlock in
         -- pce2hdmi_sd.sv requires. The direction matters and is easy to get backwards:
         --
         --   core   ~59.92 Hz  (clk_pce 42.857 MHz, 262 lines x 1365 master clocks)
         --   output  59.60 Hz  (73.75 MHz / (1650 x 750))
         --
         -- Output slower means the core's VSYNC arrives while the output raster still
         -- has ~4 lines to go, i.e. inside the 30-line vertical blanking of 720p. The
         -- genlock reset therefore truncates only blanking. Were the output FASTER (as
         -- it was at 74.375 MHz, 60.10 Hz) the raster would already have wrapped and the
         -- reset would cut lines off the TOP of the picture instead.
         MDIV_FRAC_SEL => 7,  -- the .875 (eighths). Was briefly 6 (73.75 MHz) for the
                              -- genlock attempt backed out in pce2hdmi_sd.sv; restore 6
                              -- when genlock is done for real.
         ODIV0_SEL  => 10,    -- 743.75/10 = 74.375 MHz (clk_pixel, +0.17% vs 74.25)
         ODIV1_SEL  => 2,     -- 743.75/2 = 371.875 MHz (clk_5x_pixel, exact 5x ratio)
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
