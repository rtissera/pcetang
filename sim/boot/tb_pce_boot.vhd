-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Real-ROM boot testbench for pce_top, built to answer ONE question that several rounds
-- of on-hardware probing could not: when a plain HuCard is loaded on Console 60K, does
-- the HuC6280 ever get as far as programming the VDC, and if not, where does it stop?
--
-- Mirrors src/pcetang_console60k_cd.vhd's own instantiation exactly -- same generics
-- (LITE=0, EXT_VRAM0=0, NO_CD=0, everything else default), same SGX/AC_EN/BG_EN/SPR_EN
-- port values, same 42.857 MHz clk_pce -- with two deliberate differences, both stated
-- here so no result gets over-read:
--
--   1. CD_EN is '0' (the board now drives cd_mounted_i, which is 0 for a .pce).
--   2. The ROM is an IDEAL zero-wait memory (ROM_RDY tied '1'), not the board's SDRAM
--      bridge. So this run says nothing at all about the SDRAM ROM path -- that is the
--      point: it splits "core never programs the VDC" from "SDRAM bridge starves it".
--
-- See sim_stubs.vhd for the four stubbed-out modules and the same caveat about what a
-- passing run does and does not prove.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_pce_boot is
	generic (
		ROM_FILE   : string  := "rom.bin";
		-- pce_top's ROM_SZ bucket. X"080" = 512K, matching a 524288-byte HuCard --
		-- the same value the board's own rom_sz_r traced as on real hardware.
		ROM_SZ_G   : std_logic_vector(11 downto 0) := X"080";
		SGX_G      : std_logic := '1';
		CD_EN_G    : std_logic := '0';
		-- Simulated wall-clock to run for, in microseconds. One PCE frame is ~16.7 ms.
		RUN_US     : integer := 120000;
		-- Print every VDC/VCE register write (verbose) or just the summary.
		VERBOSE    : integer := 1;
		-- Dump the first N raw CPU bus cycles (every CPU_CE with RD or WR active).
		TRACE_N    : integer := 0;
		-- Skip this many CPU bus cycles before TRACE_N starts printing.
		TRACE_SKIP : integer := 0;
		-- ROM read latency in clk_pce cycles. 0 = ideal zero-wait memory (ROM_RDY tied
		-- '1'). Nonzero mimics the SHAPE of pcetang_console60k_cd.vhd's read bridge:
		-- ROM_RDY drops while ROM_RD is asserted, the data is registered, and ROM_RDY
		-- rises ROM_LAT cycles later. This does NOT model sdram.sv -- it only tests
		-- whether the handshake protocol itself can stall the HuC6280, independently of
		-- whether the returned data is correct.
		ROM_LAT    : integer := 0
	);
end entity;

