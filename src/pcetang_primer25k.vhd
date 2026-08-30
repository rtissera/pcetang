-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Phase 1: Tang Primer 25K, TangCore-integrated (iosys_bl616: ROM load,
-- joypad, OSD), HuCard-only -- no CD (NO_CD=>1), no SGX (LITE=>1). Same shape as
-- pcetang_console60k.vhd -- see that file's header for what's new here vs. NECTang's
-- own bring-ups, and for the same caveats (joypad mapping unverified, video never
-- seen). One real difference from Console 60K: EXT_VRAM0=>1 is REQUIRED here, not
-- optional -- Primer 25K's whole engine does not fit on-chip (NECTang's own real
-- numbers), so VRAM0 routes through the physical Tang SDRAM V1.3 PMOD module
-- (src/pce/common/mem/sdram.sv + vram0_cache.vhd, both already inside pce_top.vhd),
-- same wiring NECTang's own primer25k_core_test.vhd already proved real.
--
-- HDMI/UART pins reused directly from nand2mario's own nestang primer25k.cst (this
-- board, his own working config) rather than adapted from a different board/protocol
-- like Console 60K's guess -- higher confidence, still not hardware-verified here.
--
-- NOT VERIFIED ON HARDWARE. See docs/ARCHITECTURE.md's status note.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_primer25k is
   port (
      clk           : in    std_logic;                      -- 50 MHz crystal
      key_reset_n   : in    std_logic;                       -- H11/S1, active HIGH while held (name is a misnomer, see reset_n below)

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
      uart_txd    : out   std_logic;

      leds_n      : out   std_logic_vector(1 downto 0)
   );
end entity;

