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
--   3. Real TOC load (2 tracks + lead-out), matching the real MCU-side ordering (TOC sent
--      before mount, see pcecd.cpp) -- track1 lba=0 control=0x00 (audio), track2
--      lba=0x1800 control=0x04 (data), lead-out(100) lba=0x2000.
--   4. TEST UNIT READY with DISC_MOUNTED='1' -> GOOD.
--   5. READ(6), sa=0x001000, sc=2 (2 sectors, within the real TOC lead-out) -> SECTOR_REQ
--      pulses at LBA 0x1000 then 0x1001, synthetic source streams a known byte pattern,
--      bridge relays exactly 4096 bytes (2x2048) through CD_DATA/CD_DATA_WR in the right
--      order, GOOD final status.
--   6. REQUEST SENSE with DISC_MOUNTED='1' and nothing pending -> real NO SENSE bytes.
--   7. Unrecognized opcode (0xFF) -> CHECK CONDITION; REQUEST SENSE -> real
--      ILLEGAL_REQUEST(0x5)/NSE_INVALID_COMMAND(0x20), not the old stale/NOT_READY-shaped
--      response.
--   8. GETDIRINFO mode 0x0 (first/last track) -> real BCD 0x01/0x02 from the loaded TOC.
--   9. GETDIRINFO mode 0x1 (lead-out AMSF) -> real BCD M/S/F computed from lba=0x2000.
--  10. GETDIRINFO mode 0x2, track=2 (BCD) -> real control byte (0x04) + BCD M/S/F from
--      lba=0x1800.
--  11. SAPSP (raw LBA=0x1000) -> CDDA_STATUS=PLAYING; READSUBQ -> real status byte + real
--      absolute AMSF derived from that LBA (relative fields are a named stand-in, see
--      cd_bridge.vhd's own header).
--  12. SAPEP (cdb[1]=0x00, stop) -> CDDA_STATUS=STOPPED; PAUSE while stopped -> CHECK
--      CONDITION; REQUEST SENSE -> real ILLEGAL_REQUEST(0x5)/NSE_AUDIO_NOT_PLAYING(0x2C).
--  13. SAPSP again (re-arm PLAYING) -> PAUSE while playing -> GOOD, CDDA_STATUS=PAUSED;
--      READSUBQ -> real status byte 0x02.
--  14. READ(6), sa=0x2001 (past the real TOC lead-out at 0x2000) -> CHECK CONDITION;
--      REQUEST SENSE -> real ILLEGAL_REQUEST(0x5)/NSE_INVALID_ADDRESS(0x21).
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

	signal toc_wr      : std_logic := '0';
	signal toc_track   : std_logic_vector(7 downto 0) := (others => '0');
	signal toc_control : std_logic_vector(7 downto 0) := (others => '0');
	signal toc_lba     : std_logic_vector(23 downto 0) := (others => '0');

	signal sector_req        : std_logic;
	signal sector_lba        : std_logic_vector(23 downto 0);
	signal sector_data       : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_data_valid : std_logic := '0';
	signal sector_data_last  : std_logic := '0';

	signal cd_audio_wr : std_logic;
	signal cd_dm       : std_logic;

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
	function make_sense(key : std_logic_vector(3 downto 0); asc : std_logic_vector(7 downto 0)) return sense_data_t is
		variable s : sense_data_t := (others => x"00");
	begin
		s(0) := x"70";
		s(2) := "0000" & key;
		s(7) := x"0A";
		s(12) := asc;
		return s;
	end function;

	procedure check_eq(signal errors : inout integer; got, want : std_logic_vector; msg : string) is
	begin
		if got /= want then
			report "FAIL: " & msg & " got=" & to_hstring(got) & " want=" & to_hstring(want) severity error;
			errors <= errors + 1;
		end if;
	end procedure;

	-- Real helper -- pulse CD_COMM_SEND for exactly one cycle with the given command bytes
	-- already staged on cd_comm; real SCSI initiator timing (rising-edge staged, one-cycle
	-- strobe), matches every inline command send this file used to repeat by hand.
	procedure send_cmd(signal clk : in std_logic; signal cd_comm_send : out std_logic) is
	begin
		cd_comm_send <= '1';
		wait until rising_edge(clk);
		cd_comm_send <= '0';
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
		TOC_WR            => toc_wr,
		TOC_TRACK         => toc_track,
		TOC_CONTROL       => toc_control,
		TOC_LBA           => toc_lba,
		SECTOR_REQ        => sector_req,
		SECTOR_LBA        => sector_lba,
		SECTOR_DATA       => sector_data,
		SECTOR_DATA_VALID => sector_data_valid,
		SECTOR_DATA_LAST  => sector_data_last,
		CD_AUDIO_WR       => cd_audio_wr,
		CD_DM             => cd_dm
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
		variable sense_exp : sense_data_t;
	begin
		wait for CLK_PERIOD * 4;
		rst_n <= '1';
		wait until rising_edge(clk);

		-- 1. REQUEST SENSE, no disc
		disc_mounted <= '0';
		cd_comm(7 downto 0) <= x"03";
		send_cmd(clk, cd_comm_send);
		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, SENSE_NOT_READY(i), "REQUEST SENSE (no disc) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "REQUEST SENSE (no disc) final status");
		wait for CLK_PERIOD * 4;

		-- 2. TEST UNIT READY, no disc -> CHECK CONDITION
		cd_comm(7 downto 0) <= x"00";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"02", "TEST UNIT READY (no disc) status");
		wait for CLK_PERIOD * 4;

		-- 3. Real TOC load -- track1 (audio, lba=0), track2 (data, lba=0x1800), lead-out
		-- (100, lba=0x2000). Sent before DISC_MOUNTED goes high, matching the real MCU
		-- ordering (pcecd_read_toc() before pcecd_send_mount()).
		toc_track <= x"01"; toc_control <= x"00"; toc_lba <= x"000000";
		wait until rising_edge(clk); toc_wr <= '1';
		wait until rising_edge(clk); toc_wr <= '0';
		wait until rising_edge(clk);

		toc_track <= x"02"; toc_control <= x"04"; toc_lba <= x"001800";
		wait until rising_edge(clk); toc_wr <= '1';
		wait until rising_edge(clk); toc_wr <= '0';
		wait until rising_edge(clk);

		toc_track <= x"64"; toc_control <= x"00"; toc_lba <= x"002000";  -- 100 = lead-out
		wait until rising_edge(clk); toc_wr <= '1';
		wait until rising_edge(clk); toc_wr <= '0';
		wait for CLK_PERIOD * 4;

		-- 4. TEST UNIT READY, disc mounted -> GOOD
		disc_mounted <= '1';
		cd_comm(7 downto 0) <= x"00";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "TEST UNIT READY (mounted) status");
		wait for CLK_PERIOD * 4;

		-- 5. READ(6), sa=0x001000, sc=2 (within the real TOC lead-out at 0x2000)
		cd_comm(7 downto 0)   <= x"08";               -- opcode
		cd_comm(12 downto 8)  <= "00000";              -- CDB[1][4:0] = sa[20:16]
		cd_comm(23 downto 16) <= x"10";                -- CDB[2] = sa[15:8]
		cd_comm(31 downto 24) <= x"00";                -- CDB[3] = sa[7:0]  => sa = 0x001000
		cd_comm(39 downto 32) <= x"02";                -- CDB[4] = sc = 2
		send_cmd(clk, cd_comm_send);

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

		-- 6. REQUEST SENSE, disc mounted, nothing pending -> real NO SENSE
		cd_comm(7 downto 0) <= x"03";
		send_cmd(clk, cd_comm_send);
		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, SENSE_NO_SENSE(i), "REQUEST SENSE (mounted) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "REQUEST SENSE (mounted) final status");
		wait for CLK_PERIOD * 4;

		-- 7. Unrecognized opcode (0xFF) -> CHECK CONDITION, then REQUEST SENSE ->
		-- real ILLEGAL_REQUEST(0x5)/NSE_INVALID_COMMAND(0x20)
		cd_comm(7 downto 0) <= x"FF";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"02", "unrecognized opcode status");
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"03";
		send_cmd(clk, cd_comm_send);
		sense_exp := make_sense("0101", x"20");  -- ILLEGAL_REQUEST/NSE_INVALID_COMMAND
		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, sense_exp(i), "REQUEST SENSE (bad opcode) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 4;

		-- 8. GETDIRINFO mode 0x0 -> real BCD first/last track (0x01/0x02)
		cd_comm(7 downto 0)  <= x"DE";
		cd_comm(15 downto 8) <= x"00";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"01", "GETDIRINFO mode0 first_track");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"02", "GETDIRINFO mode0 last_track");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "GETDIRINFO mode0 status");
		wait for CLK_PERIOD * 4;

		-- 9. GETDIRINFO mode 0x1 -> real lead-out AMSF (lba=0x2000 -> BCD 01:51:17)
		cd_comm(7 downto 0)  <= x"DE";
		cd_comm(15 downto 8) <= x"01";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"01", "GETDIRINFO mode1 M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"51", "GETDIRINFO mode1 S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"17", "GETDIRINFO mode1 F");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "GETDIRINFO mode1 status");
		wait for CLK_PERIOD * 4;

		-- 10. GETDIRINFO mode 0x2, track=2 (BCD) -> real control(0x04) + AMSF
		-- (lba=0x1800 -> BCD 01:23:69)
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"02";
		cd_comm(23 downto 16) <= x"02";  -- cdb[2] = BCD track 2
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"04", "GETDIRINFO mode2 control");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"01", "GETDIRINFO mode2 M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"23", "GETDIRINFO mode2 S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"69", "GETDIRINFO mode2 F");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "GETDIRINFO mode2 status");
		wait for CLK_PERIOD * 4;

		-- 11. SAPSP (raw LBA=0x1000) -> READSUBQ real status(PLAYING=0x00) + real absolute
		-- AMSF (BCD 00:56:46), relative fields are a named stand-in (all zero).
		cd_comm(7 downto 0)   <= x"D8";
		cd_comm(79 downto 78) <= "00";  -- cdb[9][7:6] = "00" = raw LBA
		cd_comm(23 downto 16) <= x"00";  -- cdb[2] (MSB of raw LBA)
		cd_comm(31 downto 24) <= x"10";  -- cdb[3]
		cd_comm(39 downto 32) <= x"00";  -- cdb[4] (LSB)  => LBA = 0x1000
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "SAPSP status");
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"DD";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "READSUBQ status byte (playing)");
		wait until rising_edge(clk) and cd_data_wr = '1';  -- track (stand-in)
		wait until rising_edge(clk) and cd_data_wr = '1';  -- index (stand-in)
		wait until rising_edge(clk) and cd_data_wr = '1';  -- rel M (stand-in)
		wait until rising_edge(clk) and cd_data_wr = '1';  -- rel S (stand-in)
		wait until rising_edge(clk) and cd_data_wr = '1';  -- rel F (stand-in)
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "READSUBQ abs M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"56", "READSUBQ abs S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"46", "READSUBQ abs F");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "READSUBQ status");
		wait for CLK_PERIOD * 4;

		-- 11b. SAPSP (BCD AMSF=01:30:25) -> READSUBQ real absolute AMSF round-trips back to
		-- 01:30:25. Real regression coverage for the "10" (BCD AMSF) addressing branch --
		-- this exact path hid a real EX4923 width-truncation bug (unsigned*4500 with a
		-- too-narrow operand) that GHDL didn't catch and gw_sh's real synthesis did.
		cd_comm(7 downto 0)   <= x"D8";
		cd_comm(79 downto 78) <= "10";  -- cdb[9][7:6] = "10" = BCD AMSF
		cd_comm(23 downto 16) <= x"01";  -- cdb[2] = BCD M
		cd_comm(31 downto 24) <= x"30";  -- cdb[3] = BCD S
		cd_comm(39 downto 32) <= x"25";  -- cdb[4] = BCD F
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "SAPSP (BCD AMSF) status");
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"DD";
		send_cmd(clk, cd_comm_send);
		for i in 1 to 6 loop
			wait until rising_edge(clk) and cd_data_wr = '1';  -- status/track/index/rel AMSF
		end loop;
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"01", "READSUBQ (BCD AMSF round-trip) abs M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"30", "READSUBQ (BCD AMSF round-trip) abs S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"25", "READSUBQ (BCD AMSF round-trip) abs F");
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 4;

		-- 12. SAPEP stop -> PAUSE while stopped -> real CHECK CONDITION +
		-- ILLEGAL_REQUEST(0x5)/NSE_AUDIO_NOT_PLAYING(0x2C)
		cd_comm(7 downto 0)  <= x"D9";
		cd_comm(15 downto 8) <= x"00";  -- cdb[1] = 0x00 = stop
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"DA";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"02", "PAUSE (stopped) status");
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"03";
		send_cmd(clk, cd_comm_send);
		sense_exp := make_sense("0101", x"2C");  -- ILLEGAL_REQUEST/NSE_AUDIO_NOT_PLAYING
		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, sense_exp(i), "REQUEST SENSE (pause-not-playing) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 4;

		-- 13. SAPSP again (re-arm PLAYING) -> PAUSE while playing -> real GOOD,
		-- READSUBQ -> real status byte 0x02 (PAUSED)
		cd_comm(7 downto 0)   <= x"D8";
		cd_comm(79 downto 78) <= "00";
		cd_comm(23 downto 16) <= x"00";
		cd_comm(31 downto 24) <= x"10";
		cd_comm(39 downto 32) <= x"00";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"DA";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "PAUSE (playing) status");
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"DD";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"02", "READSUBQ status byte (paused)");
		for i in 1 to 8 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 4;

		-- 14. READ(6), sa=0x002001 (past the real TOC lead-out at 0x2000) -> real CHECK
		-- CONDITION + ILLEGAL_REQUEST(0x5)/NSE_INVALID_ADDRESS(0x21)
		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"20";
		cd_comm(31 downto 24) <= x"01";  -- sa = 0x002001
		cd_comm(39 downto 32) <= x"01";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"02", "READ(6) out-of-range status");
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0) <= x"03";
		send_cmd(clk, cd_comm_send);
		sense_exp := make_sense("0101", x"21");  -- ILLEGAL_REQUEST/NSE_INVALID_ADDRESS
		for i in 0 to 17 loop
			wait until rising_edge(clk) and cd_data_wr = '1';
			check_eq(errors, cd_data, sense_exp(i), "REQUEST SENSE (read out-of-range) byte " & integer'image(i));
		end loop;
		wait until rising_edge(clk) and cd_stat_get = '1';

		wait for CLK_PERIOD * 4;

		-- 15. Real CDDA v1 tone write -- SAPSP (raw LBA) starts playback: CD_DM pulses
		-- exactly one cycle (real CD_BYTE_CNT re-arm), then the real byte-rate CE paces
		-- 4 real CD_AUDIO_WR pulses forming one sample: L lsb/msb, R lsb/msb, little-
		-- endian, L=R (mono tone), value = -8000 (tone_sign starts '0') = 0xE0C0.
		cd_comm(7 downto 0)   <= x"D8";
		cd_comm(79 downto 78) <= "00";
		cd_comm(23 downto 16) <= x"00";
		cd_comm(31 downto 24) <= x"00";
		cd_comm(39 downto 32) <= x"00";
		send_cmd(clk, cd_comm_send);
		-- CD_DM and CD_STAT_GET both pulse on the same real dispatch cycle -- catch
		-- CD_DM here (this also consumes SAPSP's completion, no separate stat_get wait).
		wait until rising_edge(clk) and cd_dm = '1';
		wait until rising_edge(clk);
		if cd_dm /= '0' then
			report "FAIL: CD_DM one-cycle pulse (still high next cycle)" severity error;
			errors <= errors + 1;
		end if;
		wait for CLK_PERIOD * 4;

		wait until rising_edge(clk) and cd_audio_wr = '1';
		check_eq(errors, cd_data, x"C0", "CDDA tone byte 0 (L lsb)");
		wait until rising_edge(clk) and cd_audio_wr = '1';
		check_eq(errors, cd_data, x"E0", "CDDA tone byte 1 (L msb)");
		wait until rising_edge(clk) and cd_audio_wr = '1';
		check_eq(errors, cd_data, x"C0", "CDDA tone byte 2 (R lsb)");
		wait until rising_edge(clk) and cd_audio_wr = '1';
		check_eq(errors, cd_data, x"E0", "CDDA tone byte 3 (R msb)");

		-- READ(6) during playback stops it -- real bus-ownership rule.
		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"10";
		cd_comm(31 downto 24) <= x"00";
		cd_comm(39 downto 32) <= x"01";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 20;  -- longer than one real CE period
		if cd_audio_wr /= '0' then
			report "FAIL: CD_AUDIO_WR stays low after READ(6) stops playback" severity error;
			errors <= errors + 1;
		end if;

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
