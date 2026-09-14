-- Modifications copyright (c) 2026 Romain Tisserand.
-- This file is derived from third-party code and is NOT original work of
-- this project; only the changes made here are covered by the line above.
-- See THIRD_PARTY_LICENSES.md for the upstream project, author and licence.
library STD;
use STD.TEXTIO.ALL;
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_TEXTIO.all;
use IEEE.NUMERIC_STD.ALL;

entity SCSI is
	port(
		RESET_N		: in std_logic;
		CLK 			: in std_logic;
		
		DBI			: in std_logic_vector(7 downto 0);
		DBO			: out std_logic_vector(7 downto 0);
		SEL_N			: in std_logic;
		ACK_N			: in std_logic;
		RST_N			: in std_logic;
		BSY_N			: out std_logic;
		REQ_N			: out std_logic;
		MSG_N			: out std_logic;
		CD_N			: out std_logic;
		IO_N			: out std_logic;
		
		STATUS		: in std_logic_vector(7 downto 0);
		MESSAGE		: in std_logic_vector(7 downto 0);
		STAT_GET		: in std_logic;
		
		COMMAND		: out std_logic_vector(95 downto 0);
		COMM_SEND	: out std_logic;
		
		DOUT_REQ		: in std_logic;
		DOUT			: out std_logic_vector(79 downto 0);
		DOUT_SEND	: out std_logic;
		
		CD_DATA		: in std_logic_vector(7 downto 0);
		CD_WR			: in std_logic;
		CD_DATA_END	: out std_logic;
		-- Expected sector count for the CURRENT DATA-IN transfer, driven by cd_bridge from
		-- the READ(6) CDB. 0 = unknown (short replies: GETDIRINFO, REQUEST SENSE, READSUBQ),
		-- which keeps the original "response ends when the FIFO runs dry" rule.
		--
		-- WHY THIS EXISTS (2026-09-14, real bug, reproduced in simulation). CD_DATA_END
		-- used to be pulsed at ANY sector boundary where the FIFO happened to be empty,
		-- and cd_bridge enters SCSI_READ_WAIT_END as soon as the last sector has been
		-- WRITTEN into the FIFO -- not when the CPU has drained it. So a boundary pulse
		-- inside that window was consumed as end-of-command: GOOD status, MESSAGE IN, BUS
		-- FREE, all while the CPU was still mid-transfer. The system card's fast loop reads
		-- 2048 bytes BLINDLY without polling per byte, so it then read a dead bus ($1808
		-- returns SCSI_DBI = 0xFF once BSY drops) and hung.
		--
		-- Only visible with realistic memory latency: with CD-RAM and ROM stalling every
		-- CPU access the CPU drains far slower than the MCU fills, so the window is huge.
		-- With ideal zero-wait memory the CPU keeps pace and it almost never happens, which
		-- is why every earlier simulation passed.
		DATAIN_SECTORS : in unsigned(8 downto 0) := (others => '0');
		STOP_CD_SND	: out std_logic;
		
		DBG_DATAIN_CNT: out unsigned(15 downto 0);
		-- CPU-side view of the DATA-IN stream, to tell "the bytes we fed in were
		-- wrong" apart from "the CPU never took them". DBG_FIRST8 is the first 8
		-- bytes the CPU actually ACKed after a READ(6), DBG_SP the live phase state.
		DBG_FIRST8    : out std_logic_vector(63 downto 0);
		DBG_SP        : out std_logic_vector(3 downto 0);
		-- Same idea for the GETDIRINFO replies: the boot issues several back to back and
		-- the divergence from a reference trace happens there, so append (never reset per
		-- command) the first 16 bytes the CPU takes for any 0xDE.
		-- Free space in the DATA-IN FIFO, so cd_bridge can throttle instead of
		-- overrunning it (bytes written while full are dropped, see cd_fifos.vhd).
		-- Command-phase state. Distinguishes a REAL command that stalls part-way from a
		-- PHANTOM selection: any write to $1800 asserts SEL and SP_FREE takes that as a
		-- selection without checking the data bus for a target ID, so a routine that
		-- clears $1800-$1807 starts a command phase nobody intended.
		DBG_COMM_POS  : out unsigned(3 downto 0);
		DBG_COMM0     : out std_logic_vector(7 downto 0);
		DBG_COMM1     : out std_logic_vector(7 downto 0);
		DBG_SEL_CNT   : out unsigned(15 downto 0);
		DBG_FIFO_SPACE: out unsigned(12 downto 0);
		DBG_FIFO_DROPS: out unsigned(15 downto 0);
		DBG_GDI       : out std_logic_vector(127 downto 0);
		-- Cumulative, reset only on RESET_N -- unlike DATAIN_CNT, which restarts on every
		-- SELECT, so only this one can show bytes left stranded in the FIFO across commands.
		DBG_RD_TOTAL  : out unsigned(15 downto 0);
		-- DATA IN bursts that ended anywhere other than a 2048-byte boundary, i.e. the
		-- FIFO ran dry mid-burst and the CPU reread a stale DBO. See BURST_RDY. This must
		-- be observable on HARDWARE, not just in simulation: "the game still does not boot"
		-- and "the sector gate is not working" are otherwise indistinguishable, and that
		-- distinction is the whole point of the gate.
		DBG_UNDERRUNS : out unsigned(15 downto 0)
	);
