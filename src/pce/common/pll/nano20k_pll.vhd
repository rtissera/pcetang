-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- Clock generation for the Tang Nano 20K (GW2AR-18C), PCE/SGX/TG16 core.
--
-- Structure (not the frequencies) reused from the ZX Spectrum Next port to these same
-- boards (../TangNano60K/src/boards/tang_nano20k/nano20k_pll.vhd), same author, same
-- GPL-3.0 -- see THIRD_PARTY_LICENSES.md. The frequencies below are PCE-specific and
-- replace that file's Z80-core-specific 140.4/28.08/14.04/7.02/70 MHz chain entirely --
-- this core doesn't need any of those rates. See NECTang's docs/PORTING.md's Clocking section for
-- why: HuC6280/huc6260's divide-by-N clock chains need a real ~42.9545 MHz master clock
-- (12x the NTSC colorburst frequency), not an arbitrary fast clock tolerant of any input
-- rate the way an earlier (wrong) assumption in that doc once claimed.
--
-- GW2AR-18C has exactly 2 PLL resources (ERROR (PA2017) if a build tries to use a third
-- -- hit this once this session going for a naive "just add a separate rPLL" version of
-- this file; don't repeat that mistake). Both are spent here: one for the core master
-- clock, one for HDMI. Any further derived rate must come from a CLKDIV/CLKOUTD tap off
-- one of these two, not a new rPLL instance.
--
--   rPLL: CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1),  VCO = CLKOUT * ODIV_SEL
--
-- Core master: 27 * 8 / 5 = 43.2 MHz exactly (PFD 5.4 MHz, a healthy value -- the ZX Next
-- port's own nano20k_pll.vhd independently landed on the same 5.4 MHz PFD for its own
-- 140.4 MHz solve, same chip). +0.57% high versus the exact 42.9545 MHz target -- the
-- same class of compromise that port accepted for its own clk_28 (28.08 vs 28.000,
-- +0.286%): games run a fraction of a percent fast, not a correctness bug.
--
-- clk_sdram: no new primitive needed. The HDMI rPLL already produces 135 MHz internally
-- (clk_135_i) on the way to the 27 MHz pixel clock; that same net is exposed here for
-- src/common/mem/sdram32.sv, the ZX Next port's on-package-SDRAM controller for this
-- exact board (../TangNano60K/src/common/mem/sdram32.sv, hardware-verified there at
-- 140 MHz -- see NECTang's docs/PORTING.md's "Nano 20K external memory" section for why 135 was
-- chosen over adding a third PLL, which GW2AR-18C does not have).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nano20k_pll is
   port (
      clkin      : in  std_logic;    -- 27 MHz crystal

      clk_pce    : out std_logic;    -- 42.4286 MHz -- PCE/SGX/TG16 core master clock
      clk_pce_d2 : out std_logic;    -- 21.6 MHz -- spare tap (CLKOUTD), unused so far

      clk_sdram  : out std_logic;    -- 135 MHz -- on-package SDRAM (sdram32.sv), same net
                                      -- as clk_135 below, exposed under its own name so a
                                      -- consumer doesn't have to know it's shared with HDMI

      -- HDMI output domain. 720x576p50 is a 27.000 MHz mode in CEA-861-D, and this
      -- board's crystal is 27 MHz, so the pixel clock is the input itself and TMDS is
      -- 5x that -- unrelated to the core's own clock, needed regardless of which retro
      -- core this chassis hosts.
      clk_135    : out std_logic;    -- 135 MHz = 27 x 5, TMDS
      clk_27     : out std_logic;    -- 27 MHz pixel clock, aligned to clk_135 (see below
                                      -- for why this isn't taken from the crystal pin)

      lock       : out std_logic
   );
end entity;

architecture rtl of nano20k_pll is

   component rPLL is
      generic (
         FCLKIN           : string  := "100.0";
         DEVICE           : string  := "GW2A-18";
         DYN_IDIV_SEL     : string  := "false";
         IDIV_SEL         : integer := 0;
         DYN_FBDIV_SEL    : string  := "false";
         FBDIV_SEL        : integer := 0;
         DYN_ODIV_SEL     : string  := "false";
         ODIV_SEL         : integer := 8;
         PSDA_SEL         : string  := "0000";
         DYN_DA_EN        : string  := "false";
         DUTYDA_SEL       : string  := "1000";
         CLKOUT_FT_DIR    : bit     := '1';
         CLKOUTP_FT_DIR   : bit     := '1';
         CLKOUT_DLY_STEP  : integer := 0;
         CLKOUTP_DLY_STEP : integer := 0;
         CLKFB_SEL        : string  := "internal";
         CLKOUT_BYPASS    : string  := "false";
         CLKOUTP_BYPASS   : string  := "false";
         CLKOUTD_BYPASS   : string  := "false";
         DYN_SDIV_SEL     : integer := 2;
         CLKOUTD_SRC      : string  := "CLKOUT";
         CLKOUTD3_SRC     : string  := "CLKOUT"
      );
      port (
         CLKOUT   : out std_logic;
         LOCK     : out std_logic;
         CLKOUTP  : out std_logic;
         CLKOUTD  : out std_logic;
         CLKOUTD3 : out std_logic;
         RESET    : in  std_logic;
         RESET_P  : in  std_logic;
         CLKIN    : in  std_logic;
         CLKFB    : in  std_logic;
         FBDSEL   : in  std_logic_vector(5 downto 0);
         IDSEL    : in  std_logic_vector(5 downto 0);
         ODSEL    : in  std_logic_vector(5 downto 0);
         PSDA     : in  std_logic_vector(3 downto 0);
         DUTYDA   : in  std_logic_vector(3 downto 0);
         FDLY     : in  std_logic_vector(3 downto 0)
      );
   end component;

   component CLKDIV is
      generic (
         DIV_MODE : string := "2";
         GSREN    : string := "false"
      );
      port (
         CLKOUT : out std_logic;
         HCLKIN : in  std_logic;
         RESETN : in  std_logic;
         CALIB  : in  std_logic
      );
   end component;

   signal clk_pce_i, pll_lock   : std_logic;
   signal clk_135_i, clk_27_i, pll2_lock : std_logic;

begin

   -- Core master clock rPLL. DYN_SDIV_SEL default (2) gives CLKOUTD = CLKOUT/2 = 21.6 MHz.
   pll_pce: rPLL
   generic map (
      FCLKIN    => "27",
      DEVICE    => "GW2AR-18C",
      -- 2026-09-17: 43.2 -> 42.4286 MHz (27 * 11/7). The CD-DA end-position work pushed this
      -- board (90% logic) past its own 43.2 MHz constraint -- best of a 4-way place/route sweep
      -- was 42.431 MHz with 51 setup violations. 42.4286 sits just under that, and relaxing the
      -- target also lets the placer stop fighting a goal it cannot reach.
      -- Accuracy: the exact PCE rate is 42.9545 MHz (12x NTSC colourburst). 27 * 35/22 would hit
      -- it exactly but needs PFD 27/22 = 1.23 MHz, far below this rPLL's ~3 MHz floor. With
      -- PFD >= 3 MHz the reachable neighbours are 43.2 (+0.57%), 42.4286 (-1.22%) and 42.0
      -- (-2.2%). So this trades a little speed accuracy for a board that closes timing at all.
      IDIV_SEL  => 6,           -- /7  -> PFD 3.857 MHz
      FBDIV_SEL => 10,          -- x11 -> 42.4286 MHz
      ODIV_SEL  => 16           -- VCO 678.9 MHz
   )
   port map (
      CLKOUT   => clk_pce_i,
      LOCK     => pll_lock,
      CLKOUTP  => open,
      CLKOUTD  => clk_pce_d2,
      CLKOUTD3 => open,
      RESET    => '0',
      RESET_P  => '0',
      CLKIN    => clkin,
      CLKFB    => '0',
      FBDSEL   => (others => '0'),
      IDSEL    => (others => '0'),
      ODSEL    => (others => '0'),
      PSDA     => (others => '0'),
      DUTYDA   => (others => '0'),
      FDLY     => (others => '1')
   );
   clk_pce <= clk_pce_i;

   -- HDMI rPLL: 27 x 5 = 135 MHz, VCO 540 MHz, PFD 27 MHz.
   pll_hdmi: rPLL
   generic map (
      FCLKIN    => "27",
      DEVICE    => "GW2AR-18C",
      IDIV_SEL  => 0,           -- /1  -> PFD 27 MHz
      FBDIV_SEL => 4,           -- x5  -> 135 MHz
      ODIV_SEL  => 4            -- VCO 540 MHz
   )
   port map (
      CLKOUT => clk_135_i, LOCK => pll2_lock, CLKOUTP => open, CLKOUTD => open,
      CLKOUTD3 => open, RESET => '0', RESET_P => '0', CLKIN => clkin, CLKFB => '0',
      FBDSEL => (others => '0'), IDSEL => (others => '0'), ODSEL => (others => '0'),
      PSDA => (others => '0'), DUTYDA => (others => '0'), FDLY => (others => '1')
   );

   -- Pixel clock for that TMDS clock, derived from it rather than taken from the crystal
   -- pin. They are the same frequency either way, but OSER10 needs the pixel clock to be
   -- fclk/5 AND phase-aligned to it; a PLL inserts phase the raw pin does not have, and
   -- the serialiser then breaks up periodically -- seen on hardware, on the ZX Next port,
   -- as bursts of raster bars alternating with lost sync. Carried forward unverified for
   -- this port -- re-confirm once HDMI output is actually wired up.
   div5_hdmi: CLKDIV generic map (DIV_MODE => "5", GSREN => "false")
      port map (CLKOUT => clk_27_i, HCLKIN => clk_135_i, RESETN => pll2_lock, CALIB => '0');

   clk_135   <= clk_135_i;
   clk_27    <= clk_27_i;
   clk_sdram <= clk_135_i;

   lock <= pll_lock and pll2_lock;

end architecture;
