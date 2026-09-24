-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand
-- portc_arbiter.vhd -- SIMULATION COPY of the Console 60K port-C arbiter (CD-RAM + ADPCM RAM).
--
-- The logic between the BEGIN VERBATIM / END VERBATIM markers is copied from
-- src/pcetang_console60k_cd.vhd with comments stripped, so it can be synthesised to Verilog
-- (ghdl synth) and simulated together with the real sdram.sv in Verilator.
-- sim/cd/cosim/check_arbiter_drift.py fails if this copy and the three board files diverge.
-- Moving this into a shared entity used by the boards themselves is deferred until the
-- current ADPCM fix has been confirmed on hardware.
--
-- Not included: the CD-RAM self-test mux (cdt_active is 0 in normal operation, so the
-- *_mux signals are the plain CD-RAM ports here) and the debug trace taps.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity portc_arbiter is
   port (
      clk_pce   : in  std_logic;
      -- CD-RAM / Arcade Card client (pce_top CD_RAM_*)
      cd_ram_a  : in  std_logic_vector(21 downto 0);
      cd_ram_do : in  std_logic_vector(7 downto 0);
      cd_ram_rd : in  std_logic;
      cd_ram_wr : in  std_logic;
      cd_ram_di : out std_logic_vector(7 downto 0);
      cd_ram_rdy: out std_logic;
      -- ADPCM RAM client (cd.vhd ADPCM_RAM_*)
      adpcm_ram_a        : in  std_logic_vector(16 downto 0);
      adpcm_ram_do       : in  std_logic_vector(3 downto 0);
      adpcm_ram_we       : in  std_logic;
      adpcm_ram_req      : in  std_logic;
      adpcm_ram_slot_cnt : in  std_logic_vector(1 downto 0);
      adpcm_ram_di       : out std_logic_vector(3 downto 0);
      adpcm_ram_ready    : out std_logic;
      -- sdram.sv port C
      ram_c_addr : out std_logic_vector(24 downto 0);
      ram_c_req  : out std_logic;
      ram_c_rd_n : out std_logic;
      ram_c_di   : out std_logic_vector(7 downto 0);
      ram_c_do   : in  std_logic_vector(7 downto 0);
      ram_c_wait : in  std_logic
   );
end entity;