end SCSI;

architecture rtl of SCSI is
	
	type SCSIPhase_t is (
		SP_FREE,
		SP_COMM_BEFOREREQ,
		SP_COMM_START,
		SP_COMM_END,
		SP_STAT_START,
		SP_STAT_END,
		SP_STAT_HOLD,
		SP_MSGIN_START,
		SP_MSGIN_END,
		SP_MSGIN_HOLD,
		SP_DATAIN_START,
		SP_DATAIN_END,
		SP_DATAOUT_START,
		SP_DATAOUT_END
	);
	signal SP 			: SCSIPhase_t; 
	
	signal BSY_Nr 		: std_logic;
	signal MSG_Nr 		: std_logic;
	signal CD_Nr 		: std_logic;
	signal IO_Nr 		: std_logic;
	signal REQ_Nr 		: std_logic;
--	signal TR_DONE		: std_logic;
--	signal TR_RDY		: std_logic;
	
	type CommBuf_t is array (0 to 11) of std_logic_vector(7 downto 0);
	signal COMM 		: CommBuf_t;
	signal COMM_POS 	: unsigned(3 downto 0);
	signal COMM_OUT 	: std_logic;
	type CommLen_t is array (0 to 15) of unsigned(3 downto 0);
	constant COMM_LEN : CommLen_t :=
	("0110", "0110", "1010", "1010", "1010", "1010", "1010", "1010", "1010", "1010", "1100", "1100", "1010", "1010", "1010", "1010"); 

	type DataBuf_t is array (0 to 9) of std_logic_vector(7 downto 0);
	signal DATA_BUF 	: DataBuf_t;
	signal DATA_POS	: unsigned(3 downto 0);
	signal DATA_OUT	: std_logic;
	
	signal FULL 		: std_logic;
	signal EMPTY		: std_logic;
	signal FIFO_RD_REQ: std_logic;
	signal FIFO_WR_REQ: std_logic;
	signal FIFO_D 		: std_logic_vector(7 downto 0);
	signal FIFO_Q 		: std_logic_vector(7 downto 0);
	signal CD_WR_OLD 	: std_logic;
	signal STAT_PEND 	: std_logic;
	signal DOUT_PEND  : std_logic;
	
	signal DATAIN_CNT 	: unsigned(15 downto 0);
	-- Sectors the CPU has fully ACKed in the current DATA-IN transfer. Counting SECTORS
	-- rather than bytes on purpose: a READ(6) can ask for 32 sectors (the reference boot
	-- does -- `08 00 10 1f 20 00`), which is 65536 bytes and overflows DATAIN_CNT's 16 bits.
	signal DATAIN_SECT	: unsigned(8 downto 0);

	signal SEL_COUNT     : unsigned(15 downto 0) := (others => '0');
	signal SEL_N_R       : std_logic := '1';
	signal FIFO_DROPS    : unsigned(15 downto 0);
	signal FIFO_LEVEL    : unsigned(12 downto 0);
	signal FIFO_Q_D1     : std_logic_vector(7 downto 0);
	signal DBG_GDI_ARM   : std_logic;
	signal DBG_GDI_POS   : unsigned(4 downto 0);
	signal DBG_GDI_BUF   : std_logic_vector(127 downto 0);
	signal DBG_RD_CNT    : unsigned(15 downto 0);
	signal DBG_ARM       : std_logic;
	signal DBG_POS       : unsigned(3 downto 0);
	signal DBG_BUF       : std_logic_vector(63 downto 0);

	signal STAT_COUNT    : unsigned(15 downto 0);
	signal DELAY_COUNT   : unsigned(16 downto 0);

	-- ------------------------------------------------------------------------------
	-- SECTOR BUFFERING. A real PCE CD drive buffers a whole sector and only then hands it
	-- over, and the system card depends on that completely: an instrumented mednafen run
	-- of a working boot reads $1808 63488 times in exactly 31 bursts of 2048 CONSECUTIVE
	-- reads, with no other register access anywhere inside a burst. It never rechecks REQ,
	-- DTR, or anything else once a burst starts.
	--
	-- That is fatal to a target that streams. $1808 reads return SCSI_DBO combinationally
	-- (cd.vhd) and nothing on the CD register page can stall the CPU -- WAIT_N comes only
	-- from ROM_RDY/CD_RAM_RDY. So if the FIFO runs dry mid-burst, SP_DATAIN_END drops to
	-- SP_FREE and the CPU keeps reading the SAME stale DBO until data returns: bytes are
	-- silently duplicated, the CPU's 2048 reads no longer correspond to 2048 delivered
	-- bytes, and every following sector is shifted. Our bytes arrive from the MCU at ~5 us
	-- each against a CPU that reads one per ~1 us, so the FIFO runs dry on essentially
	-- every sector. None of this is visible to a first-8-bytes check, which is how the
	-- data path was previously declared byte-identical to the reference.
	--
	-- So do not begin a DATA IN burst until the whole response is buffered. Two cases:
	--   * a sector is 2048 bytes, and cd_bridge's back-pressure only pauses BETWEEN
	--     sectors (FIFO_SPACE < 2048), so the level always reaches 2048 for real reads;
	--   * short responses (GETDIRINFO 2-4 bytes, REQUEST SENSE 18) are written back to
	--     back, one idle cycle per byte, so once the writes stop the response is complete.
	-- IDLE_MAX separates the two: 8192 cycles is ~191 us at 42.9 MHz, far longer than the
	-- ~5 us between streamed bytes, and the MCU's ~100 us per-sector decode stall happens
	-- while the FIFO is EMPTY, which this gate excludes. A burst already under way never
	-- re-checks any of this -- SP_DATAIN_END loops straight back to SP_DATAIN_START -- so
	-- this can only ever delay the START of a burst, never interrupt one.
	constant IDLE_MAX    : unsigned(14 downto 0) := to_unsigned(8192, 15);
	signal FIFO_IDLE     : unsigned(14 downto 0);
	signal BURST_RDY     : std_logic;
	-- Bursts that ran dry anyway, i.e. the gate failed. Should stay 0.
	signal UNDERRUNS     : unsigned(15 downto 0);