architecture sim of tb_pce_boot is

	constant CLK_PERIOD : time := 23.333 ns;   -- 42.857 MHz clk_pce

	signal clk       : std_logic := '0';
	signal reset     : std_logic := '1';
	signal running   : boolean   := true;

	-- pce_top ROM interface
	signal rom_rd    : std_logic;
	signal rom_a     : std_logic_vector(21 downto 0);
	signal rom_do    : std_logic_vector(7 downto 0) := (others => '1');
	signal rom_q     : std_logic_vector(7 downto 0) := (others => '1');
	signal rom_rdy   : std_logic := '1';

	-- Board-side ports that pcetang_console60k_cd.vhd routes to the shared port-C
	-- arbiter (which drives cd_ram_rdy_i, the OTHER term of pce_top's WAIT_N). Probed
	-- here rather than left open: if the CD/ADPCM side requests DRAM during a plain
	-- HuCard boot, that arbiter can stall the CPU exactly the way ROM_RDY can.
	signal cd_ram_rd_s, cd_ram_wr_s : std_logic;
	signal adpcm_req_s              : std_logic;
	signal adpcm_we_s               : std_logic;

	signal dbg_cpu_a_s  : std_logic_vector(20 downto 0);
	signal dbg_vdc_wr_s : std_logic;

	-- video
	signal video_vs, video_hs, video_vbl, video_hbl, video_ce : std_logic;
	signal video_r, video_g, video_b : std_logic_vector(2 downto 0);

	signal brm_a  : std_logic_vector(10 downto 0);
	signal brm_di : std_logic_vector(7 downto 0);
	signal brm_we : std_logic;

	signal joy_out : std_logic_vector(1 downto 0);

	signal cdda_sl, cdda_sr, adpcm_s, psg_sl, psg_sr : signed(15 downto 0);

	-- ROM image
	constant ROM_WORDS : integer := 2**22;
	type rom_t is array (0 to ROM_WORDS-1) of std_logic_vector(7 downto 0);

	type charfile is file of character;

	impure function load_rom(fn : string) return rom_t is
		file     f   : charfile;
		variable st  : file_open_status;
		variable c   : character;
		variable m   : rom_t := (others => x"FF");
		variable i   : integer := 0;
		variable l   : line;
	begin
		file_open(st, f, fn, read_mode);
		if st /= open_ok then
			write(l, string'("FATAL: cannot open ROM file "));
			write(l, fn);
			writeline(output, l);
			return m;
		end if;
		while not endfile(f) and i < ROM_WORDS loop
			read(f, c);
			m(i) := std_logic_vector(to_unsigned(character'pos(c), 8));
			i := i + 1;
		end loop;
		file_close(f);
		write(l, string'("ROM loaded: "));
		write(l, fn);
		write(l, string'("  bytes="));
		write(l, i);
		writeline(output, l);
		return m;
	end function;

	shared variable rom_img : rom_t := load_rom(ROM_FILE);

	-- ---------------------------------------------------------------- helpers
	function hex(v : std_logic_vector) return string is
		constant N : integer := (v'length + 3) / 4;
		variable p : std_logic_vector(N*4-1 downto 0) := (others => '0');
		variable s : string(1 to N);
		variable d : integer;
	begin
		p(v'length-1 downto 0) := v;
		for i in 0 to N-1 loop
			d := to_integer(unsigned(p(i*4+3 downto i*4)));
			if d < 10 then
				s(N-i) := character'val(character'pos('0') + d);
			else
				s(N-i) := character'val(character'pos('A') + d - 10);
			end if;
		end loop;
		return s;
	end function;

	function hex(v : integer; n : integer) return string is
		variable u : unsigned(31 downto 0) := to_unsigned(v, 32);
	begin
		return hex(std_logic_vector(u(n*4-1 downto 0)));
	end function;

begin

	-- ------------------------------------------------------------------ clock
	clk <= not clk after CLK_PERIOD/2 when running else '0';

	-- ------------------------------------------------------------------ reset
	-- Board holds core_resetn low well past PLL lock; 200 raw clocks is ample and the
	-- exact length is not load-bearing (HuC6280 latches its own reset internally).
	reset_proc : process
	begin
		reset <= '1';
		wait for CLK_PERIOD * 200;
		wait until rising_edge(clk);
		reset <= '0';
		wait;
	end process;

	-- -------------------------------------------------------------- ROM model
	rom_q <= rom_img(to_integer(unsigned(rom_a)));

	gen_rom_ideal : if ROM_LAT = 0 generate
		rom_do  <= rom_q;
		rom_rdy <= '1';
	end generate;

	-- Latency model. Mirrors the board bridge's own structure: ROM_RD is a LEVEL held
	-- for the whole CPU memory cycle, so the FSM must re-arm from idle (it will
	-- immediately restart while ROM_RD is still high, exactly as the board's RB_IDLE
	-- does) rather than edge-detect.
	gen_rom_lat : if ROM_LAT /= 0 generate
		process (clk)
			variable cnt   : integer := 0;
			variable busy  : boolean := false;
		begin
			if rising_edge(clk) then
				if reset = '1' then
					busy    := false;
					cnt     := 0;
					rom_rdy <= '1';
				elsif not busy then
					rom_rdy <= '1';
					if rom_rd = '1' then
						busy    := true;
						cnt     := ROM_LAT;
						rom_rdy <= '0';
					end if;
				else
					if cnt <= 1 then
						busy    := false;
						rom_do  <= rom_q;
						rom_rdy <= '1';
					else
						cnt := cnt - 1;
					end if;
				end if;
			end if;
		end process;
	end generate;

	-- ------------------------------------------------------------------- DUT
	dut : entity work.pce_top
	generic map (LITE => 0, EXT_VRAM0 => 0, NO_CD => 0)
	port map (
		RESET      => reset,
		COLD_RESET => reset,
		CLK        => clk,

		VRAM0_RAM_A_ADDR => open, VRAM0_RAM_A_REQ => open, VRAM0_RAM_A_RD_N => open,
		VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0'),
		VRAM0_RAM_A_WAIT => '0',
		DBG_DEADLINE_MISS => open, DBG_FIFO_OVERFLOW => open,
		VRAM0_RAM_A_LINE_REFILL => open, VRAM0_RAM_A_LINE_DO => (others => '0'),

		VRAM1_RAM_A_ADDR => open, VRAM1_RAM_A_REQ => open, VRAM1_RAM_A_RD_N => open,
		VRAM1_RAM_A_DI => open, VRAM1_RAM_A_DO => (others => '0'),
		VRAM1_RAM_A_WAIT => '0',
		VRAM1_RAM_A_LINE_REFILL => open, VRAM1_RAM_A_LINE_DO => (others => '0'),
		DBG_DEADLINE_MISS_1 => open, DBG_FIFO_OVERFLOW_1 => open,

		-- Mapped, not left open, so the summary can cross-check the exact signal the
		-- board's hardware trace reports (DBG_VDC_WR) against this testbench's own
		-- independent count via CPU_VDC0_SEL_N. If those two ever disagree, the
		-- hardware number would be meaningless.
		DBG_CPU_A => dbg_cpu_a_s, DBG_VDC_WR => dbg_vdc_wr_s,

		ROM_RD    => rom_rd,
		ROM_RDY   => rom_rdy,
		ROM_A     => rom_a,
		ROM_DO    => rom_do,
		ROM_SZ    => ROM_SZ_G,
		ROM_POP   => '0',
		ROM_CLKEN => open,

		BRM_A => brm_a, BRM_DI => brm_di, BRM_DO => x"FF", BRM_WE => brm_we,

		GG_EN => '0', GG_CODE => (others => '0'), GG_RESET => '0', GG_AVAIL => open,

		SP64 => '0', SGX => SGX_G,

		JOY_OUT => joy_out, JOY_IN => "1111",

		CD_EN => CD_EN_G, CD_RAM_A => open, CD_RAM_DO => open,
		CD_RAM_DI => x"FF", CD_RAM_RD => cd_ram_rd_s, CD_RAM_WR => cd_ram_wr_s,
		CD_RAM_RDY => '1',

		ADPCM_RAM_A => open, ADPCM_RAM_DO => open,
		ADPCM_RAM_WE => adpcm_we_s, ADPCM_RAM_REQ => adpcm_req_s,
		ADPCM_RAM_SLOT_CNT => open,
		ADPCM_RAM_DI => "0000", ADPCM_RAM_READY => '1',

		AC_EN => '1',

		CD_STAT => x"00", CD_MSG => x"00", CD_STAT_GET => '0',
		CD_COMM => open, CD_COMM_SEND => open,
		CD_DOUT_REQ => '0', CD_DOUT => open, CD_DOUT_SEND => open,
		CD_REGION => '0', CD_RESET => open,
		CD_DATA => x"00", CD_DATA_WR => '0', CD_AUDIO_WR => '0',
		CD_SUBCD_WR => '0', CD_DATA_END => open, CD_DM => '0',

		CDDA_SL => cdda_sl, CDDA_SR => cdda_sr, ADPCM_S => adpcm_s,
		PSG_SL => psg_sl, PSG_SR => psg_sr,

		BG_EN => '1', SPR_EN => '1', GRID_EN => "00", CPU_PAUSE_EN => '0',

		BORDER_EN => '0', ReducedVBL => '0',
		VIDEO_R => video_r, VIDEO_G => video_g, VIDEO_B => video_b,
		VIDEO_BW => open, VIDEO_CE => video_ce, VIDEO_CE_FS => open,
		VIDEO_VS => video_vs, VIDEO_HS => video_hs,
		VIDEO_HBL => video_hbl, VIDEO_VBL => video_vbl
	);

	-- ------------------------------------------------------- internal probes
	-- VHDL-2008 external names. Everything below is a read-only tap on a signal that
	-- already exists in pce_top's architecture -- no RTL change, nothing to revert.
	probe : process
		alias cpu_a       is << signal dut.CPU_A          : std_logic_vector(20 downto 0) >>;
		alias cpu_do      is << signal dut.CPU_DO         : std_logic_vector(7 downto 0) >>;
		alias cpu_di      is << signal dut.CPU_DI         : std_logic_vector(7 downto 0) >>;
		alias cpu_wr_n    is << signal dut.CPU_WR_N       : std_logic >>;
		alias cpu_rd_n    is << signal dut.CPU_RD_N       : std_logic >>;
		alias cpu_ce      is << signal dut.CPU_CE         : std_logic >>;
		alias vdc0_sel_n  is << signal dut.CPU_VDC0_SEL_N : std_logic >>;
		alias vdc1_sel_n  is << signal dut.CPU_VDC1_SEL_N : std_logic >>;
		alias vpc_sel_n   is << signal dut.CPU_VPC_SEL_N  : std_logic >>;
		alias vce_sel_n   is << signal dut.CPU_VCE_SEL_N  : std_logic >>;
		alias vdc0_irq_n  is << signal dut.VDC0_IRQ_N     : std_logic >>;
		alias vdc1_irq_n  is << signal dut.VDC1_IRQ_N     : std_logic >>;
		alias cd_irq_n    is << signal dut.CD_IRQ_N       : std_logic >>;

		variable l : line;

		variable n_vdc0_wr : integer := 0;
		variable n_vdc1_wr : integer := 0;
		variable n_vpc_wr  : integer := 0;
		variable n_vce_wr  : integer := 0;
		variable n_vdc0_rd : integer := 0;

		variable n_vdc0_irq : integer := 0;
		variable n_vdc1_irq : integer := 0;
		variable n_cd_irq   : integer := 0;

		variable printed   : integer := 0;
		variable n_bus     : integer := 0;
		variable n_dbg_vdc : integer := 0;
		variable traced    : integer := 0;
		variable vdc_reg   : std_logic_vector(4 downto 0) := (others => '0');

		-- bank coverage of ROM reads, one bit per 8K physical bank 0..127
		type bankhit_t is array (0 to 127) of boolean;
		variable bankhit : bankhit_t := (others => false);
		variable nbanks  : integer := 0;

		variable vbl_edges : integer := 0;
		variable vs_edges  : integer := 0;

		variable prev_vbl : std_logic := '0';
		variable prev_vs  : std_logic := '0';
		variable prev_v0i : std_logic := '1';
		variable prev_v1i : std_logic := '1';
		variable prev_cdi : std_logic := '1';

		-- port-C requesters (see the signal declarations above for why these matter)
		variable n_cdram_rd  : integer := 0;
		variable n_cdram_wr  : integer := 0;
		variable n_adpcm_req : integer := 0;
		variable cyc_cdram   : integer := 0;
		variable cyc_adpcm   : integer := 0;
		variable prev_crd : std_logic := '0';
		variable prev_cwr : std_logic := '0';
		variable prev_areq: std_logic := '0';

		variable b : integer;

		-- Progress heartbeat: the RAM-clear TAI alone is ~8192 iterations, so a run
		-- long enough to reach the VDC covers tens of ms. Printing where the CPU is
		-- every HB_US shows forward progress (or a loop) without a full bus dump.
		constant HB_US    : integer := 1000;
		variable hb_next  : time := 0 ns;
		variable first_vdc : time := 0 ns;
	begin
		wait until reset = '0';
		hb_next := now;

		while running loop
			-- Must also wake on `running` going false: the clock generator stops
			-- toggling at that point, so a plain `wait until rising_edge(clk)` would
			-- park here forever and the summary below would never print.
			wait until rising_edge(clk) or not running;
			exit when not running;

			-- IRQ edges (falling = asserted)
			if vdc0_irq_n = '0' and prev_v0i = '1' then n_vdc0_irq := n_vdc0_irq + 1; end if;
			if vdc1_irq_n = '0' and prev_v1i = '1' then n_vdc1_irq := n_vdc1_irq + 1; end if;
			if cd_irq_n   = '0' and prev_cdi = '1' then n_cd_irq   := n_cd_irq   + 1; end if;
			prev_v0i := vdc0_irq_n;
			prev_v1i := vdc1_irq_n;
			prev_cdi := cd_irq_n;

			-- Independent count of the port the board's hardware trace reports.
			if dbg_vdc_wr_s = '1' then
				n_dbg_vdc := n_dbg_vdc + 1;
			end if;

			-- port-C requesters: rising edges, and total cycles held asserted (the
			-- board's arbiter drops cd_ram_rdy_i for as long as it is servicing one,
			-- so the held-cycle count is what actually bounds a CPU stall).
			if cd_ram_rd_s  = '1' and prev_crd  = '0' then n_cdram_rd  := n_cdram_rd  + 1; end if;
			if cd_ram_wr_s  = '1' and prev_cwr  = '0' then n_cdram_wr  := n_cdram_wr  + 1; end if;
			if adpcm_req_s  = '1' and prev_areq = '0' then n_adpcm_req := n_adpcm_req + 1; end if;
			if cd_ram_rd_s = '1' or cd_ram_wr_s = '1' then cyc_cdram := cyc_cdram + 1; end if;
			if adpcm_req_s = '1' then cyc_adpcm := cyc_adpcm + 1; end if;
			prev_crd  := cd_ram_rd_s;
			prev_cwr  := cd_ram_wr_s;
			prev_areq := adpcm_req_s;

			-- video activity
			if video_vbl = '1' and prev_vbl = '0' then vbl_edges := vbl_edges + 1; end if;
			if video_vs  = '1' and prev_vs  = '0' then vs_edges  := vs_edges  + 1; end if;
			prev_vbl := video_vbl;
			prev_vs  := video_vs;

			if now >= hb_next then
				hb_next := now + (HB_US * 1 us);
				write(l, string'("HB "));
				write(l, now);
				write(l, string'("  cpu_a="));
				write(l, hex(cpu_a));
				write(l, string'("  bus="));
				write(l, n_bus);
				write(l, string'("  vdc0wr="));
				write(l, n_vdc0_wr);
				write(l, string'("  vbl="));
				write(l, vbl_edges);
				writeline(output, l);
			end if;

			if cpu_ce = '1' then
				if cpu_rd_n = '0' or cpu_wr_n = '0' then
					n_bus := n_bus + 1;
					if n_bus > TRACE_SKIP and traced < TRACE_N then
						traced := traced + 1;
						write(l, string'("BUS "));
						write(l, n_bus);
						if cpu_wr_n = '0' then
							write(l, string'(" WR "));
						else
							write(l, string'(" RD "));
						end if;
						write(l, hex(cpu_a));
						write(l, string'(" = "));
						if cpu_wr_n = '0' then
							write(l, hex(cpu_do));
						else
							write(l, hex(cpu_di));
						end if;
						writeline(output, l);
					end if;
				end if;

				-- ROM read bank coverage
				if cpu_a(20) = '0' and cpu_rd_n = '0' then
					b := to_integer(unsigned(cpu_a(19 downto 13)));
					if not bankhit(b) then
						bankhit(b) := true;
						nbanks := nbanks + 1;
					end if;
				end if;

				if cpu_wr_n = '0' then
					if vdc0_sel_n = '0' then
						n_vdc0_wr := n_vdc0_wr + 1;
						if first_vdc = 0 ns then
							first_vdc := now;
						end if;
						if VERBOSE /= 0 and printed < 400 then
							printed := printed + 1;
							write(l, now);
							write(l, string'("  VDC0 WR a="));
							write(l, hex(cpu_a(4 downto 0)));
							write(l, string'(" d="));
							write(l, hex(cpu_do));
							writeline(output, l);
						end if;
					elsif vdc1_sel_n = '0' then
						n_vdc1_wr := n_vdc1_wr + 1;
					elsif vpc_sel_n = '0' then
						n_vpc_wr := n_vpc_wr + 1;
					elsif vce_sel_n = '0' then
						n_vce_wr := n_vce_wr + 1;
					end if;
				elsif cpu_rd_n = '0' and vdc0_sel_n = '0' then
					n_vdc0_rd := n_vdc0_rd + 1;
				end if;
			end if;
		end loop;

		write(l, string'("")); writeline(output, l);
		write(l, string'("================ tb_pce_boot summary ================"));
		writeline(output, l);
		write(l, string'("  sim time            : ")); write(l, now); writeline(output, l);
		write(l, string'("  VDC0 writes         : ")); write(l, n_vdc0_wr); writeline(output, l);
		write(l, string'("  first VDC0 write at : ")); write(l, first_vdc); writeline(output, l);
		write(l, string'("  DBG_VDC_WR count    : ")); write(l, n_dbg_vdc);
		if n_dbg_vdc = n_vdc0_wr then
			write(l, string'("   (matches, tap is sound)"));
		else
			write(l, string'("   *** DISAGREES with VDC0 writes -- tap is WRONG ***"));
		end if;
		writeline(output, l);
		write(l, string'("  VDC0 reads          : ")); write(l, n_vdc0_rd); writeline(output, l);
		write(l, string'("  VDC1 writes         : ")); write(l, n_vdc1_wr); writeline(output, l);
		write(l, string'("  VPC  writes         : ")); write(l, n_vpc_wr);  writeline(output, l);
		write(l, string'("  VCE  writes         : ")); write(l, n_vce_wr);  writeline(output, l);
		write(l, string'("  VDC0 IRQ assertions : ")); write(l, n_vdc0_irq); writeline(output, l);
		write(l, string'("  VDC1 IRQ assertions : ")); write(l, n_vdc1_irq); writeline(output, l);
		write(l, string'("  CD   IRQ assertions : ")); write(l, n_cd_irq);   writeline(output, l);
		write(l, string'("  VBLANK edges        : ")); write(l, vbl_edges);  writeline(output, l);
		write(l, string'("  VSYNC edges         : ")); write(l, vs_edges);   writeline(output, l);
		write(l, string'("  CPU bus cycles      : ")); write(l, n_bus);      writeline(output, l);
		write(l, string'("  CD_RAM_RD pulses    : ")); write(l, n_cdram_rd);  writeline(output, l);
		write(l, string'("  CD_RAM_WR pulses    : ")); write(l, n_cdram_wr);  writeline(output, l);
		write(l, string'("  ADPCM_RAM_REQ pulses: ")); write(l, n_adpcm_req); writeline(output, l);
		write(l, string'("  CD_RAM held cycles  : ")); write(l, cyc_cdram);   writeline(output, l);
		write(l, string'("  ADPCM held cycles   : ")); write(l, cyc_adpcm);   writeline(output, l);
		write(l, string'("  distinct ROM banks  : ")); write(l, nbanks);     writeline(output, l);
		write(l, string'("  ROM banks touched   : "));
		for i in 0 to 127 loop
			if bankhit(i) then
				write(l, string'(" "));
				write(l, hex(i, 2));
			end if;
		end loop;
		writeline(output, l);
		write(l, string'("====================================================="));
		writeline(output, l);
		wait;
	end process;

	-- ------------------------------------------------------------- stop clock
	stopper : process
	begin
		wait for RUN_US * 1 us;
		running <= false;
		wait for CLK_PERIOD * 4;
		wait;
	end process;

end architecture;
