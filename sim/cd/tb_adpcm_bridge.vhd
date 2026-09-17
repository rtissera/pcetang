-- tb_adpcm_bridge.vhd -- does the board's ADPCM SDRAM bridge lose accesses?
--
-- Run: sim/cd/run_adpcm_bridge.sh   (expects: 0 never_written, 0 stale, 0 address_skips
-- with FIXED=true). FIXED=false reproduces the pre-2026-09-17 board bridge.
--
-- DUT is the REAL src/pce/tg16-mister-rtl/cd/cd.vhd. In front of its ADPCM_RAM_* port
-- sits a copy of the ADPCM half of pcetang_console60k_cd.vhd's cdr arbiter (same
-- adpcm_new / adpcm_pend / adpcm_ram_ready_i logic, same CDR_IDLE/SETTLE/HOLD shape,
-- same SETTLE_HIT), in front of a simple SDRAM model with real WAIT latency.
--
-- CD-RAM contention is deliberately absent: this is the BEST case for the bridge. Any
-- loss measured here happens with the port completely idle.
--
-- Two independent experiments:
--   A. WRITES  -- the CPU writes N bytes to $180A; afterwards the model SDRAM is compared
--                 nibble by nibble with what should be there.
--   B. READS   -- the model SDRAM is preloaded with a known nibble stream, ADPCM playback
--                 is started, and every nibble cd.vhd CONSUMES (the DRAM_CLKEN of a READ
--                 slot with ADPCM_RAM_REQ high) is compared with what memory really holds
--                 at the address it asked for.
--
-- FIXED=false : bridge exactly as on the board.
-- FIXED=true  : candidate fix -- launch on slot change OR on ADPCM_RAM_REQ rising within
--               a slot, plus a combinational READY early-drop (same idiom as the CD-RAM
--               fix). This is the control: it must read 0/0, otherwise the testbench
--               itself is suspect.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_adpcm_bridge is
	generic (
		FIXED      : boolean := false;
		N_BYTES    : integer := 2000;
		WR_GAP     : integer := 331;    -- cycles between CPU $180A writes (odd on purpose)
		N_READS    : integer := 4000;   -- playback nibbles to check
		SD_LAT     : integer := 3;      -- cycles before the SDRAM model raises WAIT
		SD_BUSY    : integer := 4       -- cycles WAIT stays high
	);
end entity;

architecture sim of tb_adpcm_bridge is
	signal clk    : std_logic := '0';
	signal rst_n  : std_logic := '0';
	signal cpu_ce : std_logic := '0';

	signal ext_a    : std_logic_vector(20 downto 0) := (others => '0');
	signal ext_di   : std_logic_vector(7 downto 0) := (others => '0');
	signal ext_wr_n : std_logic := '1';

	-- cd.vhd ADPCM RAM port
	signal a_a     : std_logic_vector(16 downto 0);
	signal a_do    : std_logic_vector(3 downto 0);
	signal a_we    : std_logic;
	signal a_req   : std_logic;
	signal a_slot  : std_logic_vector(1 downto 0);
	signal a_di    : std_logic_vector(3 downto 0) := (others => '0');
	signal a_rdy   : std_logic;

	-- bridge
	signal slot_r       : std_logic_vector(1 downto 0) := (others => '0');
	signal req_r        : std_logic := '0';
	signal pend         : std_logic := '0';
	signal ready_i      : std_logic := '1';
	signal new_comb     : std_logic;
	type st_t is (S_IDLE, S_SETTLE, S_HOLD);
	signal st           : st_t := S_IDLE;
	signal settle       : unsigned(5 downto 0) := (others => '0');
	constant SETTLE_HIT : unsigned(5 downto 0) := "010000";   -- same as the board
	signal b_addr       : unsigned(16 downto 0) := (others => '0');
	signal b_we         : std_logic := '0';
	signal b_data       : std_logic_vector(3 downto 0) := (others => '0');
	signal b_req        : std_logic := '0';
	signal launches     : integer := 0;

	-- SDRAM model
	type mem_t is array (0 to 2**17-1) of integer range -1 to 15;
	shared variable mem : mem_t := (others => -1);
	signal sd_wait  : std_logic := '0';
	signal sd_do    : std_logic_vector(3 downto 0) := (others => '0');

	signal phase    : integer := 0;   -- 0 reset, 1 writes, 2 settle, 3 reads, 9 done
	signal running  : boolean := true;
	signal reads_done : boolean := false;

	-- the stream both experiments expect: consecutive nibbles always differ (step 7 mod 16),
	-- so a re-used PREVIOUS nibble can never match by coincidence
	function nib(i : integer) return integer is
	begin
		return (i * 7 + 3) mod 16;
	end function;
