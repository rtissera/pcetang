-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- Clock generation for the Tang Console 60K (GW5AT-60B), PCE/SGX/TG16 core.
--
-- PLLA component declaration/port list structure reused from the ZX Spectrum Next port's
-- own GW5A PLL wrapper (../TangNano60K/src/common/pll/zxnext_pll_mod.vhd), same author,
-- same GPL-3.0 -- see THIRD_PARTY_LICENSES.md. That file's actual generic VALUES are
-- Z80-core-specific (28.000 MHz exactly, from a 1400 MHz VCO) and NOT reused here -- this
-- is a fresh, independent PLLA instance for PCE's own ~42.9545 MHz core master clock
-- requirement (see NECTang's docs/PORTING.md's Clocking section), not a shared/retuned instance.
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
-- data point (NECTang's docs/PORTING.md), same scope as nano20k_core_test.vhd's Nano 20K build.
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
      -- HDMI clocks, taken from the SAME 1200 MHz VCO as clk_pce so the video raster is
      -- rationally locked to the core instead of beating against it. See the "exact
      -- lock" note below.
      clk_pixel    : out std_logic; -- 1200/20 = 60 MHz
      clk_5x_pixel : out std_logic; -- 1200/4  = 300 MHz (exactly 5x clk_pixel)
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
         -- 2026-09-06: 120 -> 100 MHz (ODIV1 10 -> 12). Real hardware read-back of the
         -- ROM image showed 66 of 128 bytes wrong by 1-2 scattered bits, and the flips
         -- were 128/128 in the SAME direction (0->1, never a single 1->0) -- the
         -- signature of sampling the DQ bus before it has settled, not of a logic bug.
         -- The SDRAM clock is ODDR-forwarded at mid-phase, so the read round trip
         -- (clock out -> tAC -> data back) has to fit inside half a clk_sdram period;
         -- at 120 MHz that is 4.17 ns against a -6 part's ~5.4 ns tAC plus board and IO
         -- delay, i.e. genuinely short. 100 MHz buys 0.83 ns of period on every edge.
         -- Refresh stays well in spec: 511 cycles @100 MHz = 5.11 us vs the 7.8 us/row
         -- requirement. RASCAS_DELAY/CAS_LATENCY are counted in CYCLES, so a slower
         -- clock only makes them more conservative.
         -- 2026-09-07 REAL FIX: clk_sdram is now EXACTLY 2x clk_pce.
         --   clk_pce   = FVCO/ODIV0 = 1200/28 = 42.857142... MHz
         --   clk_sdram = FVCO/ODIV1 = 1200/14 = 85.714285... MHz   (ratio exactly 2.000)
         --
         -- Why this matters more than the frequency itself. The previous 120 MHz gave a
         -- ratio of 2.8 -- NON-INTEGER -- so although both clocks come from this one PLL,
         -- every clk_pce<->clk_sdram path was a genuine asynchronous crossing. The .sdc
         -- papered over that with `set_multicycle_path -setup 3` in both directions, which
         -- is a PROMISE that the receiver samples only every 3rd cycle. The bridge state
         -- machines sample romb_wait EVERY cycle, so the promise was never kept: STA
         -- validated a constraint the design does not honour and reported "0 violations"
         -- for paths it was effectively not checking. That is why builds with byte-
         -- identical logic behaved completely differently on hardware all evening
         -- (2 read timeouts in one, 65535 saturated in the next).
         --
         -- At an exact 2:1 ratio the two domains are SYNCHRONOUS: no metastability, and
         -- the multicycle fiction can be deleted so STA actually verifies these paths.
         -- Chosen over 120 MHz because 3:1 would need 128.57 MHz, and over 64.8 MHz
         -- (nand2mario's proven sdram_nes operating point) because 2x lands closest to
         -- the 80 MHz this board was already running.
         -- Refresh stays in spec: 511 cycles @85.714 MHz = 5.96 us vs 7.8 us/row.
         ODIV1_SEL  => 14,    -- 1200/14 = 85.714 MHz (clk_sdram) = EXACTLY 2x clk_pce
         -- EXACT VIDEO LOCK (2026-09-20). The HDMI clocks come off this same 1200 MHz
         -- VCO, on two of PLLA's five spare taps, instead of from a second PLL with an
         -- unrelated VCO. That is what makes the raster rationally locked to the core:
         --
         --   source line = 2730 core dots / 42.857 MHz  = 63.70 us
         --   output line = 1274 pixels    / 60 MHz      = 21.233 us
         --   ratio                                      = EXACTLY 3.000
         --
         -- The old path ran the pixel clock from its own 743.75 MHz VCO at 74.375 MHz
         -- with H_total 1650, giving 2.871 output lines per source line -- a non-integer
         -- ratio, so the line doubler had to show each source line for 2 or 3 output
         -- lines in a pattern that crawls. That crawl IS the line-by-line shimmer, and no
         -- amount of VTOTAL servoing could remove it because the error is generated per
         -- LINE, not per frame.
         --
         -- WHY x3 AND NOT x2. Exact lock forces the output line rate to N x 15.699 kHz:
         -- N=2 gives 31.40 kHz, which is 480p class -- and this board's own history is
         -- that some real HDMI sinks reject 480p60 outright with "no signal" (see the
         -- comment above the 720p PLL in pcetang_console60k_cd.vhd). N=3 gives 47.10 kHz,
         -- next to real 720p60's 45.00 kHz, which those same sinks accept.
         --
         -- D=20 is the only workable divider: clk_pixel must be 1200/D with D divisible
         -- by 5 (so the 5x tap is an integer ODIV) and 76440/(D*3) a whole H_total.
         -- D=5 and D=10 need 240/600 MHz TMDS; D=40 gives a 637-pixel line, too narrow
         -- for the 4:3 window. So this is the unique solution, not a preference.
         --
         -- 300 MHz TMDS is LOWER than the 371.875 MHz the 720p PLL runs at, so the
         -- serializer's timing gets easier, not harder. Core clock untouched.
         ODIV2_SEL  => 20,    -- 1200/20 = 60 MHz (clk_pixel)
         ODIV3_SEL  => 4,     -- 1200/4  = 300 MHz (clk_5x_pixel), exact 5x
         CLKOUT0_EN => "TRUE",
         CLKOUT1_EN => "TRUE",
         CLKOUT2_EN => "TRUE",
         CLKOUT3_EN => "TRUE"
      )
      port map (
         LOCK     => lock,
         CLKOUT0  => clk_pce,
         CLKOUT1  => clk_sdram,
         CLKOUT2  => clk_pixel,
         CLKOUT3  => clk_5x_pixel,
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
