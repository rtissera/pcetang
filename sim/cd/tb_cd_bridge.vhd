-- Real GHDL testbench for src/pce/common/core/cd_bridge.vhd, driven by a synthetic SCSI
-- initiator (not SCSI.vhd itself -- that state machine's own bus-phase timing is donor,
-- unmodified, real, and out of scope here) and a synthetic sector source, standing in for
-- the not-yet-built MCU-side sector protocol (see pcetang_cd_scsi_plan.md). Scratch/one-off
-- verification tool, isolate-before-integrate per this project's own working style --
-- mirrors sim/vram0/'s real testbenches structurally.
--
-- Checks, in order:
--   1. REQUEST SENSE with DISC_MOUNTED='0' -> real NOT READY/NEC 0x0B sense bytes, GOOD
--      final status.
--   2. TEST UNIT READY with DISC_MOUNTED='0' -> CHECK CONDITION.
--   3. TEST UNIT READY with DISC_MOUNTED='1' -> GOOD.
--   4. READ(6), sa=0x001000, sc=2 (2 sectors), DISC_MOUNTED='1' -> SECTOR_REQ pulses at
--      LBA 0x1000 then 0x1001, synthetic source streams a known byte pattern
--      (byte_value = sector_lba(7 downto 0) xor byte_index(7 downto 0)) for each, bridge
--      relays exactly 4096 bytes (2x2048) through CD_DATA/CD_DATA_WR in the right order,
--      GOOD final status.
--   5. REQUEST SENSE with DISC_MOUNTED='1' and nothing pending -> real NO SENSE (all-zero
--      key) bytes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_cd_bridge is
end entity;

architecture sim of tb_cd_bridge is
	constant CLK_PERIOD : time := 23.333 ns;  -- ~42.857MHz, real clk_pce rate

	signal clk    : std_logic := '0';
	signal rst_n  : std_logic := '0';

	signal cd_stat      : std_logic_vector(7 downto 0);
	signal cd_msg       : std_logic_vector(7 downto 0);
	signal cd_stat_get  : std_logic;
	signal cd_comm      : std_logic_vector(95 downto 0) := (others => '0');
	signal cd_comm_send : std_logic := '0';
	signal cd_data      : std_logic_vector(7 downto 0);
	signal cd_data_wr   : std_logic;
	signal cd_data_end  : std_logic := '0';

	signal disc_mounted : std_logic := '0';

	signal sector_req        : std_logic;
	signal sector_lba        : std_logic_vector(23 downto 0);
	signal sector_data       : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_data_valid : std_logic := '0';
	signal sector_data_last  : std_logic := '0';

	signal sim_done  : boolean := false;
	signal errors    : integer := 0;

	-- REQUEST SENSE real reference data (verified against Mednafen, see cd_bridge.vhd)
	type sense_data_t is array (0 to 17) of std_logic_vector(7 downto 0);
	constant SENSE_NOT_READY : sense_data_t := (
		x"70", x"00", x"02", x"00", x"00", x"00", x"00", x"0A",
		x"00", x"00", x"00", x"00", x"0B", x"00", x"00", x"00", x"00", x"00"
	);
	constant SENSE_NO_SENSE : sense_data_t := (
		x"70", x"00", x"00", x"00", x"00", x"00", x"00", x"0A",
		x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"
	);

	procedure check_eq(signal errors : inout integer; got, want : std_logic_vector; msg : string) is
	begin
		if got /= want then
			report "FAIL: " & msg & " got=" & to_hstring(got) & " want=" & to_hstring(want) severity error;
			errors <= errors + 1;
		end if;
	end procedure;

