-- SCSI.vhd phase-line property test, derived from a reference trace rather than from the
-- implementation.
--
-- The property: the value the CPU reads at $1800 must always be one that a working CD boot
-- produces. cd.vhd builds that byte as
--
--     not BSY_N & not REQ_N & not MSG_N & not CD_N & not IO_N & "000"
--
-- and an instrumented mednafen pce_fast run of Dungeon Explorer II that reaches the title
-- screen reads $1800 94477 times across the whole boot. It returns exactly nine distinct
-- values and no others:
--
--     00  BUS FREE                            22 reads
--     d0  COMMAND      + REQ                  97
--     90  COMMAND      , REQ low           50583   <-- waiting for the drive to answer
--     c8  DATA IN      + REQ                  68
--     88  DATA IN      , REQ low           43649   <-- waiting for the next data byte
--     d8  STATUS       + REQ                  25
--     98  STATUS       , REQ low              11
--     f8  MESSAGE IN   + REQ                  11
--     b8  MESSAGE IN   , REQ low              11
--
-- Note what is absent: 0x80 and 0xC0, i.e. DATA OUT in either REQ state. A PCE CD boot
-- never enters DATA OUT. That matters because MSG=CD=IO all deasserted is not a neutral
-- "between phases" state -- it IS DATA OUT -- and SP_COMM_END used to clear CD_Nr while
-- leaving BSY asserted, so the CPU read 0x80 for the entire time the target took to
-- produce the first byte. Over a 2 Mbaud UART that is ~10 ms per sector, against
-- microseconds on MiSTer, where this same donor code came from and where the window is too
-- short to observe.
--
-- The test therefore drives one full command with a REALISTIC turnaround: the CDB is
-- delivered, then nothing happens for TURNAROUND_US before the reply bytes appear. A test
-- that answers instantly cannot see this class of bug at all, which is why the existing
-- cd_bridge tests pass.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_scsi_phase is
	generic (
		-- Time between the last CDB byte and the first reply byte. The default is the real
		-- MCU round trip for one sector; the bug under test is invisible below ~1 us.
		TURNAROUND_US : integer := 10000
	);
end entity;

