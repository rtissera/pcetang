-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- Regression test for the SCSI_FIFO show-ahead bubble (cd_fifos.vhd's own header calls
-- this out as a KNOWN SIMPLIFICATION, "not yet verified", and asks for exactly this
-- testbench before CD_EN is driven high in a real build).
--
-- The donor instantiates all three FIFOs with LPM_SHOWAHEAD = "ON": q is valid BEFORE
-- rdreq, on the same cycle rdempty deasserts. The port reads through bram_gowin's
-- dpram, whose q is registered, so a byte written into an EMPTY fifo is not visible on
-- q until one cycle after rdempty has already gone low.
--
-- That never showed up under the donor's usage (MiSTer's HPS bursts a whole 2048-byte
-- sector in, so rd_ptr always trails far behind and q has long settled), but cd_bridge
-- feeds bytes one at a time at UART cadence -- the fifo is empty at EVERY byte, so the
-- race is hit on every byte rather than never. Measured on hardware 2026-09-11: the
-- syscard read 0xf2 as the first GETDIRINFO reply byte where the bridge had written
-- 0x01, then asked for track 0xf2 (BCD 152 > 100), got INVALID_PARAMETER, and spun in
-- a REQUEST SENSE loop forever.
--
-- STIM below is the real cadence: write one byte, wait for rdempty to fall, then pop
-- the way SCSI.vhd's SP_FREE branch does (sample q and assert rdreq in the SAME cycle).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_scsi_fifo is
end entity;

architecture sim of tb_scsi_fifo is
	signal clk     : std_logic := '0';
	signal aclr    : std_logic := '1';
	signal data    : std_logic_vector(7 downto 0) := (others => '0');
	signal wrreq   : std_logic := '0';
	signal rdreq   : std_logic := '0';
	signal q       : std_logic_vector(7 downto 0);
	signal rdempty : std_logic;
	signal wrfull  : std_logic;
	signal errors  : integer := 0;
	signal done    : boolean := false;
begin
	clk <= not clk after 5 ns when not done else '0';

	dut: entity work.SCSI_FIFO
		port map (aclr => aclr, data => data, rdclk => clk, rdreq => rdreq,
		          wrclk => clk, wrreq => wrreq, q => q,
		          rdempty => rdempty, wrfull => wrfull);

	stim: process
		-- one trickle-fed byte: push it, wait for the fifo to report non-empty, then
		-- pop exactly as SCSI.vhd does -- sample q in the same cycle rdreq is asserted.
		procedure push_pop(b : std_logic_vector(7 downto 0); tag : string) is
			variable got : std_logic_vector(7 downto 0);
		begin
			wait until rising_edge(clk);
			data  <= b;
			wrreq <= '1';
			wait until rising_edge(clk);
			wrreq <= '0';
			-- SP_FREE polls rdempty and acts the instant it falls
			while rdempty = '1' loop
				wait until rising_edge(clk);
			end loop;
			got   := q;            -- what SCSI.vhd latches into DBO
			rdreq <= '1';
			wait until rising_edge(clk);
			rdreq <= '0';
			if got /= b then
				report "FAIL " & tag & ": wrote 0x" & to_hstring(b) &
				       " but show-ahead q was 0x" & to_hstring(got) severity error;
				errors <= errors + 1;
			end if;
			wait until rising_edge(clk);
		end procedure;
		-- write `n` bytes back-to-back (donor/HPS style), then pop them one at a time
		-- with a gap, checking both value and order.
		procedure burst_drain(n : integer; tag : string) is
			variable got : std_logic_vector(7 downto 0);
		begin
			for i in 0 to n-1 loop
				wait until rising_edge(clk);
				data  <= std_logic_vector(to_unsigned(16#40# + i, 8));
				wrreq <= '1';
			end loop;
			wait until rising_edge(clk);
			wrreq <= '0';
			for i in 0 to n-1 loop
				while rdempty = '1' loop
					wait until rising_edge(clk);
				end loop;
				got   := q;
				rdreq <= '1';
				wait until rising_edge(clk);
				rdreq <= '0';
				if got /= std_logic_vector(to_unsigned(16#40# + i, 8)) then
					report "FAIL " & tag & " #" & integer'image(i) & ": expected 0x" &
					       to_hstring(std_logic_vector(to_unsigned(16#40# + i, 8))) &
					       " got 0x" & to_hstring(got) severity error;
					errors <= errors + 1;
				end if;
				wait until rising_edge(clk);
				wait until rising_edge(clk);
			end loop;
		end procedure;

		-- Write and drain concurrently so the occupancy crosses 0 repeatedly -- exactly
		-- the boundary the delayed-empty logic moves.
		procedure mixed_feed(n : integer; tag : string) is
			variable got : std_logic_vector(7 downto 0);
		begin
			for i in 0 to n-1 loop
				wait until rising_edge(clk);
				data  <= std_logic_vector(to_unsigned(16#80# + i, 8));
				wrreq <= '1';
				wait until rising_edge(clk);
				wrreq <= '0';
				if (i mod 3) /= 2 then
					wait until rising_edge(clk);
				end if;
				while rdempty = '1' loop
					wait until rising_edge(clk);
				end loop;
				got   := q;
				rdreq <= '1';
				wait until rising_edge(clk);
				rdreq <= '0';
				if got /= std_logic_vector(to_unsigned(16#80# + i, 8)) then
					report "FAIL " & tag & " #" & integer'image(i) & ": expected 0x" &
					       to_hstring(std_logic_vector(to_unsigned(16#80# + i, 8))) &
					       " got 0x" & to_hstring(got) severity error;
					errors <= errors + 1;
				end if;
			end loop;
		end procedure;
	begin
		wait for 40 ns;
		aclr <= '0';
		wait until rising_edge(clk);
		wait until rising_edge(clk);

		-- The exact bytes the bridge writes for GETDIRINFO mode 0 on this disc.
		push_pop(x"01", "GDI m0 byte0 (first track)");
		push_pop(x"34", "GDI m0 byte1 (last track)");
		-- lead-out MSF, mode 1
		push_pop(x"70", "GDI m1 byte0");
		push_pop(x"15", "GDI m1 byte1");
		push_pop(x"36", "GDI m1 byte2");
		-- a couple of sector bytes, same cadence READ(6) uses
		push_pop(x"82", "sector0 byte0");
		push_pop(x"b1", "sector0 byte1");

		-- Donor cadence: a whole burst written back-to-back, then drained one byte at a
		-- time. This is the pattern that hid the bug, so it must keep passing -- it is
		-- the regression guard on the fix itself, not on the original defect.
		burst_drain(16, "burst-then-drain");
		-- Interleaved: keep writing while draining, so the FIFO is sometimes empty and
		-- sometimes not. Covers the boundary the delayed-empty logic actually moves.
		mixed_feed(24, "interleaved feed");

		if errors = 0 then
			report "PASS: SCSI_FIFO show-ahead is correct under byte-at-a-time feed"
				severity note;
		else
			report "FAILED with " & integer'image(errors) & " bad bytes" severity failure;
		end if;
		done <= true;
		wait;
	end process;
end architecture;
