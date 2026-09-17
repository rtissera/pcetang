-- tb_adpcm_golden.vhd -- replay a real game's ADPCM playback against a beetle-pce-fast trace.
--
-- Run: sim/cd/run_adpcm_golden.sh
--
-- The golden case (sim/cd/golden/adpcm_rondo_play8, see its README) was captured from
-- beetle-pce-fast running Akumajou Dracula X - Chi no Rondo: the ADPCM RAM image at the moment
-- playback started, the game's exact register writes for that playback, and the nibbles
-- beetle fed to its OKI decoder.
--
-- DUT is the REAL src/pce/tg16-mister-rtl/cd/cd.vhd. The model SDRAM is preloaded with the
-- RAM image (byte k -> nibble 2k high, 2k+1 low, the FPGA's layout), the register writes are
-- replayed through the CPU bus, and every nibble cd.vhd actually CONSUMES in a READ slot is
-- compared in order with beetle's. The ADPCM RAM bridge in front of the model is the board's,
-- as fixed on 2026-09-17 (see tb_adpcm_bridge.vhd for that logic's own regression).
--
-- What this proves: cd.vhd's ADPCM register semantics (address latch, read address, length
-- latch, play, auto-stop) and its RAM read path reproduce what the game gets on a reference
-- emulator -- same start, same order, same length. What it does NOT prove: the DMA load path
-- from CD (Rondo loads everything that way; the RAM is preloaded here), the MSM5205 decode
-- itself, and timing -- beetle's ADPCM is not cycle-accurate.
--
-- FAST_FREQ=true replaces the game's $180E sample-rate value with the fastest rate. That
-- changes only how often a nibble is consumed, not which nibble or in what order, and makes
-- the run about eight times shorter.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_adpcm_golden is
	generic (
		DIR        : string  := "sim/cd/golden/adpcm_rondo_play8";
		FAST_FREQ  : boolean := true;
		EXTRA_CYC  : integer := 600000;   -- after the expected count, watch this long for over-play
		STALL_CYC  : integer := 3000000;  -- give up if no nibble is consumed for this long
		-- If set, the ADPCM output AD_S is written here, one decimal value per consumed nibble,
		-- for sim/cd/adpcm_wav.py to turn into a WAV and diff against the golden decode.
		PCM_OUT    : string  := ""
	);
end entity;

architecture sim of tb_adpcm_golden is
	signal clk    : std_logic := '0';
	signal rst_n  : std_logic := '0';
	signal cpu_ce : std_logic := '0';
	signal running : boolean := true;

	signal ext_a    : std_logic_vector(20 downto 0) := (others => '0');
	signal ext_di   : std_logic_vector(7 downto 0) := (others => '0');
	signal ext_wr_n : std_logic := '1';
	signal ext_rd_n : std_logic := '1';

	signal a_a    : std_logic_vector(16 downto 0);
	signal a_do   : std_logic_vector(3 downto 0);
	signal a_we   : std_logic;
	signal a_req  : std_logic;
	signal a_slot : std_logic_vector(1 downto 0);
	signal a_di   : std_logic_vector(3 downto 0) := (others => '0');
	signal a_rdy  : std_logic;
	signal ad_s   : signed(15 downto 0);

	-- bridge (board logic, fixed 2026-09-17)
	signal slot_r   : std_logic_vector(1 downto 0) := (others => '0');
	signal req_r    : std_logic := '0';
	signal pend     : std_logic := '0';
	signal ready_i  : std_logic := '1';
	signal new_comb : std_logic;
	type st_t is (S_IDLE, S_SETTLE, S_HOLD);
	signal st       : st_t := S_IDLE;
	signal settle   : unsigned(5 downto 0) := (others => '0');
	constant SETTLE_HIT : unsigned(5 downto 0) := "010000";
	signal b_addr   : unsigned(16 downto 0) := (others => '0');
	signal b_we     : std_logic := '0';
	signal b_data   : std_logic_vector(3 downto 0) := (others => '0');
	signal b_req    : std_logic := '0';

	-- SDRAM model, nibble per address
	type mem_t is array (0 to 2**17-1) of integer range 0 to 15;
	shared variable mem : mem_t := (others => 0);
	signal sd_wait : std_logic := '0';
	signal sd_do   : std_logic_vector(3 downto 0) := (others => '0');

	type nibs_t is array (0 to 65535) of integer range 0 to 15;
	shared variable gold   : nibs_t;
	shared variable n_gold : integer := 0;

	signal playing_armed : boolean := false;
	signal all_done      : boolean := false;
begin
	clk <= not clk after 5 ns when running;

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
		EXT_WR_N => ext_wr_n, EXT_RD_N => ext_rd_n, CPU_CE => cpu_ce,
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
		DM => '0', CD_SL => open, CD_SR => open, AD_S => ad_s,
		ADPCM_RAM_A => a_a, ADPCM_RAM_DO => a_do, ADPCM_RAM_WE => a_we,
		ADPCM_RAM_REQ => a_req, ADPCM_RAM_SLOT_CNT => a_slot,
		ADPCM_RAM_DI => a_di, ADPCM_RAM_READY => a_rdy
	);

	-- ---- bridge: launch on slot change OR REQ rising; READY dropped combinationally ----
	new_comb <= '1' when a_req = '1' and (a_slot /= slot_r or req_r = '0') else '0';
	a_rdy    <= ready_i and not new_comb;

	process (clk)
	begin
		if rising_edge(clk) then
			slot_r <= a_slot;
			req_r  <= a_req;
			if new_comb = '1' then
				pend    <= '1';
				ready_i <= '0';
			end if;
			case st is
				when S_IDLE =>
					b_req <= '0';
					if pend = '1' or new_comb = '1' then
						b_addr <= unsigned(a_a); b_we <= a_we; b_data <= a_do;
						b_req <= '1'; pend <= '0'; settle <= (others => '0');
						st <= S_SETTLE;
					end if;
				when S_SETTLE =>
					b_req <= '1';
					if sd_wait = '1' then
						st <= S_HOLD;
					elsif settle = SETTLE_HIT then
						a_di <= sd_do; ready_i <= '1'; b_req <= '0'; st <= S_IDLE;
					else
						settle <= settle + 1;
					end if;
				when S_HOLD =>
					b_req <= '1';
					if sd_wait = '0' then
						a_di <= sd_do; ready_i <= '1'; b_req <= '0'; st <= S_IDLE;
					end if;
			end case;
		end if;
	end process;

	-- ---- SDRAM model ----
	process (clk)
		variable n    : integer := 0;
		variable busy : boolean := false;
		variable rq_r : std_logic := '0';
	begin
		if rising_edge(clk) then
			if not busy and b_req = '1' and rq_r = '0' then busy := true; n := 0; end if;
			if busy then
				n := n + 1;
				if n = 3 then
					sd_wait <= '1';
				elsif n = 7 then
					if b_we = '1' then
						mem(to_integer(b_addr)) := to_integer(unsigned(b_data));
						sd_do <= b_data;
					else
						sd_do <= std_logic_vector(to_unsigned(mem(to_integer(b_addr)), 4));
					end if;
					sd_wait <= '0'; busy := false;
				end if;
			end if;
			rq_r := b_req;
		end if;
	end process;

	-- ---- stimulus: load golden data, replay the game's register writes ----
	process
		file f     : text;
		variable l : line;
		variable v : std_logic_vector(7 downto 0);
		variable n4: std_logic_vector(3 downto 0);
		variable k : integer;
		variable r : std_logic_vector(3 downto 0);
		variable good : boolean;

		procedure reg_wr(reg : integer; val : std_logic_vector(7 downto 0)) is
		begin
			wait until rising_edge(clk) and cpu_ce = '0';
			ext_a    <= "11111111" & "11000" & std_logic_vector(to_unsigned(reg, 8));
			ext_di   <= val;
			ext_wr_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			wait until rising_edge(clk);
			ext_wr_n <= '1';
			-- real games leave several CPU instructions between register writes
			for i in 1 to 300 loop wait until rising_edge(clk); end loop;
		end procedure;

		-- A register READ. Some reads change ADPCM state: reading $180A queues a RAM read,
		-- and that queued read is what makes cd.vhd load its read address while $180D bit 3
		-- is set. Without replaying it, playback starts at address 0.
		procedure reg_rd(reg : integer) is
		begin
			wait until rising_edge(clk) and cpu_ce = '0';
			ext_a    <= "11111111" & "11000" & std_logic_vector(to_unsigned(reg, 8));
			ext_rd_n <= '0';
			wait until rising_edge(clk) and cpu_ce = '1';
			wait until rising_edge(clk);
			ext_rd_n <= '1';
			for i in 1 to 300 loop wait until rising_edge(clk); end loop;
		end procedure;
		variable kind : character;
	begin
		-- RAM image, bytes -> nibbles
		file_open(f, DIR & "/ram.hex", read_mode);
		k := 0;
		while not endfile(f) loop
			readline(f, l); hread(l, v, good);
			if good then
				mem(2*k)   := to_integer(unsigned(v(7 downto 4)));
				mem(2*k+1) := to_integer(unsigned(v(3 downto 0)));
				k := k + 1;
			end if;
		end loop;
		file_close(f);
		-- golden nibble stream
		file_open(f, DIR & "/nib.hex", read_mode);
		n_gold := 0;
		while not endfile(f) loop
			readline(f, l); hread(l, n4, good);
			if good then gold(n_gold) := to_integer(unsigned(n4)); n_gold := n_gold + 1; end if;
		end loop;
		file_close(f);
		write(l, string'("loaded RAM bytes=")); write(l, k);
		write(l, string'(" golden nibbles=")); write(l, n_gold);
		writeline(output, l);

		rst_n <= '0';
		for i in 1 to 20 loop wait until rising_edge(clk); end loop;
		rst_n <= '1';
		for i in 1 to 500 loop wait until rising_edge(clk); end loop;

		-- the game's own register writes, from regs.txt
		file_open(f, DIR & "/regs.txt", read_mode);
		-- lines: "W reg value" or "R reg 00"
		while not endfile(f) loop
			readline(f, l);
			read(l, kind, good);
			if good then
				hread(l, r, good);
				hread(l, v, good);
			end if;
			if good then
				if kind = 'R' then
					reg_rd(to_integer(unsigned(r)));
				else
					if FAST_FREQ and to_integer(unsigned(r)) = 16#E# then
						v := x"0F";
					end if;
					if to_integer(unsigned(r)) = 16#D# and v(5) = '1' then
						playing_armed <= true;   -- consumption checking starts with PLAY
					end if;
					reg_wr(to_integer(unsigned(r)), v);
				end if;
			end if;
		end loop;
		file_close(f);
		wait until all_done;
		running <= false;
		wait;
	end process;

	-- ---- checker: compare every consumed nibble with beetle's, in order ----
	-- A read is consumed on the DRAM_CLKEN edge of a READ slot when a request was present at
	-- the gate decision (REQ high on both the gate cycle and the CLKEN cycle); the slot count
	-- moves on that same edge, so it is detected one sample later.
	process
		variable l : line;
		variable p_slot : std_logic_vector(1 downto 0) := "00";
		variable p_req, p2_req : std_logic := '0';
		variable p_di : std_logic_vector(3 downto 0) := "0000";
		variable p_a  : integer := 0;
		variable got, matched, extra, first_bad, idle, after_end : integer := 0;
		variable start_addr : integer := -1;
		variable finished : boolean := false;
	begin
		first_bad := -1;
		loop
			wait until rising_edge(clk);
			if playing_armed and not finished then
				idle := idle + 1;
				if a_slot /= p_slot and p_slot = "11" and p_req = '1' and p2_req = '1' then
					idle := 0;
					if got = 0 then start_addr := p_a; end if;
					if got < n_gold then
						if to_integer(unsigned(p_di)) = gold(got) then
							matched := matched + 1;
						elsif first_bad < 0 then
							first_bad := got;
						end if;
					else
						extra := extra + 1;
					end if;
					got := got + 1;
				end if;
				if got >= n_gold then
					after_end := after_end + 1;
				end if;
				if (got >= n_gold and after_end >= EXTRA_CYC) or idle >= STALL_CYC then
					finished := true;
					write(l, string'("RESULT golden=")); write(l, n_gold);
					write(l, string'(" consumed=")); write(l, got);
					write(l, string'(" matched=")); write(l, matched);
					write(l, string'(" first_mismatch_at=")); write(l, first_bad);
					write(l, string'(" reads_past_end=")); write(l, extra);
					write(l, string'(" start_nibble_addr=0x"));
					if start_addr >= 0 then hwrite(l, std_logic_vector(to_unsigned(start_addr, 20)));
					else write(l, string'("none")); end if;
					writeline(output, l);
					if idle >= STALL_CYC then
						write(l, string'("  STOPPED: no nibble consumed for STALL_CYC cycles"));
						writeline(output, l);
					end if;
					-- PASS allows exactly ONE read past the end, and only if playback has stopped
					-- (AD_S gated to 0). That read is the stop fetch, not a played sample: with
					-- $180D bit 6 set, cd.vhd checks "length = 0" when a nibble ARRIVES, so the
					-- nibble after the last one is fetched, sees 0, forces M5205_D to 0 and clears
					-- ADPCM_PLAY -- it is never decoded. beetle also fetches one past the end at
					-- stop without decoding it (a whole byte there, a nibble here); only where the
					-- read address ends up differs. The WAV diff confirms the audio is identical.
					if matched = n_gold and (extra = 0 or (extra = 1 and ad_s = 0)) then
						if extra = 1 then
							write(l, string'("PASS: cd.vhd plays exactly what beetle played (+1 stop fetch, read and discarded, not decoded)"));
						else
							write(l, string'("PASS: cd.vhd plays exactly what beetle played"));
						end if;
					else
						write(l, string'("FAIL"));
					end if;
					writeline(output, l);
					all_done <= true;
				end if;
			end if;
			p2_req := p_req;
			p_slot := a_slot; p_req := a_req;
			p_a := to_integer(unsigned(a_a)); p_di := a_di;
		end loop;
	end process;
	-- ---- PCM capture: AD_S at every consumed nibble ----
	-- The MSM5205 decodes a nibble on its VCK falling edge, AFTER cd.vhd has latched it, so the
	-- AD_S sampled at consumption n is the decode of nibble n-1. adpcm_wav.py aligns for that.
	process
		file pf : text;
		variable pl : line;
		variable p_slot : std_logic_vector(1 downto 0) := "00";
		variable p_req, p2_req : std_logic := '0';
		variable opened : boolean := false;
	begin
		if PCM_OUT'length = 0 then wait; end if;
		loop
			wait until rising_edge(clk);
			if playing_armed and not all_done then
				if a_slot /= p_slot and p_slot = "11" and p_req = '1' and p2_req = '1' then
					if not opened then file_open(pf, PCM_OUT, write_mode); opened := true; end if;
					write(pl, to_integer(ad_s)); writeline(pf, pl);
				end if;
			end if;
			if all_done and opened then
				-- one more AD_S after the last nibble, so its decode is captured too
				write(pl, to_integer(ad_s)); writeline(pf, pl);
				file_close(pf); wait;
			end if;
			p2_req := p_req; p_slot := a_slot; p_req := a_req;
		end loop;
	end process;
end architecture;