architecture sim of tb_scsi_phase is

	constant CLK_PERIOD : time := 23.3 ns;          -- 42.9 MHz, as cd.vhd is clocked

	signal clk     : std_logic := '0';
	signal reset_n : std_logic := '0';
	signal done    : boolean   := false;

	signal dbi, dbo       : std_logic_vector(7 downto 0) := (others => '0');
	signal sel_n, ack_n   : std_logic := '1';
	signal bsy_n, req_n   : std_logic;
	signal msg_n, cd_n, io_n : std_logic;
	signal status_s, message_s : std_logic_vector(7 downto 0) := (others => '0');
	signal stat_get       : std_logic := '0';
	signal command_s      : std_logic_vector(95 downto 0);
	signal comm_send      : std_logic;
	signal dout_req       : std_logic := '0';
	signal dout_s         : std_logic_vector(79 downto 0);
	signal dout_send      : std_logic;
	-- cd_data/cd_wr are driven from exactly ONE place -- the mux below. Two processes
	-- assigning them resolves to 'U' on a std_logic type, SCSI.vhd's CD_WR edge detect then
	-- never fires, and the testbench hangs with no data and no error. Cost an hour.
	signal cd_data        : std_logic_vector(7 downto 0);
	signal cd_wr          : std_logic;
	signal stim_data      : std_logic_vector(7 downto 0) := (others => '0');
	signal stim_wr        : std_logic := '0';
	signal feed_data      : std_logic_vector(7 downto 0) := (others => '0');
	signal feed_wr        : std_logic := '0';
	signal cd_data_end    : std_logic;
	signal stop_snd       : std_logic;

	signal dbg_datain_cnt : unsigned(15 downto 0);
	signal dbg_first8     : std_logic_vector(63 downto 0);
	signal dbg_sp         : std_logic_vector(3 downto 0);
	signal dbg_comm_pos   : unsigned(3 downto 0);
	signal dbg_comm0      : std_logic_vector(7 downto 0);
	signal dbg_comm1      : std_logic_vector(7 downto 0);
	signal dbg_sel_cnt    : unsigned(15 downto 0);
	signal dbg_fifo_space : unsigned(12 downto 0);
	signal dbg_fifo_drops : unsigned(15 downto 0);
	signal dbg_gdi        : std_logic_vector(127 downto 0);
	signal dbg_rd_total   : unsigned(15 downto 0);

	-- What the CPU would read at $1800, exactly as cd.vhd composes it.
	signal reg1800 : std_logic_vector(7 downto 0);
	signal errors  : integer := 0;
	signal burst_bad : integer := 0;
	signal gate_stuck : boolean := false;
	-- SCSI.vhd reports free space; the level is what the gate keys on.
	signal dbg_level_dbg : integer := 0;
	signal feed_start  : boolean := false;
	signal burst_check : boolean := false;
	type bytes_t is array (0 to 2047) of std_logic_vector(7 downto 0);
	signal burst_got : bytes_t := (others => (others => '0'));
	signal seen    : std_logic_vector(255 downto 0) := (others => '0');

	function hex(v : std_logic_vector) return string is
		constant T : string := "0123456789ABCDEF";
		variable r : string(1 to v'length/4);
		variable u : unsigned(v'length-1 downto 0);
	begin
		u := unsigned(v);
		for i in r'range loop
			r(i) := T(to_integer(u(v'length-1 downto v'length-4)) + 1);
			u := shift_left(u, 4);
		end loop;
		return r;
	end function;

	-- The nine values a working boot produces.
	function is_golden(v : std_logic_vector(7 downto 0)) return boolean is
	begin
		case v is
			when x"00" | x"d0" | x"90" | x"c8" | x"88"
			   | x"d8" | x"98" | x"f8" | x"b8" => return true;
			when others => return false;
		end case;
	end function;

	function phase_name(v : std_logic_vector(7 downto 0)) return string is
	begin
		case v is
			when x"00" => return "BUS FREE";
			when x"d0" => return "COMMAND +REQ";
			when x"90" => return "COMMAND";
			when x"c8" => return "DATA IN +REQ";
			when x"88" => return "DATA IN";
			when x"d8" => return "STATUS +REQ";
			when x"98" => return "STATUS";
			when x"f8" => return "MESSAGE IN +REQ";
			when x"b8" => return "MESSAGE IN";
			when x"c0" => return "DATA OUT +REQ  <-- never in a real boot";
			when x"80" => return "DATA OUT       <-- never in a real boot";
			when others => return "unknown";
		end case;
	end function;

begin

	clk <= not clk after CLK_PERIOD / 2 when not done else '0';

	dut : entity work.SCSI
	port map (
		RESET_N => reset_n, CLK => clk,
		DBI => dbi, DBO => dbo, SEL_N => sel_n, ACK_N => ack_n, RST_N => '1',
		BSY_N => bsy_n, REQ_N => req_n, MSG_N => msg_n, CD_N => cd_n, IO_N => io_n,
		STATUS => status_s, MESSAGE => message_s, STAT_GET => stat_get,
		COMMAND => command_s, COMM_SEND => comm_send,
		DOUT_REQ => dout_req, DOUT => dout_s, DOUT_SEND => dout_send,
		CD_DATA => cd_data, CD_WR => cd_wr, CD_DATA_END => cd_data_end,
		STOP_CD_SND => stop_snd,
		DBG_DATAIN_CNT => dbg_datain_cnt, DBG_FIRST8 => dbg_first8, DBG_SP => dbg_sp,
		DBG_COMM_POS => dbg_comm_pos, DBG_COMM0 => dbg_comm0, DBG_COMM1 => dbg_comm1,
		DBG_SEL_CNT => dbg_sel_cnt, DBG_FIFO_SPACE => dbg_fifo_space,
		DBG_FIFO_DROPS => dbg_fifo_drops, DBG_GDI => dbg_gdi, DBG_RD_TOTAL => dbg_rd_total
	);

	cd_data <= feed_data when feed_start else stim_data;
	cd_wr   <= feed_wr   when feed_start else stim_wr;

	dbg_level_dbg <= 4096 - to_integer(dbg_fifo_space);

	reg1800 <= (not bsy_n) & (not req_n) & (not msg_n) & (not cd_n) & (not io_n) & "000";

	-- The property, checked on every cycle and reported once per distinct value.
	monitor : process (clk)
		variable l : line;
	begin
		if rising_edge(clk) and reset_n = '1' then
			if seen(to_integer(unsigned(reg1800))) = '0' then
				seen(to_integer(unsigned(reg1800))) <= '1';
				write(l, string'("  $1800 = ")); write(l, hex(reg1800));
				write(l, string'("  ")); write(l, phase_name(reg1800));
				if not is_golden(reg1800) then
					write(l, string'("   *** NOT IN THE REFERENCE ***"));
					errors <= errors + 1;
				end if;
				writeline(output, l);
			end if;
		end if;
	end process;

	-- Feeds one 2048-byte sector at the real MCU byte pace. Contents are a counting
	-- pattern so a duplicate or a skip is unambiguous.
	feeder : process
		variable l2 : line;
	begin
		wait until feed_start;
		wait for 100 us;                   -- the MCU's own decode stall before byte 0
		for i in 0 to 2047 loop
			if i mod 512 = 0 then
				write(l2, string'("  [feeder] byte ")); write(l2, i);
				write(l2, string'("  fifo_level_seen=")); write(l2, dbg_level_dbg);
				writeline(output, l2);
			end if;
			feed_data <= std_logic_vector(to_unsigned(i mod 256, 8));
			feed_wr   <= '1';
			wait until rising_edge(clk);
			feed_wr   <= '0';
			for g in 0 to 212 loop         -- 214 cycles/byte = 2 Mbaud
				wait until rising_edge(clk);
			end loop;
		end loop;
		wait;
	end process;

	-- Checks the burst the CPU actually took.
	checker : process
		variable l : line;
		variable bad, firstbad : integer := -1;
		variable nbad : integer := 0;
	begin
		wait until burst_check;
		for i in 0 to 2047 loop
			if burst_got(i) /= std_logic_vector(to_unsigned(i mod 256, 8)) then
				nbad := nbad + 1;
				if firstbad < 0 then firstbad := i; end if;
			end if;
		end loop;
		if nbad = 0 then
			write(l, string'("  all 2048 bytes correct, in order"));
		else
			write(l, string'("  ")); write(l, nbad);
			write(l, string'(" of 2048 bytes WRONG, first at index ")); write(l, firstbad);
			write(l, string'(" -- the FIFO ran dry mid-burst and the CPU reread stale DBO"));
			burst_bad <= nbad;
		end if;
		writeline(output, l);
		write(l, string'("  SCSI.vhd underrun counter: "));
		write(l, integer'image(to_integer(unsigned(dbg_rd_total))));
		write(l, string'(" bytes delivered in total"));
		writeline(output, l);
		wait;
	end process;

	stim : process
		-- GETDIRINFO mode 2 for track 34, the command a real boot issues right after the
		-- third READ(6), with the reply bytes mednafen returns for this disc.
		constant CDB   : std_logic_vector(79 downto 0) := x"DE023400000000000000";
		constant REPLY : std_logic_vector(31 downto 0) := x"66295204";
		variable l : line;
		variable waited : integer := 0;

		procedure cpu_ack_byte(b : std_logic_vector(7 downto 0)) is
		begin
			-- The CPU waits for REQ, puts its byte on the bus, pulses ACK, and waits for
			-- the target to drop REQ before releasing ACK. This is $1801/$1802 bit 7.
			wait until rising_edge(clk) and req_n = '0';
			dbi <= b;
			wait until rising_edge(clk);
			ack_n <= '0';
			wait until rising_edge(clk) and req_n = '1';
			wait until rising_edge(clk);
			ack_n <= '1';
			wait until rising_edge(clk);
		end procedure;

		procedure cpu_take_byte is
		begin
			wait until rising_edge(clk) and req_n = '0';
			wait until rising_edge(clk);
			ack_n <= '0';
			wait until rising_edge(clk) and req_n = '1';
			wait until rising_edge(clk);
			ack_n <= '1';
			wait until rising_edge(clk);
		end procedure;
	begin
		reset_n <= '0';
		wait for CLK_PERIOD * 10;
		reset_n <= '1';
		wait for CLK_PERIOD * 10;

		writeline(output, l);
		write(l, string'("distinct $1800 values observed, in order of first appearance:"));
		writeline(output, l);

		-- SELECT: a write to $1800 asserts SEL for one CPU access.
		sel_n <= '0';
		wait for CLK_PERIOD * 4;
		sel_n <= '1';

		-- COMMAND phase: ten bytes for a 0xDE opcode.
		for i in 0 to 9 loop
			cpu_ack_byte(CDB(79 - i*8 downto 72 - i*8));
		end loop;

		wait until rising_edge(clk) and comm_send = '1';

		-- THE WINDOW UNDER TEST. The target has the command and is fetching over the UART.
		-- Nothing is driven here on purpose: whatever the CPU reads at $1800 during this
		-- time is what the system card has to interpret, and for ~10 ms.
		wait for TURNAROUND_US * 1 us;

		-- Reply bytes arrive, one DATA IN handshake each.
		for i in 0 to 3 loop
			stim_data <= REPLY(31 - i*8 downto 24 - i*8);
			stim_wr   <= '1';
			wait for CLK_PERIOD * 2;
			stim_wr   <= '0';
			wait for CLK_PERIOD * 2;
			cpu_take_byte;
		end loop;

		-- Completion: GOOD status then the message byte, then the bus goes free.
		status_s  <= x"00";
		message_s <= x"00";
		wait for CLK_PERIOD * 4;
		stat_get <= '1';
		wait for CLK_PERIOD * 2;
		stat_get <= '0';

		cpu_take_byte;      -- STATUS
		cpu_take_byte;      -- MESSAGE IN

		-- SP_MSGIN_HOLD sits for 6600 cycles (154 us) before it releases BSY, so wait for
		-- the bus to actually go free rather than guessing a delay. A SELECT asserted while
		-- the target is still in MSGIN_HOLD is simply ignored.
		while reg1800 /= x"00" loop
			wait until rising_edge(clk);
		end loop;
		wait for CLK_PERIOD * 20;

		-- ------------------------------------------------------------------ burst test
		-- The second property, and the one the phase check above cannot see: a whole
		-- sector must survive the way the system card actually reads it.
		--
		-- A working boot reads $1808 63488 times in exactly 31 bursts of 2048 CONSECUTIVE
		-- reads -- measured, no other register access appears anywhere inside a burst. The
		-- CPU does not recheck REQ per byte, and cd.vhd cannot stall it: $1808 returns
		-- SCSI_DBO combinationally and WAIT_N is driven only by ROM_RDY/CD_RAM_RDY. So the
		-- CPU model below reads DBO every 8 cycles come what may, and auto-ACKs only when
		-- REQ happens to be asserted, exactly as cd.vhd does.
		--
		-- Meanwhile the feeder supplies bytes at 214 cycles each -- the real 2 Mbaud MCU
		-- pace, ~5 us per byte against a CPU taking one per ~0.2 us here. Without the
		-- BURST_RDY gate the FIFO runs dry within a few bytes and the CPU reads the same
		-- stale DBO over and over, which is silent corruption: the count still comes to
		-- 2048.
		writeline(output, l);
		write(l, string'("burst test: 2048 bytes fed at MCU pace, read as one burst"));
		writeline(output, l);

		sel_n <= '0';
		wait for CLK_PERIOD * 4;
		sel_n <= '1';
		for i in 0 to 5 loop
			cpu_ack_byte(x"08");            -- a 6-byte CDB, opcode 0x08 = READ(6)
		end loop;
		wait until rising_edge(clk) and comm_send = '1';

		feed_start <= true;                -- feeder process takes it from here

		-- Poll $1800 for DATA IN, as the system card does, then burst without looking back.
		-- Bounded: a gate that never opens is a bug to report, not a reason to hang.
		waited := 0;
		while reg1800 /= x"c8" and reg1800 /= x"88" and waited < 1200000 loop
			wait until rising_edge(clk);
			waited := waited + 1;
		end loop;
		if waited >= 1200000 then
			write(l, string'("  FAIL: DATA IN never started -- BURST_RDY did not open"));
			writeline(output, l);
			gate_stuck <= true;
		end if;

		for i in 0 to 2047 loop
			for g in 0 to 6 loop
				wait until rising_edge(clk);
			end loop;
			burst_got(i) <= dbo;            -- the $1808 read itself
			if req_n = '0' then              -- cd.vhd's auto-ACK, only when REQ is up
				ack_n <= '0';
				wait until rising_edge(clk);
				ack_n <= '1';
			end if;
			wait until rising_edge(clk);
		end loop;

		burst_check <= true;
		wait for CLK_PERIOD * 20;

		writeline(output, l);
		if gate_stuck then
			write(l, string'("FAIL: the DATA IN gate never opened"));
			writeline(output, l);
		end if;
		if errors = 0 and burst_bad = 0 and not gate_stuck then
			write(l, string'("PASS: phase lines match the reference AND the 2048-byte burst is intact"));
		elsif burst_bad /= 0 and errors = 0 then
			write(l, integer'image(burst_bad));
			write(l, string'(" byte(s) of the burst corrupted -- see above"));
		else
			write(l, integer'image(errors));
			write(l, string'(" $1800 value(s) outside the reference -- see the marked lines above"));
		end if;
		writeline(output, l);
		if errors /= 0 or burst_bad /= 0 or gate_stuck then
			report "tb_scsi_phase FAILED" severity error;
		end if;
		done <= true;
		wait for CLK_PERIOD;
		std.env.stop;
	end process;

end architecture;
