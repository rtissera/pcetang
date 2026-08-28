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
-- ROM moved off on-chip BRAM onto SDRAM port B (2026-08-28), same recipe as
-- pcetang_primer25k.vhd (see that file's comment at its own ROM_SDRAM_BASE for the
-- fuller rationale): the old 32K on-chip dpram couldn't hold any real commercial
-- HuCard (smallest is 128K). Unlike Primer 25K, VRAM0 stays on-chip here (EXT_VRAM0=>0
-- unchanged -- Console 60K's whole engine minus ROM already fits on-chip), so ROM gets
-- the SDRAM's entire address space starting at 0x000000, not offset behind a VRAM0
-- region. Real pins are nand2mario's own nestang/src/boards/console.cst SDRAM block
-- (verified byte-for-byit real hardware pins, same physical Tang SDRAM V1.3 PMOD module
-- Primer 25K uses) -- confirmed matching signal set (13 addr bits, 2 ba, 2 dqm, no cke
-- pin wired on either board's real .cst despite the port existing on the sdram.sv
-- component, same as Primer 25K). sdram.sv's RAM_A (VRAM0) and RAM_C (CD-RAM) ports are
-- tied off exactly the way pcetang_primer25k.vhd ties off RAM_C -- this board needs
-- neither. Also added the core_resetn reset-gating fix pcetang_primer25k.vhd's own
-- header describes (RESET/COLD_RESET was gated on raw reset_n before, which is now a
-- real correctness problem: the ROM read path has genuine multi-cycle SDRAM latency for
-- the first time, so without gating the CPU could run and issue ROM_RD during a load,
-- racing the write side on the same SDRAM port).
--
-- NOT VERIFIED ON HARDWARE. First real gw_sh attempt for this repo -- see
-- docs/ARCHITECTURE.md's status note. Joypad button mapping (iosys_bl616's DS2/SNES-
-- shaped joy1[11:0] onto pce_top's 2-select-bit/4-data-bit protocol) is a reasonable
-- first guess, not verified against real PCE controller protocol documentation --
-- doesn't block a real synthesis attempt (any 4-bit signal wires fine), does need a
-- real check before this is trusted to control an actual game. Audio (PSG/CDDA/ADPCM)
-- is still tied to `open` here, same as before this change -- a separate, real gap,
-- not touched by the SDRAM/ROM work above.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pcetang_console60k is
   port (
      clk         : in    std_logic;                      -- 50 MHz crystal
      key_reset_n : in    std_logic;                       -- S2, active low
      leds_n      : out   std_logic_vector(1 downto 0);

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
         RAM_A_DI   : in    std_logic_vector(15 downto 0);
         RAM_A_DO   : out   std_logic_vector(15 downto 0);
         RAM_A_WAIT : out   std_logic;
         RAM_A_LINE_REFILL : in    std_logic;
         RAM_A_LINE_DO     : out   std_logic_vector(63 downto 0);
         RAM_B_ADDR : in    std_logic_vector(20 downto 0);
         RAM_B_REQ  : in    std_logic;
         RAM_B_WE   : in    std_logic;
         RAM_B_DI   : in    std_logic_vector(7 downto 0);
         RAM_B_DO   : out   std_logic_vector(7 downto 0);
         RAM_B_WAIT : out   std_logic;
         RAM_C_ADDR : in    std_logic_vector(20 downto 0);
         RAM_C_REQ  : in    std_logic;
         RAM_C_RD_n : in    std_logic;
         RAM_C_DI   : in    std_logic_vector(7 downto 0);
         RAM_C_DO   : out   std_logic_vector(7 downto 0);
         RAM_C_WAIT : out   std_logic
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

         psg_sl  : in std_logic_vector(15 downto 0);
         psg_sr  : in std_logic_vector(15 downto 0);
         cdda_sl : in std_logic_vector(15 downto 0);
         cdda_sr : in std_logic_vector(15 downto 0);
         adpcm_s : in std_logic_vector(15 downto 0);

         tmds_clk_n : out std_logic;
         tmds_clk_p : out std_logic;
         tmds_d_n   : out std_logic_vector(2 downto 0);
         tmds_d_p   : out std_logic_vector(2 downto 0)
      );
   end component;

   signal clk_pce, clk_sdram, clk_pixel, clk_5x_pixel : std_logic;
   signal pll_lock, hdmi_pll_lock, reset_n : std_logic;
   signal sdram_init : std_logic;

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

   -- NO_CD=>1 here: plain PCE/SGX has no CDDA/ADPCM circuitry at all (that's PCE-CD
   -- hardware, not present on a HuCard-only unit) -- pce_top's gen_no_cd branch
   -- correctly hardwires CDDA_SL/SR/ADPCM_S to zero, not just "tied off for now".
   -- Only PSG carries real audio here. Signals wired anyway for symmetry with
   -- pcetang_primer25k.vhd/pcetang_console60k_cd.vhd's port shape.
   signal psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s : signed(15 downto 0);

   -- ROM on SDRAM port B, whole 2MB address space (no VRAM0 co-tenant on this board --
   -- see file header). 1MB window covers every standard HuCard size pce_top.vhd:672-680
   -- can mirror (128K/256K/384K/512K/768K/1MB); SF2's 2560K bank-switched mapper is NOT
   -- supported (would need a separate rombank register pce_top has no port for) -- same
   -- real limitation as Primer 25K, same reason.
   constant ROM_SDRAM_BASE  : unsigned(20 downto 0) := to_unsigned(0, 21);
   constant ROM_SDRAM_ABITS : integer := 20;
   signal rom_a       : std_logic_vector(21 downto 0);
   signal rom_do_i    : std_logic_vector(7 downto 0) := (others => '0');
   signal rom_rdy_i   : std_logic := '1';
   signal rom_rd_i    : std_logic;
   signal rom_wr_addr : unsigned(ROM_SDRAM_ABITS-1 downto 0) := (others => '0');
   signal rom_loading_r : std_logic := '0';
   signal rom_sz_r    : std_logic_vector(11 downto 0) := x"040";

   -- Core reset gated on rom_loading (same fix as pcetang_primer25k.vhd's
   -- core_resetn, 2026-08-27 there) -- held in reset through the whole ROM load,
   -- released exactly on loading's falling edge. Needed now that ROM reads have real
   -- SDRAM latency: without this, the CPU could run and issue ROM_RD mid-load, racing
   -- the write bridge on the same SDRAM port B.
   signal core_resetn : std_logic := '0';

   signal romb_addr : std_logic_vector(20 downto 0);
   signal romb_req  : std_logic := '0';
   signal romb_we   : std_logic := '0';
   signal romb_di   : std_logic_vector(7 downto 0);
   signal romb_do   : std_logic_vector(7 downto 0);
   signal romb_wait : std_logic;

   type romb_state_t is (RB_IDLE, RB_SETTLE, RB_WAIT);

   signal rd_state       : romb_state_t := RB_IDLE;
   signal rd_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal rd_req         : std_logic := '0';
   signal rd_addr        : std_logic_vector(20 downto 0);

   signal wr_state       : romb_state_t := RB_IDLE;
   signal wr_settle_cnt  : unsigned(2 downto 0) := (others => '0');
   signal wr_req         : std_logic := '0';
   signal wr_addr        : std_logic_vector(20 downto 0);
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

   reset_n <= key_reset_n and pll_lock and hdmi_pll_lock;

   pll: console60k_pll
   port map (clkin => clk, reset => not key_reset_n, clk_pce => clk_pce,
             clk_sdram => clk_sdram, lock => pll_lock);

   hdmi_pll: pcetang_console60k_hdmi_pll
   port map (clkin => clk, reset => not key_reset_n, clk_pixel => clk_pixel,
             clk_5x_pixel => clk_5x_pixel, lock => hdmi_pll_lock);

   -- Same init-hold shape as pcetang_primer25k.vhd's sdram_init process.
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
            -- all of them except SF2 (unsupported, see ROM_SDRAM_ABITS's comment above).
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

   -- Static mux: write bridge (load) owns port B while rom_loading_r is set, read
   -- bridge (gameplay fetch) owns it otherwise. Mutually exclusive because the core is
   -- held in core_resetn's reset for the whole load, so ROM_RD cannot fire during it.
   romb_addr <= wr_addr when rom_loading_r = '1' else rd_addr;
   romb_req  <= wr_req  when rom_loading_r = '1' else rd_req;
   romb_we   <= '1'     when rom_loading_r = '1' else '0';
   romb_di   <= wr_data;

   -- ROM write bridge: one iosys_bl616 byte (rom_do/rom_do_valid) becomes one real
   -- SDRAM write via port B. Same pattern as pcetang_primer25k.vhd's ROM write bridge.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case wr_state is
            when RB_IDLE =>
               if rom_do_valid = '1' then
                  wr_addr <= std_logic_vector(ROM_SDRAM_BASE + resize(rom_wr_addr, 21));
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

   -- ROM read bridge: one pce_top ROM_RD per CPU cart-ROM byte access becomes one real
   -- SDRAM read via port B. Same pattern as pcetang_primer25k.vhd's ROM read bridge.
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         case rd_state is
            when RB_IDLE =>
               rom_rdy_i <= '1';
               if rom_rd_i = '1' then
                  rd_addr <= std_logic_vector(ROM_SDRAM_BASE +
                             resize(unsigned(rom_a(ROM_SDRAM_ABITS-1 downto 0)), 21));
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
      -- No VRAM0 on SDRAM on this board (EXT_VRAM0=>0, stays on-chip) -- tied off
      -- exactly like pcetang_primer25k.vhd ties off its unused port C.
      RAM_A_ADDR => (others => '0'),
      RAM_A_REQ  => '0',
      RAM_A_RD_n => '1',
      RAM_A_DI   => (others => '0'),
      RAM_A_DO   => open,
      RAM_A_WAIT => open,
      RAM_A_LINE_REFILL => '0',
      RAM_A_LINE_DO     => open,
      RAM_B_ADDR => romb_addr,
      RAM_B_REQ  => romb_req,
      RAM_B_WE   => romb_we,
      RAM_B_DI   => romb_di,
      RAM_B_DO   => romb_do,
      RAM_B_WAIT => romb_wait,
      -- No CD-RAM on this board either (NO_CD=>1).
      RAM_C_ADDR => (others => '0'),
      RAM_C_REQ  => '0',
      RAM_C_RD_n => '1',
      RAM_C_DI   => (others => '0'),
      RAM_C_DO   => open,
      RAM_C_WAIT => open
   );

   backup_ram: entity work.spram
   generic map (addr_width => 11, data_width => 8)
   port map (
      clock => clk_pce, address => brm_a, data => brm_di, wren => brm_we, q => brm_do
   );

   core: entity work.pce_top
   generic map (LITE => 1, EXT_VRAM0 => 0, NO_CD => 1)
   port map (
      RESET      => not core_resetn,
      COLD_RESET => not core_resetn,
      CLK        => clk_pce,

      VRAM0_RAM_A_ADDR => open, VRAM0_RAM_A_REQ => open, VRAM0_RAM_A_RD_N => open,
      VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0'),
      VRAM0_RAM_A_WAIT => '0',
      DBG_DEADLINE_MISS => open, DBG_FIFO_OVERFLOW => open,
      VRAM0_RAM_A_LINE_REFILL => open, VRAM0_RAM_A_LINE_DO => (others => '0'),

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
      psg_sl => std_logic_vector(psg_sl), psg_sr => std_logic_vector(psg_sr),
      cdda_sl => std_logic_vector(cdda_sl), cdda_sr => std_logic_vector(cdda_sr),
      adpcm_s => std_logic_vector(adpcm_s),
      tmds_clk_n => tmds_clk_n, tmds_clk_p => tmds_clk_p,
      tmds_d_n => tmds_d_n, tmds_d_p => tmds_d_p
   );

   leds_n(0) <= not (pll_lock and hdmi_pll_lock);
   leds_n(1) <= not rom_loading(0);

end architecture;
