-- SPDX-License-Identifier: GPL-3.0-or-later

-- Block RAM wrappers for the PC Engine / SuperGrafx / TurboGrafx-16 core, retargeted from
-- Altera altsyncram to Gowin GW2AR/GW5A BSRAM inference.
--
-- Entity names and port/generic names match TurboGrafx16_MiSTer's rtl/dpram.vhd EXACTLY
-- (see NECTang's docs/PORTING.md memory-template table -- NECTang is this project's
-- sibling standalone-board port, a separate checkout, not vendored into this repo) so
-- donor .vhd files instantiate these unmodified. This is a different signature convention
-- from the ZX Spectrum Next port's own src/common/mem/bram_gowin.vhd (address_a/data_a vs
-- that port's differently-named ports) -- only the underlying technique is shared, not
-- the file.
--
-- Technique proven on the ZX Next port (a separate project this codebase's sdram.sv/
-- bram_gowin.vhd convention derives from, not vendored here -- see that project's own
-- docs, not a path in this repo): a SHARED VARIABLE with blocking (:=) writes, not a signal with
-- non-blocking (<=) writes. Gowin's block-RAM inference for a signal-based
-- write-then-read template maps to WRITE_MODE 2'b10 (read-old-data-during-write), which
-- GW5A's BSRAM does not support (ERROR (PA2122)). The shared-variable/blocking-write form
-- maps to WRITE_MODE 2'b01 (write-through), which GW5A supports.
--
-- This matches the donor's own semantics: TurboGrafx16_MiSTer/rtl/dpram.vhd hardcodes
-- read_during_write_mode_port_a/b => "NEW_DATA_NO_NBE_READ" on its altsyncram instances --
-- i.e. the donor already assumes new-data/write-through on ordinary same-port
-- coincident read+write. That assumption does NOT necessarily hold for every consumer;
-- see NECTang's docs/PORTING.md's writeup on huc6270.vhd's SPR_LINE_BUF0/1 before assuming this
-- wrapper is a safe drop-in for the sprite line buffers specifically -- that one needs a
-- simulation-verified answer, not an inferred one.
--
-- NOTE: entity order matters. GowinSynthesis analyses a file top to bottom and requires
-- an entity to exist in the library before it is instantiated.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.voltab_pkg.all;
use work.huc6260_palette_init_pkg.all;

--------------------------------------------------------------------------------
-- Single-clock, true dual-port. Matches rtl/dpram.vhd's plain `dpram` entity.
--------------------------------------------------------------------------------
entity dpram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string  := " ";
		disable_value : std_logic := '1'
	);
	port (
		clock     : in  std_logic;

		address_a : in  std_logic_vector(addr_width-1 downto 0);
		data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width-1 downto 0);
		cs_a      : in  std_logic := '1';

		address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end entity;

architecture rtl of dpram is

	constant DEPTH : natural := 2**addr_width;
	type mem_t is array (0 to DEPTH-1) of std_logic_vector(data_width-1 downto 0);

	-- mem_init_file selects a mif2vhd.py-generated package by the exact string the donor
	-- instantiates with (rtl/HUC6280/psg.vhd's "HUC6280/voltab.mif", rtl/huc6260.vhd's
	-- "huc6260_palette_init.mif") -- see NECTang's docs/PORTING.md's ".mif files" section. Anything
	-- else zero-inits, same as before either conversion existed.
	impure function init_mem return mem_t is
		variable m : mem_t := (others => (others => '0'));
	begin
		if mem_init_file = "HUC6280/voltab.mif" then
			for i in 0 to DEPTH-1 loop
				exit when i > voltab'high;
				m(i) := voltab(i);
			end loop;
		elsif mem_init_file = "huc6260_palette_init.mif" then
			for i in 0 to DEPTH-1 loop
				exit when i > huc6260_palette_init'high;
				m(i) := huc6260_palette_init(i);
			end loop;
		end if;
		return m;
	end function;

	shared variable mem : mem_t := init_mem;

	signal q0 : std_logic_vector(data_width-1 downto 0) := (others => '0');
	signal q1 : std_logic_vector(data_width-1 downto 0) := (others => '0');

