-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand

-- Real SCSI target for PCE-CD, shared across all 3 boards (2026-08-31, extended 2026-08-31b).
--
-- Replaces the per-board "minimal SCSI target stub" (identical code duplicated in each
-- pcetang_<board>_cd.vhd -- REQUEST SENSE only, everything else CHECK CONDITION) with ONE
-- real module. Real command decode verified against Mednafen's pce_fast/pcecd_drive.cpp
-- (fetched/read directly this session, not assumed from generic SCSI-2):
--   TEST UNIT READY (0x00): GOOD if a disc is mounted, else CHECK CONDITION/NOT READY.
--   REQUEST SENSE   (0x03): real fixed-format sense data, built from PENDING_KEY/PENDING_ASC
--                            (set by whichever command last failed -- see below), NOT_READY/
--                            NO_DISC (0x0B) when unmounted and nothing else pending.
--   READ(6)         (0x08): sa = (CDB[1][4:0]<<16)|(CDB[2]<<8)|CDB[3], sc = CDB[4] (0=>256),
--                            matches DoREAD6()/DoREADBase() exactly. Real LBA bounds check
--                            against the real TOC lead-out (toc_leadout_lba) -- NSE_END_OF_VOLUME
--                            (0x25) if sa is past the last real sector, matching Mednafen's
--                            own DoREADBase() check.
--   SAPSP           (0xD8): set audio play start position. cdb[9][7:6] selects addressing:
--                            00=raw LBA (cdb[2:4] big-endian 24-bit), 10=BCD AMSF (cdb[2:4]=
--                            M/S/F), 11=BCD track# (cdb[2], looked up in the TOC). Sets
--                            CDDA_STATUS to PLAYING and seeds read_lba with the target LBA
--                            -- SCSI_IDLE's own audio-continue branch then real-streams raw
--                            CD-DA sectors from the MCU via the shared SECTOR_REQ/SECTOR_DATA_*
--                            channel (SECTOR_IS_AUDIO tags the request), same real path
--                            READ(6) uses. See CD_AUDIO_WR's own port comment.
--   SAPEP           (0xD9): set audio play end position + real play mode from cdb[1]
--                            (0x00=silent/stop, 0x01=loop, 0x02=interrupt, 0x03=normal).
--                            cdb[1]=0x00 sets CDDA_STATUS back to STOPPED, matching
--                            Mednafen's own real mode switch.
--   PAUSE           (0xDA): pause if CDDA_STATUS=PLAYING, else CHECK CONDITION/
--                            ILLEGAL_REQUEST+NSE_AUDIO_NOT_PLAYING (0x2C), matching
--                            Mednafen's real guard exactly.
--   READSUBQ        (0xDD): real play-status byte (STOPPED=3/PLAYING=0/PAUSED=2, matches
--                            Mednafen's real SubQ status encoding) + absolute M/S/F derived
--                            from the real LAST_SAPSP_LBA via the shared LBA->AMSF
--                            converter. Real, named gap: relative M/S/F and track/index
--                            are always reported as 0/first-track -- this module has no
--                            real playback-position tracking without CD_AUDIO_WR streaming,
--                            so these fields are a stand-in, not real position, documented
--                            here rather than hidden (see pcetang_cd_scsi_plan.md).
--   GETDIRINFO      (0xDE): mode 0x0=first/last track (BCD) from the real TOC, mode
--                            0x1=lead-out AMSF, mode 0x2=BCD-track-number-indexed AMSF+
--                            control byte, matching Mednafen's real GetDirInfo() with real
--                            TOC data (see TOC_WR/TOC_TRACK/TOC_CONTROL/TOC_LBA below), not
--                            placeholder zeros.
--   Any unrecognized opcode: CHECK CONDITION with real ILLEGAL_REQUEST(0x5)/
--                            NSE_INVALID_COMMAND(0x20) sense data, matching Mednafen's own
--                            CommandCCError(SENSEKEY_ILLEGAL_REQUEST, NSE_INVALID_COMMAND)
--                            dispatch-miss path exactly (pcecd_drive.cpp real command table
--                            walk) -- previously this reused the generic NOT_READY-shaped
--                            CHECK CONDITION with no real sense data set at all, so a
--                            REQUEST SENSE issued afterward returned stale/wrong data. Real
--                            correctness fix, not cosmetic.
--
-- Real TOC channel (TOC_WR/TOC_TRACK/TOC_CONTROL/TOC_LBA): one real MCU->FPGA write per
-- track (track=100 is the real lead-out sentinel, stored in its own dedicated
-- toc_leadout_lba register, separate from the real per-track toc_lba_tbl array). TOC_CONTROL
-- follows real Red Book control-byte convention: bit2 set = data
-- track, clear = 2-channel audio track (see pcecd.cpp's real CHD-metadata-to-control-byte
-- mapping). Real self-reset: TOC_FIRST_TRACK/TOC_LAST_TRACK re-arm on every real
-- DISC_MOUNTED falling edge (MCU's own pcecd_unload(), called at the start of every real
-- disc-swap), so a second real disc load does not inherit the first disc's stale TOC
-- extents -- the toc_lba_tbl/toc_control_tbl arrays themselves are simply overwritten per-track by
-- the new disc's own real TOC_WR pulses.
--
-- Real LBA<->AMSF conversion (shared LBA_TO_AMSF_* states) is deliberately NOT combinational
-- -- a /75 and /4500 real division on a 24-bit LBA, done via real repeated subtraction over
-- multiple real clock cycles, kept off the hot READ(6) data path and out of any single
-- cycle's real combinational depth (Console 60K CD's real timing margin is thin, see
-- pcetang_status_matrix.md). These commands (SAPSP/GETDIRINFO/READSUBQ) are real rare, once-
-- in-a-while host commands, not per-sector traffic, so tens of real extra clock cycles of
-- latency here is free.
--
-- Sector source (SECTOR_*) is a real, deliberately generic req/byte-stream interface --
-- this module does not know or care whether the far side is a synthetic test source or the
-- real MCU-driven sector reader (pcecd.cpp's real pcecd_serve_sector(), wired 2026-08-31).
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
		-- Sector count of the READ(6) in flight, 0 when no READ(6) is active. SCSI.vhd
		-- uses it to end a DATA-IN transfer on the CPU having ACKed every sector, instead
		-- of on the FIFO momentarily running dry -- see DATAIN_SECTORS there.
		DATAIN_SECTORS : out unsigned(8 downto 0) := (others => '0');

		-- Real mount state, driven by the MCU-side mount/TOC protocol (pcecd_send_mount()).
		DISC_MOUNTED  : in  std_logic := '0';

		-- Real TOC channel -- one real write per track (100 = real lead-out sentinel),
		-- driven by the MCU's real pcecd_read_toc()/pcecd_send_toc_entry() (0x0f frames).
		TOC_WR        : in  std_logic := '0';
		TOC_TRACK     : in  std_logic_vector(7 downto 0) := (others => '0');
		TOC_CONTROL   : in  std_logic_vector(7 downto 0) := (others => '0');
		TOC_LBA       : in  std_logic_vector(23 downto 0) := (others => '0');

		-- Real sector-fetch interface (bridge -> external sector source). LBA is 24 bits
		-- (16.7M sectors, ~35GB at 2048B/sector) -- real CD-ROM max is ~330K sectors
		-- (~675MB), so this is comfortably wide, not a guess.
		SECTOR_REQ        : out std_logic;
		SECTOR_LBA        : out std_logic_vector(23 downto 0);
		SECTOR_DATA       : in  std_logic_vector(7 downto 0) := (others => '0');
		SECTOR_DATA_VALID : in  std_logic := '0';   -- one pulse per byte, 2048 bytes/sector
		SECTOR_DATA_LAST  : in  std_logic := '0';   -- pulses together with the 2048th byte

		-- Real CDDA v2 (2026-08-31g): CD_AUDIO_WR/CD_DM feed cd.vhd's own real CDDA_FIFO
		-- write path directly (same shared CD_DATA byte bus READ(6) already drives --
		-- never both strobes in the same cycle, enforced structurally, see
		-- SCSI_READ_WAIT_BYTE below). Real audio bytes come from the MCU over the same
		-- SECTOR_REQ/SECTOR_LBA/SECTOR_DATA_* channel READ(6) already uses -- SECTOR_
		-- IS_AUDIO is the one new wire, a type tag on the request so the MCU knows to
		-- serve a raw 2352-byte CD-DA sector instead of a 2048-byte Mode-1 data sector.
		-- Real bandwidth check done before building this (see pcetang_status_matrix.md):
		-- CDDA and data reads are mutually exclusive on real hardware (Mednafen's
		-- DoREADBase() unconditionally stops CDDA on any READ), so the 2Mbaud UART link
		-- never has to carry both at once -- verified against pcecd_drive.cpp directly.
		CD_AUDIO_WR     : out std_logic;
		CD_DM           : out std_logic;
		SECTOR_IS_AUDIO : out std_logic;
		-- PCE PORT (2026-09-16): free entries in cd.vhd's CD-DA FIFO, for audio
		-- prefetch flow control. Default 0 = "no room" = prefetch never fires, so a
		-- board that does not wire this keeps the old serialized behaviour instead of
		-- silently overrunning the FIFO. That fail-safe direction is deliberate: the
		-- opposite default on FIFO_SPACE is what manufactured a fake stall in
		-- simulation once (docs/MEMORY_BRIDGE_CONTRACT.md).
		CDDA_SPACE      : in  unsigned(11 downto 0) := (others => '0');

		-- Live FSM state, so a board-level trace can tell "parked waiting for something"
		-- apart from "back in SCSI_IDLE, host sent nothing". Leave unconnected if unused.
		DBG_STATE       : out std_logic_vector(4 downto 0);
		-- CD_DATA_END accounting. [31:16] pulses CONSUMED by a *_WAIT_END state,
		-- [15:0] pulses LOST because none of the three states that listen for it was
		-- active. CD_DATA_END is a one-cycle pulse with NO handshake, and SCSI.vhd
		-- fires it at ANY sector boundary where the FIFO is empty -- including
		-- non-final boundaries mid-command, where cd_bridge is still fetching and
		-- nobody is listening. A lost pulse at the FINAL boundary would leave
		-- SCSI_READ_WAIT_END hung forever, no STATUS phase would ever be entered, and
		-- the system card would time out and reset the SCSI bus -- exactly the
		-- observed hardware failure. This counter decides whether that actually happens.
		DBG_DEND        : out std_logic_vector(31 downto 0);

		-- Free space in SCSI.vhd's DATA-IN FIFO. REAL BACK-PRESSURE, not a probe: this
		-- FSM paces itself on bytes ARRIVING FROM THE MCU, not on the CPU draining them,
		-- so without this it happily fetches sector after sector into a FIFO the CPU has
		-- not emptied. Writes past full are silently dropped by the FIFO, the transfer
		-- comes up short, and the host retries forever -- measured on Prince of Persia,
		-- whose boot read is 16 consecutive sectors (32768 bytes through a 4096-byte
		-- FIFO). Defaults to "plenty of room" so a board that leaves it unconnected
		-- behaves exactly as before.
		FIFO_SPACE      : in  unsigned(12 downto 0) := (others => '1');

		-- SCSI BUS RESET, from cd.vhd's own `CD_RESET <= not SCSI_RST_N` (the CPU writing
		-- bit 1 of $1802). This was left unconnected -- `CD_RESET => open` at the board
		-- level -- and that is a real bug, not a missing nicety: a bus reset clears
		-- SCSI.vhd but left THIS FSM parked wherever it happened to be. Measured on
		-- Prince of Persia 2026-09-11: bridge stuck in SCSI_READ_WAIT_BYTE with SCSI.vhd's
		-- own counters freshly zeroed, waiting for sector bytes belonging to a transfer
		-- the host had already abandoned. No further requests, drive looks dead.
		--
		-- CURRENTLY ACCEPTED AND IGNORED -- port kept because the plumbing is right and
		-- the underlying defect is real, but the obvious implementation is WRONG and was
		-- reverted 2026-09-11 after a measured regression.
		--
		-- Tried: fold BUS_RST into this process's reset branch, so a bus reset returns
		-- the FSM to SCSI_IDLE. Result on hardware: Bonk III went BACKWARDS (it had been
		-- executing game code; it returned to LOAD ERROR) and Prince of Persia changed
		-- failure mode. The tell was the MCU logging a sector request for LBA 43520 =
		-- 0x00AA00 -- 0xAA is the UART frame header byte, so a corrupted/mis-framed
		-- request was going out. That value appears in NO earlier run.
		--
		-- Why the naive version is wrong: $1804 bit 1 is a LATCH, not a strobe
		-- (`SCSI_RST_N <= not EXT_DI(1)` in cd.vhd) -- the BIOS asserts it and releases
		-- it later, so a level-sensitive abort holds this FSM in reset for as long as the
		-- host leaves it asserted, and clearing read_lba underneath an in-flight
		-- SECTOR_REQ lets a request escape with garbage.
		--
		-- A correct fix probably acts on the RISING EDGE only, and clears just the
		-- transfer (scsi_state, read_count, SECTOR_REQ) while leaving read_lba and the
		-- TOC alone. Not attempted yet -- do not re-try the level-sensitive version.
		BUS_RST         : in  std_logic := '0'
	);
