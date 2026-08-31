-- SPDX-License-Identifier: GPL-3.0-or-later

-- Real SCSI target for PCE-CD, shared across all 3 boards (2026-08-31).
--
-- Replaces the per-board "minimal SCSI target stub" (identical code duplicated in each
-- pcetang_<board>_cd.vhd -- REQUEST SENSE only, everything else CHECK CONDITION) with ONE
-- real module. Real command decode verified against Mednafen's pce_fast/pcecd_drive.cpp
-- (fetched/read directly this session, not assumed from generic SCSI-2):
--   TEST UNIT READY (0x00): GOOD if a disc is mounted, else CHECK CONDITION/NOT READY.
--   REQUEST SENSE   (0x03): unchanged from the prior stub -- real fixed-format sense data,
--                            NOT READY/NEC's own "no disc" ASC (0x0B) when unmounted, GOOD
--                            sense (all zero) when mounted (nothing pending to report).
--   READ(6)         (0x08): sa = (CDB[1][4:0]<<16)|(CDB[2]<<8)|CDB[3], sc = CDB[4] (0=>256),
--                            matches DoREAD6()/DoREADBase() exactly. Walks the sector
--                            interface below, one 2048-byte Mode-1 sector at a time, pushed
--                            byte-by-byte into SCSI.vhd's own DATA-IN FIFO via CD_DATA/
--                            CD_DATA_WR -- same real path REQUEST SENSE already used for its
--                            18 sense bytes, now sized for real sector traffic (see
--                            cd_fifos.vhd's SCSI_FIFO ADDR_W=11 widening, same commit).
--   Everything else (the 5 PCE audio/subcode ops 0xD8/D9/DA/DD/DE, and any unrecognized
--   opcode): still CHECK CONDITION, same blanket behavior as the prior stub. Real, named
--   gap, not hidden -- CDDA/audio-track playback needs its own real wiring on top of this
--   (see pcetang_cd_scsi_plan.md step 6), deliberately out of scope for this pass, which
--   targets the boot/data-read path (syscard3 + HuCard-equivalent game code on CD).
--
-- Sector source (SECTOR_*) is a real, deliberately generic req/byte-stream interface --
-- this module does not know or care whether the far side is a synthetic test source (this
-- session's own isolated gw_sh fit-check) or a real MCU-driven sector reader (the next
-- phase, per pcetang_cd_scsi_plan.md -- new UART command pair, not yet built). Leaving
-- SECTOR_DATA_VALID permanently '0' (its real default) reproduces the prior stub's exact
-- behavior for every command except READ(6), which would then simply never complete -- a
-- real, inert dead state until a real sector source is wired in, not a functional
-- regression (READ(6) already never worked against the old stub either).
-- SECTOR_DATA_LAST is real protocol surface for a future sector-source bridge (e.g. to
-- flag the final byte of a hunk-boundary chunk) -- this FSM tracks sector completion
-- itself via READ_BYTE_CT and does not consume it yet; kept as a port so a real bridge
-- module can drive it without an interface change later.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cd_bridge is
	port (
		CLK           : in  std_logic;
		RST_N         : in  std_logic;

		-- cd.vhd's SCSI target-side port group (same names/widths as SCSI.vhd's own ports)
		CD_STAT       : out std_logic_vector(7 downto 0);
		CD_MSG        : out std_logic_vector(7 downto 0);
		CD_STAT_GET   : out std_logic;
		CD_COMM       : in  std_logic_vector(95 downto 0);
		CD_COMM_SEND  : in  std_logic;
		CD_DATA       : out std_logic_vector(7 downto 0);
		CD_DATA_WR    : out std_logic;
		CD_DATA_END   : in  std_logic;

		-- Real mount state (2026-08-31: no real driver yet -- ties '0', preserving the
		-- prior stub's "no disc" behavior exactly until the MCU-side mount/TOC protocol
		-- lands, per pcetang_cd_scsi_plan.md).
		DISC_MOUNTED  : in  std_logic := '0';

		-- Real sector-fetch interface (bridge -> external sector source). LBA is 24 bits
		-- (16.7M sectors, ~35GB at 2048B/sector) -- real CD-ROM max is ~330K sectors
		-- (~675MB), so this is comfortably wide, not a guess.
		SECTOR_REQ        : out std_logic;
		SECTOR_LBA        : out std_logic_vector(23 downto 0);
		SECTOR_DATA       : in  std_logic_vector(7 downto 0) := (others => '0');
		SECTOR_DATA_VALID : in  std_logic := '0';   -- one pulse per byte, 2048 bytes/sector
		SECTOR_DATA_LAST  : in  std_logic := '0'    -- pulses together with the 2048th byte
	);
