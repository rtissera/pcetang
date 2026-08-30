-- SPDX-License-Identifier: GPL-3.0-or-later

-- pcetang Primer 25K SGX: SuperGrafx (dual-VDC), HuCard-only -- no CD (NO_CD=>1),
-- SGX enabled (LITE=>0, SGX=>'1'). Copied from pcetang_primer25k.vhd (that file's own
-- header covers the shared TangCore/HDMI/ROM-bridge background); this file's own real
-- difference is EXT_VRAM1=>1: VDC1's own VRAM routes through the SAME physical Tang
-- SDRAM V1.3 PMOD module as VRAM0, via sdram.sv's port C (real 16-bit + line-refill
-- additions -- RAM_C_WIDE/RAM_C_LINE_REFILL, see that file's own header), not CD-RAM's
-- old 8-bit byte interface.
--
-- DEAD END, gw_sh-CONFIRMED (2026-08-30, see pcetang_status_matrix.md lever 15 for
-- the full record). Two-VDC bus-contention feasibility WAS real (GHDL-verified via
-- sim/vram0/tb_sgx_contention.vhd, no material regression to either VDC's deadline-
-- miss/overrun rate) -- the blocker is device resource capacity, not timing:
--   * VRAM1_PREFETCH/VRAM1_CG_PREFETCH=>1 (the only shippable config -- VDC1 needs
--     the same BAT+CG0/CG1 correctness fix VDC0 needed, not just a perf nicety):
--     ERROR (RP0006), logic 24089/23040 LUT+ALU (+1049 over).
--   * Same config probed with prefetch=>0 (NOT shippable, kept only to isolate the
--     axis): ERROR (PA2017), BSRAM 59/56 (+3 over).
-- The original scoping arithmetic (VRAM1-on-chip=32 BSRAM borrowed from Console 60K
-- CD's own resource report, vs. an assumed +13 surplus after offload) was wrong: that
-- 32 was never re-measured on THIS device family (GW5A vs Console 60K CD's GW5AT),
-- and Primer 25K plain's own baseline already sits at 35/56 BSRAM (63%) before any
-- second-VDC stack is added at all -- fixed costs (RAM/MCODE/VT = 31 blocks alone)
-- leave far less real headroom than the cross-device estimate implied. No
-- configuration of this board fits GW5A-25A on either resource axis. Left in the tree
-- as a documented negative result, not a live target -- do not resume work on this
-- file without a real new capacity lever (dropping some other module, or a smaller
-- second-VDC memory design) to point to first.
--
-- NOT VERIFIED ON HARDWARE. gw_sh-VERIFIED FAILING (both axes, see above).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_primer25k_sgx is
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

architecture rtl of pcetang_primer25k_sgx is

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
         RAM_A_ADDR : in    std_logic_vector(24 downto 0);
         RAM_A_REQ  : in    std_logic;
         RAM_A_RD_n : in    std_logic;
         RAM_A_DI   : in    std_logic_vector(15 downto 0);
         RAM_A_DO   : out   std_logic_vector(15 downto 0);
         RAM_A_WAIT : out   std_logic;
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
         -- PCE PORT (2026-08-30): real 16-bit + line-refill additions -- this board's
         -- own reason for existing. VRAM1/SGX is a real WIDE client (RAM_C_WIDE='1'
         -- permanently, tied below, never toggled per-transaction -- CD-RAM and VRAM1
         -- never coexist on this board) -- see sdram.sv's own header.
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

   -- VDC1's own copy, backed by sdram.sv's port C (real 16-bit/line-refill, see that
   -- component's own comment above).
   signal vram1_ram_a_addr : std_logic_vector(20 downto 0);
   signal vram1_ram_a_req  : std_logic;
   signal vram1_ram_a_rd_n : std_logic;
   signal vram1_ram_a_di   : std_logic_vector(15 downto 0);
   signal vram1_ram_a_do   : std_logic_vector(15 downto 0);
   signal vram1_ram_a_wait : std_logic;
   signal vram1_ram_a_line_refill : std_logic;
   signal vram1_ram_a_line_do     : std_logic_vector(63 downto 0);

   -- Sticky latches (2026-08-27, per an independent Fable-model audit's P3) -- see
   -- pcetang_nano20k.vhd's identical comment for why (raw pce_top pulses are invisible
   -- on a real LED at clk_pce rate). Both VDCs' own deadline-miss/fifo-overflow flags
   -- OR into the SAME two sticky bits/LEDs -- a real HW test only needs to know
   -- "did either VDC ever miss," not distinguish which one, for a first bring-up.
   signal dbg_deadline_miss   : std_logic;
   signal dbg_fifo_overflow   : std_logic;
   signal dbg_deadline_miss_1 : std_logic;
   signal dbg_fifo_overflow_1 : std_logic;
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

   -- Same real ROM-on-SDRAM-port-B design as pcetang_primer25k.vhd -- see that file's
   -- own header for the full rationale, unchanged here.
   constant ROM_SDRAM_BASE  : unsigned(24 downto 0) := to_unsigned(16#010000#, 25);
   constant ROM_SDRAM_ABITS : integer := 20;
   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal rom_loading_r : std_logic := '0';

   signal rom_sz_r : std_logic_vector(11 downto 0) := x"040";

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

   reset_n <= (not key_reset_n) and pll_lock and hdmi_pll_lock;

   pll: console60k_pll
   port map (clkin => clk, reset => key_reset_n, clk_pce => clk_pce,
             clk_sdram => clk_sdram, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll_480p
   port map (clkin => clk, reset => key_reset_n, clk_pixel => clk_pixel,
             clk_5x_pixel => clk_5x_pixel, lock => hdmi_pll_lock);

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
      -- PCE PORT (2026-08-30): VRAM1/SGX -- real wide (16-bit) + line-refill port-C
      -- client. RAM_C_ADDR zero-extended like RAM_A_ADDR (VRAM1 stays within the first
      -- 2MB, same bank-0 scope as VRAM0 -- this board has no CD-RAM/ADPCM/Arcade-Card
      -- to share the address space with, since NO_CD=>1 below).
      RAM_C_ADDR => "0000" & vram1_ram_a_addr,
      RAM_C_REQ  => vram1_ram_a_req,
      RAM_C_RD_n => vram1_ram_a_rd_n,
      RAM_C_DI   => (others => '0'),
      RAM_C_DO   => open,
      RAM_C_WAIT => vram1_ram_a_wait,
      RAM_C_WIDE => '1',
      RAM_C_DI16 => vram1_ram_a_di,
      RAM_C_DO16 => vram1_ram_a_do,
      RAM_C_LINE_REFILL => vram1_ram_a_line_refill,
      RAM_C_LINE_DO     => vram1_ram_a_line_do
   );

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

   -- PCE PORT (2026-08-30): LITE=>0/SGX=>'1' (vs. pcetang_primer25k.vhd's LITE=>1/
   -- SGX=>'0') -- this file's whole reason for existing. EXT_VRAM1=>1 routes VDC1's
   -- own VRAM through sdram.sv's port C (see this file's own header for the real
   -- BSRAM arithmetic that makes this fit where flat SGX doesn't). VRAM1_LINE_REFILL/
   -- VRAM1_PREFETCH/VRAM1_CG_PREFETCH all => 1 from the start (not staged) -- the BAT+
   -- CG0/CG1 fix is a real correctness requirement for a second real-time-rendering
   -- VDC, not just a performance add-on, same reasoning VRAM0_PREFETCH/
   -- VRAM0_CG_PREFETCH already carry on every EXT_VRAM0 board in this project.
   core: entity work.pce_top
   -- DEAD END (2026-08-30, gw_sh-confirmed both ways -- see pcetang_status_matrix.md
   -- lever 15): =>1/=>1 (shippable config, BAT+CG correctness needed) hits RP0006,
   -- logic 24089/23040 (+1049 over). Probed =>0/=>0 (not shippable, no correctness
   -- fix -- kept only for the historical record) to isolate the axis: still hits
   -- PA2017, BSRAM 59/56 (+3 over). No configuration of this board fits GW5A-25A.
   -- Left at =>1/=>1 here since that's the only config anyone should ever build.
   generic map (LITE => 0, EXT_VRAM0 => 1, NO_CD => 1, VRAM0_LINE_REFILL => 1,
                VRAM0_PREFETCH => 1, VRAM0_CG_PREFETCH => 1,
                EXT_VRAM1 => 1, VRAM1_LINE_REFILL => 1,
                VRAM1_PREFETCH => 1, VRAM1_CG_PREFETCH => 1)
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

      VRAM1_RAM_A_ADDR => vram1_ram_a_addr,
      VRAM1_RAM_A_REQ  => vram1_ram_a_req,
      VRAM1_RAM_A_RD_N => vram1_ram_a_rd_n,
      VRAM1_RAM_A_DI   => vram1_ram_a_di,
      VRAM1_RAM_A_DO   => vram1_ram_a_do,
      VRAM1_RAM_A_WAIT => vram1_ram_a_wait,
      DBG_DEADLINE_MISS_1 => dbg_deadline_miss_1, DBG_FIFO_OVERFLOW_1 => dbg_fifo_overflow_1,
      VRAM1_RAM_A_LINE_REFILL => vram1_ram_a_line_refill, VRAM1_RAM_A_LINE_DO => vram1_ram_a_line_do,

      ROM_RD    => rom_rd_i,
      ROM_RDY   => rom_rdy_i,
      ROM_A     => rom_a,
      ROM_DO    => rom_do_i,
      ROM_SZ    => rom_sz_r,
      ROM_POP   => '0',
      ROM_CLKEN => open,

      BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => brm_do, BRM_WE => brm_we,

      GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

      SP64 => '0', SGX => '1',

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
         dbg_deadline_miss_r <= dbg_deadline_miss_r or dbg_deadline_miss or dbg_deadline_miss_1;
         dbg_fifo_overflow_r <= dbg_fifo_overflow_r or dbg_fifo_overflow or dbg_fifo_overflow_1;
      end if;
   end process;

   leds_n(0) <= not dbg_deadline_miss_r;
   leds_n(1) <= not dbg_fifo_overflow_r;

end architecture;