begin

	q_a <= q0 when cs_a = '1' else (others => disable_value);
	q_b <= q1 when cs_b = '1' else (others => disable_value);

	port_a : process (clock)
	begin
		if rising_edge(clock) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					mem(to_integer(unsigned(address_a))) := data_a;
				end if;
				q0 <= mem(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;

	port_b : process (clock)
	begin
		if rising_edge(clock) then
			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					mem(to_integer(unsigned(address_b))) := data_b;
				end if;
				q1 <= mem(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;

end rtl;

--------------------------------------------------------------------------------
-- Dual-clock, true dual-port, independent widths per port. Matches rtl/dpram.vhd's
-- `dpram_difclk` entity. UNVERIFIED on GW5A this session -- the ZX Next port never
-- needed a genuinely dual-clock BSRAM (its dpram is single-clock like the plain `dpram`
-- above). Two clock domains into one shared-variable array is exactly the shape a GHDL
-- testbench should check before trusting on real hardware -- see NECTang's docs/PORTING.md.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_difclk is
	generic (
		addr_width_a : integer := 8;
		data_width_a : integer := 8;
		addr_width_b : integer := 8;
		data_width_b : integer := 8;
		mem_init_file : string := " "
	);
	port (
		clock0    : in  std_logic;
		clock1    : in  std_logic;

		address_a : in  std_logic_vector(addr_width_a-1 downto 0);
		data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width_a-1 downto 0);
		cs_a      : in  std_logic := '1';

		address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width_b-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end entity;

architecture rtl of dpram_difclk is

	constant DEPTH : natural := 2**addr_width_a;
	subtype word_t is std_logic_vector(data_width_a-1 downto 0);
	type mem_t is array (0 to DEPTH-1) of word_t;

	shared variable mem : mem_t := (others => (others => '0'));

	signal q0 : std_logic_vector(data_width_a-1 downto 0) := (others => '0');
	signal q1 : std_logic_vector(data_width_b-1 downto 0) := (others => '0');

begin

	assert data_width_a = data_width_b and addr_width_a = addr_width_b
		report "dpram_difclk: this Gowin port only supports symmetric port widths"
		severity failure;

	q_a <= q0 when cs_a = '1' else (others => '1');
	q_b <= q1 when cs_b = '1' else (others => '1');

	port_a : process (clock0)
	begin
		if rising_edge(clock0) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					mem(to_integer(unsigned(address_a))) := data_a;
				end if;
				q0 <= mem(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;

	port_b : process (clock1)
	begin
		if rising_edge(clock1) then
			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					mem(to_integer(unsigned(address_b))) := std_logic_vector(resize(unsigned(data_b), data_width_a));
				end if;
				q1 <= mem(to_integer(unsigned(address_b)))(data_width_b-1 downto 0);
			end if;
		end if;
	end process;

end rtl;

--------------------------------------------------------------------------------
-- Single port. Matches rtl/dpram.vhd's `spram` entity. No confirmed consumer found in
-- rtl/*.vhd this session (grep outside dpram.vhd itself came up empty) -- included for
-- completeness/signature-matching; verify against the full fetched tree before relying
-- on it, per NECTang's docs/PORTING.md.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string  := " ";
		mem_name      : string  := "MEM"
	);
	port (
		clock   : in  std_logic;
		address : in  std_logic_vector(addr_width-1 downto 0);
		data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable  : in  std_logic := '1';
		wren    : in  std_logic := '0';
		q       : out std_logic_vector(data_width-1 downto 0);
		cs      : in  std_logic := '1'
	);
end entity;

architecture rtl of spram is

	constant DEPTH : natural := 2**addr_width;
	type mem_t is array (0 to DEPTH-1) of std_logic_vector(data_width-1 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));

	signal q0 : std_logic_vector(data_width-1 downto 0) := (others => '0');

begin

	q <= q0 when cs = '1' else (others => '1');

	process (clock)
	begin
		if rising_edge(clock) then
			if enable = '1' then
				if wren = '1' and cs = '1' then
					mem(to_integer(unsigned(address))) := data;
				end if;
				q0 <= mem(to_integer(unsigned(address)));
			end if;
		end if;
	end process;

end rtl;
