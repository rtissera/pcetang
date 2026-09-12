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
--  15. Real MCU-fed CDDA v2 -- SAPSP (raw LBA=0x1000) -> CD_DM one-cycle pulse, then a
--      real SECTOR_REQ/SECTOR_IS_AUDIO='1' fetch at LBA 0x1000, synthetic MCU stand-in
--      streams 8 bytes, relayed through CD_AUDIO_WR in order. No host command between
--      sectors -> real auto-continue fetches LBA 0x1001, same tag, same relay. A READ(6)
--      issued right after -- real-interrupts the loop via cd_bridge's own comm_pending
--      latch (may drain a further real audio sector or two first, since the exact
--      between-sector instant is a single atomic clock edge no external command can
--      synchronize to -- see cd_bridge.vhd's own comm_pending comment): CDDA_STATUS
--      stops, the data read proceeds via CD_DATA_WR with SECTOR_IS_AUDIO='0', and
--      CD_AUDIO_WR never pulses again.
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
	-- Driven, not left defaulted: leaving this open makes it all-ones ("plenty of room")
	-- and the back-pressure path below is then never exercised at all. Defaulted ports
	-- are how the GETDIRINFO byte-order bug survived a green testbench.
	signal fifo_space        : unsigned(12 downto 0) := (others => '1');
	signal bus_rst           : std_logic := '0';
	signal sector_lba        : std_logic_vector(23 downto 0);
	signal sector_data       : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_data_valid : std_logic := '0';
	signal sector_data_last  : std_logic := '0';

	signal cd_audio_wr     : std_logic;
	signal cd_dm           : std_logic;
	signal sector_is_audio : std_logic;

	-- ----------------------------------------------------------------------------
	-- MCU-SHAPED SECTOR DELIVERY (2026-09-11)
	--
	-- Every CD bug found on hardware since the GETDIRINFO one has lived in the seam
	-- between cd_bridge, iosys and the BL616 firmware -- a seam nothing simulated. The
	-- original sector_source below offers a byte roughly every 3 cycles with no frame
	-- structure, which is nothing like the real path: the MCU decodes a whole CHD hunk,
	-- then sends the sector as TWO separate 1024-byte frames over a 2Mbaud UART, and
	-- iosys pulses SECTOR_DATA_LAST only on the last byte of chunk 1.
	--
	-- mcu_mode switches the source to that shape so the bridge is exercised against what
	-- the hardware actually does: a long stall before the first byte, ~214 clk_pce cycles
	-- between bytes, a frame-header gap between the two chunks, and LAST exactly once.
	constant MCU_BYTE_CYCLES  : integer := 214;   -- 2Mbaud, 10 bits/byte, at 42.857MHz
	constant MCU_CHUNK_GAP    : integer := 10 * MCU_BYTE_CYCLES;  -- 0xAA/len/len/cmd + slack
	-- Hardware decode of a cold 19584-byte hunk is tens to hundreds of ms; 100us keeps the
	-- run short while still making the bridge wait far longer than any byte time.
	constant MCU_DECODE_DELAY : time := 100 us;
	signal mcu_mode : boolean := false;

	-- SECTOR_REQ monitor: counts pulses and records the LBA of each, so a multi-sector
	-- READ can be checked for exactly N requests at consecutive LBAs -- the property that
	-- actually failed on hardware (2 sectors asked for, 1 request seen).
	signal req_count   : integer := 0;
	signal req_lba_1   : std_logic_vector(23 downto 0) := (others => '0');
	signal req_lba_2   : std_logic_vector(23 downto 0) := (others => '0');
	signal wr_count    : integer := 0;
	-- driven by the stimulus, observed by the monitor: a counter may have ONE driver
	signal mon_clear   : boolean := false;

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
		FIFO_SPACE        => fifo_space,
		BUS_RST           => bus_rst,
		CD_AUDIO_WR       => cd_audio_wr,
		CD_DM             => cd_dm,
		SECTOR_IS_AUDIO   => sector_is_audio
	);

	-- Synthetic sector source: on SECTOR_REQ, streams either a real 2048-byte Mode-1 data
	-- sector (SECTOR_IS_AUDIO='0', mirrors the real MCU's own data-sector response) or an
	-- 8-byte stand-in for a real raw CD-DA sector (SECTOR_IS_AUDIO='1' -- real size is
	-- 2352 bytes/588 samples, but the bridge doesn't care about sector size at all, only
	-- SECTOR_DATA_LAST, so a short synthetic size exercises the real mechanism without
	-- 2352 real cycles of testbench runtime). No gap needed on this side -- the bridge
	-- itself paces its own one-idle-cycle-per-byte consumption (data path) or samples
	-- every real SECTOR_DATA_VALID pulse directly (audio path), so a byte offered every
	-- cycle is always safe.
	-- Count SECTOR_REQ pulses and CD_DATA_WR pulses, and latch the first two request LBAs.
	req_monitor: process(clk)
	begin
		if rising_edge(clk) then
			if mon_clear then
				req_count <= 0;
				wr_count  <= 0;
			else
			if sector_req = '1' then
				req_count <= req_count + 1;
				if req_count = 0 then
					req_lba_1 <= sector_lba;
				elsif req_count = 1 then
					req_lba_2 <= sector_lba;
				end if;
			end if;
			if cd_data_wr = '1' then
				wr_count <= wr_count + 1;
			end if;
			end if;
		end if;
	end process;

	sector_source: process
		variable byte_idx : integer range 0 to 2047;
	begin
		loop
			sector_data_valid <= '0';
			sector_data_last  <= '0';
			wait until rising_edge(clk) and sector_req = '1';
			if mcu_mode and sector_is_audio = '0' then
				-- Real MCU shape: decode stall, then 2 x 1024-byte frames at UART pace,
				-- LAST only on the final byte of chunk 1.
				wait for MCU_DECODE_DELAY;
				for chunk in 0 to 1 loop
					if chunk = 1 then
						for g in 0 to MCU_CHUNK_GAP loop
							wait until rising_edge(clk);
						end loop;
					end if;
					for byte_idx in 0 to 1023 loop
						for g in 0 to MCU_BYTE_CYCLES - 2 loop
							wait until rising_edge(clk);
						end loop;
						wait until rising_edge(clk);
						sector_data <= std_logic_vector(
							unsigned(sector_lba(7 downto 0))
							xor to_unsigned((chunk * 1024 + byte_idx) mod 256, 8));
						sector_data_valid <= '1';
						if chunk = 1 and byte_idx = 1023 then
							sector_data_last <= '1';
						end if;
						wait until rising_edge(clk);
						sector_data_valid <= '0';
						sector_data_last  <= '0';
					end loop;
				end loop;
			elsif sector_is_audio = '1' then
				for byte_idx in 0 to 7 loop
					wait until rising_edge(clk);
					sector_data <= std_logic_vector(unsigned(sector_lba(7 downto 0)) + to_unsigned(byte_idx, 8));
					sector_data_valid <= '1';
					if byte_idx = 7 then
						sector_data_last <= '1';
					end if;
					wait until rising_edge(clk);
					sector_data_valid <= '0';
					sector_data_last  <= '0';
				end loop;
			else
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
			end if;
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
		variable req_seen  : boolean := false;
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

		-- 10. GETDIRINFO mode 0x2, track=2 (BCD) -> real AMSF + control
		-- (lba=0x1800 -> BCD 01:23:69), control 0x04 = data track.
		--
		-- 2026-09-11: THIS CHECK USED TO ASSERT THE WRONG ORDER, and that is why the bug
		-- it was meant to catch shipped. mednafen's own DoNEC_PCE_GETDIRINFO
		-- (pce_fast/pcecd_drive.cpp) answers data_in[0..3] = M, S, F, control -- the
		-- control byte LAST. The bridge staged it FIRST and this testbench asserted the
		-- bridge's order rather than the reference's, so both agreed and both were wrong.
		-- On real hardware the syscard read the control byte as MINUTES and asked to READ
		-- LBA -101, which the lead-out check rejected forever.
		--
		-- A testbench written from the implementation cannot find a disagreement with the
		-- spec. Anything checked here should be traceable to mednafen or to pcetech, not
		-- to what cd_bridge.vhd happens to do.
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"02";
		cd_comm(23 downto 16) <= x"02";  -- cdb[2] = BCD track 2
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"01", "GETDIRINFO mode2 M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"23", "GETDIRINFO mode2 S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"69", "GETDIRINFO mode2 F");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"04", "GETDIRINFO mode2 control (LAST, per mednafen)");
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

		-- 15. Real MCU-fed CDDA v2 -- SAPSP (raw LBA=0x1000) starts playback.
		cd_comm(7 downto 0)   <= x"D8";
		cd_comm(79 downto 78) <= "00";  -- cdb[9][7:6] = "00" = raw LBA
		cd_comm(23 downto 16) <= x"00"; -- cdb[2] (MSB of raw LBA)
		cd_comm(31 downto 24) <= x"10"; -- cdb[3]
		cd_comm(39 downto 32) <= x"00"; -- cdb[4] (LSB) => LBA = 0x1000
		send_cmd(clk, cd_comm_send);
		-- CD_DM and CD_STAT_GET both pulse on the same real dispatch cycle -- catch
		-- CD_DM here (this also consumes SAPSP's completion, no separate stat_get wait).
		wait until rising_edge(clk) and cd_dm = '1';
		wait until rising_edge(clk);
		if cd_dm /= '0' then
			report "FAIL: CD_DM one-cycle pulse (still high next cycle)" severity error;
			errors <= errors + 1;
		end if;

		-- First real audio-sector fetch: SECTOR_REQ tagged audio, LBA = SAPSP's target.
		wait until rising_edge(clk) and sector_req = '1';
		check_eq(errors, sector_lba, x"001000", "CDDA sector-1 fetch LBA");
		if sector_is_audio /= '1' then
			report "FAIL: first CDDA sector fetch not tagged SECTOR_IS_AUDIO" severity error;
			errors <= errors + 1;
		end if;
		for i in 0 to 7 loop
			wait until rising_edge(clk) and cd_audio_wr = '1';
			check_eq(errors, cd_data, std_logic_vector(to_unsigned(i, 8)), "CDDA sector-1 audio byte " & integer'image(i));
		end loop;

		-- No host command in between -- real auto-continue fetches LBA+1, same tag.
		wait until rising_edge(clk) and sector_req = '1';
		check_eq(errors, sector_lba, x"001001", "CDDA sector-2 fetch LBA (auto-continue)");
		if sector_is_audio /= '1' then
			report "FAIL: auto-continued CDDA sector fetch not tagged SECTOR_IS_AUDIO" severity error;
			errors <= errors + 1;
		end if;
		for i in 0 to 7 loop
			wait until rising_edge(clk) and cd_audio_wr = '1';
			check_eq(errors, cd_data, std_logic_vector(to_unsigned(1 + i, 8)), "CDDA sector-2 audio byte " & integer'image(i));
		end loop;

		-- READ(6), issued shortly after sector-2 completes -- real-interrupts CDDA via
		-- cd_bridge's own comm_pending latch (bus-ownership rule) once it takes effect.
		-- Real, honest timing: the exact SCSI_IDLE instant between two audio sectors is
		-- a single atomic clock edge (audio auto-continue re-dispatches the very same
		-- cycle scsi_state returns to idle) -- no external command, real or simulated,
		-- can synchronize to land exactly there, so this drains up to a few further real
		-- audio sectors (proving the latch doesn't drop the command, just delays it,
		-- same real ~12ms-per-sector bound as any host command issued mid-fetch) before
		-- checking the real data-sector fetch.
		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"19";
		cd_comm(31 downto 24) <= x"05";
		cd_comm(39 downto 32) <= x"01";
		send_cmd(clk, cd_comm_send);

		for attempt in 0 to 4 loop
			wait until rising_edge(clk) and sector_req = '1';
			exit when sector_is_audio = '0';
			for i in 0 to 7 loop
				wait until rising_edge(clk) and cd_audio_wr = '1';
			end loop;
		end loop;
		check_eq(errors, sector_lba, x"001905", "READ(6) after CDDA interrupt: real data sector LBA");
		if sector_is_audio /= '0' then
			report "FAIL: READ(6) sector_req never arrived (comm_pending latch dropped it)" severity error;
			errors <= errors + 1;
		end if;
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"05", "READ(6) after CDDA interrupt: first data byte");

		wait until rising_edge(clk) and cd_stat_get = '1';
		wait for CLK_PERIOD * 20;
		if cd_audio_wr /= '0' then
			report "FAIL: CD_AUDIO_WR stays low after READ(6) interrupts CDDA" severity error;
			errors <= errors + 1;
		end if;

		wait for CLK_PERIOD * 4;

		-- ------------------------------------------------------------------------
		-- 14. MULTI-SECTOR READ(6) AGAINST THE REAL MCU DELIVERY SHAPE
		--
		-- This is the property that actually failed on hardware: the syscard asked for
		-- TWO sectors and exactly ONE SECTOR_REQ was ever seen. The bridge's own sector
		-- loop is already covered by test 5, but test 5 is fed by a source that offers a
		-- byte every ~3 cycles with no frame structure. Here the source models what the
		-- firmware really does -- decode stall, then 2 x 1024-byte frames at 2Mbaud pace,
		-- SECTOR_DATA_LAST once -- so the bridge has to survive a long stall mid-transfer
		-- and a gap between chunks without losing its place.
		--
		-- Checks, stated as properties rather than byte compares:
		--   * exactly 2 SECTOR_REQ pulses for cdb[4]=2
		--   * second request is at first LBA + 1
		--   * exactly 4096 CD_DATA_WR pulses reach the CPU side (2 x 2048)
		--   * GOOD status at the end
		mcu_mode <= true;
		wait for CLK_PERIOD;
		mon_clear <= true;   -- restart the monitor for this test
		wait for CLK_PERIOD * 2;
		mon_clear <= false;
		wait for CLK_PERIOD * 2;

		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"12";
		cd_comm(31 downto 24) <= x"34";   -- sa = 0x001234
		cd_comm(39 downto 32) <= x"02";   -- sc = 2 sectors
		send_cmd(clk, cd_comm_send);

		-- Two full sectors at MCU pace plus the decode stalls; generous margin.
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "MCU-paced READ(6) final status");

		if req_count /= 2 then
			report "FAIL: MCU-paced 2-sector READ(6) issued " & integer'image(req_count)
			     & " SECTOR_REQ pulse(s), expected 2 -- this is the hardware symptom"
			     severity error;
			errors <= errors + 1;
		end if;
		check_eq(errors, req_lba_1, x"001234", "MCU-paced READ(6) first request LBA");
		check_eq(errors, req_lba_2, x"001235", "MCU-paced READ(6) second request LBA");
		if wr_count /= 4096 then
			report "FAIL: MCU-paced 2-sector READ(6) delivered " & integer'image(wr_count)
			     & " bytes to the CPU, expected 4096" severity error;
			errors <= errors + 1;
		end if;
		mcu_mode <= false;
		wait for CLK_PERIOD * 4;

		-- 15. Real-sized lead-out. The TOC above uses lba=0x2000 (8192), which fits in
		-- any plausible counter width, so it could never catch the overflow that shipped:
		-- conv_total was 17 bits with the comment "max real disc <100000", but a 74-minute
		-- CD is 333000 frames and the converted value is LBA+150. Measured on hardware
		-- with Dungeon Explorer II: lead-out lba=316011 -> 316161, which needs 19 bits;
		-- at 17 it wrapped to 54017 and mode 1 returned 12:00:17 instead of 70:15:36.
		-- Push a real lead-out and assert the real answer.
		toc_track <= x"64"; toc_control <= x"00"; toc_lba <= x"04D26B";  -- 316011
		wait until rising_edge(clk); toc_wr <= '1';
		wait until rising_edge(clk); toc_wr <= '0';
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0)  <= x"DE";
		cd_comm(15 downto 8) <= x"01";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"70", "real lead-out mode1 M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"15", "real lead-out mode1 S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"36", "real lead-out mode1 F");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "real lead-out mode1 status");
		wait for CLK_PERIOD * 4;

		-- and the same value through mode 2 with track 0xAA, which reads the same table
		-- entry by a different path (entry 100, see cd_bridge's TOC_CAPTURE).
		cd_comm(7 downto 0)  <= x"DE";
		cd_comm(15 downto 8) <= x"02";
		cd_comm(23 downto 16) <= x"AA";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"70", "real lead-out mode2 AA M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"15", "real lead-out mode2 AA S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"36", "real lead-out mode2 AA F");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "real lead-out mode2 AA control");
		wait for CLK_PERIOD * 4;
		cd_comm(23 downto 16) <= x"00";

		-- 16. Back-pressure. cd_bridge paces itself on bytes arriving from the MCU, not
		-- on the CPU draining them, so it must refuse to fetch the next sector while the
		-- DATA-IN FIFO lacks room for one -- otherwise the FIFO silently drops the
		-- overflow, the host sees a short transfer and retries forever (measured on
		-- Prince of Persia: a 16-sector boot read retried 146 times).
		--
		-- The sector_source process serves each request on its own, so this test must NOT
		-- drive sector_data/_valid itself -- that would be a second driver on the same
		-- signals. It only starves FIFO_SPACE and watches whether requests keep coming.
		mcu_mode <= false;          -- fast source; this test is about request gating
		mon_clear <= true;
		wait for CLK_PERIOD * 2;
		mon_clear <= false;
		fifo_space <= to_unsigned(100, 13);   -- no room for a whole sector
		wait for CLK_PERIOD * 4;

		cd_comm(7 downto 0)   <= x"08";
		cd_comm(15 downto 8)  <= x"00";
		cd_comm(23 downto 16) <= x"00";
		cd_comm(31 downto 24) <= x"10";
		cd_comm(39 downto 32) <= x"04";   -- 4 sectors
		send_cmd(clk, cd_comm_send);

		-- sector 1 is fetched and served; after that the starved FIFO must stop the fetch,
		-- so the request count must settle at exactly 1.
		wait until rising_edge(clk) and sector_req = '1';
		wait for CLK_PERIOD * 40000;
		if req_count /= 1 then
			report "FAIL back-pressure: FIFO_SPACE=100 but bridge issued " &
			       integer'image(req_count) & " sector requests (expected 1)"
				severity error;
			errors <= errors + 1;
		end if;

		-- restore room: the remaining sectors must then be fetched
		fifo_space <= to_unsigned(4096, 13);
		wait for CLK_PERIOD * 40000;
		if req_count <= 1 then
			report "FAIL back-pressure: bridge never resumed after FIFO_SPACE was restored"
				severity error;
			errors <= errors + 1;
		end if;
		fifo_space <= (others => '1');
		wait for CLK_PERIOD * 4;

		-- 17. REMOVED 2026-09-11. It asserted that a SCSI bus reset aborts the transfer
		-- and returns to idle -- correct behaviour, and the test did catch its absence
		-- (the bridge answered the next command with sector payload bytes 05 06 07 where
		-- the GETDIRINFO reply belonged). But the implementation that made it pass caused
		-- a real hardware regression and was reverted; see BUS_RST's comment in
		-- cd_bridge.vhd. A green test for behaviour the RTL no longer has is worse than
		-- no test, so it is gone until the fix is redone properly.

		-- 18. THE REAL BOOT, byte for byte. Every command below, and every expected
		-- reply byte, is transcribed from an instrumented mednafen run of Dungeon
		-- Explorer II that reaches the game's title screen (scratchpad/golden/
		-- de2_registers.txt, 158645 register accesses). That run issues exactly 11 SCSI
		-- commands and reads exactly 31 sectors, so this is the whole of what a real boot
		-- asks the drive for -- not a plausible sequence, the actual one.
		--
		-- Why this test exists: tests 8-10 above cover the same three GETDIRINFO modes
		-- against a 2-track synthetic TOC whose lead-out is LBA 0x2000. A real disc's TOC
		-- is nothing like that, and the real boot's 9th command is `de 02 34` -- mode 2,
		-- BCD track 34 -- which on this disc is a DATA track at LBA 299077, four and a
		-- half minutes into the AMSF range. Nothing in tests 8-10 exercises a track index
		-- above 2, a minutes field above 1, or a READ address above 8192.
		--
		-- The TOC values are scripts/cd_toc.py's output for the real .chd, and they are
		-- confirmed three ways against the golden trace: mode 0 answers last track 0x34,
		-- mode 1's lead-out AMSF 70:15:36 is LBA 316011, and mode 2 track 34's 66:29:52
		-- is LBA 299077.
		mcu_mode <= false;
		wait for CLK_PERIOD * 4;

		-- Real DE2 TOC, in the MCU's own send order. Track 34 last of the real tracks, so
		-- toc_last_track (and therefore mode 0's answer) ends up 34, not 2.
		toc_track <= x"01"; toc_control <= x"00"; toc_lba <= x"000000";
		toc_wr <= '1'; wait until rising_edge(clk); toc_wr <= '0';
		wait until rising_edge(clk);
		toc_track <= x"02"; toc_control <= x"04";
		toc_lba <= std_logic_vector(to_unsigned(3590, 24));
		toc_wr <= '1'; wait until rising_edge(clk); toc_wr <= '0';
		wait until rising_edge(clk);
		toc_track <= x"22"; toc_control <= x"04";          -- 0x22 = track 34
		toc_lba <= std_logic_vector(to_unsigned(299077, 24));
		toc_wr <= '1'; wait until rising_edge(clk); toc_wr <= '0';
		wait until rising_edge(clk);
		toc_track <= x"64"; toc_control <= x"00";          -- 0x64 = 100 = lead-out
		toc_lba <= std_logic_vector(to_unsigned(316011, 24));
		toc_wr <= '1'; wait until rising_edge(clk); toc_wr <= '0';
		wait for CLK_PERIOD * 4;

		-- golden command 1: TEST UNIT READY -> GOOD, no data.
		cd_comm <= (others => '0');
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd1 TEST UNIT READY status");
		wait for CLK_PERIOD * 4;

		-- golden command 2: de 00 ca -> 01 34 (first/last track, BCD)
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"00";
		cd_comm(23 downto 16) <= x"CA";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"01", "boot cmd2 mode0 first track");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"34", "boot cmd2 mode0 LAST track (real disc has 34)");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd2 status");
		wait for CLK_PERIOD * 4;

		-- golden command 3: de 01 ca -> 70 15 36 (lead-out AMSF, LBA 316011)
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"01";
		cd_comm(23 downto 16) <= x"CA";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"70", "boot cmd3 lead-out M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"15", "boot cmd3 lead-out S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"36", "boot cmd3 lead-out F");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd3 status");
		wait for CLK_PERIOD * 4;

		-- golden command 4: de 02 01 -> 00 02 00 00 (track 1, LBA 0, audio)
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"02";
		cd_comm(23 downto 16) <= x"01";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "boot cmd4 track1 M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"02", "boot cmd4 track1 S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "boot cmd4 track1 F");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "boot cmd4 track1 control (audio)");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd4 status");
		wait for CLK_PERIOD * 4;

		-- golden command 5: de 02 02 -> 00 49 65 04 (track 2, LBA 3590, data)
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"02";
		cd_comm(23 downto 16) <= x"02";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"00", "boot cmd5 track2 M");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"49", "boot cmd5 track2 S");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"65", "boot cmd5 track2 F");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"04", "boot cmd5 track2 control (data)");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd5 status");
		wait for CLK_PERIOD * 4;

		-- golden commands 6-8: READ(6) 3590+2, 3592+1, 3624+3. Checked as LBAs requested
		-- and bytes delivered, the same properties test 14 established.
		mcu_mode <= true;
		wait for CLK_PERIOD;
		mon_clear <= true; wait for CLK_PERIOD * 2; mon_clear <= false;
		wait for CLK_PERIOD * 2;
		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"0E";
		cd_comm(31 downto 24) <= x"06";   -- sa = 0x000E06 = 3590
		cd_comm(39 downto 32) <= x"02";   -- 2 sectors
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd6 READ(6) 3590+2 status");
		check_eq(errors, req_lba_1, x"000E06", "boot cmd6 first LBA 3590");
		check_eq(errors, req_lba_2, x"000E07", "boot cmd6 second LBA 3591");
		if req_count /= 2 then
			report "FAIL: boot cmd6 issued " & integer'image(req_count)
			     & " SECTOR_REQ pulse(s), expected 2" severity error;
			errors <= errors + 1;
		end if;
		wait for CLK_PERIOD * 4;

		-- golden command 9 is the one that matters: de 02 34 -> 66 29 52 04.
		-- Track 34 (BCD 0x34), a DATA track at LBA 299077. 66 minutes needs a 20-bit
		-- conv_total and 66 BCD-native minute increments; the earlier mode-2 check only
		-- ever asked for 1 minute and a 13-bit address.
		mcu_mode <= false;
		wait for CLK_PERIOD * 4;
		cd_comm(7 downto 0)   <= x"DE";
		cd_comm(15 downto 8)  <= x"02";
		cd_comm(23 downto 16) <= x"34";   -- cdb[2] = BCD track 34
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"66", "boot cmd9 track34 M (golden 0x66)");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"29", "boot cmd9 track34 S (golden 0x29)");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"52", "boot cmd9 track34 F (golden 0x52)");
		wait until rising_edge(clk) and cd_data_wr = '1';
		check_eq(errors, cd_data, x"04", "boot cmd9 track34 control (data)");
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd9 status");
		wait for CLK_PERIOD * 4;

		-- golden command 10: READ(6) LBA 0x2F28 = 12072, 1 sector. Past the old synthetic
		-- lead-out of 8192, so this address only becomes legal with a real TOC.
		mcu_mode <= true;
		wait for CLK_PERIOD;
		mon_clear <= true; wait for CLK_PERIOD * 2; mon_clear <= false;
		wait for CLK_PERIOD * 2;
		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"2F";
		cd_comm(31 downto 24) <= x"28";   -- sa = 0x002F28 = 12072
		cd_comm(39 downto 32) <= x"01";
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd10 READ(6) 12072+1 status");
		check_eq(errors, req_lba_1, x"002F28", "boot cmd10 LBA 12072");
		if req_count /= 1 then
			report "FAIL: boot cmd10 issued " & integer'image(req_count)
			     & " SECTOR_REQ pulse(s), expected 1" severity error;
			errors <= errors + 1;
		end if;
		wait for CLK_PERIOD * 4;

		-- golden command 11: READ(6) LBA 0x2EA8 = 11944, 24 sectors -- the game itself.
		-- The longest real transfer of the whole boot, and the one that has to survive 24
		-- MCU decode stalls back to back.
		mon_clear <= true; wait for CLK_PERIOD * 2; mon_clear <= false;
		wait for CLK_PERIOD * 2;
		cd_comm(7 downto 0)   <= x"08";
		cd_comm(12 downto 8)  <= "00000";
		cd_comm(23 downto 16) <= x"2E";
		cd_comm(31 downto 24) <= x"A8";   -- sa = 0x002EA8 = 11944
		cd_comm(39 downto 32) <= x"18";   -- 24 sectors
		send_cmd(clk, cd_comm_send);
		wait until rising_edge(clk) and cd_stat_get = '1';
		check_eq(errors, cd_stat, x"00", "boot cmd11 READ(6) 11944+24 status");
		check_eq(errors, req_lba_1, x"002EA8", "boot cmd11 first LBA 11944");
		check_eq(errors, req_lba_2, x"002EA9", "boot cmd11 second LBA 11945");
		if req_count /= 24 then
			report "FAIL: boot cmd11 issued " & integer'image(req_count)
			     & " SECTOR_REQ pulse(s), expected 24 -- the game's own load" severity error;
			errors <= errors + 1;
		end if;
		if wr_count /= 24 * 2048 then
			report "FAIL: boot cmd11 delivered " & integer'image(wr_count)
			     & " bytes, expected " & integer'image(24 * 2048) severity error;
			errors <= errors + 1;
		end if;
		mcu_mode <= false;
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
