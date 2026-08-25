-- SPDX-License-Identifier: GPL-3.0-or-later

-- Gowin-clean replacements for TurboGrafx16_MiSTer's three Quartus dcfifo_mixed_widths
-- megafunction wizard files (rtl/cd/SCSI_FIFO.vhd, CDDA_FIFO.vhd, CDSUBC_FIFO.vhd) --
-- same category as bram_gowin.vhd's dpram/dpram_difclk/spram: a toolchain-portability
-- replacement, not a licensing question (the donor files carry no author copyright of
-- their own, being wizard output).
--
-- All three turn out to be SINGLE-CLOCK in actual use, not the dual-clock FIFOs their
-- name/generics suggest: rtl/cd/SCSI.vhd instantiates SCSI_FIFO with wrclk and rdclk both
-- tied to the same CLK signal, and CDDA_FIFO/CDSUBC_FIFO only ever had one `clock` port
-- to begin with. So these are plain synchronous FIFOs backed by bram_gowin.vhd's dpram
-- (one port for write, one for read, same clock) -- no CDC, no gray-code pointers needed.
--
-- Depths match the donor's LPM_NUMWORDS exactly (SCSI_FIFO/CDDA_FIFO: 4096; CDSUBC_FIFO:
-- donor is 490, rounded up to the next power of two, 512, for simple pointer wraparound
-- -- strictly larger than the donor's capacity, never causes an earlier overflow than the
-- original).
--
-- KNOWN SIMPLIFICATION, not yet verified: all three donor instantiations set
-- LPM_SHOWAHEAD = "ON" (q combinationally reflects the current front-of-queue item, valid
-- before rdreq is even asserted -- "first-word-fall-through"). This implementation reads
-- through bram_gowin's dpram, which has the same one-cycle synchronous latency as every
-- other memory in this port: q reflects rd_ptr's target starting one cycle after rd_ptr
-- last changed, not combinationally on it. For a STABLE rd_ptr (no pop this cycle) q is
-- valid continuously, same as showahead; the difference only shows up in the cycle
-- immediately after a pop, where true showahead has zero bubble and this has one.
--
-- Not exercised by any path in this port yet -- CD_EN gates the whole CD subsystem off
-- at the pce_top.vhd level, and cd.vhd's own SCSI/ADPCM state machines are the only
-- consumers of these three FIFOs' timing. Needed here only so pce_top.vhd (which
-- instantiates cd.vhd unconditionally, not inside a generate) compiles at all. Before
-- CD_EN is ever driven high in a real build, verify against cd.vhd's/SCSI.vhd's actual
-- pop cadence whether the one-cycle bubble matters -- a GHDL testbench, not inference,
-- per this project's own working style (see docs/PORTING.md).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--------------------------------------------------------------------------------
entity SCSI_FIFO is
	port (
		aclr    : in  std_logic := '0';
		data    : in  std_logic_vector(7 downto 0);
		rdclk   : in  std_logic;
		rdreq   : in  std_logic;
		wrclk   : in  std_logic;
		wrreq   : in  std_logic;
		q       : out std_logic_vector(7 downto 0);
		rdempty : out std_logic;
		wrfull  : out std_logic
	);
end entity;

architecture rtl of SCSI_FIFO is
	constant ADDR_W : integer := 12;   -- 4096 entries, matches donor LPM_NUMWORDS
	signal wr_ptr, rd_ptr : unsigned(ADDR_W downto 0) := (others => '0');
	signal mem_q : std_logic_vector(7 downto 0);
	signal empty_i, full_i, wren_a_i : std_logic;
begin
	-- wrclk = rdclk always in this design (see file header) -- both tied to the same
	-- port map signal by rtl/cd/SCSI.vhd, so a single-clock implementation is exact,
	-- not an approximation, regardless of the two port names.
	wren_a_i <= wrreq and not full_i;
	ram: entity work.dpram
		generic map (ADDR_W, 8)
		port map (
			clock     => wrclk,
			address_a => std_logic_vector(wr_ptr(ADDR_W-1 downto 0)),
			data_a    => data,
			wren_a    => wren_a_i,
			address_b => std_logic_vector(rd_ptr(ADDR_W-1 downto 0)),
			q_b       => mem_q
		);
	q <= mem_q;

	empty_i <= '1' when wr_ptr = rd_ptr else '0';
	full_i  <= '1' when wr_ptr(ADDR_W-1 downto 0) = rd_ptr(ADDR_W-1 downto 0)
	                and wr_ptr(ADDR_W) /= rd_ptr(ADDR_W) else '0';
	rdempty <= empty_i;
	wrfull  <= full_i;

	process (wrclk, aclr)
	begin
		if aclr = '1' then
			wr_ptr <= (others => '0');
			rd_ptr <= (others => '0');
		elsif rising_edge(wrclk) then
			if wrreq = '1' and full_i = '0' then
				wr_ptr <= wr_ptr + 1;
			end if;
			if rdreq = '1' and empty_i = '0' then
				rd_ptr <= rd_ptr + 1;
			end if;
		end if;
	end process;