begin
	clk <= not clk after 5 ns when running;

	-- CPU clock enable, roughly the real one's rate
	process (clk)
		variable n : integer := 0;
	begin
		if rising_edge(clk) then
			n := (n + 1) mod 6;
			if n = 0 then cpu_ce <= '1'; else cpu_ce <= '0'; end if;
		end if;
	end process;

	dut : entity work.cd
	port map (
		RST_N => rst_n, CLK => clk, EN => '1',
		EXT_A => ext_a, EXT_DI => ext_di, EXT_DO => open,
		EXT_WR_N => ext_wr_n, EXT_RD_N => '1', CPU_CE => cpu_ce,
		SEL_N => open, IRQ_N => open, RAM_CS_N => open, BRAM_EN => open,
		CD_STAT => (others => '0'), CD_MSG => (others => '0'), CD_STAT_GET => '0',
		CD_COMM => open, CD_COMM_SEND => open,
		CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
		CD_REGION => '0', CD_RESET => open,
		CD_DATA => (others => '0'), CD_DATA_WR => '0', CD_AUDIO_WR => '0', CD_SUBCD_WR => '0',
		CD_DATA_END => open,
		DBG_DATAIN_CNT => open, DBG_FIRST8 => open, DBG_SP => open, DBG_ADPCM => open,
		DBG_COMM_POS => open, DBG_COMM0 => open, DBG_COMM1 => open, DBG_SEL_CNT => open,
		DBG_FIFO_SPACE => open, DBG_FIFO_DROPS => open, DBG_GDI => open,
		DBG_RD_TOTAL => open, DBG_CDDA_SPACE => open, DBG_UNDERRUNS => open,
		DM => '0', CD_SL => open, CD_SR => open, AD_S => open,
		ADPCM_RAM_A => a_a, ADPCM_RAM_DO => a_do, ADPCM_RAM_WE => a_we,
		ADPCM_RAM_REQ => a_req, ADPCM_RAM_SLOT_CNT => a_slot,
		ADPCM_RAM_DI => a_di, ADPCM_RAM_READY => a_rdy
	);

	------------------------------------------------------------------------------------
	-- BRIDGE -- the ADPCM half of the board's cdr arbiter
	------------------------------------------------------------------------------------
	new_comb <= '1' when a_req = '1' and (a_slot /= slot_r or (FIXED and req_r = '0')) else '0';

	a_rdy <= (ready_i and not new_comb) when FIXED else ready_i;

	process (clk)
		variable an : std_logic;
	begin
		if rising_edge(clk) then
			slot_r <= a_slot;
			req_r  <= a_req;
			if FIXED then
				an := new_comb;
			else
				-- board: `if adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r then adpcm_new := adpcm_ram_req_i`
				if a_slot /= slot_r then an := a_req; else an := '0'; end if;
			end if;
			if an = '1' then
				pend    <= '1';
				ready_i <= '0';
			end if;

			case st is
				when S_IDLE =>
					b_req <= '0';
					if pend = '1' or an = '1' then
						b_addr   <= unsigned(a_a);
						b_we     <= a_we;
						b_data   <= a_do;
						b_req    <= '1';
						pend     <= '0';
						settle   <= (others => '0');
						launches <= launches + 1;
						st       <= S_SETTLE;
					end if;
				when S_SETTLE =>
					b_req <= '1';
					if sd_wait = '1' then
						st <= S_HOLD;
					elsif settle = SETTLE_HIT then
						a_di    <= sd_do;
						ready_i <= '1';
						b_req   <= '0';
						st      <= S_IDLE;
					else
						settle <= settle + 1;
					end if;
				when S_HOLD =>
					b_req <= '1';
					if sd_wait = '0' then
						a_di    <= sd_do;
						ready_i <= '1';
						b_req   <= '0';
						st      <= S_IDLE;
					end if;
			end case;
		end if;
	end process;

	------------------------------------------------------------------------------------
	-- SDRAM MODEL -- a request raises WAIT after SD_LAT cycles, holds it SD_BUSY cycles,
	-- and performs the access (read into sd_do, or the write) as WAIT falls.
	------------------------------------------------------------------------------------
	process (clk)
		variable n    : integer := 0;
		variable busy : boolean := false;
		variable rq_r : std_logic := '0';
	begin
		if rising_edge(clk) then
			if not busy and b_req = '1' and rq_r = '0' then
				busy := true; n := 0;
			end if;
			if busy then
				n := n + 1;
				if n = SD_LAT then
					sd_wait <= '1';
				elsif n = SD_LAT + SD_BUSY then
					if b_we = '1' then
						mem(to_integer(b_addr)) := to_integer(unsigned(b_data));
						sd_do <= b_data;
					else
						if mem(to_integer(b_addr)) < 0 then sd_do <= "0000";
						else sd_do <= std_logic_vector(to_unsigned(mem(to_integer(b_addr)), 4)); end if;
					end if;
					sd_wait <= '0';
					busy := false;
				end if;
			end if;
			rq_r := b_req;
		end if;
	end process;

	------------------------------------------------------------------------------------
	-- STIMULUS
	------------------------------------------------------------------------------------
	process
		procedure reg_wr(r : integer; v : integer) is
		begin
			wait until rising_edge(clk) and cpu_ce = '0';
			ext_a    <= "11111111" & "11000" & std_logic_vector(to_unsigned(r, 8));
			ext_di   <= std_logic_vector(to_unsigned(v, 8));
			ext_wr_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			wait until rising_edge(clk);
			ext_wr_n <= '1';
		end procedure;
		variable l : line;
	begin
		rst_n <= '0';
		for i in 1 to 20 loop wait until rising_edge(clk); end loop;
		rst_n <= '1';
		for i in 1 to 200 loop wait until rising_edge(clk); end loop;

		-- ADPCM reset: clears WRADDR/RDADDR/LEN, then release
		reg_wr(16#0D#, 16#80#);
		for i in 1 to 200 loop wait until rising_edge(clk); end loop;
		reg_wr(16#0D#, 16#00#);
		for i in 1 to 200 loop wait until rising_edge(clk); end loop;

		-- ---- A: CPU writes ----
		phase <= 1;
		for b in 0 to N_BYTES - 1 loop
			reg_wr(16#0A#, nib(2*b) * 16 + nib(2*b + 1));   -- high nibble first, then low
			for i in 1 to WR_GAP loop wait until rising_edge(clk); end loop;
		end loop;
		for i in 1 to 2000 loop wait until rising_edge(clk); end loop;
		phase <= 2;
		wait until rising_edge(clk);

		-- ---- B: playback reads from a PRELOADED memory ----
		-- Overwrite the whole model with the exact expected stream, so the read experiment
		-- is independent of whatever the write experiment left behind.
		for i in 0 to 2**17 - 1 loop
			mem(i) := nib(i);
		end loop;
		reg_wr(16#0E#, 16#0F#);          -- fastest ADPCM rate: most reads per sim second
		reg_wr(16#0D#, 16#20#);          -- PLAY
		phase <= 3;
		wait until reads_done;
		running <= false;
		wait;
	end process;

	------------------------------------------------------------------------------------
	-- CHECKERS
	------------------------------------------------------------------------------------
	-- A slot's access is CONSUMED by cd.vhd on the edge where DRAM_CLKEN fires, which is the
	-- edge where ADPCM_RAM_SLOT_CNT then changes. Signals read at a rising edge are the
	-- pre-edge values, so capture every cycle and evaluate the previous capture when the
	-- slot count is seen to have moved.
	process
		variable p_slot : std_logic_vector(1 downto 0) := "00";
		variable p_req  : std_logic := '0';
		variable p_we   : std_logic := '0';
		variable p_a    : integer := 0;
		variable p_di   : std_logic_vector(3 downto 0) := "0000";
		variable reads, stale : integer := 0;
		variable w_events : integer := 0;
		variable first_stale : integer := -1;
		variable l : line;
		variable bad, never : integer := 0;
		variable p2_req : std_logic := '0';
		variable stale_late : integer := 0;
		variable deferred, skips, last_a : integer := 0;
		variable have_last : boolean := false;
	begin
		wait until rising_edge(clk);
		loop
			wait until rising_edge(clk);
			if a_slot /= p_slot then
				-- the edge just consumed the slot described by p_*
				-- With the cd.vhd fix a read is consumed only if REQ was already high on the
				-- gate-decision cycle (p2_req) as well as on the DRAM_CLKEN cycle (p_req); one
				-- that rose in between is DEFERRED to the next round. That condition is taken
				-- from the fix, so it is cross-checked independently below: consumed addresses
				-- must be strictly sequential. A deferred read that cd.vhd nevertheless
				-- consumed would advance RDADDR and show up as a skip.
				if phase = 3 and p_slot = "11" and p_req = '1' and p_we = '0' and p2_req = '0' then
					deferred := deferred + 1;
				end if;
				if phase = 3 and p_slot = "11" and p_req = '1' and p_we = '0' and p2_req = '1' then
					if have_last and p_a /= last_a + 1 then skips := skips + 1; end if;
					last_a := p_a; have_last := true;
					reads := reads + 1;
					if to_integer(unsigned(p_di)) /= nib(p_a) then
						stale := stale + 1;
						if p2_req = '0' then stale_late := stale_late + 1; end if;
						if first_stale < 0 then first_stale := reads; end if;
					end if;
					if reads = N_READS then
						-- ---- report A: writes ----
						for i in 0 to 2 * N_BYTES - 1 loop
							null;
						end loop;
						write(l, string'("RESULT FIXED=")); write(l, FIXED);
						writeline(output, l);
						write(l, string'("  READS : consumed=")); write(l, reads);
						write(l, string'(" stale=")); write(l, stale);
						write(l, string'(" (")); write(l, (stale * 1000) / reads);
						write(l, string'(" per mille)  first_stale_at=")); write(l, first_stale);
						write(l, string'("  deferred=")); write(l, deferred);
						write(l, string'("  address_skips=")); write(l, skips);
						writeline(output, l);
						reads_done <= true;
					end if;
				end if;
				if phase = 1 and (p_slot = "01" or p_slot = "10") and p_req = '1' and p_we = '1' then
					w_events := w_events + 1;
				end if;
			end if;
			p2_req := p_req;
			p_slot := a_slot; p_req := a_req; p_we := a_we;
			p_a := to_integer(unsigned(a_a)); p_di := a_di;
		end loop;
	end process;

	-- write-experiment report, taken as phase 2 begins (before the preload overwrites mem)
	process
		variable l : line;
		variable bad, never : integer := 0;
	begin
		wait until phase = 2;
		for i in 0 to 2 * N_BYTES - 1 loop
			if mem(i) < 0 then never := never + 1;
			elsif mem(i) /= nib(i) then bad := bad + 1;
			end if;
		end loop;
		write(l, string'("  WRITES: nibbles=")); write(l, 2 * N_BYTES);
		write(l, string'(" never_written=")); write(l, never);
		write(l, string'(" wrong=")); write(l, bad);
		write(l, string'(" (")); write(l, ((never + bad) * 1000) / (2 * N_BYTES));
		write(l, string'(" per mille)  bridge_launches=")); write(l, launches);
		writeline(output, l);
		wait;
	end process;

end architecture;
