-- SPDX-License-Identifier: GPL-3.0-or-later

-- Direct Gowin DPX9B primitive instantiation, forcing WRITE_MODE0/1 = 2'b01
-- (write-through) explicitly via defparam-equivalent generics, bypassing automatic
-- `dpram` inference entirely. Written for exactly one consumer:
-- src/common/core/huc6270.vhd's SPR_LINE_BUF0/1 (9-bit address, 9-bit data).
--
-- WHY THIS EXISTS: SPR_LINE_BUF0/1 needs two independently-addressed writers (the
-- tile-fetch pipeline on port A, the clear-sweep on port B) with no way to statically
-- prove their addresses never coincide. On GW5A (Console 60K/Primer 25K) this hits
-- `ERROR (PA2122): Not support 'mem'(DPB) WRITE_MODE1 = 2'b10` at place-and-route, even
-- though automatic `dpram` inference (src/common/mem/bram_gowin.vhd) reliably produces
-- 2'b01 for every OTHER memory in this design (confirmed: PRAM/RAM/VRAM0/SAT/voltab/
-- palette all isolated and tested clean on GW5A). Root cause, found in
-- `~/gowin-edu/IDE/doc/EN/UG285-1.3.7E_Gowin BSRAM & SSRAM User Guide.pdf` (Section 3.1,
-- Note [1] on the DPB/DPX9B functional description): "Performing read and write
-- operations to the same address at the same time is not allowed." Confirmed present
-- even with the completely unmodified upstream donor wiring (no mux, no retiming) --
-- this predates and is independent of this port's own sprite-buffer fix. See
-- docs/PORTING.md's "ROOT CAUSE FOUND" section for the full isolation trail.
--
-- Template: this file's generic/port structure is transcribed directly from UG285
-- Section 3.1's official VHDL instantiation example (page 16-17, "Vhdl Instantiation"),
-- not invented -- match any future change against that document, not against inference
-- or assumption.
--
-- Port/generic mapping notes (UG285 Table 2-2, "18Kbits / 2K x 9" row): DPX9B's usable
-- address field for 9-bit-wide data occupies ADA[13:3] (11 bits, 2048-deep native
-- granularity); this buffer only needs 512 entries (9-bit logical address), so the real
-- address occupies the low 9 of those 11 bits (ADA[11:3]) with ADA[13:12] tied to "00"
-- and the fixed ADA[2:0] = "000" convention UG285's own example uses for narrower-than-16
-- widths. DIA/DOA are 16-bit physical buses; the real 9-bit data occupies the low 9 bits
-- (DIA[8:0]), upper 7 bits tied to '0', matching UG285's BIT_WIDTH=8 example's identical
-- low-bits-real/high-bits-zero convention.
--
-- UNTESTED ON REAL HARDWARE, but real gw_sh place-and-route is the actual verification
-- this needs -- rebuild scripts/build_console60k_core_test.tcl against this file next.

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

architecture rtl of dpram9_dpb_wm01 is

	component DPX9B
		generic (
			BIT_WIDTH_0    : integer := 18;
			BIT_WIDTH_1    : integer := 18;
			READ_MODE0     : bit    := '0';
			READ_MODE1     : bit    := '0';
			WRITE_MODE0    : bit_vector := "00";
			WRITE_MODE1    : bit_vector := "00";
			BLK_SEL_0      : bit_vector := "000";
			BLK_SEL_1      : bit_vector := "000";
			RESET_MODE     : string := "SYNC"
		);
		port (
			DOA    : out std_logic_vector(17 downto 0);
			DOB    : out std_logic_vector(17 downto 0);
			CLKA   : in  std_logic;
			CLKB   : in  std_logic;
			CEA    : in  std_logic;
			CEB    : in  std_logic;
			OCEA   : in  std_logic;
			OCEB   : in  std_logic;
			RESETA : in  std_logic;
			RESETB : in  std_logic;
			WREA   : in  std_logic;
			WREB   : in  std_logic;
			ADA    : in  std_logic_vector(13 downto 0);
			ADB    : in  std_logic_vector(13 downto 0);
			BLKSELA: in  std_logic_vector(2 downto 0);
			BLKSELB: in  std_logic_vector(2 downto 0);
			DIA    : in  std_logic_vector(17 downto 0);
			DIB    : in  std_logic_vector(17 downto 0)
		);
	end component;

	-- DPX9B (the 18Kbit variant) has 18-bit-wide physical DOA/DOB/DIA/DIB buses --
	-- confirmed by a real build error (EX4923, "expected 18u") after an initial mistake
	-- copying DPB's 16-bit width here. Figure 3-7 in UG285 labels DPX9B's data buses
	-- "18", DPB's "16" -- different primitives, don't conflate them again.
	signal doa18, dob18 : std_logic_vector(17 downto 0);
	signal dia18, dib18 : std_logic_vector(17 downto 0) := (others => '0');
	signal ada14, adb14 : std_logic_vector(13 downto 0) := (others => '0');

begin

	-- Real 9-bit address occupies ADA/ADB[11:3] (low 9 of the 11-bit field UG285's
	-- 2Kx9 configuration defines); [13:12] unused-depth bits and [2:0] fixed per the
	-- guide's own narrower-than-16 convention -- see this file's header.
	ada14 <= "00" & address_a & "000";
	adb14 <= "00" & address_b & "000";

	dia18 <= "000000000" & data_a;
	dib18 <= "000000000" & data_b;

	q_a <= doa18(8 downto 0);
	q_b <= dob18(8 downto 0);

	uut : DPX9B
		generic map (
			BIT_WIDTH_0 => 9,
			BIT_WIDTH_1 => 9,
			READ_MODE0  => '0',              -- bypass, matches bram_gowin.vhd's dpram timing
			READ_MODE1  => '0',
			WRITE_MODE0 => "01",             -- write-through -- THE FIX, forced explicitly
			WRITE_MODE1 => "01",
			BLK_SEL_0   => "000",
			BLK_SEL_1   => "000",
			RESET_MODE  => "SYNC"
		)
		port map (
			DOA     => doa18,
			DOB     => dob18,
			CLKA    => clock,
			CLKB    => clock,
			CEA     => '1',
			CEB     => '1',
			OCEA    => '1',
			OCEB    => '1',
			RESETA  => '0',
			RESETB  => '0',
			WREA    => wren_a,
			WREB    => wren_b,
			ADA     => ada14,
			ADB     => adb14,
			BLKSELA => "000",
			BLKSELB => "000",
			DIA     => dia18,
			DIB     => dib18
		);

end architecture;