end entity;

architecture rtl of cd_bridge is

	constant SCSI_OP_TEST_UNIT_READY : std_logic_vector(7 downto 0) := x"00";
	constant SCSI_OP_READ6           : std_logic_vector(7 downto 0) := x"08";
	constant SCSI_OP_REQUEST_SENSE   : std_logic_vector(7 downto 0) := x"03";

	-- Verified against Mednafen's MakeSense()/NSE_NO_DISC (pce_fast/pcecd_drive.cpp) --
	-- see the prior per-board stub's own comment (now removed from the board files) for
	-- the full byte-by-byte trace. Unchanged here, just relocated.
	type sense_data_t is array (0 to 17) of std_logic_vector(7 downto 0);
	constant SENSE_NOT_READY : sense_data_t := (
		x"70", x"00", x"02", x"00", x"00", x"00", x"00", x"0A",
		x"00", x"00", x"00", x"00", x"0B", x"00", x"00", x"00", x"00", x"00"
	);
	-- GOOD sense (0x00 sense key, NO SENSE) -- returned by REQUEST SENSE when a disc is
	-- mounted and nothing else is pending. Same fixed format, byte 7 (additional sense
	-- length) still 0x0A, everything else that isn't a "why not ready" field is zero.
	constant SENSE_NO_SENSE : sense_data_t := (
		x"70", x"00", x"00", x"00", x"00", x"00", x"00", x"0A",
		x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"
	);

	type scsi_state_t is (
		SCSI_IDLE,
		SCSI_SENSE_PULSE, SCSI_SENSE_GAP, SCSI_SENSE_WAIT_END,
		SCSI_READ_REQ, SCSI_READ_WAIT_BYTE, SCSI_READ_GAP,
		SCSI_READ_NEXT_SECTOR, SCSI_READ_WAIT_END
	);
	signal scsi_state : scsi_state_t := SCSI_IDLE;
	signal sense_idx   : integer range 0 to 17 := 0;
	signal sense_src   : sense_data_t := SENSE_NOT_READY;

	signal cd_comm_send_r : std_logic := '0';

	-- READ(6) real working state
	signal read_lba     : unsigned(23 downto 0) := (others => '0');
	signal read_count   : unsigned(8 downto 0)  := (others => '0');  -- 0..256, needs 9 bits
	signal read_byte_ct : unsigned(11 downto 0) := (others => '0');  -- 0..2047