end architecture;

--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity CDDA_FIFO is
	port (
		clock : in  std_logic;
		data  : in  std_logic_vector(31 downto 0);
		rdreq : in  std_logic;
		sclr  : in  std_logic;
		wrreq : in  std_logic;
		empty : out std_logic;
		full  : out std_logic;
		q     : out std_logic_vector(31 downto 0)
	);
end entity;

architecture rtl of CDDA_FIFO is
	constant ADDR_W : integer := 12;   -- 4096 entries, matches donor LPM_NUMWORDS
	signal wr_ptr, rd_ptr : unsigned(ADDR_W downto 0) := (others => '0');
	signal mem_q : std_logic_vector(31 downto 0);
	signal empty_i, full_i, wren_a_i : std_logic;
begin
	wren_a_i <= wrreq and not full_i;
	ram: entity work.dpram
		generic map (ADDR_W, 32)
		port map (
			clock     => clock,
			address_a => std_logic_vector(wr_ptr(ADDR_W-1 downto 0)),
			data_a    => data,
			wren_a    => wren_a_i,
			address_b => std_logic_vector(rd_ptr(ADDR_W-1 downto 0)),
			q_b       => mem_q
		);
	q <= mem_q;

	empty_i <= '1' when wr_ptr = rd_ptr else '0';
	full_i  <= '1' when wr_ptr(ADDR_W-1 downto 0) = rd_ptr(ADDR_W-1 downto 0)
	                and wr_ptr(ADDR_W) /= rd_ptr(ADDR_W) else '0';
	empty <= empty_i;
	full  <= full_i;

	process (clock)
	begin
		if rising_edge(clock) then
			if sclr = '1' then
				wr_ptr <= (others => '0');
				rd_ptr <= (others => '0');
			else
				if wrreq = '1' and full_i = '0' then
					wr_ptr <= wr_ptr + 1;
				end if;
				if rdreq = '1' and empty_i = '0' then
					rd_ptr <= rd_ptr + 1;
				end if;
			end if;
		end if;
	end process;
end architecture;

--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity CDSUBC_FIFO is
	port (
		clock : in  std_logic;
		data  : in  std_logic_vector(7 downto 0);
		rdreq : in  std_logic;
		sclr  : in  std_logic;
		wrreq : in  std_logic;
		empty : out std_logic;
		full  : out std_logic;
		q     : out std_logic_vector(7 downto 0)
	);
end entity;

architecture rtl of CDSUBC_FIFO is
	constant ADDR_W : integer := 9;    -- 512 entries, donor LPM_NUMWORDS=490 rounded up
	signal wr_ptr, rd_ptr : unsigned(ADDR_W downto 0) := (others => '0');
	signal mem_q : std_logic_vector(7 downto 0);
	signal empty_i, full_i, wren_a_i : std_logic;
begin
	wren_a_i <= wrreq and not full_i;
	ram: entity work.dpram
		generic map (ADDR_W, 8)
		port map (
			clock     => clock,
			address_a => std_logic_vector(wr_ptr(ADDR_W-1 downto 0)),
			data_a    => data,
			wren_a    => wren_a_i,
			address_b => std_logic_vector(rd_ptr(ADDR_W-1 downto 0)),
			q_b       => mem_q
		);
	q <= mem_q;

	empty_i <= '1' when wr_ptr = rd_ptr else '0';
	full_i  <= '1' when wr_ptr(ADDR_W-1 downto 0) = rd_ptr(ADDR_W-1 downto 0)
	                and wr_ptr(ADDR_W) /= rd_ptr(ADDR_W) else '0';
	empty <= empty_i;
	full  <= full_i;

	process (clock)
	begin
		if rising_edge(clock) then
			if sclr = '1' then
				wr_ptr <= (others => '0');
				rd_ptr <= (others => '0');
			else
				if wrreq = '1' and full_i = '0' then
					wr_ptr <= wr_ptr + 1;
				end if;
				if rdreq = '1' and empty_i = '0' then
					rd_ptr <= rd_ptr + 1;
				end if;
			end if;
		end if;
	end process;
end architecture;