begin

	process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
			FIFO_D <= (others => '0');
			FIFO_WR_REQ <= '0';
			--CD_WR_OLD <= '0';
		elsif rising_edge(CLK) then
			FIFO_WR_REQ <= '0';
--			if EN = '1' then
				CD_WR_OLD <= CD_WR;
				if CD_WR = '1' and CD_WR_OLD = '0' then
					FIFO_D <= CD_DATA;
					if FULL = '0' then
						FIFO_WR_REQ <= '1';
					end if;
				end if;
--			end if;
		end if;
	end process;

	
	FIFO : entity work.SCSI_FIFO 
	port map(
		aclr     => not RESET_N,

		wrclk		=> CLK,
		data		=> FIFO_D,
		wrreq		=> FIFO_WR_REQ,
		wrfull	=> FULL,
		
		rdclk		=> CLK,
		rdreq		=> FIFO_RD_REQ,
		rdempty	=> EMPTY,
		q			=> FIFO_Q,
		dbg_drops => FIFO_DROPS,
		dbg_level => FIFO_LEVEL
	);

	process( CLK, RESET_N ) begin
		if RESET_N = '0' then
			DBO <= (others => '0');
			BSY_Nr <= '1';
			MSG_Nr <= '1';
			CD_Nr <= '1';
			IO_Nr <= '1';
			REQ_Nr <= '1';
			COMM <= (others => (others => '0'));
			COMM_POS <= (others => '0');
			DATA_BUF <= (others => (others => '0'));
			DATA_POS <= (others => '0');
			SP <= SP_FREE;
			STOP_CD_SND <= '0';
			
			COMM_OUT <= '0';
			DATA_OUT <= '0';
			CD_DATA_END <= '0';
			STAT_PEND <= '0';
			DOUT_PEND <= '0';
			FIFO_RD_REQ <= '0';
			
			STAT_COUNT  <= (others => '0');
			DELAY_COUNT <= (others => '0');
			
			DATAIN_CNT  <= (others => '0');
			DATAIN_SECT <= (others => '0');
			FIFO_IDLE   <= (others => '0');
			UNDERRUNS   <= (others => '0');

		elsif rising_edge( CLK ) then
			-- Cycles since the last byte was pushed into the DATA IN FIFO. Saturates, so
			-- it is a "has been quiet for a while" flag rather than a wrapping counter.
			if FIFO_WR_REQ = '1' then
				FIFO_IDLE <= (others => '0');
			elsif FIFO_IDLE < IDLE_MAX then
				FIFO_IDLE <= FIFO_IDLE + 1;
			end if;

			if STAT_GET = '1' then
				STAT_PEND <= '1';
			end if;
			
			if DOUT_REQ = '1' then
				DOUT_PEND <= '1';
			end if;
			

			COMM_OUT <= '0';
			DATA_OUT <= '0';
			CD_DATA_END <= '0';
			FIFO_RD_REQ <= '0';
			
			if RST_N = '0' then
				BSY_Nr <= '1';
				MSG_Nr <= '1';
				CD_Nr <= '1';
				IO_Nr <= '1';
				REQ_Nr <= '1';
			else
				case SP is
					when SP_FREE =>
						if SEL_N = '0' then
							BSY_Nr <= '0';
							MSG_Nr <= '1';
							CD_Nr <= '0';
							IO_Nr <= '1';
							SP <= SP_COMM_BEFOREREQ;
							DELAY_COUNT <= to_unsigned(1700, DELAY_COUNT'LENGTH);		-- Wait 40 microseconds after control signals are set up, before triggering REQ in COMMAND phase
							DATAIN_CNT  <= (others => '0');
							DATAIN_SECT <= (others => '0');
						elsif STAT_PEND = '1' then
							STAT_COUNT <= STAT_COUNT + 1;

							if (STAT_COUNT = 45000) then		-- CLK is 42.95 MHz; this gives ~1.05 millisec delay before transitioning to STATUS phase
																		-- this is empirical and may not be correct but it solves
																		-- the Sailor Moon hang issue
								STAT_COUNT <= (others => '0');
								STAT_PEND <= '0';
								DBO <= STATUS;
								BSY_Nr <= '0';
								MSG_Nr <= '1';
								CD_Nr <= '0';
								IO_Nr <= '0';
								REQ_Nr <= '0';
								SP <= SP_STAT_START;
							end if;
						elsif EMPTY = '0' and BURST_RDY = '1' then
							-- See BURST_RDY's declaration: a DATA IN burst must not start
							-- until the whole response is in the FIFO, because the CPU
							-- reads every byte of it without ever looking back.
							DBO <= FIFO_Q;
							BSY_Nr <= '0';
							MSG_Nr <= '1';
							CD_Nr <= '1';
							IO_Nr <= '0';
							REQ_Nr <= '0';
							FIFO_RD_REQ <= '1';
							SP <= SP_DATAIN_START;
						elsif DOUT_PEND = '1' then
							DOUT_PEND <= '0';
							BSY_Nr <= '0';
							MSG_Nr <= '1';
							CD_Nr <= '1';
							IO_Nr <= '1';
							REQ_Nr <= '0';
							SP <= SP_DATAOUT_START;
						end if;
						
					when SP_COMM_BEFOREREQ =>
						if (DELAY_COUNT = 0) then
							REQ_Nr <= '0';
							SP <= SP_COMM_START;
						else
							DELAY_COUNT <= DELAY_COUNT - 1;
						end if;

					when SP_COMM_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							COMM(to_integer(COMM_POS)) <= DBI;
							COMM_POS <= COMM_POS + 1;
							SP <= SP_COMM_END;
						end if;
					
					when SP_COMM_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							if COMM_POS = COMM_LEN(to_integer(unsigned(COMM(0)(7 downto 4)))) then
								COMM_POS <= (others => '0');
								COMM_OUT <= '1';
								-- CD_Nr DELIBERATELY LEFT ASSERTED (2026-09-12).
								--
								-- The donor cleared it here, which drops every phase line
								-- while BSY stays asserted. MSG=CD=IO all deasserted is not
								-- a neutral state -- it is DATA OUT. So the CPU reads $1800
								-- as 0x80, i.e. "drive is in DATA OUT phase, REQ not yet
								-- asserted", and it reads that for as long as the target
								-- takes to produce the first byte. A real boot never enters
								-- DATA OUT at all (neither 0x80 nor 0xC0 ever appears).
								--
								-- An instrumented mednafen run of a CD boot that reaches the
								-- title screen reads $1800 94477 times and NEVER ONCE sees
								-- 0x80. The only values that occur are 00, 88, 90, 98, b8,
								-- c8, d0, d8, f8 -- BUS FREE plus COMMAND, DATA IN, STATUS
								-- and MESSAGE IN, each with and without REQ. Its two
								-- dominant values are exactly the two
								-- busy-waits: 0x90 (BSY|CD, 50583 reads) waiting for the
								-- drive to answer a command, and 0x88 (BSY|IO, 43649 reads)
								-- waiting for the next data byte. So the reference holds
								-- COMMAND phase across the whole seek, and we announced an
								-- unassigned phase instead.
								--
								-- Why it matters here and not on MiSTer, running this same
								-- donor code: there the sector comes from SDRAM in
								-- microseconds, so the illegal window is invisible. Our
								-- sectors come from the MCU over a 2 Mbaud UART, ~10 ms per
								-- sector -- a thousand times longer. Nothing else changes:
								-- every SP_FREE branch sets all four lines explicitly when
								-- it picks the next phase, and cd.vhd's CD_DTR/CD_DTD and
								-- ADPCM-DMA conditions all test REQ together with the phase
								-- lines, so none of them can trigger during the wait.
								SP <= SP_FREE;
								if ((COMM(0) = x"08") or (COMM(0) = x"DA")) then	-- READ6 and PAUSE commands should mute sound, but still drain FIFO
									STOP_CD_SND <= '1';
								end if;
								if ((COMM(0) = x"D8") or (COMM(0) = x"D9")) then	-- SAPSP and SAPEP commands should unmute sound (FIFO should be empty by now)
									STOP_CD_SND <= '0';
								end if;
							else
								SP <= SP_COMM_BEFOREREQ;
								DELAY_COUNT <= to_unsigned(5370, DELAY_COUNT'LENGTH);	-- Wait 125 microseconds after ACK, before next REQ in COMMAND phase
							end if;
						end if;

					when SP_STAT_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							SP <= SP_STAT_END;
						end if;
					
					when SP_STAT_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							SP <= SP_STAT_HOLD;
							DELAY_COUNT <= to_unsigned(49400, DELAY_COUNT'LENGTH);	-- wait 1.15 milliseconds after ACK in STATUS pahse before transitioning to next phase (MSGIN)
						end if;

					when SP_STAT_HOLD =>
						if (DELAY_COUNT = 0) then
							DBO <= MESSAGE;
							BSY_Nr <= '0';
							MSG_Nr <= '0';
							CD_Nr <= '0';
							IO_Nr <= '0';
							REQ_Nr <= '0';
							SP <= SP_MSGIN_START;
						else
							DELAY_COUNT <= DELAY_COUNT - 1;
						end if;
					
					when SP_MSGIN_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							SP <= SP_MSGIN_END;
						end if;
					
					when SP_MSGIN_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							SP <= SP_MSGIN_HOLD;
							DELAY_COUNT <= to_unsigned(6600, DELAY_COUNT'LENGTH);		-- wait 154 microseconds after ACK in STATUS phase before transitioning to next phase/disconnecting
						end if;

					when SP_MSGIN_HOLD =>
						if (DELAY_COUNT = 0) then
							BSY_Nr <= '1';
							MSG_Nr <= '1';
							CD_Nr <= '1';
							IO_Nr <= '1';
							REQ_Nr <= '1';
							SP <= SP_FREE;
						else
							DELAY_COUNT <= DELAY_COUNT - 1;
						end if;

					when SP_DATAIN_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							SP <= SP_DATAIN_END;
							STOP_CD_SND <= '0';		-- unmute
						end if;
					
					when SP_DATAIN_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							-- END THE BURST ON EVERY 2048-BYTE BOUNDARY for READ(6).
							--
							-- BURST_RDY only gates where a burst STARTS. Without this test a
							-- burst that began with a full sector kept going while the FIFO
							-- happened to be non-empty, ran straight through the sector
							-- boundary into the next sector's bytes, and then ended wherever
							-- the producer fell behind -- in the middle of a sector. The CPU
							-- carries on reading its 2048, gets SCSI_DBI (zeros) once BSY
							-- drops, and the sector is corrupt from that byte on.
							--
							-- Measured, against an instrumented mednafen boot of the same
							-- disc: sectors 0-4 byte-perfect, sector 5 -- the third sector of
							-- a 3-sector READ(6) -- correct to byte 90 then 1907 zeros.
							--
							-- The reference does exactly this: 31 separate bursts of exactly
							-- 2048 bytes, with $1800 polls in between, because a real drive
							-- hands over one buffered sector and stops. DATAIN_CNT resets on
							-- SELECT, so bit 10..0 = all ones is the 2048th byte of a sector.
							-- A READ(6) ends when the CPU has ACKed every sector the CDB
							-- asked for -- NOT when the FIFO happens to run dry. See
							-- DATAIN_SECTORS' port comment for the bug that motivates this.
							if COMM(0) = x"08" and DATAIN_SECTORS /= 0
							   and DATAIN_CNT(10 downto 0) = "11111111111" then
								-- 2048th byte of a sector, and the length is known.
								if DATAIN_SECT + 1 = DATAIN_SECTORS then
									-- genuinely the last byte of the last sector
									CD_DATA_END <= '1';
									SP <= SP_FREE;
								else
									-- more sectors still owed to the CPU: pause the burst and
									-- WAIT, whether or not the FIFO is momentarily empty. The
									-- producer refills and SP_FREE restarts on BURST_RDY.
									SP <= SP_FREE;
								end if;
								DATAIN_SECT <= DATAIN_SECT + 1;
							elsif EMPTY = '0'
							   and not (COMM(0) = x"08"
							            and DATAIN_CNT(10 downto 0) = "11111111111") then
								DBO <= FIFO_Q;
								REQ_Nr <= '0';
								FIFO_RD_REQ <= '1';
								SP <= SP_DATAIN_START;
							elsif EMPTY = '0' then
								-- Sector boundary with more data still queued: PAUSE the
								-- burst, and deliberately do NOT pulse CD_DATA_END.
								--
								-- cd_bridge's SCSI_READ_WAIT_END completes the whole command
								-- on CD_DATA_END, so pulsing it at every 2048-byte boundary
								-- finishes a multi-sector READ(6) while later sectors are
								-- still streaming: GOOD status goes out early, the FIFO keeps
								-- bytes nobody asked for, and the next burst starts partway
								-- into a sector. Measured as sector 5 arriving 4 bytes late
								-- with drops=0 -- nothing was lost, the stream was misaligned.
								SP <= SP_FREE;
							else
								-- FIFO empty: the response really is over. For a sector read
								-- that means the last sector's 2048th byte; for a short reply
								-- it is whatever length the reply was.
								--
								-- NOTE: UNDERRUNS as written counts every short response as an
								-- underrun, because those legitimately end off a 2048-byte
								-- boundary. Restricted to READ(6), where 2048 is the only
								-- correct place to end.
								if COMM(0) = x"08"
								   and DATAIN_CNT(10 downto 0) /= "11111111111" then
									UNDERRUNS <= UNDERRUNS + 1;
								end if;
								-- For a READ(6) whose length is known, NEVER signal
								-- end-of-command from here. This branch means the FIFO ran
								-- dry MID-SECTOR, which is an underrun to be waited out --
								-- the producer refills and BURST_RDY restarts the burst --
								-- not the end of the transfer. Pulsing CD_DATA_END here is
								-- the same premature-completion bug the sector count was
								-- added to fix: cd_bridge may already be sitting in
								-- SCSI_READ_WAIT_END (it enters as soon as the last sector
								-- is WRITTEN) and would take it as "command complete",
								-- dropping BSY while the CPU is still reading.
								if not (COMM(0) = x"08" and DATAIN_SECTORS /= 0) then
									CD_DATA_END <= '1';
								end if;
								SP <= SP_FREE;
							end if;
							DATAIN_CNT <= DATAIN_CNT + 1;
						end if;
						
					when SP_DATAOUT_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							DATA_BUF(to_integer(DATA_POS)) <= DBI;
							DATA_POS <= DATA_POS + 1;
							SP <= SP_DATAOUT_END;
						end if;
					
					when SP_DATAOUT_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							if DATA_POS = 10 then
								DATA_POS <= (others => '0');
								DATA_OUT <= '1';
								SP <= SP_FREE;
							else
								REQ_Nr <= '0';
								SP <= SP_DATAOUT_START;
							end if;
						end if;
						
					when others => null;
				end case;
			end if;
		end if;
	end process;
	
	BSY_N <= BSY_Nr;
	MSG_N <= MSG_Nr;
	CD_N <= CD_Nr;
	IO_N <= IO_Nr;
	REQ_N <= REQ_Nr;
	
	COMMAND <= COMM(11) & COMM(10) & COMM(9) & COMM(8) & COMM(7) & COMM(6) & COMM(5) & COMM(4) & COMM(3) & COMM(2) & COMM(1) & COMM(0);
	COMM_SEND <= COMM_OUT;
	
	DOUT <= DATA_BUF(9) & DATA_BUF(8) & DATA_BUF(7) & DATA_BUF(6) & DATA_BUF(5) & DATA_BUF(4) & DATA_BUF(3) & DATA_BUF(2) & DATA_BUF(1) & DATA_BUF(0);
	DOUT_SEND <= DATA_OUT;
	
	DBG_DATAIN_CNT <= DATAIN_CNT;
	DBG_FIFO_DROPS <= FIFO_DROPS;
	DBG_COMM_POS <= COMM_POS;
	DBG_COMM0    <= COMM(0);
	DBG_COMM1    <= COMM(1);
	DBG_SEL_CNT  <= SEL_COUNT;
	DBG_FIFO_SPACE <= to_unsigned(4096, 13) - FIFO_LEVEL;
	DBG_UNDERRUNS  <= UNDERRUNS;
	-- A full sector is buffered, or -- for a command that is NOT a sector read -- the
	-- writer has gone quiet and the short response is complete.
	--
	-- The opcode test is load-bearing (2026-09-13). The first version of this gate allowed
	-- the idle path for ANY command, on the reasoning that the MCU's per-sector decode
	-- stall happens while the FIFO is empty so it could not mis-fire mid-sector. That was
	-- wrong: during the gap between two sectors of a multi-sector READ(6) the FIFO can hold
	-- a PARTIAL sector, and the idle timer then opens the gate on it. A real boot
	-- simulation caught it -- the 6th sector of the boot (LBA 3626, the third sector of a
	-- 3-sector read) arrived correct for 90 bytes and was then followed by 1907 zero bytes,
	-- which is what the CPU reads once the target has left DATA IN and released BSY
	-- ($1808 returns SCSI_DBI, not SCSI_DBO). Byte-for-byte against an instrumented
	-- mednafen boot: sectors 0-4 perfect, sector 5 wrong from byte 91.
	--
	-- READ(6) is opcode 0x08 and its response is ALWAYS 2048 bytes, so for that command the
	-- only correct condition is a full sector. Everything that answers with a short burst
	-- (GETDIRINFO 2-4 bytes, REQUEST SENSE 18, READSUBQ 10) has a different opcode, so the
	-- idle path still serves them and needs no length signal plumbed in from cd_bridge.
	BURST_RDY <= '1' when FIFO_LEVEL >= 2048
	                      or (COMM(0) /= x"08"
	                          and EMPTY = '0' and FIFO_IDLE >= IDLE_MAX) else '0';
	DBG_FIRST8 <= DBG_BUF;
	DBG_GDI <= DBG_GDI_BUF;
	DBG_RD_TOTAL <= DBG_RD_CNT;
	with SP select DBG_SP <=
		x"0" when SP_FREE,          x"1" when SP_COMM_BEFOREREQ,
		x"2" when SP_COMM_START,    x"3" when SP_COMM_END,
		x"4" when SP_STAT_START,    x"5" when SP_STAT_END,
		x"6" when SP_STAT_HOLD,     x"7" when SP_MSGIN_START,
		x"8" when SP_MSGIN_END,     x"9" when SP_MSGIN_HOLD,
		x"A" when SP_DATAIN_START,  x"B" when SP_DATAIN_END,
		x"C" when SP_DATAOUT_START, x"D" when others;

	-- The byte handed to the CPU on the cycle FIFO_RD_REQ is high was latched into
	-- DBO the PREVIOUS cycle (both assignments happen together), so the CPU-visible
	-- byte is FIFO_Q delayed by one -- DBO itself is an out port and cannot be read
	-- back in VHDL-93. Sampling FIFO_Q_D1 records what the CPU sees, not what we wrote.
	process( RESET_N, CLK ) begin
		if RESET_N = '0' then
			DBG_ARM <= '0';
			DBG_POS <= (others => '0');
			DBG_BUF <= (others => '0');
			FIFO_Q_D1 <= (others => '0');
			SEL_COUNT <= (others => '0');
			SEL_N_R <= '1';
			DBG_GDI_ARM <= '0';
			DBG_GDI_POS <= (others => '0');
			DBG_GDI_BUF <= (others => '0');
			DBG_RD_CNT <= (others => '0');
		elsif rising_edge(CLK) then
			FIFO_Q_D1 <= FIFO_Q;
			SEL_N_R <= SEL_N;
			if SEL_N = '0' and SEL_N_R = '1' then
				SEL_COUNT <= SEL_COUNT + 1;
			end if;
			if FIFO_RD_REQ = '1' then
				DBG_RD_CNT <= DBG_RD_CNT + 1;
			end if;
			-- GETDIRINFO capture: armed by any 0xDE, disarmed by any other command, so the
			-- buffer accumulates only reply bytes and never the following READ's payload.
			if COMM_OUT = '1' then
				if COMM(0) = x"DE" then
					DBG_GDI_ARM <= '1';
				else
					DBG_GDI_ARM <= '0';
				end if;
			elsif DBG_GDI_ARM = '1' and FIFO_RD_REQ = '1' and DBG_GDI_POS < 16 then
				-- indexed, not shifted: the replies total 13 bytes, not 16, so a shift
				-- register would leave byte 0 at an offset that depends on how many
				-- arrived. Fixed position keeps byte 0 at [127:120] however many come.
				DBG_GDI_BUF(127 - to_integer(DBG_GDI_POS)*8 downto 120 - to_integer(DBG_GDI_POS)*8)
					<= FIFO_Q_D1;
				DBG_GDI_POS <= DBG_GDI_POS + 1;
			end if;
			if COMM_OUT = '1' and COMM(0) = x"08" then
				DBG_ARM <= '1';
				DBG_POS <= (others => '0');
				DBG_BUF <= (others => '0');
			elsif DBG_ARM = '1' and FIFO_RD_REQ = '1' then
				DBG_BUF <= DBG_BUF(55 downto 0) & FIFO_Q_D1;
				if DBG_POS = 7 then
					DBG_ARM <= '0';
				else
					DBG_POS <= DBG_POS + 1;
				end if;
			end if;
		end if;
	end process;

end rtl;