begin

	clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

	dut: entity work.cd_bridge
	port map (
		CLK               => clk,
		RST_N             => rst_n,
		CD_STAT           => cd_stat,
		CD_MSG            => cd_msg,
		CD_STAT_GET       => cd_stat_get,
		CD_COMM           => cd_comm,
		CD_COMM_SEND      => cd_comm_send,
		CD_DATA           => cd_data,
		CD_DATA_WR        => cd_data_wr,
		CD_DATA_END       => cd_data_end,
		DISC_MOUNTED      => disc_mounted,
		SECTOR_REQ        => sector_req,
		SECTOR_LBA        => sector_lba,
		SECTOR_DATA       => sector_data,
		SECTOR_DATA_VALID => sector_data_valid,
		SECTOR_DATA_LAST  => sector_data_last
	);

	-- Synthetic sector source: on SECTOR_REQ, streams 2048 bytes one per CLK (no gap
	-- needed on this side -- the bridge itself paces its own one-idle-cycle-per-byte
	-- consumption via SCSI_READ_WAIT_BYTE, so a byte offered every cycle is safe; the
	-- bridge simply won't sample it every cycle).
	sector_source: process
		variable byte_idx : integer range 0 to 2047;
	begin
		loop
			sector_data_valid <= '0';
			sector_data_last  <= '0';
			wait until rising_edge(clk) and sector_req = '1';
			for byte_idx in 0 to 2047 loop
				wait until rising_edge(clk);
				sector_data <= std_logic_vector(unsigned(sector_lba(7 downto 0)) xor to_unsigned(byte_idx mod 256, 8));
				sector_data_valid <= '1';
				if byte_idx = 2047 then
					sector_data_last <= '1';
				end if;
				wait until rising_edge(clk);
				sector_data_valid <= '0';
				sector_data_last  <= '0';
				-- one real idle cycle, mirrors the bridge's own SCSI_READ_GAP pacing
				wait until rising_edge(clk);
			end loop;
		end loop;
	end process;

	-- CD_DATA_END real behavior, from SCSI.vhd's donor source: pulses once the DATA-IN
	-- FIFO has been fully drained by the CPU side. This testbench doesn't model the FIFO
	-- itself (out of scope -- SCSI_FIFO is donor RTL, real, unmodified); instead it fires
	-- CD_DATA_END a fixed number of cycles after the last CD_DATA_WR pulse it observes,
	-- long enough that the bridge's own WAIT_END states are exercised for real.
	data_end_driver: process
		variable last_wr_seen : time := 0 ns;
	begin
		loop
			wait until rising_edge(clk);
			cd_data_end <= '0';
			if cd_data_wr = '1' then
				for i in 1 to 20 loop
					wait until rising_edge(clk);
				end loop;
				cd_data_end <= '1';
			end if;
		end loop;
	end process;

	stimulus: process
		variable rx_count : integer;
		variable exp_byte  : std_logic_vector(7 downto 0);
	begin
		wait for CLK_PERIOD * 4;
		rst_n <= '1';
		wait until rising_edge(clk);

		-- 1. REQUEST SENSE, no disc
		disc_mounted <= '0';
		cd_comm(7 downto 0) <= x"03";
		cd_comm_send <= '1';
		wait until rising_edge(clk);
		cd_comm_send <= '0';

		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, SENSE_NOT_READY(i), "REQUEST SENSE (no disc) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "REQUEST SENSE (no disc) final status");
		wait for CLK_PERIOD * 4;

		-- 2. TEST UNIT READY, no disc -> CHECK CONDITION
		cd_comm(7 downto 0) <= x"00";
		cd_comm_send <= '1';
		wait until rising_edge(clk);
		cd_comm_send <= '0';
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"02", "TEST UNIT READY (no disc) status");
		wait for CLK_PERIOD * 4;

		-- 3. TEST UNIT READY, disc mounted -> GOOD
		disc_mounted <= '1';
		cd_comm(7 downto 0) <= x"00";
		cd_comm_send <= '1';
		wait until rising_edge(clk);
		cd_comm_send <= '0';
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "TEST UNIT READY (mounted) status");
		wait for CLK_PERIOD * 4;

		-- 4. READ(6), sa=0x001000, sc=2
		cd_comm(7 downto 0)   <= x"08";               -- opcode
		cd_comm(12 downto 8)  <= "00000";              -- CDB[1][4:0] = sa[20:16]
		cd_comm(23 downto 16) <= x"10";                -- CDB[2] = sa[15:8]
		cd_comm(31 downto 24) <= x"00";                -- CDB[3] = sa[7:0]  => sa = 0x001000
		cd_comm(39 downto 32) <= x"02";                -- CDB[4] = sc = 2
		cd_comm_send <= '1';
		wait until rising_edge(clk);
		cd_comm_send <= '0';

		rx_count := 0;
		while rx_count < 4096 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			if rx_count < 2048 then
				exp_byte := std_logic_vector(to_unsigned(16#00#, 8) xor to_unsigned(rx_count mod 256, 8));
			else
				exp_byte := std_logic_vector(to_unsigned(16#01#, 8) xor to_unsigned((rx_count - 2048) mod 256, 8));
			end if;
			check_eq(errors, cd_data, exp_byte, "READ(6) byte " & integer'image(rx_count));
			rx_count := rx_count + 1;
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "READ(6) final status");
		wait for CLK_PERIOD * 4;

		-- 5. REQUEST SENSE, disc mounted, nothing pending -> real NO SENSE
		cd_comm(7 downto 0) <= x"03";
		cd_comm_send <= '1';
		wait until rising_edge(clk);
		cd_comm_send <= '0';
		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, SENSE_NO_SENSE(i), "REQUEST SENSE (mounted) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "REQUEST SENSE (mounted) final status");

		wait for CLK_PERIOD * 4;

		if errors = 0 then
			report "PASS: all cd_bridge checks passed";
		else
			report "FAIL: " & integer'image(errors) & " check(s) failed" severity error;
		end if;
		sim_done <= true;
		wait for CLK_PERIOD;
		std.env.stop;
	end process;

end architecture;
