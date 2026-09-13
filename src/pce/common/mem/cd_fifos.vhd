-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

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
-- SHOW-AHEAD BUBBLE -- was a KNOWN SIMPLIFICATION here, and it was a real bug. FIXED
-- 2026-09-11; sim/cd/tb_scsi_fifo.vhd is the regression test, and it fails on the old
-- code for every byte.
--
-- All three donor instantiations set LPM_SHOWAHEAD = "ON": q reflects the current
-- front-of-queue item combinationally, valid on the same cycle rdempty deasserts and
-- before rdreq is ever asserted. This implementation reads through bram_gowin's dpram,
-- whose q is REGISTERED -- it reflects address_b's target one cycle later. So the naive
-- "empty when wr_ptr = rd_ptr" deasserts empty one cycle before q actually holds the
-- byte, and a consumer that samples q on that cycle (SCSI.vhd's SP_FREE and
-- SP_DATAIN_END branches both do exactly that) latches whatever the RAM held before.
--
-- Why it stayed hidden: under the donor's own usage the FIFO is never observed empty in
-- the steady state. MiSTer's HPS bursts an entire 2048-byte sector in at once, so rd_ptr
-- trails far behind wr_ptr and q has settled many cycles earlier. cd_bridge.vhd feeds
-- bytes ONE AT A TIME at UART cadence (~214 clk_pce cycles apart), so the FIFO is empty
-- at every single byte and the race is hit on every byte instead of never. Measured on
-- real hardware 2026-09-11: the syscard read 0xf2 as the first GETDIRINFO reply byte
-- where cd_bridge had written 0x01, concluded first_track = 0xf2, asked for track 0xf2
-- (BCD 152 > 100), got INVALID_PARAMETER back, and spun in a REQUEST SENSE loop.
--
-- The fix, applied to all three FIFOs: hold `empty` asserted until q is genuinely valid,
-- which is one cycle after EITHER pointer moves --
--   * a write into an empty FIFO: compare rd_ptr against a REGISTERED copy of wr_ptr, so
--     empty deasserts a cycle later, by which time dpram has registered the new byte;
--   * the cycle right after a pop: q still shows the PREVIOUS entry (dpram registered it
--     from the old address_b), so re-assert empty for that one cycle.
-- full/wrfull keep using the true wr_ptr -- delaying those would risk a real overflow.
-- This costs one cycle of latency per byte and nothing else; no consumer in this port
-- pops on consecutive cycles (every SCSI.vhd pop is gated behind a REQ/ACK handshake).

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
		wrfull  : out std_logic;
		-- Bytes thrown away because a write arrived while full. The donor silently
		-- dropped these (wrreq is gated on FULL with no back-pressure), which makes a
		-- short transfer indistinguishable from a correct one. Counted so it is visible.
		dbg_drops : out unsigned(15 downto 0);
		-- Live occupancy, so cd_bridge can refuse to request another sector until there
		-- is genuinely room for it.
		dbg_level : out unsigned(12 downto 0)
	);
end entity;