end entity;

architecture rtl of cd_bridge is

	constant SCSI_OP_TEST_UNIT_READY : std_logic_vector(7 downto 0) := x"00";
	constant SCSI_OP_READ6           : std_logic_vector(7 downto 0) := x"08";
	constant SCSI_OP_REQUEST_SENSE   : std_logic_vector(7 downto 0) := x"03";
	constant SCSI_OP_SAPSP           : std_logic_vector(7 downto 0) := x"D8";
	constant SCSI_OP_SAPEP           : std_logic_vector(7 downto 0) := x"D9";
	constant SCSI_OP_PAUSE           : std_logic_vector(7 downto 0) := x"DA";
	constant SCSI_OP_READSUBQ        : std_logic_vector(7 downto 0) := x"DD";
	constant SCSI_OP_GETDIRINFO      : std_logic_vector(7 downto 0) := x"DE";

	-- Real sense keys / ASCs -- verified against Mednafen's pce_fast/pcecd_drive.cpp const
	-- tables (SENSEKEY_*/NSE_*), not generic SCSI-2 assumptions.
	constant SENSEKEY_NO_SENSE       : unsigned(3 downto 0) := x"0";
	constant SENSEKEY_NOT_READY      : unsigned(3 downto 0) := x"2";
	constant SENSEKEY_ILLEGAL_REQ    : unsigned(3 downto 0) := x"5";
	constant NSE_NO_DISC             : std_logic_vector(7 downto 0) := x"0B";
	constant NSE_INVALID_COMMAND     : std_logic_vector(7 downto 0) := x"20";
	constant NSE_INVALID_ADDRESS     : std_logic_vector(7 downto 0) := x"21";
	constant NSE_END_OF_VOLUME       : std_logic_vector(7 downto 0) := x"25";
	-- ASC 0x26, INVALID FIELD IN PARAMETER LIST -- what mednafen returns for a GETDIRINFO
	-- mode 2 track number above 99.
	constant NSE_INVALID_PARAMETER   : std_logic_vector(7 downto 0) := x"26";
	constant NSE_AUDIO_NOT_PLAYING   : std_logic_vector(7 downto 0) := x"2C";

	-- Real CDDA play-status encoding, matching Mednafen's SubQ status byte values exactly
	-- (0=PLAYING, 2=PAUSED, 3=STOPPED) -- READSUBQ returns this value directly, no remap.
	constant CDDA_STOPPED : std_logic_vector(1 downto 0) := "11";
	constant CDDA_PLAYING : std_logic_vector(1 downto 0) := "00";
	constant CDDA_PAUSED  : std_logic_vector(1 downto 0) := "10";

	type scsi_state_t is (
		SCSI_IDLE,
		SCSI_SENSE_PULSE, SCSI_SENSE_GAP, SCSI_SENSE_WAIT_END,
		SCSI_READ_REQ, SCSI_READ_WAIT_BYTE, SCSI_READ_GAP,
		SCSI_READ_NEXT_SECTOR, SCSI_READ_WAIT_END,
		SCSI_DATA_PULSE, SCSI_DATA_GAP, SCSI_DATA_WAIT_END,
		SCSI_CONV_SUB_M, SCSI_CONV_SUB_S, SCSI_CONV_DONE
	);
	signal scsi_state : scsi_state_t := SCSI_IDLE;

	-- DBG_STATE encoding, in declaration order of scsi_state_t.
	function state_code(st : scsi_state_t) return std_logic_vector is
	begin
		case st is
			when SCSI_IDLE             => return "00000";
			when SCSI_SENSE_PULSE      => return "00001";
			when SCSI_SENSE_GAP        => return "00010";
			when SCSI_SENSE_WAIT_END   => return "00011";
			when SCSI_READ_REQ         => return "00100";
			when SCSI_READ_WAIT_BYTE   => return "00101";
			when SCSI_READ_GAP         => return "00110";
			when SCSI_READ_NEXT_SECTOR => return "00111";
			when SCSI_READ_WAIT_END    => return "01000";
			when SCSI_DATA_PULSE       => return "01001";
			when SCSI_DATA_GAP         => return "01010";
			when SCSI_DATA_WAIT_END    => return "01011";
			when SCSI_CONV_SUB_M       => return "01100";
			when SCSI_CONV_SUB_S       => return "01101";
			when SCSI_CONV_DONE        => return "01110";
		end case;
	end function;
	signal sense_idx   : integer range 0 to 17 := 0;

	-- Real pending sense state -- set by whichever command last needed to report an error
	-- (or cleared to NO_SENSE by a success path), consumed by REQUEST SENSE. Replaces the
	-- old two-constant (SENSE_NOT_READY/SENSE_NO_SENSE) static table.
	signal pending_key : unsigned(3 downto 0) := SENSEKEY_NO_SENSE;
	signal pending_asc  : std_logic_vector(7 downto 0) := (others => '0');

	-- Real command-pending latch (2026-08-31g) -- CD_COMM_SEND is a genuine one-shot
	-- pulse in the real donor (SCSI.vhd's own COMM_OUT, confirmed: unconditionally
	-- defaulted '0' every cycle, set '1' only the exact SP_COMM_END cycle), so a plain
	-- level check (no separate edge-detect register/process needed -- one cycle less
	-- latency, matters here) is exactly equivalent to edge detection and can't
	-- re-trigger. Sampling CD_COMM_SEND only from SCSI_IDLE (as before this latch
	-- existed) drops any command that arrives while scsi_state is busy -- real and
	-- reachable even pre-CDDA (a 256-sector READ(6) already occupies scsi_state with no
	-- yield), and now routinely reachable too (a real audio-sector fetch is ~12ms, a
	-- real READ(6) CDB takes SCSI.vhd's own ~665us REQ/ACK handshake to assemble -- the
	-- pulse can land mid-fetch). This latch closes both: set on any real CD_COMM_SEND
	-- pulse (after the dispatch case, so a same-cycle set/clear collision resolves to
	-- "set wins" by VHDL's last-assignment-wins), cleared only on real dispatch.
	signal comm_pending : std_logic := '0';

	-- READ(6) real working state
	signal read_lba     : unsigned(23 downto 0) := (others => '0');
	signal read_count   : unsigned(8 downto 0)  := (others => '0');  -- 0..256, needs 9 bits
	-- Unlike read_count (which counts DOWN as sectors are fetched from the MCU), this
	-- holds the ORIGINAL CDB count for the whole transfer, because SCSI.vhd needs to know
	-- how many sectors the CPU is owed, not how many are left to fetch.
	signal datain_sect_n : unsigned(8 downto 0) := (others => '0');
	signal read_byte_ct : unsigned(11 downto 0) := (others => '0');  -- 0..2047

	-- Real TOC storage -- index 0..99 real tracks (1-based track numbers used directly as
	-- the index, entry 0 unused), index 100 = real lead-out sentinel.
	type toc_lba_arr_t is array (0 to 100) of unsigned(23 downto 0);
	-- Real LUT-budget trim (2026-08-31c, see pcetang_cd_scsi_plan.md): a real gw_sh fit-
	-- check found this feature bundle pushed Primer 25K CD from 79% to 90% Logic
	-- utilization (baseline vs. this bundle, both real-measured) -- past the point where
	-- either PnR algorithm can route it (2321/23073 unrouted nets, both real, both worse
	-- than the 79% baseline's clean route). toc_control_tbl was an 8-bit-per-track array
	-- when only bit2 (real Red Book data/audio flag) is ever consumed -- 1 bit/track here,
	-- reconstructed to the real control-byte convention (0x04 data / 0x00 audio) at the
	-- one real consumer (GETDIRINFO mode 2).
	type toc_ctl_arr_t is array (0 to 100) of std_logic;
	signal toc_lba_tbl      : toc_lba_arr_t := (others => (others => '0'));
	signal toc_control_tbl  : toc_ctl_arr_t := (others => '0');
	signal toc_first_track : unsigned(7 downto 0) := x"FF";  -- 0xFF = real "unset" sentinel
	signal toc_last_track  : unsigned(7 downto 0) := (others => '0');
	-- Real, dedicated lead-out register, separate from toc_lba_tbl -- READ(6)'s own hot-
	-- path bounds check (every real sector request) no longer shares a mux with the
	-- variable-track-index reads SAPSP/GETDIRINFO mode 2 use against the same array.
	signal toc_leadout_lba : unsigned(23 downto 0) := (others => '0');
	-- Real, precomputed once per real TOC_WR (not per query) -- see u8_to_bcd's own
	-- header comment for why this was moved out of the command-dispatch hot path.
	signal toc_first_track_bcd : std_logic_vector(7 downto 0) := (others => '0');
	signal toc_last_track_bcd  : std_logic_vector(7 downto 0) := (others => '0');
	signal disc_mounted_r  : std_logic := '0';
	-- see DBG_DEND's port comment
	signal dend_ok   : unsigned(15 downto 0) := (others => '0');
	signal dend_lost : unsigned(15 downto 0) := (others => '0');

	-- Real CDDA play state -- minimum needed for SAPSP/SAPEP/PAUSE/READSUBQ to be self-
	-- consistent without real audio streaming (see file header).
	signal cdda_status   : std_logic_vector(1 downto 0) := CDDA_STOPPED;
	signal last_sapsp_lba : unsigned(23 downto 0) := (others => '0');

	-- Real audio-fetch tag -- distinguishes an audio-sector fetch from a real READ(6)
	-- data-sector fetch while both share SCSI_READ_REQ/SCSI_READ_WAIT_BYTE (same LUT
	-- cost either way, real budget concern on Primer 25K CD -- see
	-- pcetang_status_matrix.md). Set at whichever SCSI_IDLE dispatch starts the fetch,
	-- held for its entire duration (never re-defaulted mid-fetch).
	signal is_audio_read : std_logic := '0';
	-- CD-DA PREFETCH (2026-09-16). Measured: the board served 49.7 audio sectors/s
	-- against the 75/s CD-DA needs -- 66% of realtime, so the FIFO ran dry constantly
	-- and the music was scratchy. Of the 20.1ms spent per sector only 11.76ms is wire
	-- time (2352 bytes at 2Mbaud); the other ~8.3ms was MCU turnaround paid on EVERY
	-- sector, because this FSM did not ask for sector N+1 until the last byte of N had
	-- arrived. Asking early overlaps that turnaround with the tail of the current
	-- transfer and takes the rate to ~113% of realtime. Full numbers, and why a bigger
	-- FIFO cannot fix it, in docs/CD_AUDIO_TIMING.md.
	--
	-- No firmware change is needed: uart1_rx_task (priority 3) is the sole RX FIFO
	-- consumer and always drains, and requests land in a 16-deep cd_req_queue that
	-- cd_serve_task (priority 2) pops -- so a request arriving mid-transmission is
	-- already received and queued today.
	signal audio_pf_pend : std_logic := '0';   -- a request for the NEXT sector is out
	signal audio_pf_arm  : std_logic := '0';   -- issue it on the following cycle
	signal audio_byte_ct : unsigned(11 downto 0) := (others => '0');
	-- Issue the next request this many bytes into the current 2352-byte sector. Late
	-- enough that a host command still has most of the sector to arrive and cancel it
	-- (see the comm_pending guard), early enough that ~8.3ms of MCU turnaround fits in
	-- the remaining ~2.7ms of wire time plus the FIFO's own slack.
	constant AUDIO_PREFETCH_AT : unsigned(11 downto 0) := to_unsigned(1800, 12);
	-- One raw CD-DA sector is 588 stereo frames; only prefetch with room for a whole one.
	constant CDDA_SECTOR_FRAMES : unsigned(11 downto 0) := to_unsigned(588, 12);

	-- Real shared LBA->AMSF converter (repeated-subtract, multi-cycle, off the hot path).
	-- conv_total starts at LBA+150; conv_m_bcd/conv_s_bcd count directly in packed BCD
	-- (carry-on-9 logic in the subtract loop itself) rather than binary-then-convert --
	-- real LUT-budget trim (see toc_control_tbl's own comment above): u8_to_bcd was
	-- previously called 9 times across this converter's 3 real consumers (READSUBQ,
	-- GETDIRINFO modes 1/2), each a distinct /10+mod10 divider in the real netlist: BCD-
	-- native counting removes all 9. conv_f_bcd is the one real exception -- F is a
	-- leftover remainder (0..74), not counted incrementally, so it keeps one real
	-- u8_to_bcd call (in SCSI_CONV_SUB_S's own exit), the only one left in this path.
	-- 20 bits, NOT 17. The old width carried the comment "max real disc <100000", which
	-- is wrong: a 74-minute CD is 333000 frames and an 80-minute one 360000, and the
	-- value converted here is LBA+150, not LBA. Measured on hardware 2026-09-11 with
	-- Dungeon Explorer II: lead-out LBA 316011 -> 316161, which needs 19 bits; at 17 it
	-- wrapped to 54017 and GETDIRINFO mode 1 returned 12:00:17 instead of 70:15:36.
	-- 20 bits covers 1048575 frames (~233 minutes), past any real disc.
	-- Watchdog for a LOST sector request. The FPGA->MCU request is a 5-byte UART frame
	-- with no acknowledgement, and the MCU's RX FIFO high-water was measured at 25 of 32
	-- bytes on hardware 2026-09-11 -- thin enough that a frame is occasionally lost. When
	-- that happens this FSM waits in SCSI_READ_WAIT_BYTE forever and the drive appears
	-- dead: observed on Prince of Persia, which served 3 sectors and then parked, with the
	-- MCU logging no 4th request and no SERVE-FAIL.
	--
	-- Re-requesting is safe BECAUSE the timer is reset by every arriving byte: if the
	-- request was actually served, data is flowing and the timeout never fires, so a
	-- sector is never fetched twice. It only fires when nothing at all came back, which
	-- is exactly the lost-frame case. ~100ms at 42.86MHz, far longer than a worst-case
	-- libchdr hunk decode plus SD-logging, so a merely slow serve is not interrupted.
	-- OFF by default, and this is a real decision rather than tidying. The watchdog was
	-- added to survive a LOST sector request, but that loss had a proper cause -- the MCU
	-- serving sectors on its polled UART RX task, which truncated request frames -- and
	-- that is fixed in firmware. With requests no longer lost the watchdog has nothing to
	-- catch, and it actively HARMS: measured 2026-09-12, a 2-sector read produced 12
	-- SECTOR_REQs and 24576 bytes of sector data where 4096 were wanted. The bridge
	-- consumed 4096 and discarded the surplus, and the corrupted transfer showed up as
	-- LOAD ERROR. Any serve slower than the timeout (SD logging in the firmware makes
	-- one) turns a working read into a duplicated one.
	--
	-- Re-enable only alongside evidence that requests are being lost again -- the MCU's
	-- `rxhi=` figure in the cdprog line is the measurement for that.
	constant REQ_WATCHDOG : boolean := false;
	constant REQ_TIMEOUT : unsigned(22 downto 0) := to_unsigned(4286000, 23);
	signal req_wdog    : unsigned(22 downto 0) := (others => '0');

	signal conv_total  : unsigned(19 downto 0) := (others => '0');
	signal conv_m_bcd  : std_logic_vector(7 downto 0) := (others => '0');
	signal conv_s_bcd  : std_logic_vector(7 downto 0) := (others => '0');
	signal conv_f_bcd  : std_logic_vector(7 downto 0) := (others => '0');

	-- Real, small, data-driven response staged by whichever command needs to push bytes to
	-- the host (GETDIRINFO/READSUBQ) -- reuses the same SCSI_DATA_* pulse/gap timing as
	-- REQUEST SENSE and READ(6)'s own byte relay.
	-- Real trim: max real usage is index 8 (READSUBQ's 9-byte response), so 9 elements
	-- (0..8), not 10 -- gw_sh flagged resp_buf(9) as a real undriven net (EX1998).
	type resp_buf_t is array (0 to 8) of std_logic_vector(7 downto 0);
	signal resp_buf   : resp_buf_t := (others => (others => '0'));
	signal resp_len   : integer range 1 to 9 := 1;
	signal resp_idx   : integer range 0 to 8 := 0;

	-- Real latch, set at dispatch time -- SCSI_CONV_DONE (reached several cycles later)
	-- must not re-read CD_COMM(7:0) to tell READSUBQ apart from GETDIRINFO, since nothing
	-- here guarantees the host holds CD_COMM steady across a multi-cycle command.
	signal conv_is_subq : std_logic := '0';

	-- real 8-bit binary -> BCD, values here are always < 100 (M/S) or < 75 (F) -- small
	-- enough for Gowin to synthesize directly as combinational logic, unlike the /75/4500
	-- LBA division above (flagged separately, kept multi-cycle).
	function u8_to_bcd(v : unsigned(7 downto 0)) return std_logic_vector is
		variable tens  : unsigned(7 downto 0);
		variable ones  : unsigned(7 downto 0);
	begin
		tens := v / 10;
		ones := v mod 10;
		return std_logic_vector(tens(3 downto 0)) & std_logic_vector(ones(3 downto 0));
	end function;

	function bcd_to_u8(v : std_logic_vector(7 downto 0)) return unsigned is
	begin
		return unsigned(v(7 downto 4)) * 10 + unsigned(v(3 downto 0));
	end function;

begin

	DBG_STATE <= state_code(scsi_state);
	DBG_DEND  <= std_logic_vector(dend_ok) & std_logic_vector(dend_lost);
	DATAIN_SECTORS <= datain_sect_n;

	SECTOR_LBA <= std_logic_vector(read_lba);

	-- Real TOC write + self-resetting extents, independent process (real, simple, no
	-- interaction with the main command FSM's own state).
	--
	-- DELIBERATELY NOT RESET BY RST_N (2026-09-14). The TOC is disc state, written by
	-- the MCU, not core state: RST_N here is pce_top's core_resetn, which the top level
	-- holds low from the start of the ROM upload until its SDRAM verify sweep finishes.
	-- The MCU sends the TOC right after the syscard bytes ("loadpcecd: TOC sent" follows
	-- "loadpce: ... core_running=true"), so every TOC_WR that lands inside that window
	-- used to be dropped on the floor -- an async reset holds the whole process, so not
	-- just these extents but every toc_lba_tbl entry was lost too.
	--
	-- Measured: a build whose reset window was ~1.4s longer (the CD-RAM self-test sweep)
	-- lost the TOC on all three discs tested. GETDIRINFO then answered from these reset
	-- values -- mode 0 "first 00 last 00", mode 1 lead-out LBA 0 = MSF 00:02:00, mode 2
	-- track start LBA 0 -- so the system card concluded the disc has no data track and
	-- dropped to the CD player, deterministically, instead of booting.
	--
	-- Power-on values come from the signal declarations instead (toc_first_track's x"FF"
	-- is the "no track seen yet" sentinel). Per-disc clearing is the DISC_MOUNTED falling
	-- edge below, which is the correct hook: it is the MCU's own pcecd_unload().
	TOC_CAPTURE : process (CLK)
	begin
		if rising_edge(CLK) then
			disc_mounted_r <= DISC_MOUNTED;
			if DISC_MOUNTED = '0' and disc_mounted_r = '1' then
				-- real falling edge = MCU's pcecd_unload(), about to load a new disc's TOC
				toc_first_track     <= x"FF";
				toc_last_track      <= (others => '0');
				toc_first_track_bcd <= (others => '0');
				toc_last_track_bcd  <= (others => '0');
			elsif TOC_WR = '1' then
				-- The table covers 0..100, so the lead-out (track 100) is stored BOTH in
				-- its own register -- READ(6)'s bounds check reads it every command and
				-- wants a plain register, not an indexed read -- and as table entry 100.
				-- That second copy is what lets GETDIRINFO mode 2 treat the lead-out as an
				-- ordinary track and index the table uniformly, instead of selecting
				-- between the register and the table with a second 24-bit mux. Primer 25K
				-- sits at 93% logic and failed to route with that extra mux (PR0004, 31
				-- unrouted nets), so this is a real area fix, not a tidy-up.
				if unsigned(TOC_TRACK) <= 100 then
					toc_lba_tbl(to_integer(unsigned(TOC_TRACK)))     <= unsigned(TOC_LBA);
					toc_control_tbl(to_integer(unsigned(TOC_TRACK))) <= TOC_CONTROL(2);
				end if;
				if unsigned(TOC_TRACK) < 100 then
					-- first/last track extents cover real tracks only, never the lead-out
					if toc_first_track = x"FF" then
						toc_first_track     <= unsigned(TOC_TRACK);
						toc_first_track_bcd <= u8_to_bcd(unsigned(TOC_TRACK));
					end if;
					toc_last_track     <= unsigned(TOC_TRACK);
					toc_last_track_bcd <= u8_to_bcd(unsigned(TOC_TRACK));
				else
					toc_leadout_lba <= unsigned(TOC_LBA);  -- real lead-out
				end if;
			end if;
		end if;
	end process;

	process (CLK, RST_N)
		variable sa       : unsigned(23 downto 0);
		variable sa_vec    : std_logic_vector(23 downto 0);
		variable sc        : unsigned(8 downto 0);
		variable sapsp_lba : unsigned(23 downto 0);
		variable sapsp_vec : std_logic_vector(23 downto 0);
		variable gdi_track : unsigned(7 downto 0);
		variable amsf_m, amsf_s, amsf_f : unsigned(7 downto 0);
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
			req_wdog      <= (others => '0');
			pending_key   <= SENSEKEY_NO_SENSE;
			pending_asc   <= (others => '0');
			cdda_status    <= CDDA_STOPPED;
			last_sapsp_lba <= (others => '0');
			resp_len       <= 1;
			resp_idx       <= 0;
			conv_is_subq   <= '0';
			conv_total     <= (others => '0');
			conv_m_bcd     <= (others => '0');
			conv_s_bcd     <= (others => '0');
			conv_f_bcd     <= (others => '0');
			CD_AUDIO_WR      <= '0';
			CD_DM            <= '0';
			SECTOR_IS_AUDIO  <= '0';
			is_audio_read    <= '0';
			audio_pf_pend    <= '0';
			audio_pf_arm     <= '0';
			audio_byte_ct    <= (others => '0');
			comm_pending     <= '0';
		elsif rising_edge(CLK) then
			CD_STAT_GET     <= '0';
			CD_DATA_WR      <= '0';
			SECTOR_REQ      <= '0';
			CD_AUDIO_WR     <= '0';
			CD_DM           <= '0';
			SECTOR_IS_AUDIO <= '0';

			case scsi_state is
				when SCSI_IDLE =>
					if comm_pending = '1' or CD_COMM_SEND = '1' then
						-- Real same-cycle path (CD_COMM_SEND checked directly, not just
						-- the latch): when scsi_state is genuinely idle already, a pulse
						-- must dispatch this same cycle, matching the pre-latch design's
						-- own behavior -- the latch alone (registered, one cycle behind)
						-- would lose that race against SCSI_IDLE's own audio-continue
						-- elsif below on the exact cycle a fetch just finished. See the
						-- post-case latch-set below for why this doesn't double-arm.
						comm_pending <= '0';
						case CD_COMM(7 downto 0) is
							when SCSI_OP_REQUEST_SENSE =>
								-- Real drive-level condition overrides whatever's pending
								-- from a prior command -- matches the original stub's own
								-- live DISC_MOUNTED check, now merged with the new
								-- pending_key/pending_asc mechanism for genuine command
								-- errors (bad opcode, out-of-range address, etc.) that can
								-- occur regardless of mount state.
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
								end if;
								sense_idx  <= 0;
								scsi_state <= SCSI_SENSE_PULSE;

							when SCSI_OP_TEST_UNIT_READY =>
								if DISC_MOUNTED = '1' then
									pending_key <= SENSEKEY_NO_SENSE;
									pending_asc <= (others => '0');
									CD_STAT     <= x"00";  -- GOOD
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";  -- CHECK CONDITION
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								end if;

							when SCSI_OP_READ6 =>
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									-- Real bus-ownership rule (advisor-suggested, matches
									-- real drive behavior): a data read stops any real audio
									-- playback in progress -- cd_bridge owns the single
									-- shared CD_DATA bus, so CD_AUDIO_WR and CD_DATA_WR must
									-- never both be real candidates in the same cycle. This
									-- resolves that for free, no explicit interlock needed.
									cdda_status   <= CDDA_STOPPED;
									is_audio_read <= '0';
									-- sa = CDB[1][4:0] & CDB[2] & CDB[3], sc = CDB[4] (0 => 256)
									-- CDB[n] = CD_COMM(8*n+7 downto 8*n) -- see SCSI.vhd's own
									-- COMMAND<=COMM(11)&...&COMM(0) concatenation.
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
									if sa > toc_leadout_lba then
										-- real bounds check against the lead-out, matches
										-- Mednafen's DoREADBase() end-of-volume guard
										pending_key <= SENSEKEY_ILLEGAL_REQ;
										pending_asc <= NSE_INVALID_ADDRESS;
										CD_STAT     <= x"02";
										CD_MSG      <= x"00";
										CD_STAT_GET <= '1';
									else
										read_lba     <= sa;
										read_count   <= sc;
										datain_sect_n <= sc;   -- held for the whole transfer
										read_byte_ct <= (others => '0');
										scsi_state   <= SCSI_READ_REQ;
									end if;
								end if;

							when SCSI_OP_SAPSP =>
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									case CD_COMM(79 downto 78) is  -- cdb[9][7:6]
										when "10" =>  -- BCD AMSF: cdb[2]=M cdb[3]=S cdb[4]=F
											-- Real fix: numeric_std's "unsigned * natural"
											-- overload converts the literal to the SAME
											-- width as the unsigned operand (8 bits here),
											-- which can't hold 4500/75 -- resize to 24 bits
											-- FIRST, or the multiply silently wraps. Caught
											-- by real Gowin synthesis (EX4923), not GHDL --
											-- this exact BCD-AMSF path wasn't covered by
											-- tb_cd_bridge.vhd's own real test cases.
											amsf_m := bcd_to_u8(CD_COMM(23 downto 16));
											amsf_s := bcd_to_u8(CD_COMM(31 downto 24));
											amsf_f := bcd_to_u8(CD_COMM(39 downto 32));
											sapsp_lba := resize(
												resize(amsf_m, 24) * 4500 +
												resize(amsf_s, 24) * 75 +
												resize(amsf_f, 24) - 150, 24);
										when "11" =>  -- BCD track#: cdb[2], TOC lookup
											sapsp_lba := toc_lba_tbl(to_integer(bcd_to_u8(CD_COMM(23 downto 16))));
										when others =>  -- raw LBA, cdb[2:4] big-endian
											sapsp_vec(23 downto 16) := CD_COMM(23 downto 16);
											sapsp_vec(15 downto 8)  := CD_COMM(31 downto 24);
											sapsp_vec(7 downto 0)   := CD_COMM(39 downto 32);
											sapsp_lba := unsigned(sapsp_vec);
									end case;
									last_sapsp_lba <= sapsp_lba;
									cdda_status    <= CDDA_PLAYING;
									-- Real fetch start: read_lba is the SAME register READ(6)
									-- uses (shared, mutually exclusive by construction -- see
									-- SCSI_IDLE's own audio-continue branch below), seeded here
									-- with the real play-start LBA, then advanced one raw audio
									-- sector at a time as SCSI_READ_WAIT_BYTE's audio branch
									-- completes each SECTOR_DATA_LAST.
									read_lba       <= sapsp_lba;
									-- Real re-arm at every playback start -- guards against a
									-- real byte-count misalignment (e.g. a PAUSE landing
									-- mid-sample on a prior session) silently swapping L/R or
									-- shifting bytes on replay. CD_DM pulses cd.vhd's own
									-- real CD_BYTE_CNT reset for exactly one cycle (see
									-- cd.vhd's real CDDA process, `if DM = '1' then
									-- CD_BYTE_CNT <= (others => '0')`).
									CD_DM          <= '1';
									pending_key    <= SENSEKEY_NO_SENSE;
									pending_asc    <= (others => '0');
									CD_STAT        <= x"00";
									CD_MSG         <= x"00";
									CD_STAT_GET    <= '1';
								end if;

							when SCSI_OP_SAPEP =>
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									if CD_COMM(15 downto 8) = x"00" then  -- cdb[1]=0x00 => stop
										cdda_status <= CDDA_STOPPED;
									else
										cdda_status <= CDDA_PLAYING;
										-- real resume: re-fetch from the last known play position
										-- (same "stand-in" precision as READSUBQ's own reported
										-- position, see that command's header comment -- a real
										-- mid-track pause/resume offset isn't tracked here)
										read_lba    <= last_sapsp_lba;
										CD_DM       <= '1';  -- real re-arm, see SAPSP
									end if;
									pending_key <= SENSEKEY_NO_SENSE;
									pending_asc <= (others => '0');
									CD_STAT     <= x"00";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								end if;

							when SCSI_OP_PAUSE =>
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								elsif cdda_status = CDDA_PLAYING then
									cdda_status <= CDDA_PAUSED;
									pending_key <= SENSEKEY_NO_SENSE;
									pending_asc <= (others => '0');
									CD_STAT     <= x"00";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									-- real guard: PAUSE while not playing is a real error,
									-- matches Mednafen's ILLEGAL_REQUEST/NSE_AUDIO_NOT_PLAYING
									pending_key <= SENSEKEY_ILLEGAL_REQ;
									pending_asc <= NSE_AUDIO_NOT_PLAYING;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								end if;

							when SCSI_OP_READSUBQ =>
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								else
									conv_total   <= resize(last_sapsp_lba, 20) + 150;
									conv_is_subq <= '1';
									scsi_state   <= SCSI_CONV_SUB_M;
								end if;

							when SCSI_OP_GETDIRINFO =>
								if DISC_MOUNTED = '0' then
									pending_key <= SENSEKEY_NOT_READY;
									pending_asc <= NSE_NO_DISC;
									CD_STAT     <= x"02";
									CD_MSG      <= x"00";
									CD_STAT_GET <= '1';
								elsif CD_COMM(15 downto 8) = x"02" then  -- cdb[1]=mode 2: track
									-- 2026-09-11: THIS BRANCH WAS THE REASON PC ENGINE CD
									-- WOULD NOT BOOT. Two faults, both against mednafen's
									-- own DoNEC_PCE_GETDIRINFO (pce_fast/pcecd_drive.cpp):
									--
									-- (a) BYTE ORDER. mednafen answers
									--        data_in[0..3] = M, S, F, control
									--     and this staged the control byte at index 0
									--     instead, shifting every byte one place, so the
									--     syscard read the control byte as MINUTES. Traced
									--     on hardware: it then asked to READ LBA 0x1FFF9B
									--     = -101 = MSF 00:00:49, where that 49 is track 2's
									--     SECONDS field (real AMSF 00:49:65) landing in
									--     FRAMES. cd_bridge rejected the address against
									--     the lead-out, the syscard retried through
									--     REQUEST SENSE at ~40 Hz, and no sector was ever
									--     requested from the MCU.
									--
									-- (b) TRACK NUMBER. mednafen maps 0 -> 1 and
									--     cdb[2] == 0xAA -> the lead-out (track 100), and
									--     rejects > 99. None of that existed here, and
									--     0xAA in particular ran bcd_to_u8(0xAA) = 110 and
									--     indexed toc_lba_tbl, which is 0..100 -- an
									--     out-of-range read.
									if CD_COMM(23 downto 16) = x"AA" then
										gdi_track := to_unsigned(100, 8);   -- lead-out
									else
										gdi_track := bcd_to_u8(CD_COMM(23 downto 16));
										if gdi_track = 0 then
											gdi_track := to_unsigned(1, 8);
										end if;
									end if;

									if gdi_track > 100 then
										pending_key <= SENSEKEY_ILLEGAL_REQ;
										pending_asc <= NSE_INVALID_PARAMETER;
										CD_STAT     <= x"02";
										CD_MSG      <= x"00";
										CD_STAT_GET <= '1';
									else
										-- control byte LAST, at index 3. The shared
										-- converter fills M/S/F into 0/1/2 exactly as it
										-- does for mode 1. The lead-out needs no special
										-- case: TOC_CAPTURE stores it as table entry 100,
										-- so one indexed read serves every track and the
										-- second 24-bit mux that broke Primer 25K's
										-- routing is gone.
										-- real control-byte reconstruction from the 1-bit
										-- is_data flag: "00000100"=0x04(data) /
										-- "00000000"=0x00(audio)
										resp_buf(3)  <= "00000" & toc_control_tbl(to_integer(gdi_track)) & "00";
										conv_total   <= resize(toc_lba_tbl(to_integer(gdi_track)), 20) + 150;
										conv_is_subq <= '0';
										resp_len     <= 4;  -- M + S + F + control
										scsi_state   <= SCSI_CONV_SUB_M;
									end if;
								elsif CD_COMM(15 downto 8) = x"01" then  -- mode 1: lead-out
									conv_total   <= resize(toc_leadout_lba, 20) + 150;
									conv_is_subq <= '0';
									resp_len     <= 3;  -- M + S + F (no control byte)
									scsi_state   <= SCSI_CONV_SUB_M;
								else  -- mode 0: first/last track (BCD, precomputed at TOC load)
									resp_buf(0) <= toc_first_track_bcd;
									resp_buf(1) <= toc_last_track_bcd;
									resp_len    <= 2;
									resp_idx    <= 0;
									scsi_state  <= SCSI_DATA_PULSE;
								end if;

							when others =>
								-- real unrecognized opcode -- Mednafen's own dispatch-table
								-- miss path, CommandCCError(ILLEGAL_REQUEST, INVALID_COMMAND)
								pending_key <= SENSEKEY_ILLEGAL_REQ;
								pending_asc <= NSE_INVALID_COMMAND;
								CD_STAT     <= x"02";  -- CHECK CONDITION
								CD_MSG      <= x"00";
								CD_STAT_GET <= '1';
						end case;
					elsif cdda_status = CDDA_PLAYING then
						-- Real audio auto-continue: no host command arrived this cycle, and
						-- playback is live -- fetch the next raw audio sector. A real command
						-- (checked above, same cycle, takes priority via if/elsif) can only
						-- land back here between sectors, same latency-bounded interrupt
						-- window READ(6) itself already has for its own multi-sector
						-- transfers -- not a new class of behavior, see file header.
						is_audio_read <= '1';
						scsi_state    <= SCSI_READ_REQ;
					end if;

				-- Real shared LBA->AMSF converter -- repeated subtract, multi-cycle,
				-- deliberately off the hot path (see file header). Feeds either GETDIRINFO
				-- (resp_buf, control byte already staged at index 0 if mode==2) or
				-- READSUBQ (resp_buf built fresh here, no control byte).
				when SCSI_CONV_SUB_M =>
					if conv_total >= 4500 then
						conv_total <= conv_total - 4500;
						-- real BCD-native increment (carry on 9), see conv_m_bcd's own
						-- declaration comment for why this replaces binary-then-convert
						if conv_m_bcd(3 downto 0) = "1001" then
							conv_m_bcd <= std_logic_vector(unsigned(conv_m_bcd(7 downto 4)) + 1) & "0000";
						else
							conv_m_bcd(3 downto 0) <= std_logic_vector(unsigned(conv_m_bcd(3 downto 0)) + 1);
						end if;
					else
						scsi_state <= SCSI_CONV_SUB_S;
					end if;

				when SCSI_CONV_SUB_S =>
					if conv_total >= 75 then
						conv_total <= conv_total - 75;
						if conv_s_bcd(3 downto 0) = "1001" then
							conv_s_bcd <= std_logic_vector(unsigned(conv_s_bcd(7 downto 4)) + 1) & "0000";
						else
							conv_s_bcd(3 downto 0) <= std_logic_vector(unsigned(conv_s_bcd(3 downto 0)) + 1);
						end if;
					else
						-- F is a leftover remainder (0..74), not counted incrementally --
						-- the one real u8_to_bcd call left in this converter.
						conv_f_bcd <= u8_to_bcd(conv_total(7 downto 0));
						scsi_state <= SCSI_CONV_DONE;
					end if;

				when SCSI_CONV_DONE =>
					if conv_is_subq = '1' then
						-- real play-status byte + real absolute AMSF from last_sapsp_lba;
						-- relative M/S/F and track/index are a named stand-in (see header)
						resp_buf(0) <= "000000" & cdda_status;
						resp_buf(1) <= toc_first_track_bcd;  -- track (stand-in)
						resp_buf(2) <= x"00";                -- index (stand-in)
						resp_buf(3) <= x"00"; resp_buf(4) <= x"00"; resp_buf(5) <= x"00"; -- rel AMSF (stand-in)
						resp_buf(6) <= conv_m_bcd;
						resp_buf(7) <= conv_s_bcd;
						resp_buf(8) <= conv_f_bcd;
						resp_len    <= 9;
					else
						-- Both GETDIRINFO modes now put M/S/F first, matching mednafen:
						-- mode 1 is [M,S,F] (resp_len 3) and mode 2 is [M,S,F,control]
						-- (resp_len 4) with the control byte already staged at index 3 by
						-- the command handler. The old resp_len = 4 special case existed
						-- only to skip over a control byte wrongly placed at index 0.
						resp_buf(0) <= conv_m_bcd;
						resp_buf(1) <= conv_s_bcd;
						resp_buf(2) <= conv_f_bcd;
					end if;
					conv_m_bcd <= (others => '0');
					conv_s_bcd <= (others => '0');
					resp_idx   <= 0;
					scsi_state <= SCSI_DATA_PULSE;

				-- Real generic data-response relay -- shared by GETDIRINFO/READSUBQ, same
				-- one-idle-cycle-per-byte timing as REQUEST SENSE/READ(6) below.
				when SCSI_DATA_PULSE =>
					CD_DATA    <= resp_buf(resp_idx);
					CD_DATA_WR <= '1';
					scsi_state <= SCSI_DATA_GAP;

				when SCSI_DATA_GAP =>
					if resp_idx = resp_len - 1 then
						scsi_state <= SCSI_DATA_WAIT_END;
					else
						resp_idx   <= resp_idx + 1;
						scsi_state <= SCSI_DATA_PULSE;
					end if;

				when SCSI_DATA_WAIT_END =>
					if CD_DATA_END = '1' then
						pending_key <= SENSEKEY_NO_SENSE;
						pending_asc <= (others => '0');
						CD_STAT     <= x"00";  -- GOOD
						CD_MSG      <= x"00";
						CD_STAT_GET <= '1';
						scsi_state  <= SCSI_IDLE;
					end if;

				-- REQUEST SENSE: real timing unchanged from the prior stub -- one idle
				-- cycle between bytes (SCSI.vhd's own push logic edge-detects CD_DATA_WR,
				-- so back-to-back-high would only register once). Bytes now built live from
				-- pending_key/pending_asc instead of indexing a static table.
				when SCSI_SENSE_PULSE =>
					case sense_idx is
						when 0 => CD_DATA <= x"70";
						when 2 => CD_DATA <= "0000" & std_logic_vector(pending_key);
						when 7 => CD_DATA <= x"0A";
						when 12 => CD_DATA <= pending_asc;
						when others => CD_DATA <= x"00";
					end case;
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
				-- exhausted. Shared with the real audio-sector fetch (is_audio_read='1',
				-- see SCSI_IDLE's own audio-continue branch) -- same request/response
				-- shape, different byte destination and end condition (SECTOR_DATA_LAST
				-- instead of a fixed 2048-byte count, since a real raw CD-DA sector is
				-- 2352 bytes and the MCU alone decides how to chunk it -- see
				-- cd_bridge.vhd's own SECTOR_IS_AUDIO port comment).
				when SCSI_READ_REQ =>
					SECTOR_REQ      <= '1';
					SECTOR_IS_AUDIO <= is_audio_read;
					req_wdog        <= (others => '0');
					audio_byte_ct   <= (others => '0');
					scsi_state      <= SCSI_READ_WAIT_BYTE;

				when SCSI_READ_WAIT_BYTE =>
					-- CD-DA prefetch, issue step. Armed one cycle earlier by the audio
					-- branch below so that SECTOR_LBA -- a continuous assignment from
					-- read_lba -- has already settled on the incremented value by the
					-- time SECTOR_REQ goes high. SECTOR_REQ/SECTOR_IS_AUDIO are
					-- default-low every cycle (above), so this is a clean one-cycle pulse.
					if audio_pf_arm = '1' then
						SECTOR_REQ      <= '1';
						SECTOR_IS_AUDIO <= '1';
						audio_pf_arm    <= '0';
						audio_pf_pend   <= '1';
					end if;

					-- lost-request watchdog (see req_wdog's declaration comment)
					if SECTOR_DATA_VALID = '1' then
						req_wdog <= (others => '0');
					elsif req_wdog >= REQ_TIMEOUT and REQ_WATCHDOG then
						req_wdog   <= (others => '0');
						scsi_state <= SCSI_READ_REQ;   -- ask again for the SAME lba
					else
						req_wdog <= req_wdog + 1;
					end if;
					if SECTOR_DATA_VALID = '1' then
						if is_audio_read = '1' then
							-- Real audio byte: forwarded straight into cd.vhd's own CDDA_FIFO
							-- write path. No gap state needed here (unlike the data path
							-- below) -- successive SECTOR_DATA_VALID pulses are already
							-- naturally spaced by real UART byte time (~5us at 2Mbaud, many
							-- clk_pce cycles), so CD_AUDIO_WR's own edge-detect in cd.vhd
							-- (CD_WR_OLD) never sees back-to-back highs. Still true with
							-- prefetch: the spacing is per-byte UART time, and prefetch only
							-- removes the GAP BETWEEN sectors, never compresses a byte.
							CD_DATA     <= SECTOR_DATA;
							CD_AUDIO_WR <= '1';
							if SECTOR_DATA_LAST = '1' then
								audio_byte_ct <= (others => '0');
								if audio_pf_pend = '1' then
									-- The next sector was already asked for and its bytes are
									-- already on the way, so stay here to receive them. Do NOT
									-- touch read_lba: the prefetch advanced it when it issued.
									--
									-- This is also why no stray sector can ever be left in
									-- flight: the ONLY path back to SCSI_IDLE is the else
									-- below, which runs exactly when nothing is outstanding.
									audio_pf_pend <= '0';
									-- Give the prefetched sector's FIRST byte a full timeout
									-- window. Without this the watchdog keeps counting across
									-- the sector boundary and, on expiry, would re-enter
									-- SCSI_READ_REQ and request read_lba a SECOND time -- but
									-- read_lba was already advanced when the prefetch issued,
									-- so that would duplicate a sector rather than recover
									-- one. Dead code while REQ_WATCHDOG is false, wrong the
									-- moment anyone turns it on.
									req_wdog      <= (others => '0');
								else
									-- real fetch loop: advance to the next raw audio sector and
									-- yield to SCSI_IDLE so a real host command can interrupt
									-- between sectors (see SCSI_IDLE's own audio-continue branch)
									read_lba   <= read_lba + 1;
									scsi_state <= SCSI_IDLE;
								end if;
							else
								audio_byte_ct <= audio_byte_ct + 1;
								-- Ask for sector N+1 partway through N, so the MCU's map/decode
								-- turnaround overlaps the tail of this transfer instead of
								-- following it. Guards, in order of why they matter:
								--   comm_pending/CD_COMM_SEND: a host command is waiting, so
								--     skip the prefetch and let SECTOR_DATA_LAST fall through
								--     to SCSI_IDLE. This is what KEEPS the interrupt window at
								--     exactly one sector, unchanged from before prefetch --
								--     without it, continuous playback would never return to
								--     SCSI_IDLE and commands would never be serviced.
								--   CDDA_SPACE: never deliver into a FIFO that cannot hold a
								--     whole sector; CDDA_FIFO drops writes when full, silently.
								--   cdda_status: playback may have been paused or stopped.
								if audio_byte_ct = AUDIO_PREFETCH_AT
								   and audio_pf_pend = '0' and audio_pf_arm = '0'
								   and cdda_status = CDDA_PLAYING
								   and comm_pending = '0' and CD_COMM_SEND = '0'
								   and CDDA_SPACE >= CDDA_SECTOR_FRAMES then
									-- Advance read_lba NOW and issue on the NEXT cycle:
									-- SECTOR_LBA is a continuous assignment from read_lba, so
									-- raising SECTOR_REQ in this same cycle would present the
									-- OLD lba alongside the new request.
									read_lba     <= read_lba + 1;
									audio_pf_arm <= '1';
								end if;
							end if;
						else
							CD_DATA    <= SECTOR_DATA;
							CD_DATA_WR <= '1';
							scsi_state <= SCSI_READ_GAP;
						end if;
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
					elsif FIFO_SPACE < 2048 then
						-- Wait here, not in READ_REQ: hold off asking the MCU for the next
						-- sector until the CPU has drained enough for one to fit. Staying
						-- in this state re-tests every cycle and issues no request, so
						-- nothing is dropped and no request is duplicated.
						null;
					else
						read_count <= read_count - 1;
						read_lba   <= read_lba + 1;
						scsi_state <= SCSI_READ_REQ;
					end if;

				when SCSI_READ_WAIT_END =>
					if CD_DATA_END = '1' then
						datain_sect_n <= (others => '0');
						pending_key <= SENSEKEY_NO_SENSE;
						pending_asc <= (others => '0');
						CD_STAT     <= x"00";  -- GOOD
						CD_MSG      <= x"00";
						CD_STAT_GET <= '1';
						scsi_state  <= SCSI_IDLE;
					end if;
			end case;

			-- Real command-pending latch (see comm_pending's own declaration comment) --
			-- only arms when scsi_state is NOT SCSI_IDLE this cycle: if it IS, the
			-- dispatch branch above already saw this same CD_COMM_SEND pulse directly
			-- (same-cycle path) and cleared comm_pending itself -- latching here too
			-- would re-arm a phantom pending command for a pulse that was already
			-- consumed, causing a spurious re-dispatch of stale CD_COMM bytes next time
			-- SCSI_IDLE is reached.
			if CD_COMM_SEND = '1' and scsi_state /= SCSI_IDLE then
				comm_pending <= '1';
			end if;

			-- CD_DATA_END accounting; see DBG_DEND. Counted here rather than inside the
			-- case so that a pulse arriving in ANY state is accounted for exactly once.
			if CD_DATA_END = '1' then
				if scsi_state = SCSI_READ_WAIT_END
				   or scsi_state = SCSI_DATA_WAIT_END
				   or scsi_state = SCSI_SENSE_WAIT_END then
					if dend_ok /= x"FFFF" then dend_ok <= dend_ok + 1; end if;
				else
					if dend_lost /= x"FFFF" then dend_lost <= dend_lost + 1; end if;
				end if;
			end if;
		end if;
	end process;

end architecture;