begin

	CD_COMM_SEND_EDGE : process (CLK, RST_N)
	begin
		if RST_N = '0' then
			cd_comm_send_r <= '0';
		elsif rising_edge(CLK) then
			cd_comm_send_r <= CD_COMM_SEND;
		end if;
	end process;

	SECTOR_LBA <= std_logic_vector(read_lba);

	process (CLK, RST_N)
		variable sa     : unsigned(23 downto 0);
		variable sa_vec : std_logic_vector(23 downto 0);
		variable sc     : unsigned(8 downto 0);
	begin
		if RST_N = '0' then
			scsi_state    <= SCSI_IDLE;
			CD_STAT       <= (others => '0');
			CD_MSG        <= (others => '0');
			CD_STAT_GET   <= '0';
			CD_DATA       <= (others => '0');
			CD_DATA_WR    <= '0';
			SECTOR_REQ    <= '0';
			sense_idx     <= 0;
			read_lba      <= (others => '0');
			read_count    <= (others => '0');
			read_byte_ct  <= (others => '0');
		elsif rising_edge(CLK) then
			CD_STAT_GET <= '0';
			CD_DATA_WR  <= '0';
			SECTOR_REQ  <= '0';

			case scsi_state is
				when SCSI_IDLE =>
					if CD_COMM_SEND = '1' and cd_comm_send_r = '0' then
						case CD_COMM(7 downto 0) is
							when SCSI_OP_REQUEST_SENSE =>
								sense_idx <= 0;
								if DISC_MOUNTED = '1' then
									sense_src <= SENSE_NO_SENSE;
								else
									sense_src <= SENSE_NOT_READY;
								end if;
								scsi_state <= SCSI_SENSE_PULSE;

							when SCSI_OP_TEST_UNIT_READY =>
								if DISC_MOUNTED = '1' then
									CD_STAT     <= x"00";  -- GOOD
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									CD_STAT     <= x"02";  -- CHECK CONDITION
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								end if;

							when SCSI_OP_READ6 =>
								if DISC_MOUNTED = '1' then
									-- sa = CDB[1][4:0] & CDB[2] & CDB[3], sc = CDB[4] (0 => 256)
									-- CDB[n] = CD_COMM(8*n+7 downto 8*n) -- see SCSI.vhd's own
									-- COMMAND<=COMM(11)&...&COMM(0) concatenation, verified above.
									sa_vec(23 downto 21) := "000";
									sa_vec(20 downto 16) := CD_COMM(12 downto 8);
									sa_vec(15 downto 8)  := CD_COMM(23 downto 16);
									sa_vec(7 downto 0)   := CD_COMM(31 downto 24);
									sa := unsigned(sa_vec);
									if CD_COMM(39 downto 32) = x"00" then
										sc := to_unsigned(256, 9);
									else
										sc := "0" & unsigned(CD_COMM(39 downto 32));
									end if;
									read_lba     <= sa;
									read_count   <= sc;
									read_byte_ct <= (others => '0');
									scsi_state   <= SCSI_READ_REQ;
								else
									sense_idx  <= 0;
									sense_src  <= SENSE_NOT_READY;
									CD_STAT    <= x"02";  -- CHECK CONDITION
									CD_MSG     <= x"00";
									CD_STAT_GET <= '1';
								end if;

							when others =>
								CD_STAT     <= x"02";  -- CHECK CONDITION
								CD_MSG      <= x"00";
								CD_STAT_GET <= '1';
						end case;
					end if;

				-- REQUEST SENSE: unchanged real timing from the prior per-board stub --
				-- one idle cycle between bytes (SCSI.vhd's own push logic edge-detects
				-- CD_DATA_WR, so back-to-back-high would only register once).
				when SCSI_SENSE_PULSE =>
					CD_DATA    <= sense_src(sense_idx);
					CD_DATA_WR <= '1';
					scsi_state <= SCSI_SENSE_GAP;

				when SCSI_SENSE_GAP =>
					if sense_idx = 17 then
						scsi_state <= SCSI_SENSE_WAIT_END;
					else
						sense_idx  <= sense_idx + 1;
						scsi_state <= SCSI_SENSE_PULSE;
					end if;

				when SCSI_SENSE_WAIT_END =>
					if CD_DATA_END = '1' then
						CD_STAT     <= x"00";  -- GOOD -- REQUEST SENSE itself succeeded
						CD_MSG      <= x"00";
						CD_STAT_GET <= '1';
						scsi_state  <= SCSI_IDLE;
					end if;

				-- READ(6): request one sector at READ_LBA, wait for the external source to
				-- stream its 2048 bytes (SECTOR_DATA_VALID pulses), relay each byte into
				-- SCSI.vhd's DATA-IN FIFO with the same one-idle-cycle-per-byte gap as
				-- REQUEST SENSE, then advance to the next sector until READ_COUNT is
				-- exhausted.
				when SCSI_READ_REQ =>
					SECTOR_REQ <= '1';
					scsi_state <= SCSI_READ_WAIT_BYTE;

				when SCSI_READ_WAIT_BYTE =>
					if SECTOR_DATA_VALID = '1' then
						CD_DATA    <= SECTOR_DATA;
						CD_DATA_WR <= '1';
						scsi_state <= SCSI_READ_GAP;
					end if;

				when SCSI_READ_GAP =>
					if read_byte_ct = 2047 then
						read_byte_ct <= (others => '0');
						scsi_state   <= SCSI_READ_NEXT_SECTOR;
					else
						read_byte_ct <= read_byte_ct + 1;
						scsi_state   <= SCSI_READ_WAIT_BYTE;
					end if;

				when SCSI_READ_NEXT_SECTOR =>
					if read_count = 1 then
						scsi_state <= SCSI_READ_WAIT_END;
					else
						read_count <= read_count - 1;
						read_lba   <= read_lba + 1;
						scsi_state <= SCSI_READ_REQ;
					end if;

				when SCSI_READ_WAIT_END =>
					if CD_DATA_END = '1' then
						CD_STAT     <= x"00";  -- GOOD
						CD_MSG      <= x"00";
						CD_STAT_GET <= '1';
						scsi_state  <= SCSI_IDLE;
					end if;
			end case;
		end if;
	end process;

end architecture;