architecture rtl of SCSI_FIFO is
	-- PCE PORT (2026-08-27): shrunk from 12 (4096, matching the donor's LPM_NUMWORDS) to
	-- 6 (64 entries). Real measured reason, not a guess: this FIFO was dead code in every
	-- build in this project until Primer 25K's CD build first drove CD_STAT_GET/
	-- CD_COMM_SEND/CD_DATA_WR for real (a minimal SCSI target stub, see
	-- pcetang_primer25k_cd.vhd) -- before that, CD_STAT_GET tied to a constant '0' made
	-- STAT_PEND provably always 0, so the whole SP_STAT_*/SP_DATAIN_* state machine (and
	-- this FIFO's real write/read enables) were dead and swept away. The instant they
	-- became real, this 4096x8 FIFO (32768 bits) needed real backing and Primer 25K had
	-- 0 free BSRAM blocks left -- Gowin fell back to LUT/DFF storage for the whole thing,
	-- +~11000 LUTs (measured: 13313/23040 clean -> 24061/23040, RP0006). 64 entries is
	-- real headroom for this stub's actual use (18 sense bytes at a time) at a LUT cost
	-- small enough not to need a real BSRAM block at all. NOTE (corrected 2026-08-27):
	-- this does NOT synthesize as a RAM16 primitive as originally assumed/written here --
	-- the real synthesis report shows SSRAM(RAM16)=0 for this instance; it becomes ~260
	-- registers + ~204 LUTs, i.e. real CLS fabric (already ~93% utilized project-wide),
	-- not a free/neutral resource. Still the right fix for the immediate BSRAM-exhaustion
	-- problem (LUTs were available, BSRAM wasn't), just not for the reason first stated.
	-- WIDENED BACK (2026-08-31): the real CD sector-streaming design (cd_bridge.vhd) this
	-- comment predicted has arrived -- READ(6) now drains real 2048-byte data sectors
	-- through this exact FIFO (SCSI.vhd's own DATA-IN path, same one REQUEST SENSE already
	-- used for its 18 sense bytes). 2048 entries x 8 bits = 1 BSRAM block/board on Gowin
	-- (same size class as CDDA_FIFO's own 2048x32 = 4 blocks), real, affordable post-PSG-
	-- Path-A headroom on all 3 boards (see pcetang_status_matrix.md lever 20). Chosen over
	-- adding UART-side flow control/pacing to the new sector protocol -- simpler, and this
	-- FIFO now has to absorb a full sector while the CPU drains it a byte at a time.
	-- RESTORED TO DONOR DEPTH 2026-09-11. The donor instantiates this with
	-- LPM_NUMWORDS = 4096 (see rtl/cd/SCSI_FIFO.vhd); it had been left at 2048 from the
	-- Primer-25K BSRAM-pressure work and never revisited for Console 60K, which runs at
	-- 73/118 blocks with room to spare.
	--
	-- Depth is a real correctness margin here, not just buffering, because of how
	-- cd_bridge paces itself: it requests the NEXT sector as soon as it has counted 2048
	-- bytes ARRIVING FROM THE MCU, not when the CPU has drained them. So occupancy grows
	-- with any CPU lag, and FIFO_WR_REQ is gated on FULL='0' with no back-pressure --
	-- over-capacity bytes are silently DROPPED. At 2048 we tolerate one sector of lag;
	-- at the donor's 4096, two. That is the shape of "3-sector read works, 16-sector read
	-- fails" seen on Prince of Persia. See the DBG_DROPS counter below, which now counts
	-- the drops instead of leaving them invisible.
	constant ADDR_W : integer := 12;   -- 4096 entries, donor LPM_NUMWORDS
	signal wr_ptr, rd_ptr : unsigned(ADDR_W downto 0) := (others => '0');
	-- see the show-ahead note in this file's header: q is only valid one cycle after
	-- either pointer moves, so empty is computed from a delayed write pointer and
	-- re-asserted for the single cycle following a pop.
	signal wr_ptr_q : unsigned(ADDR_W downto 0) := (others => '0');
	signal pop_d    : std_logic := '0';
	signal drops_i  : unsigned(15 downto 0) := (others => '0');
	signal mem_q : std_logic_vector(7 downto 0);
	signal empty_i, full_i, wren_a_i : std_logic;
begin
	dbg_drops <= drops_i;
	dbg_level <= resize(wr_ptr - rd_ptr, 13);

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

	empty_i <= '1' when wr_ptr_q = rd_ptr or pop_d = '1' else '0';
	full_i  <= '1' when wr_ptr(ADDR_W-1 downto 0) = rd_ptr(ADDR_W-1 downto 0)
	                and wr_ptr(ADDR_W) /= rd_ptr(ADDR_W) else '0';
	rdempty <= empty_i;
	wrfull  <= full_i;

	process (wrclk, aclr)
	begin
		if aclr = '1' then
			wr_ptr   <= (others => '0');
			rd_ptr   <= (others => '0');
			wr_ptr_q <= (others => '0');
			pop_d    <= '0';
			drops_i  <= (others => '0');
		elsif rising_edge(wrclk) then
			wr_ptr_q <= wr_ptr;
			pop_d    <= '0';
			if wrreq = '1' and full_i = '0' then
				wr_ptr <= wr_ptr + 1;
			elsif wrreq = '1' then
				drops_i <= drops_i + 1;   -- silently lost before this counter existed
			end if;
			if rdreq = '1' and empty_i = '0' then
				rd_ptr <= rd_ptr + 1;
				pop_d  <= '1';
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
	-- MEASUREMENT ONLY (2026-08-30) -- shrunk 12->11 (4096->2048 entries, ~93ms->~46ms
	-- of jitter tolerance at 44.1kHz stereo) to measure the real BSRAM cost of a
	-- smaller depth on Console 60K CD (the tightest board, PA2017 at full depth: 121/118,
	-- +8 blocks, over by 3). Real donor-inherited value was 4096 (LPM_NUMWORDS, sized for
	-- a different reference platform's own I/O latency, never revisited for this
	-- project's real BL616/RP2350 UART link) -- see this project's own status matrix
	-- for the real UART-bandwidth analysis this shrink question is coupled to (2Mbaud/
	-- 8N1 = 200kB/s vs CD-DA's 176.4kB/s raw need, only 13.4% margin BEFORE any
	-- concurrent traffic). Not yet a committed design decision -- do not revert without
	-- being asked, but do not treat this depth as final either.
	constant ADDR_W : integer := 11;   -- 2048 entries, was 12/4096
	signal wr_ptr, rd_ptr : unsigned(ADDR_W downto 0) := (others => '0');
	-- see the show-ahead note in this file's header
	signal wr_ptr_q : unsigned(ADDR_W downto 0) := (others => '0');
	signal pop_d    : std_logic := '0';
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

	empty_i <= '1' when wr_ptr_q = rd_ptr or pop_d = '1' else '0';
	full_i  <= '1' when wr_ptr(ADDR_W-1 downto 0) = rd_ptr(ADDR_W-1 downto 0)
	                and wr_ptr(ADDR_W) /= rd_ptr(ADDR_W) else '0';
	empty <= empty_i;
	full  <= full_i;

	process (clock)
	begin
		if rising_edge(clock) then
			if sclr = '1' then
				wr_ptr   <= (others => '0');
				rd_ptr   <= (others => '0');
				wr_ptr_q <= (others => '0');
				pop_d    <= '0';
			else
				wr_ptr_q <= wr_ptr;
				pop_d    <= '0';
				if wrreq = '1' and full_i = '0' then
					wr_ptr <= wr_ptr + 1;
				end if;
				if rdreq = '1' and empty_i = '0' then
					rd_ptr <= rd_ptr + 1;
					pop_d  <= '1';
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
	-- MEASUREMENT ONLY (2026-08-30) -- shrunk 9->8 (512->256 entries) alongside
	-- CDDA_FIFO's own shrink, per the same real BSRAM-headroom question. This FIFO is
	-- 8-bit wide (4Kbit at 512 deep) -- NOT a real driver of the BSRAM problem
	-- (CDDA_FIFO's 32-bit width is the entire measured +8-block cost) -- shrunk here
	-- for consistency, not because it was itself a resource concern.
	constant ADDR_W : integer := 8;    -- 256 entries, was 9/512 (donor LPM_NUMWORDS=490)
	signal wr_ptr, rd_ptr : unsigned(ADDR_W downto 0) := (others => '0');
	-- see the show-ahead note in this file's header
	signal wr_ptr_q : unsigned(ADDR_W downto 0) := (others => '0');
	signal pop_d    : std_logic := '0';
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

	empty_i <= '1' when wr_ptr_q = rd_ptr or pop_d = '1' else '0';
	full_i  <= '1' when wr_ptr(ADDR_W-1 downto 0) = rd_ptr(ADDR_W-1 downto 0)
	                and wr_ptr(ADDR_W) /= rd_ptr(ADDR_W) else '0';
	empty <= empty_i;
	full  <= full_i;

	process (clock)
	begin
		if rising_edge(clock) then
			if sclr = '1' then
				wr_ptr   <= (others => '0');
				rd_ptr   <= (others => '0');
				wr_ptr_q <= (others => '0');
				pop_d    <= '0';
			else
				wr_ptr_q <= wr_ptr;
				pop_d    <= '0';
				if wrreq = '1' and full_i = '0' then
					wr_ptr <= wr_ptr + 1;
				end if;
				if rdreq = '1' and empty_i = '0' then
					rd_ptr <= rd_ptr + 1;
					pop_d  <= '1';
				end if;
			end if;
		end if;
	end process;
end architecture;
