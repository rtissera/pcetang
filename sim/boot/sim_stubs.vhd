-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- SIMULATION-ONLY stubs, never added to any build_*.tcl.
--
-- pce_top.vhd instantiates four things a plain GHDL run cannot elaborate:
--
--   CODES / ARCADE_CARD           -- SystemVerilog (src/pce/common/core/cheatcodes.sv,
--                                    arcade.sv). Declared in pce_top as VHDL
--                                    `component`s, so binding a VHDL entity of the same
--                                    name here is legal and needs no change to pce_top.
--   dpram9_dpb_wm01               -- direct Gowin DPX9B primitive instantiation
--   dpram8x16_dpb_wm01            -- direct Gowin DPB primitive instantiation
--
-- The two _dpb_wm01 wrappers back huc6270's SPR_LINE_BUF0/1 and SAT -- sprite rendering
-- only. They are replaced here by plain behavioural dual-port memories (the same shape
-- src/common/mem/bram_gowin.vhd's inferred `dpram` already has). That is deliberate and
-- has a real consequence for how a passing run may be read:
--
--   *** A clean boot in this testbench does NOT exonerate the Gowin primitive wrappers,
--   *** nor the SDRAM ROM bridge, nor anything else in the board top. It only says the
--   *** core logic reached that state given ideal memories. Treat a pass as a
--   *** bisection result ("bug is downstream of pce_top"), never as "the core is fine".
--
-- CODES is stubbed inactive because both boards drive GG_EN => '0'. ARCADE_CARD is
-- stubbed inactive (SEL_N/RAM_CS_N held high) because a plain HuCard never touches the
-- Arcade Card's $40-$43 ports or banks; on the CD path this stub would be wrong and must
-- not be used.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity CODES is
	generic (
		ADDR_WIDTH : in integer := 16;
		DATA_WIDTH : in integer := 8
	);
	port (
		clk        : in  std_logic;
		reset      : in  std_logic;
		enable     : in  std_logic;
		addr_in    : in  std_logic_vector(20 downto 0);
		data_in    : in  std_logic_vector(7 downto 0);
		code       : in  std_logic_vector(128 downto 0);
		available  : out std_logic;
		genie_ovr  : out boolean;
		genie_data : out std_logic_vector(7 downto 0)
	);
end entity;

architecture sim of CODES is
begin
	available  <= '0';
	genie_ovr  <= false;
	genie_data <= (others => '0');
end architecture;

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ARCADE_CARD is
	port (
		CLK      : in  std_logic;
		RST_N    : in  std_logic;

		EN       : in  std_logic;
		WR_N     : in  std_logic;
		RD_N     : in  std_logic;
		A        : in  std_logic_vector(20 downto 0);
		DI       : in  std_logic_vector(7 downto 0);
		DO       : out std_logic_vector(7 downto 0);

		SEL_N    : out std_logic;

		RAM_CS_N : out std_logic;
		RAM_A    : out std_logic_vector(20 downto 0)
	);
end entity;

architecture sim of ARCADE_CARD is
begin
	DO       <= (others => '1');
	SEL_N    <= '1';
	RAM_CS_N <= '1';
	RAM_A    <= (others => '0');
end architecture;

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram9_dpb_wm01 is
	port (
		clock     : in  std_logic;

		address_a : in  std_logic_vector(8 downto 0);
		data_a    : in  std_logic_vector(8 downto 0) := (others => '0');
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(8 downto 0);

		address_b : in  std_logic_vector(8 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(8 downto 0) := (others => '0');
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(8 downto 0)
	);
end entity;

architecture sim of dpram9_dpb_wm01 is
	type mem_t is array (0 to 511) of std_logic_vector(8 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
begin
	process (clock) begin
		if rising_edge(clock) then
			if wren_a = '1' then
				mem(to_integer(unsigned(address_a))) := data_a;
			end if;
			q_a <= mem(to_integer(unsigned(address_a)));
		end if;
	end process;

	process (clock) begin
		if rising_edge(clock) then
			if wren_b = '1' then
				mem(to_integer(unsigned(address_b))) := data_b;
			end if;
			q_b <= mem(to_integer(unsigned(address_b)));
		end if;
	end process;
end architecture;

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram8x16_dpb_wm01 is
	port (
		clock     : in  std_logic;

		address_a : in  std_logic_vector(7 downto 0);
		data_a    : in  std_logic_vector(15 downto 0) := (others => '0');
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(15 downto 0);

		address_b : in  std_logic_vector(7 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(15 downto 0) := (others => '0');
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(15 downto 0)
	);
end entity;

architecture sim of dpram8x16_dpb_wm01 is
	type mem_t is array (0 to 255) of std_logic_vector(15 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
begin
	process (clock) begin
		if rising_edge(clock) then
			if wren_a = '1' then
				mem(to_integer(unsigned(address_a))) := data_a;
			end if;
			q_a <= mem(to_integer(unsigned(address_a)));
		end if;
	end process;

	process (clock) begin
		if rising_edge(clock) then
			if wren_b = '1' then
				mem(to_integer(unsigned(address_b))) := data_b;
			end if;
			q_b <= mem(to_integer(unsigned(address_b)));
		end if;
	end process;
end architecture;