architecture rtl of portc_arbiter is
   constant CDRAM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#040000#, 25);
   constant ADPCM_SDRAM_BASE : unsigned(24 downto 0) := to_unsigned(16#080000#, 25);
   constant AC_SDRAM_BASE    : unsigned(24 downto 0) := to_unsigned(16#200000#, 25);
   constant SETTLE_HIT       : unsigned(5 downto 0)  := "010000";

   signal cdr_a_mux  : std_logic_vector(21 downto 0);
   signal cdr_do_mux : std_logic_vector(7 downto 0);
   signal cdr_rd_mux : std_logic;
   signal cdr_wr_mux : std_logic;

   signal cd_ram_di_i  : std_logic_vector(7 downto 0) := (others => '0');
   signal cd_ram_rdy_i : std_logic := '1';
   signal cdr_addr : std_logic_vector(24 downto 0) := (others => '0');
   signal cdr_req  : std_logic := '0';
   signal cdr_rd_n : std_logic := '0';
   signal cdr_di   : std_logic_vector(7 downto 0) := (others => '0');
   signal cdr_do   : std_logic_vector(7 downto 0);
   signal cdr_wait_m : std_logic := '0';
   signal cdr_wait   : std_logic := '0';
   type cdr_state_t is (CDR_IDLE, CDR_SETTLE, CDR_HOLD);
   signal cdr_state      : cdr_state_t := CDR_IDLE;
   signal cdr_settle_cnt : unsigned(5 downto 0) := (others => '0');
   signal cdr_seen_wait  : std_logic := '0';
   signal cdr_wdog       : unsigned(11 downto 0) := (others => '0');
   signal dbg_cdr_timeout_cnt : unsigned(7 downto 0) := (others => '0');
   signal cdram_rd_r, cdram_wr_r : std_logic := '0';
   signal cdr_a_last     : std_logic_vector(21 downto 0) := (others => '0');
   signal cd_new_comb    : std_logic;
   signal cd_done        : std_logic := '0';
   signal cd_ram_rdy_comb: std_logic;
   signal adpcm_ram_a_i  : std_logic_vector(16 downto 0);
   signal adpcm_ram_do_i : std_logic_vector(3 downto 0);
   signal adpcm_ram_we_i : std_logic;
   signal adpcm_ram_req_i: std_logic;
   signal adpcm_ram_slot_cnt_i : std_logic_vector(1 downto 0);
   signal adpcm_ram_di_i    : std_logic_vector(3 downto 0) := (others => '0');
   signal adpcm_ram_ready_i : std_logic := '1';
   signal adpcm_slot_cnt_r  : std_logic_vector(1 downto 0) := (others => '0');
   signal adpcm_bridge_req_r: std_logic := '0';
   signal adpcm_new_comb       : std_logic;
   signal adpcm_ram_ready_comb : std_logic;
   type cdr_owner_t is (OWNER_NONE, OWNER_CDRAM, OWNER_ADPCM);
   signal cdr_owner : cdr_owner_t := OWNER_NONE;
   signal cd_pend, adpcm_pend : std_logic := '0';
begin
   cdr_a_mux  <= cd_ram_a;
   cdr_do_mux <= cd_ram_do;
   cdr_rd_mux <= cd_ram_rd;
   cdr_wr_mux <= cd_ram_wr;
   adpcm_ram_a_i  <= adpcm_ram_a;
   adpcm_ram_do_i <= adpcm_ram_do;
   adpcm_ram_we_i <= adpcm_ram_we;
   adpcm_ram_req_i <= adpcm_ram_req;
   adpcm_ram_slot_cnt_i <= adpcm_ram_slot_cnt;

   cdr_do <= ram_c_do;
   process (clk_pce)
   begin
      if rising_edge(clk_pce) then
         cdr_wait_m <= ram_c_wait;
         cdr_wait   <= cdr_wait_m;
      end if;
   end process;

   -- ===== BEGIN VERBATIM (cd_new_comb, cd_ram_rdy_comb) =====
   cd_new_comb <= '1' when (cdr_rd_mux = '1' or cdr_wr_mux = '1')
                           and ((cdr_rd_mux = '1' and cdram_rd_r = '0')
                                or (cdr_wr_mux = '1' and cdram_wr_r = '0')
                                or cdr_a_mux /= cdr_a_last)
                  else '0';
   cd_ram_rdy_comb <= cd_ram_rdy_i and not (cd_new_comb and not cd_done);
   -- ===== END VERBATIM =====

   -- ===== BEGIN VERBATIM (arbiter) =====
   adpcm_new_comb <= '1' when adpcm_ram_req_i = '1'
                               and (adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r
                                    or adpcm_bridge_req_r = '0')
                     else '0';
   adpcm_ram_ready_comb <= adpcm_ram_ready_i and not adpcm_new_comb;
   process (clk_pce)
      variable cd_new, adpcm_new : std_logic;
   begin
      if rising_edge(clk_pce) then
         cd_done <= '0';
         cdram_rd_r      <= cdr_rd_mux;
         cdram_wr_r      <= cdr_wr_mux;
         adpcm_slot_cnt_r <= adpcm_ram_slot_cnt_i;
         adpcm_bridge_req_r <= adpcm_ram_req_i;
         cd_new := cd_new_comb;
         adpcm_new := adpcm_new_comb;   -- see adpcm_new_comb's comment
         if cd_new = '1' then
            cd_pend      <= '1';
            cd_ram_rdy_i <= '0';
         end if;
         if adpcm_new = '1' then
            adpcm_pend        <= '1';
            adpcm_ram_ready_i <= '0';
         end if;
         case cdr_state is
            when CDR_IDLE =>
               cdr_req <= '0';
               if cd_pend = '1' or cd_new = '1' then
                  if cdr_a_mux(21) = '0' then
                     cdr_addr <= std_logic_vector(AC_SDRAM_BASE +
                                 resize(unsigned(cdr_a_mux(20 downto 0)), 25));
                  else
                     cdr_addr <= std_logic_vector(CDRAM_SDRAM_BASE +
                                 resize(unsigned(cdr_a_mux(17 downto 0)), 25));
                  end if;
                  cdr_rd_n <= cdr_wr_mux;   -- '0' read, '1' write (mux, see cdr_addr)
                  cdr_di   <= cdr_do_mux;
                  cdr_req  <= '1';
                  cdr_owner <= OWNER_CDRAM;
                  cd_pend  <= '0';
                  cdr_a_last <= cdr_a_mux;
                  cdr_settle_cnt <= (others => '0');
                  cdr_seen_wait  <= '0';
                  cdr_wdog       <= (others => '0');
                  cdr_state <= CDR_SETTLE;
               elsif adpcm_pend = '1' or adpcm_new = '1' then
                  cdr_addr <= std_logic_vector(ADPCM_SDRAM_BASE +
                              resize(unsigned(adpcm_ram_a_i), 25));
                  cdr_rd_n <= adpcm_ram_we_i;
                  cdr_di   <= "0000" & adpcm_ram_do_i;  -- one nibble packed per SDRAM byte
                  cdr_req  <= '1';
                  cdr_owner <= OWNER_ADPCM;
                  adpcm_pend <= '0';
                  cdr_settle_cnt <= (others => '0');
                  cdr_seen_wait  <= '0';
                  cdr_wdog       <= (others => '0');
                  cdr_state <= CDR_SETTLE;
               end if;
            when CDR_SETTLE =>
               cdr_req <= '1';
               if cdr_wait = '1' then
                  cdr_seen_wait <= '1';
                  cdr_state <= CDR_HOLD;
               elsif cdr_settle_cnt = SETTLE_HIT then
                  if cdr_owner = OWNER_CDRAM then
                     cd_ram_di_i  <= cdr_do;
                     cd_ram_rdy_i <= '1';
                     cd_done      <= '1';
                  else
                     adpcm_ram_di_i    <= cdr_do(3 downto 0);
                     adpcm_ram_ready_i <= '1';
                  end if;
                  cdr_req <= '0';
                  cdr_owner <= OWNER_NONE;
                  cdr_state <= CDR_IDLE;
               else
                  cdr_settle_cnt <= cdr_settle_cnt + 1;
               end if;
            when CDR_HOLD =>
               cdr_req <= '1';
               cdr_wdog <= cdr_wdog + 1;
               if cdr_wait = '0' or cdr_wdog = x"3FF" then
                  if cdr_wdog = x"3FF" and dbg_cdr_timeout_cnt /= x"FF" then
                     dbg_cdr_timeout_cnt <= dbg_cdr_timeout_cnt + 1;
                  end if;
                  if cdr_owner = OWNER_CDRAM then
                     cd_ram_di_i  <= cdr_do;
                     cd_ram_rdy_i <= '1';
                     cd_done      <= '1';
                  else
                     adpcm_ram_di_i    <= cdr_do(3 downto 0);
                     adpcm_ram_ready_i <= '1';
                  end if;
                  cdr_req <= '0';
                  cdr_owner <= OWNER_NONE;
                  cdr_state <= CDR_IDLE;
               end if;
         end case;
      end if;
   end process;
   -- ===== END VERBATIM =====

   cd_ram_di       <= cd_ram_di_i;
   cd_ram_rdy      <= cd_ram_rdy_comb;
   adpcm_ram_di    <= adpcm_ram_di_i;
   adpcm_ram_ready <= adpcm_ram_ready_comb;
   ram_c_addr <= cdr_addr;
   ram_c_req  <= cdr_req;
   ram_c_rd_n <= cdr_rd_n;
   ram_c_di   <= cdr_di;
end architecture;
