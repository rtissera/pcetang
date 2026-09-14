-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- END-OF-COMMAND phase walk for a MULTI-SECTOR READ(6).
--
-- WHY THIS EXISTS. Two testbenches already cover this area and neither can see the seam
-- between them: tb_cd_bridge.vhd instantiates cd_bridge with a stubbed SCSI side ("real,
-- and out of scope here"), and tb_scsi_phase.vhd instantiates SCSI.vhd with a stubbed
-- bridge. The suspected defect lives exactly in the handshake BETWEEN them, so it is
-- structurally invisible to both.
--
-- THE PROPERTY UNDER TEST. After the last byte of the last sector of a READ(6), a real
-- drive walks DATA IN -> STATUS -> MESSAGE IN -> BUS FREE, and only then will the system
-- card issue another command. An instrumented mednafen boot of Rondo shows exactly that:
--
--     c8 / 88   DATA IN with / without REQ      (~1560 polls of 88 between sectors)
--     d8        STATUS + REQ,  status byte 00 = GOOD
--     f8        MESSAGE IN + REQ, message 00 = COMMAND COMPLETE
--     00        BUS FREE, then the next command
--
-- THE SUSPECTED DEFECT. CD_DATA_END is a ONE-CYCLE PULSE WITH NO HANDSHAKE. SCSI.vhd
-- fires it in SP_DATAIN_END whenever the FIFO is empty at a sector boundary -- including
-- NON-FINAL boundaries mid-command, which is the normal state, because sectors arrive
-- from the MCU ~10 ms apart while the CPU drains 2048 bytes far faster. Only three
-- cd_bridge states listen for it (SCSI_READ_WAIT_END, SCSI_DATA_WAIT_END,
-- SCSI_SENSE_WAIT_END); in every other state the pulse is silently discarded. If the
-- pulse at the TRUE final boundary is ever lost, cd_bridge stays in SCSI_READ_WAIT_END
-- forever, STAT_GET never fires, no STATUS phase is entered, and the system card times
-- out and resets the SCSI bus -- which is precisely what the board does.
--
-- Whether that race can actually be lost depends on the relative timing of the CPU
-- draining the FIFO and cd_bridge writing the next sector, so BOTH are parameterised and
-- swept rather than assumed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cd_endcmd is
	generic (
		-- Sectors in the READ(6). The board's failing command is 8; golden also uses
		-- 10 and 12, and 1 is the degenerate case.
		SECTORS        : integer := 8;
		-- MCU turnaround before the FIRST byte of each sector, microseconds. The real
		-- link is ~10 ms/sector at 2 Mbaud.
		SECTOR_LAT_US  : integer := 10000;
		-- clk cycles between bytes the MCU streams into the bridge. 214 = real 2 Mbaud.
		FEED_CYCLES    : integer := 214;
		-- clk cycles between successive CPU reads of $1808. The HuC6280 reads roughly
		-- one byte per microsecond, i.e. ~43 cycles at 42.9 MHz.
		CPU_CYCLES     : integer := 43;
		-- The real MCU's per-sector latency is NOT uniform. Serving a sector whose data
		-- is in an already-decompressed CHD hunk is fast; one that needs a fresh hunk
		-- read plus decompression is far slower. The board's own log shows the ratio:
		-- "REQRING: 33 traced of 33 total ... hunk_reads=5", i.e. roughly one sector in
		-- six pays the long path. A race that survives uniform timing can still lose
		-- against that asymmetry, so it is modelled rather than averaged away.
		HUNK_EVERY     : integer := 0;        -- 0 = uniform (no slow sectors)
		HUNK_EXTRA_US  : integer := 0;        -- extra latency on those sectors
		VERBOSE        : integer := 0
	);
end entity;

architecture sim of tb_cd_endcmd is
	constant CLK_PERIOD : time := 23.3 ns;   -- 42.9 MHz, as cd.vhd is clocked

	signal clk     : std_logic := '0';
	signal reset_n : std_logic := '0';
	signal done    : boolean   := false;

	-- SCSI bus
	signal dbi, dbo          : std_logic_vector(7 downto 0) := (others => '0');
	signal sel_n, ack_n      : std_logic := '1';
	signal bsy_n, req_n      : std_logic;
	signal msg_n, cd_n, io_n : std_logic;

	-- bridge <-> SCSI target seam (named as cd.vhd maps them)
	signal cd_stat, cd_msg   : std_logic_vector(7 downto 0);
	signal cd_stat_get       : std_logic;
	signal cd_comm           : std_logic_vector(95 downto 0);
	signal cd_comm_send      : std_logic;
	signal cd_data           : std_logic_vector(7 downto 0);
	signal cd_data_wr        : std_logic;
	signal cd_data_end       : std_logic;
	signal stop_cd_snd       : std_logic;
	signal dout_req          : std_logic := '0';
	signal dout_s            : std_logic_vector(79 downto 0) := (others => '0');
	signal dout_send         : std_logic;

	-- MCU-side sector source
	signal sector_req        : std_logic;
	signal sector_lba        : std_logic_vector(23 downto 0);
	signal sector_data       : std_logic_vector(7 downto 0) := (others => '0');
	signal sector_data_valid : std_logic := '0';
	signal sector_data_last  : std_logic := '0';
	signal sector_is_audio   : std_logic;
	signal cd_audio_wr, cd_dm : std_logic;

	signal toc_wr      : std_logic := '0';
	signal toc_track   : std_logic_vector(7 downto 0)  := (others => '0');
	signal toc_control : std_logic_vector(7 downto 0)  := (others => '0');
	signal toc_lba     : std_logic_vector(23 downto 0) := (others => '0');
	signal disc_mounted : std_logic := '0';

	signal dbg_state   : std_logic_vector(4 downto 0);
	signal dbg_dend    : std_logic_vector(31 downto 0);
	signal dbg_datain_cnt : unsigned(15 downto 0);
	signal dbg_first8  : std_logic_vector(63 downto 0);
	signal dbg_sp      : std_logic_vector(3 downto 0);
	signal dbg_comm_pos : unsigned(3 downto 0);
	signal dbg_comm0, dbg_comm1 : std_logic_vector(7 downto 0);
	signal dbg_sel_cnt : unsigned(15 downto 0);
	signal dbg_fifo_space : unsigned(12 downto 0);
	signal dbg_fifo_drops : unsigned(15 downto 0);
	signal dbg_gdi     : std_logic_vector(127 downto 0);
	signal dbg_rd_total : unsigned(15 downto 0);
	signal dbg_underruns : unsigned(15 downto 0);

	-- exactly how cd.vhd composes what the CPU reads at $1800
	signal phase : std_logic_vector(7 downto 0);

	-- observations
	signal saw_d8, saw_f8, saw_busfree : boolean := false;
	signal bytes_read : integer := 0;

begin
	clk <= not clk after CLK_PERIOD/2 when not done else '0';
	phase <= (not bsy_n) & (not req_n) & (not msg_n) & (not cd_n) & (not io_n) & "000";

	scsi_inst : entity work.SCSI
	port map (
		RESET_N => reset_n, CLK => clk,
		DBI => dbi, DBO => dbo, SEL_N => sel_n, ACK_N => ack_n, RST_N => '1',
		BSY_N => bsy_n, REQ_N => req_n, MSG_N => msg_n, CD_N => cd_n, IO_N => io_n,
		STATUS => cd_stat, MESSAGE => cd_msg, STAT_GET => cd_stat_get,
		COMMAND => cd_comm, COMM_SEND => cd_comm_send,
		DOUT_REQ => dout_req, DOUT => dout_s, DOUT_SEND => dout_send,
		STOP_CD_SND => stop_cd_snd,
		CD_DATA => cd_data, CD_WR => cd_data_wr, CD_DATA_END => cd_data_end,
		DBG_DATAIN_CNT => dbg_datain_cnt, DBG_FIRST8 => dbg_first8, DBG_SP => dbg_sp,
		DBG_COMM_POS => dbg_comm_pos, DBG_COMM0 => dbg_comm0, DBG_COMM1 => dbg_comm1,
		DBG_SEL_CNT => dbg_sel_cnt, DBG_FIFO_SPACE => dbg_fifo_space,
		DBG_FIFO_DROPS => dbg_fifo_drops, DBG_GDI => dbg_gdi,
		DBG_RD_TOTAL => dbg_rd_total, DBG_UNDERRUNS => dbg_underruns
	);

	bridge_inst : entity work.cd_bridge
	port map (
		CLK => clk, RST_N => reset_n,
		CD_STAT => cd_stat, CD_MSG => cd_msg, CD_STAT_GET => cd_stat_get,
		CD_COMM => cd_comm, CD_COMM_SEND => cd_comm_send,
		CD_DATA => cd_data, CD_DATA_WR => cd_data_wr, CD_DATA_END => cd_data_end,
		DISC_MOUNTED => disc_mounted,
		TOC_WR => toc_wr, TOC_TRACK => toc_track, TOC_CONTROL => toc_control,
		TOC_LBA => toc_lba,
		SECTOR_REQ => sector_req, SECTOR_LBA => sector_lba,
		SECTOR_DATA => sector_data, SECTOR_DATA_VALID => sector_data_valid,
		SECTOR_DATA_LAST => sector_data_last,
		CD_AUDIO_WR => cd_audio_wr, CD_DM => cd_dm, SECTOR_IS_AUDIO => sector_is_audio,
		DBG_STATE => dbg_state, DBG_DEND => dbg_dend
	);

	-- MCU: answer each SECTOR_REQ after a real turnaround, then stream 2048 bytes at
	-- the real 2 Mbaud byte pace. Byte value encodes the sector so mis-ordering shows up.
	mcu : process
		variable sect  : integer := 0;
		variable nsect : integer := 0;
	begin
		sector_data_valid <= '0'; sector_data_last <= '0';
		wait until reset_n = '1';
		loop
			wait until rising_edge(clk) and sector_req = '1';
			sect := to_integer(unsigned(sector_lba));
			nsect := nsect + 1;
			if HUNK_EVERY > 0 and (nsect mod HUNK_EVERY) = 0 then
				wait for (SECTOR_LAT_US + HUNK_EXTRA_US) * 1 us / 1000;
			else
				wait for SECTOR_LAT_US * 1 us / 1000;
			end if;
			for i in 0 to 2047 loop
				for c in 1 to FEED_CYCLES loop wait until rising_edge(clk); end loop;
				sector_data <= std_logic_vector(to_unsigned((sect + i) mod 256, 8));
				sector_data_valid <= '1';
				if i = 2047 then sector_data_last <= '1'; end if;
				wait until rising_edge(clk);
				sector_data_valid <= '0'; sector_data_last <= '0';
			end loop;
		end loop;
	end process;

	-- CPU: select the target, send a READ(6), then behave like the HuC6280 -- poll $1800
	-- and ACK each DATA IN byte, then walk STATUS and MESSAGE IN with the manual ACK
	-- pulse the system card really uses ($1802 bit 7).
	cpu : process
		procedure tick(n : integer) is
		begin
			for i in 1 to n loop wait until rising_edge(clk); end loop;
		end procedure;
		variable guard : integer;
	begin
		wait until reset_n = '1';
		tick(10);
		-- mount a disc and give the bridge a lead-out far past what we read
		disc_mounted <= '1';
		toc_track <= x"01"; toc_control <= x"00"; toc_lba <= x"000000";
		toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(2);
		toc_track <= x"64"; toc_control <= x"00"; toc_lba <= x"010000";
		toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(4);

		-- SELECT
		sel_n <= '0'; tick(4); sel_n <= '1';
		-- COMMAND phase: READ(6) LBA 0x001000, SECTORS sectors
		for b in 0 to 5 loop
			guard := 0;
			while not (req_n = '0' and cd_n = '0' and io_n = '1') loop
				wait until rising_edge(clk); guard := guard + 1;
				assert guard < 5_000_000 report "TIMEOUT waiting for COMMAND REQ" severity failure;
			end loop;
			case b is
				when 0 => dbi <= x"08";
				when 1 => dbi <= x"00";
				when 2 => dbi <= x"10";
				when 3 => dbi <= x"00";
				when 4 => dbi <= std_logic_vector(to_unsigned(SECTORS, 8));
				when others => dbi <= x"00";
			end case;
			tick(1); ack_n <= '0';
			guard := 0;
			while req_n = '0' loop
				wait until rising_edge(clk); guard := guard + 1;
				assert guard < 5_000_000 report "TIMEOUT waiting for COMMAND REQ release" severity failure;
			end loop;
			ack_n <= '1'; tick(2);
		end loop;

		-- DATA IN: drain every byte the target offers, at CPU pace, until the target
		-- leaves DATA IN. This is the part that races cd_bridge's next-sector fetch.
		guard := 0;
		loop
			wait until rising_edge(clk);
			guard := guard + 1;
			assert guard < 200_000_000
				report "TIMEOUT in DATA IN -- target never left the data phase" severity failure;
			if req_n = '0' and cd_n = '1' and io_n = '0' and msg_n = '1' then
				-- DATA IN byte available
				tick(CPU_CYCLES);
				ack_n <= '0';
				while req_n = '0' loop wait until rising_edge(clk); end loop;
				ack_n <= '1';
				bytes_read <= bytes_read + 1;
			elsif req_n = '0' and cd_n = '0' and io_n = '0' and msg_n = '1' then
				exit;                                  -- STATUS phase reached
			end if;
		end loop;

		-- STATUS
		saw_d8 <= true;
		assert cd_stat = x"00" report "STATUS byte is not GOOD" severity error;
		tick(2); ack_n <= '0';
		while req_n = '0' loop wait until rising_edge(clk); end loop;
		ack_n <= '1';

		-- MESSAGE IN
		guard := 0;
		while not (req_n = '0' and msg_n = '0') loop
			wait until rising_edge(clk); guard := guard + 1;
			assert guard < 20_000_000 report "TIMEOUT waiting for MESSAGE IN" severity failure;
		end loop;
		saw_f8 <= true;
		tick(2); ack_n <= '0';
		while req_n = '0' loop wait until rising_edge(clk); end loop;
		ack_n <= '1';

		-- BUS FREE
		guard := 0;
		while bsy_n = '0' loop
			wait until rising_edge(clk); guard := guard + 1;
			assert guard < 20_000_000 report "TIMEOUT waiting for BUS FREE" severity failure;
		end loop;
		saw_busfree <= true;
		tick(20);

		report "RESULT SECTORS=" & integer'image(SECTORS)
		     & " bytes_read=" & integer'image(bytes_read)
		     & " dend_consumed=" & integer'image(to_integer(unsigned(dbg_dend(31 downto 16))))
		     & " dend_LOST=" & integer'image(to_integer(unsigned(dbg_dend(15 downto 0))))
		     & " underruns=" & integer'image(to_integer(dbg_underruns))
		     & " bridge_state=" & integer'image(to_integer(unsigned(dbg_state)));
		assert bytes_read = SECTORS * 2048
			report "WRONG BYTE COUNT: got " & integer'image(bytes_read)
			     & " expected " & integer'image(SECTORS * 2048) severity error;
		report "PASS: full end-of-command walk completed";
		done <= true;
		wait;
	end process;

	rst : process
	begin
		reset_n <= '0'; wait for 1 us; reset_n <= '1'; wait;
	end process;
end architecture;