architecture rtl of pcetang_primer25k is

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
         -- PCE PORT (2026-08-29): widened 21->25 bits -- see sdram.sv's own header note.
         RAM_A_ADDR : in    std_logic_vector(24 downto 0);
         RAM_A_REQ  : in    std_logic;
         RAM_A_RD_n : in    std_logic;
         RAM_A_DI   : in    std_logic_vector(15 downto 0);
         RAM_A_DO   : out   std_logic_vector(15 downto 0);
         RAM_A_WAIT : out   std_logic;
         -- PCE PORT (2026-08-28): 4-word VRAM0 line-refill -- see sdram.sv's own header.
         -- Tied off here (feature not yet wired end-to-end on this board -- vram0_cache's
         -- own G_LINE_REFILL generic defaults false, so this is inert either way, but
         -- tied explicitly rather than relying on the Verilog-side default across the
         -- VHDL/Verilog boundary, which Gowin's mixed-language elaborator does not honor
         -- (real EX4232 error, confirmed) -- matches this file's own existing convention
         -- of always tying off unused ports explicitly (see RAM_C_* below).
         RAM_A_LINE_REFILL : in    std_logic;
         RAM_A_LINE_DO     : out   std_logic_vector(63 downto 0);
         RAM_B_ADDR : in    std_logic_vector(24 downto 0);
         RAM_B_REQ  : in    std_logic;
         RAM_B_WE   : in    std_logic;
         RAM_B_DI   : in    std_logic_vector(7 downto 0);
         RAM_B_DO   : out   std_logic_vector(7 downto 0);
         RAM_B_WAIT : out   std_logic;
         RAM_C_ADDR : in    std_logic_vector(24 downto 0);
         RAM_C_REQ  : in    std_logic;
         RAM_C_RD_n : in    std_logic;
         RAM_C_DI   : in    std_logic_vector(7 downto 0);
         RAM_C_DO   : out   std_logic_vector(7 downto 0);
         RAM_C_WAIT : out   std_logic;
         -- PCE PORT (2026-08-30): real 16-bit + line-refill additions for a wide port-C
         -- client (VRAM1/SGX) -- see sdram.sv's own header. Tied off explicitly below,
         -- not left to the .sv side's own defaults -- same mixed-language-boundary
         -- rationale as RAM_A_LINE_REFILL/RAM_C_* above (real EX4232 error otherwise).
         RAM_C_WIDE : in    std_logic;
         RAM_C_DI16 : in    std_logic_vector(15 downto 0);
         RAM_C_DO16 : out   std_logic_vector(15 downto 0);
         RAM_C_LINE_REFILL : in    std_logic;
         RAM_C_LINE_DO     : out   std_logic_vector(63 downto 0)
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

   signal psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s : signed(15 downto 0);

   signal vram0_ram_a_addr : std_logic_vector(20 downto 0);
   signal vram0_ram_a_req  : std_logic;
   signal vram0_ram_a_rd_n : std_logic;
   signal vram0_ram_a_di   : std_logic_vector(15 downto 0);
   signal vram0_ram_a_do   : std_logic_vector(15 downto 0);
   signal vram0_ram_a_wait : std_logic;
   signal vram0_ram_a_line_refill : std_logic;
   signal vram0_ram_a_line_do     : std_logic_vector(63 downto 0);

   -- Sticky latches (2026-08-27, per an independent Fable-model audit's P3) -- see
   -- pcetang_nano20k.vhd's identical comment for why (raw pce_top pulses are invisible
   -- on a real LED at clk_pce rate).
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

   -- ROM moved off on-chip BRAM onto SDRAM port B (2026-08-27): the old 32K on-chip
   -- dpram couldn't hold any real commercial HuCard (smallest is 128K). 1MB region --
   -- covers every standard HuCard size pce_top.vhd:672-680 can mirror (128K/256K/
   -- 384K/512K/768K/1MB); SF2's 2560K bank-switched mapper is NOT supported (would
   -- need a separate rombank register pce_top has no port for). Placed right after
   -- VRAM0's 64K region (0x000000-0x00FFFF) -- nothing else uses SDRAM on this board.
   -- Same read/write port-B bridge pattern as pcetang_primer25k_cd.vhd's ROM bridge
   -- (that file's the proven reference this was copied from).
   -- PCE PORT (2026-08-29): widened 21->25 bits alongside sdram.sv's own port widening --
   -- no layout change on this board (still 0x010000, well inside the first 2MB), just
   -- matching sdram.sv's now-wider RAM_B_ADDR so the resize()s below don't truncate.
   constant ROM_SDRAM_BASE  : unsigned(24 downto 0) := to_unsigned(16#010000#, 25);
   constant ROM_SDRAM_ABITS : integer := 20;
   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal rom_loading_r : std_logic := '0';

   -- Dynamic ROM_SZ (2026-08-27): latched from rom_wr_addr's final byte count at
   -- rom_loading's falling edge, rounded up to the nearest pce_top mirroring bucket.
   -- Was hardcoded x"008" (hits pce_top's straight-1MB-mapping else branch always,
   -- wrong for any smaller real HuCard that needs address mirroring). Reset default
   -- x"040" is arbitrary -- never used, core stays held in reset (see core_resetn)
   -- until the first load completes and overwrites it.
   signal rom_sz_r : std_logic_vector(11 downto 0) := x"040";

   -- Core reset gated on rom_loading (2026-08-27): previously RESET/COLD_RESET only
   -- depended on board-level reset_n (button+PLL), so the CPU ran during the whole
   -- ROM load -- issuing real ROM_RD fetches against a partially-written SDRAM region
   -- while port B was mux'd to the write side (see romb_addr mux below), reading back
   -- stale/torn data. Same missing-gate bug as nano20k/console60k/console60k_cd
   -- (not fixed there yet -- flagged, not touched, out of this change's scope).
   -- Reference pattern: NECTang's sibling nestang_top.sv's reset_nes -- held in reset
   -- through the whole load, released exactly on loading's falling edge. Consequence:
   -- a board that never loads anything never releases core reset (matches nestang,
   -- more correct than the old behavior of running against uninitialized SDRAM).
   signal core_resetn : std_logic := '0';

   signal romb_addr : std_logic_vector(24 downto 0);
   signal romb_req  : std_logic := '0';
   signal romb_we   : std_logic := '0';
   signal romb_di   : std_logic_vector(7 downto 0);
   signal romb_do   : std_logic_vector(7 downto 0);
   signal romb_wait : std_logic;

   type romb_state_t is (RB_IDLE, RB_SETTLE, RB_WAIT);

   signal rd_state       : romb_state_t := RB_IDLE;
   signal rd_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal rd_req         : std_logic := '0';
   signal rd_addr        : std_logic_vector(24 downto 0);

   signal wr_state       : romb_state_t := RB_IDLE;
   signal wr_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal wr_req         : std_logic := '0';
   signal wr_addr        : std_logic_vector(24 downto 0);
   signal wr_data        : std_logic_vector(7 downto 0);

   signal video_r, video_g, video_b : std_logic_vector(2 downto 0);
   signal video_ce, video_hs, video_vs, video_hbl, video_vbl : std_logic;

   signal joy_out : std_logic_vector(1 downto 0);
   signal joy_in  : std_logic_vector(3 downto 0);

   signal brm_a  : std_logic_vector(10 downto 0);
   signal brm_di : std_logic_vector(7 downto 0);
   signal brm_do : std_logic_vector(7 downto 0);
   signal brm_we : std_logic;

begin

   -- key_reset_n is misnamed: H11 (schematic net H11_IOT3A_S1) is pulled DOWN
   -- (.cst PULL_MODE=DOWN) and driven to 3V3 through S1+R7 only while held, so
   -- the raw pin is active-HIGH-while-pressed, not active-low as the name
   -- implies. Invert at point of use rather than rename board-wide.
   reset_n <= (not key_reset_n) and pll_lock and hdmi_pll_lock;

   pll: console60k_pll
   port map (clkin => clk, reset => key_reset_n, clk_pce => clk_pce,
             clk_sdram => clk_sdram, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll_480p
   port map (clkin => clk, reset => key_reset_n, clk_pixel => clk_pixel,
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
      -- PCE PORT (2026-08-29): zero-extended, not widened -- VRAM0 stays within the
      -- first 2MB (bank 0), this widening's scope is ROM/CD-RAM/ADPCM/Arcade-Card, not
      -- VRAM0 addressing -- see sdram.sv's own port widening note.
      RAM_A_ADDR => "0000" & vram0_ram_a_addr,
      RAM_A_REQ  => vram0_ram_a_req,
      RAM_A_RD_n => vram0_ram_a_rd_n,
      RAM_A_DI   => vram0_ram_a_di,
      RAM_A_DO   => vram0_ram_a_do,
      RAM_A_WAIT => vram0_ram_a_wait,
      RAM_A_LINE_REFILL => vram0_ram_a_line_refill, RAM_A_LINE_DO => vram0_ram_a_line_do,
      RAM_B_ADDR => romb_addr,
      RAM_B_REQ  => romb_req,
      RAM_B_WE   => romb_we,
      RAM_B_DI   => romb_di,
      RAM_B_DO   => romb_do,
      RAM_B_WAIT => romb_wait,
      RAM_C_ADDR => (others => '0'),
      RAM_C_REQ  => '0',
      RAM_C_RD_n => '1',
      RAM_C_DI   => (others => '0'),
      RAM_C_DO   => open,
      RAM_C_WAIT => open,
      RAM_C_WIDE => '0',
      RAM_C_DI16 => (others => '0'),
      RAM_C_DO16 => open,
      RAM_C_LINE_REFILL => '0',
      RAM_C_LINE_DO     => open
   );

   -- Static mux: write bridge (load) owns port B while rom_loading_r is set, read
   -- bridge (gameplay fetch) owns it otherwise. Now genuinely mutually exclusive --
   -- the core is held in core_resetn's reset for the whole load, so ROM_RD cannot
   -- fire during it (see core_resetn's header for why this wasn't true before).
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
            -- Round up to the smallest pce_top bucket covering the real byte count.
            -- Real HuCard dumps are exact standard sizes, so this lands exactly for
            -- all of them except SF2 (unsupported, see ROM_SDRAM_ABITS's header).
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

   -- ROM write bridge: one iosys_bl616 byte (rom_do/rom_do_valid) becomes one real
   -- SDRAM write via port B. Same pattern as pcetang_primer25k_cd.vhd's ROM write
   -- bridge (copied from there) -- see that file's header for the settle-window
   -- rationale (clk_sdram is ~2.8x clk_pce, 4 cycles is >10x margin).
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case wr_state is
            when RB_IDLE =>
               if rom_do_valid = '1' then
                  wr_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(rom_wr_addr, 25));
                  wr_data <= rom_do;
                  wr_req  <= not wr_req;
                  wr_settle_cnt <= (others => '0');
                  wr_state <= RB_SETTLE;
               end if;

            when RB_SETTLE =>
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

   -- ROM read bridge: one pce_top ROM_RD per CPU cart-ROM byte access becomes one
   -- real SDRAM read via port B. Same pattern as pcetang_primer25k_cd.vhd's ROM read
   -- bridge (copied from there).
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case rd_state is
            when RB_IDLE =>
               rom_rdy_i <= '1';
               if rom_rd_i = '1' then
                  rd_addr <= std_logic_vector(ROM_SDRAM_BASE +
                             resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 25));
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

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   core: entity work.pce_top
   -- PCE PORT (2026-08-28): VRAM0_LINE_REFILL => 1 enables the real 4-word line-refill
   -- mechanism (see sdram.sv's own "line refill" header note and
   -- scratchpad/vram0_deadline_implementation_plans.md) -- this board's sdram.sv
   -- instance implements it; wired to real signals below, not tied off like every
   -- other board.
   -- PCE PORT (2026-08-28): VRAM0_PREFETCH => 1 enables vram0_prefetch.vhd's BAT
   -- prefetch engine (see that file's own header). Real acceptance-test result: BAT
   -- deadline-miss data corruption (previously ~100% wrong on every genuine cache
   -- miss, GHDL-measured) closed to 0 wrong reads out of 66739 checked, 1257/1257
   -- deadline-miss events now delivering correct data.
   -- PCE PORT (2026-08-29): VRAM0_CG_PREFETCH => 1 enables the same file's CG0/CG1
   -- extension (see its own "G_CG_PREFETCH EXTENSION" header) -- GHDL-verified
   -- cg_hit_wrong=0 across steady-state and mid-frame BYR-rewrite/SCREEN-change
   -- stress. Real cost on THIS board: clk_pce Fmax margin drops from BAT-alone's
   -- ~2.13% to ~0.656% (0 setup/hold violations either way, TNS=0) -- razor-thin,
   -- accepted as a real tradeoff for closing the CG0/CG1 deadline-miss gap, not a
   -- free addition.
   generic map (LITE => 1, EXT_VRAM0 => 1, NO_CD => 1, VRAM0_LINE_REFILL => 1,
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
      VRAM0_RAM_A_LINE_REFILL => vram0_ram_a_line_refill, VRAM0_RAM_A_LINE_DO => vram0_ram_a_line_do,

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

      CD_EN => '0', CD_RAM_A => open, CD_RAM_DO => open,
      CD_RAM_DI => (others => '0'), CD_RAM_RD => open, CD_RAM_WR => open,
      AC_EN => '0',

      CD_STAT => (others => '0'), CD_MSG => (others => '0'), CD_STAT_GET => '0',
      CD_COMM => open, CD_COMM_SEND => open,
      CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
      CD_REGION => '0', CD_RESET => open,
      CD_DATA => (others => '0'), CD_DATA_WR => '0', CD_AUDIO_WR => '0',
      CD_SUBCD_WR => '0', CD_DATA_END => open, CD_DM => '0',

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

   -- pce2hdmi (on-chip-BRAM capture framebuffer scandoubler) swapped for pce2hdmi_sd
   -- (2-line ping-pong scandoubler, no capture framebuffer) -- real gw_sh-verified
   -- -11 BSRAM blocks (45/56 -> 34/56), wired exactly as the already-hardware-proven
   -- pcetang_primer25k_cd.vhd wires it. Output mode changes 720p60 -> 720x480p60
   -- (pce2hdmi_sd's proven config) -- a real, accepted tradeoff, not an artifact.
   hdmi_out: pce2hdmi_sd
   port map (
      clk => clk_pce, resetn => reset_n,
      video_r => video_r, video_g => video_g, video_b => video_b,
      video_ce => video_ce, video_hs => video_hs, video_vs => video_vs,
      video_hbl => video_hbl, video_vbl => video_vbl,
      overlay => overlay, overlay_x => overlay_x, overlay_y => overlay_y,
      overlay_color => overlay_color,
      clk_pixel => clk_pixel, clk_5x_pixel => clk_5x_pixel,
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
