-- SPDX-License-Identifier: GPL-3.0-or-later

-- Direct Gowin DPB primitive instantiation, forcing WRITE_MODE0/1 = 2'b01 explicitly,
-- same technique and same reason as dpram9_dpb_wm01.vhd (see that file's header for the
-- full root-cause writeup) -- written for huc6270.vhd's SAT (sprite attribute table,
-- 8-bit address, 16-bit data): port A is a DMA write (independent address
-- DMAS_SAT_ADDR), port B muxes a read address (SPR_EVAL_X) against a clear-sweep write
-- address (CLR_A) with q_b actively read -- the same two-independently-addressed-writers
-- shape that hit ERROR (PA2122) for SPR_LINE_BUF0/1, confirmed to hit it here too once
-- SPR_LINE_BUF0/1's own instance was no longer occupying the position Gowin's error
-- reports first (see NECTang's docs/PORTING.md's "ROOT CAUSE FOUND" section).
--
-- Unlike the 9-bit sprite buffers (needing DPX9B, the 18Kbit variant), this shape's
-- 16-bit width fits DPB (the 16Kbit variant) natively -- UG285 Table 2-2's "1K x 16" row:
-- 1,024-deep native granularity, address field ADA[13:4] (10 bits), full 16-bit DIA/DOA,
-- no padding needed. This buffer only needs 256 entries (8-bit logical address), so the
-- real address occupies the low 8 of those 10 bits: ADA[11:4] = real address, ADA[13:12]
-- = "00", fixed ADA[3:0] = "0000" (this variant's granularity has no extra alignment bits
-- below the address field, unlike the 9-bit case's ADA[2:0] convention -- verify this
-- against UG285 Table 2-2/Figure 3-7 if BIT_WIDTH ever changes here).
--
-- UNTESTED ON REAL HARDWARE, but real gw_sh place-and-route is the actual verification
-- this needs.

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

architecture rtl of dpram8x16_dpb_wm01 is

	component DPB
		generic (
			BIT_WIDTH_0    : integer := 16;
			BIT_WIDTH_1    : integer := 16;
			READ_MODE0     : bit    := '0';
			READ_MODE1     : bit    := '0';
			WRITE_MODE0    : bit_vector := "00";
			WRITE_MODE1    : bit_vector := "00";
			BLK_SEL_0      : bit_vector := "000";
			BLK_SEL_1      : bit_vector := "000";
			RESET_MODE     : string := "SYNC"
		);
		port (
			DOA    : out std_logic_vector(15 downto 0);
			DOB    : out std_logic_vector(15 downto 0);
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
			DIA    : in  std_logic_vector(15 downto 0);
			DIB    : in  std_logic_vector(15 downto 0)
		);
	end component;

	signal ada14, adb14 : std_logic_vector(13 downto 0) := (others => '0');

begin

	-- Real 8-bit address occupies ADA/ADB[11:4] (low 8 of the 10-bit field UG285's
	-- 1Kx16 configuration defines); [13:12] unused-depth bits and [3:0] fixed -- see
	-- this file's header.
	ada14 <= "00" & address_a & "0000";
	adb14 <= "00" & address_b & "0000";

	uut : DPB
		generic map (
			BIT_WIDTH_0 => 16,
			BIT_WIDTH_1 => 16,
			READ_MODE0  => '0',              -- bypass, matches bram_gowin.vhd's dpram timing
			READ_MODE1  => '0',
			WRITE_MODE0 => "01",             -- write-through -- THE FIX, forced explicitly
			WRITE_MODE1 => "01",
			BLK_SEL_0   => "000",
			BLK_SEL_1   => "000",
			RESET_MODE  => "SYNC"
		)
		port map (
			DOA     => q_a,
			DOB     => q_b,
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
			DIA     => data_a,
			DIB     => data_b
		);

end architecture;
