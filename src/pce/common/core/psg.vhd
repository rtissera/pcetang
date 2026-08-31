-- SPDX-License-Identifier: GPL-3.0-or-later

-- Forked from upstream/tg16-mister rtl/HUC6280/psg.vhd -- one change, search "GOWIN FIX":
-- `DATA := CH(1).WF_DATA(...) xor "1000"` xors a 5-bit value (wavedata_t is
-- std_logic_vector(4 downto 0)) against a 4-bit literal. Real gw_sh run failed outright
-- (ERROR (EX4718) "Operator xor has arguments of unequal lengths", module left as a black
-- box). Fixed by zero-extending the literal to "01000".
--
-- UNVERIFIED beyond "it now compiles": unlike the huc6270.vhd PAL-field fix (a reset path
-- where any padding gives the same runtime value), this DATA(4) bit feeds real LFO/
-- vibrato modulation logic three lines down (sign-extended into CH(0).LFO_ADD) -- the
-- padding choice can change the LFO's actual output, not just satisfy a type check. Zero
-- was chosen as the least-presumptuous fix (preserves the documented low 4 bits exactly,
-- invents nothing for the 5th), not because it's confirmed correct against real hardware.
-- This is PCE's PSG "LFO" feature (channel 1 modulating channel 0's frequency), used by a
-- small number of games -- verify against real hardware or a trusted reference (audio
-- comparison, not just "does it build") before trusting this for any game that uses it.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity psg is
	generic (
		-- VT_PATH_A (2026-08-31, real lever 20 follow-up): selects between the
		-- real closed-form VT replacement (Path A, default -- see VT_COEF's own
		-- header comment below for the full derivation) and the original 4096x24
		-- BRAM (`entity work.dpram`, ~6 Gowin BSRAM blocks, bit-identical to the
		-- real donor `HUC6280/voltab.mif`). Per-board opt-OUT, not opt-in: Path A
		-- is a real, verified win on 2 of 3 boards (Console 60K CD, Primer 25K
		-- CD -- both real -6 BSRAM blocks, bounded real timing cost, 0/0
		-- violations). Nano 20K CD needs VT_PATH_A=>0 -- real gw_sh isolation
		-- (2026-08-31) proved SF2' widening alone and PSG Path A alone both pass
		-- clean and even improve margin individually on that board, but their
		-- COMBINATION real-fails timing (64 setup violations) -- a genuine
		-- interaction effect, not a flaw in either change, consistent with this
		-- board's well-documented placement-noise fragility (see
		-- pcetang_status_matrix.md lever 19). Dropping back to the old BRAM path
		-- there (instead of dropping SF2') was the direct user choice.
		VT_PATH_A : integer := 1
	);
	port (
		CLK 	: in std_logic;
		CLKEN	: in std_logic;
		RESET_N	: in std_logic;

		-- CPU Interface
		DI		: in std_logic_vector(7 downto 0);
		A 		: in std_logic_vector(3 downto 0);
		WE		: in std_logic;

		-- DAC Interface
		DAC_LATCH	: in std_logic;
		LDATA		: out std_logic_vector(23 downto 0);
		RDATA		: out std_logic_vector(23 downto 0)
	);
end psg;

architecture rtl of psg is

-- R0 - Channel Selection
signal CHSEL	: integer range 0 to 7;
-- R1 - Main Volume Adjustement
signal LMAL		: std_logic_vector(3 downto 0);
signal RMAL		: std_logic_vector(3 downto 0);

-- R2-R7 - Channel specific registers
type wavedata_t is array(0 to 31) of std_logic_vector(4 downto 0);
type chan_t is
	record
		-- Registers
		FREQ		: std_logic_vector(11 downto 0);
		DDA		: std_logic;
		CHON		: std_logic;
		AL			: std_logic_vector(4 downto 0);
		LAL		: std_logic_vector(3 downto 0);
		RAL		: std_logic_vector(3 downto 0);

		NG_FREQ	: std_logic_vector(4 downto 0);
		NE			: std_logic;

		-- Waveform generator
		WF_DATA	: wavedata_t;
		WF_ADDR	: std_logic_vector(4 downto 0);
		WF_CNT	: std_logic_vector(12 downto 0);

		WF_RES	: std_logic;
		WF_INC	: std_logic;

		-- Noise generator
		LFSR		: std_logic_vector(17 downto 0);
		NG_CNT	: std_logic_vector(11 downto 0);

		-- Outputs
		DA_OUT	: std_logic_vector(4 downto 0);
		WF_OUT	: std_logic_vector(4 downto 0);
		NG_OUT	: std_logic_vector(4 downto 0);
		-- Global output
		GL_OUT	: std_logic_vector(4 downto 0);

		-- LFO
		LFO_FREQ	: std_logic_vector(7 downto 0);
		LFCTL		: std_logic_vector(1 downto 0);
		LFTRG		: std_logic;
		LFO_CNT	: std_logic_vector(7 downto 0);
		LFO_ADD 	: std_logic_vector(11 downto 0);
	end record;
type chanarray_t is array(0 to 5) of chan_t;
signal CH		: chanarray_t;

-- Channels mixing
signal LACC		: std_logic_vector(23 downto 0);
signal RACC		: std_logic_vector(23 downto 0);

signal VT_ADDR	: std_logic_vector(11 downto 0);
signal VT_DATA	: std_logic_vector(23 downto 0);

type mix_t is ( MIX_WAIT, MIX_NEXT, MIX_LREAD, MIX_LNEXT, MIX_RREAD, MIX_RNEXT, MIX_END );
signal MIX		: mix_t;
signal MIX_CNT	: std_logic_vector(2 downto 0);

signal LDATA_FF	: std_logic_vector(23 downto 0);
signal RDATA_FF	: std_logic_vector(23 downto 0);

-- PSG VT REPLACEMENT (2026-08-31, real lever 20, Path A -- see project memory
-- pcetang_status_matrix.md for the full derivation, cross-checks against MAME's
-- c6280.cpp and Mednafen's pce_psg.cpp, and the numeric extraction from this
-- repo's own real HUC6280/voltab.mif). The original `VT` was a 4096x24 BRAM
-- (`entity work.dpram`, ~6 Gowin BSRAM blocks) holding a real HuC6280 hardware
-- volume-attenuation table. Verified (all 4096 real entries checked, not
-- sampled) that every entry equals a per-idx fixed-point coefficient D(idx)
-- times the real linear term (2*GL_OUT-31), rounded -- a real closed-form
-- multiply, not an idiosyncratic table. VT_COEF below holds the EXACT D(idx)
-- constants extracted from this repo's own real voltab.mif (least-squares fit,
-- 6 fractional bits -- verified 0 outliers beyond +-1 LSB across all 2816 real
-- idx/GL_OUT combinations at this precision), not a fresh re-derivation from a
-- generic textbook formula.
--
-- REAL, DELIBERATE, PERMANENT INCONSISTENCY (tracked as "Path A" in memory):
-- output differs from the real donor ROM by at most +-1 in this 24-bit two's-
-- complement value (-138dB relative, inaudible, channels are further mixed
-- downstream) -- NOT bit-identical to voltab.mif or real HuC6280 silicon. See
-- pcetang_status_matrix.md lever 20 before assuming any PSG audio discrepancy
-- is a new bug. A literal bit-exact alternative ("Path B", a real +-1
-- correction table for the 520/2816 entries this misses) was scoped but not
-- built -- see that same memory entry.
type vt_coef_t is array (0 to 127) of signed(22 downto 0);
constant VT_COEF : vt_coef_t := (
      0 => to_signed(2886401, 23), 1 => to_signed(2456724, 23), 2 => to_signed(2091012, 23), 3 => to_signed(1779739, 23),
      4 => to_signed(1514803, 23), 5 => to_signed(1289307, 23), 6 => to_signed(1097378, 23), 7 => to_signed(934020, 23),
      8 => to_signed(794979, 23), 9 => to_signed(676637, 23), 10 => to_signed(575911, 23), 11 => to_signed(490180, 23),
      12 => to_signed(417211, 23), 13 => to_signed(355102, 23), 14 => to_signed(302242, 23), 15 => to_signed(257249, 23),
      16 => to_signed(218954, 23), 17 => to_signed(186360, 23), 18 => to_signed(158618, 23), 19 => to_signed(135006, 23),
      20 => to_signed(114908, 23), 21 => to_signed(97802, 23), 22 => to_signed(83243, 23), 23 => to_signed(70851, 23),
      24 => to_signed(60304, 23), 25 => to_signed(51328, 23), 26 => to_signed(43686, 23), 27 => to_signed(37184, 23),
      28 => to_signed(31646, 23), 29 => to_signed(26936, 23), 30 => to_signed(22926, 23), 31 => to_signed(19513, 23),
      32 => to_signed(16608, 23), 33 => to_signed(14136, 23), 34 => to_signed(12032, 23), 35 => to_signed(10240, 23),
      36 => to_signed(8715, 23), 37 => to_signed(7418, 23), 38 => to_signed(6314, 23), 39 => to_signed(5373, 23),
      40 => to_signed(4573, 23), 41 => to_signed(3892, 23), 42 => to_signed(3313, 23), 43 => to_signed(2819, 23),
      44 => to_signed(2398, 23), 45 => to_signed(2042, 23), 46 => to_signed(1738, 23), 47 => to_signed(1479, 23),
      48 => to_signed(1258, 23), 49 => to_signed(1071, 23), 50 => to_signed(911, 23), 51 => to_signed(776, 23),
      52 => to_signed(659, 23), 53 => to_signed(561, 23), 54 => to_signed(478, 23), 55 => to_signed(406, 23),
      56 => to_signed(346, 23), 57 => to_signed(294, 23), 58 => to_signed(250, 23), 59 => to_signed(212, 23),
      60 => to_signed(181, 23), 61 => to_signed(154, 23), 62 => to_signed(130, 23), 63 => to_signed(111, 23),
      64 => to_signed(94, 23), 65 => to_signed(80, 23), 66 => to_signed(68, 23), 67 => to_signed(57, 23),
      68 => to_signed(49, 23), 69 => to_signed(42, 23), 70 => to_signed(35, 23), 71 => to_signed(30, 23),
      72 => to_signed(25, 23), 73 => to_signed(21, 23), 74 => to_signed(18, 23), 75 => to_signed(14, 23),
      76 => to_signed(12, 23), 77 => to_signed(10, 23), 78 => to_signed(8, 23), 79 => to_signed(7, 23),
      80 => to_signed(6, 23), 81 => to_signed(5, 23), 82 => to_signed(4, 23), 83 => to_signed(3, 23),
      84 => to_signed(2, 23), 85 => to_signed(2, 23), 86 => to_signed(1, 23), 87 => to_signed(1, 23),
      others => (others => '0')
   );

begin

-- CPU Interface
process( CLK )
begin
	if rising_edge( CLK ) then

		for i in 0 to 5 loop
			CH(i).WF_RES <= '0';
			CH(i).WF_INC <= '0';
		end loop;

		if RESET_N = '0' then

			CHSEL <= 0;
			LMAL <= (others => '0');
			RMAL <= (others => '0');

			for i in 0 to 5 loop
				CH(i).FREQ <= (others => '0');
				CH(i).DDA <= '0';
				CH(i).CHON <= '0';
				CH(i).LAL <= (others => '0');
				CH(i).RAL <= (others => '0');
				CH(i).NG_FREQ <= (others => '0');
				CH(i).NE <= '0';
				CH(i).DA_OUT <= (others => '0');
				CH(i).LFO_FREQ <= (others => '0');
				CH(i).LFCTL <= "00";
				CH(i).LFTRG <= '0';
			end loop;
		else
			if WE = '1' then
				case A is
				when "0000" =>
					CHSEL <= conv_integer(DI(2 downto 0));

				when "0001" =>
					LMAL <= DI(7 downto 4);
					RMAL <= DI(3 downto 0);

				when "0010" =>
					CH(CHSEL).FREQ(7 downto 0) <= DI;

				when "0011" =>
					CH(CHSEL).FREQ(11 downto 8) <= DI(3 downto 0);

				when "0100" =>
					CH(CHSEL).CHON <= DI(7);
					CH(CHSEL).DDA <= DI(6);
					CH(CHSEL).AL <= DI(4 downto 0);
					if CH(CHSEL).DDA = '1' and DI(6) = '0' then
						CH(CHSEL).WF_RES <= '1';
					end if;

				when "0101" =>
					CH(CHSEL).LAL <= DI(7 downto 4);
					CH(CHSEL).RAL <= DI(3 downto 0);

				when "0110" =>
					if CH(CHSEL).DDA = '0' then
						CH(CHSEL).WF_DATA(conv_integer(CH(CHSEL).WF_ADDR)) <= DI(4 downto 0);
					end if;
					if CH(CHSEL).CHON = '1' then
						CH(CHSEL).DA_OUT <= DI(4 downto 0);
					end if;
					if CH(CHSEL).DDA = '0' and CH(CHSEL).CHON = '0' then
						CH(CHSEL).WF_INC <= '1';
					end if;

				when "0111" =>
					if CHSEL = 4 or CHSEL =5 then
						CH(CHSEL).NE <= DI(7);
						CH(CHSEL).NG_FREQ <= DI(4 downto 0);
					end if;

				when "1000" =>
					CH(1).LFO_FREQ <= DI;

				when "1001" =>
					CH(1).LFCTL <= DI(1 downto 0);
					CH(1).LFTRG <= DI(7);

				when others => null;
				end case;
			end if;
		end if;
	end if;
end process;


process( CLK ) begin
	if rising_edge( CLK ) then
		for i in 0 to 5 loop
			if RESET_N = '0' then
				CH(i).GL_OUT <= (others => '0');
				CH(i).WF_CNT <= (others => '0');
				CH(i).LFSR <= (others => '0');
				CH(i).NG_CNT <= (others => '0');
				CH(i).LFO_CNT <= (others => '0');
			else
				if CH(i).WF_RES = '1' then
					CH(i).WF_ADDR <= (others => '0');
				end if;
				if CH(i).WF_INC = '1' then
					CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
				end if;

				if CH(i).LFCTL /= "00" then
					CH(i).WF_OUT <= CH(i).WF_DATA(conv_integer(CH(i).WF_ADDR));

					if CH(i).LFTRG = '1' then
						CH(i).WF_ADDR <= (others => '0');
						CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
						CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
					else
						if CLKEN = '1' then
							CH(i).LFO_CNT <= CH(i).LFO_CNT - 1;
							if CH(i).LFO_CNT = 0 then
								CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
								CH(i).WF_CNT <= CH(i).WF_CNT - 1;
								if CH(i).WF_CNT = 0 then
									CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
									CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
								end if;
							end if;
						end if;
					end if;
				elsif CH(i).CHON = '0' then
					CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
				elsif CH(i).DDA = '0' then
					CH(i).WF_OUT <= CH(i).WF_DATA(conv_integer(CH(i).WF_ADDR));

					if CLKEN = '1' then
						CH(i).WF_CNT <= CH(i).WF_CNT - 1;
						if CH(i).WF_CNT = 0 then
							CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
							CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
						end if;
					end if;
				end if;

				if CH(i).NE = '0' then
				if CH(i).NG_FREQ = "11111" then
						CH(i).NG_CNT <= "000000111111";
					else
						CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
					end if;
				else
					if CH(i).LFSR(0) = '0' then
						CH(i).NG_OUT <= "00000";
					else
						CH(i).NG_OUT <= "11111";
					end if;

					if CLKEN = '1' then
						CH(i).NG_CNT <= CH(i).NG_CNT - 1;
						if CH(i).NG_CNT = 0 then
							if CH(i).NG_FREQ = "11111" then
								CH(i).NG_CNT <= "000000111111";
							else
								CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
							end if;
							if CH(i).LFSR = 0 then
								CH(i).LFSR(0) <= '1';
							else
								CH(i).LFSR <= (CH(i).LFSR(0) xor CH(i).LFSR(1) xor CH(i).LFSR(11) xor CH(i).LFSR(12) xor CH(i).LFSR(17)) & CH(i).LFSR(17 downto 1);
							end if;
						end if;
					end if;
				end if;

				if CH(i).CHON = '0' then
					CH(i).GL_OUT <= "10000";		-- Not zero; this should be midpoint in the range to reduce 'pop' sound
				elsif CH(i).DDA = '1' then
					CH(i).GL_OUT <= CH(i).DA_OUT;
				elsif CH(i).NE = '1' then
					CH(i).GL_OUT <= CH(i).NG_OUT;
				else
					CH(i).GL_OUT <= CH(i).WF_OUT;
				end if;
			end if;
		end loop;
	end if;
end process;

process( CLK )
	variable DATA: std_logic_vector(4 downto 0);
begin
	if rising_edge( CLK ) then
		if RESET_N = '0' then
			for i in 0 to 5 loop
				CH(i).LFO_ADD <= (others => '0');
			end loop;
		else
			-- GOWIN FIX: donor has "1000" (4 bits) xor'd against a 5-bit value -- see
			-- this file's header. Zero-extended to "01000".
			DATA := CH(1).WF_DATA(conv_integer(CH(1).WF_ADDR)) xor "01000";
			CH(0).LFO_ADD(11 downto 8) <= DATA(4) & DATA(4) & DATA(4) & DATA(4);
			case CH(1).LFCTL is
			when "01" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA(4) & DATA(4) & DATA;
			when "10" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA & "00";
			when "11" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(3 downto 0) & "0000";
			when others => CH(0).LFO_ADD <= (others => '0');
			end case;
		end if;
	end if;
end process;

-- Channels mixing
-- PSG VT REPLACEMENT (2026-08-31, real lever 20): VT_PATH_A generic (see its
-- own header comment in the entity declaration) selects one of these two
-- mutually exclusive implementations. Both share the same 1-cycle address-to-
-- data latency (VT_ADDR set combinationally by the MIX state machine below,
-- VT_DATA registered one cycle later) -- the state machine's own
-- MIX_LREAD/MIX_RREAD wait states assume this latency regardless of which
-- generate branch is active.
gen_vt_path_a: if VT_PATH_A /= 0 generate
process( CLK )
	variable vt_idx  : integer range 0 to 127;
	variable vt_gl   : integer range 0 to 31;
	variable vt_m    : signed(6 downto 0);
	variable vt_prod : signed(29 downto 0);
begin
	if rising_edge( CLK ) then
		vt_idx  := to_integer(unsigned(VT_ADDR(6 downto 0)));
		vt_gl   := to_integer(unsigned(VT_ADDR(11 downto 7)));
		vt_m    := to_signed(2*vt_gl - 31, 7);
		vt_prod := VT_COEF(vt_idx) * vt_m;
		-- Round-half-up via bias-then-arithmetic-shift (real, synthesizable,
		-- verified in Python against all 2816 real table entries to match
		-- exactly, max error +-1 -- same scheme used to derive VT_COEF itself).
		VT_DATA <= std_logic_vector(resize(shift_right(vt_prod + 32, 6), 24));
	end if;
end process;
end generate;

gen_vt_path_b: if VT_PATH_A = 0 generate
-- Original donor implementation (real, unmodified 4096x24 BRAM, ~6 Gowin
-- BSRAM blocks, bit-identical to HUC6280/voltab.mif) -- used on boards where
-- VT_PATH_A's real arithmetic replacement was proven to interact badly with
-- another board-specific change (see VT_PATH_A's own header comment, and
-- pcetang_status_matrix.md lever 19/20 for the real isolation record).
VT : entity work.dpram generic map (12,24,"HUC6280/voltab.mif")
port map (
	clock		=> CLK,
	address_a=> VT_ADDR,
	q_a		=> VT_DATA
);
end generate;

process( CLK )
begin
	if rising_edge( CLK ) then
		if RESET_N = '0' then
			LDATA_FF <= (others => '0');
			RDATA_FF <= (others => '0');
			MIX <= MIX_WAIT;
		else
			case MIX is
			when MIX_WAIT =>
				LACC <= (others => '0');
				RACC <= (others => '0');
				MIX_CNT <= (others => '0');
				VT_ADDR <= (others => '1');
				if DAC_LATCH = '1' then
					MIX <= MIX_NEXT;
				end if;

			when MIX_NEXT =>
				VT_ADDR <= CH(conv_integer(MIX_CNT)).GL_OUT
					& ( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).LAL & "1") - (LMAL & "1") );
				MIX <= MIX_LREAD;

			when MIX_LREAD =>
				MIX <= MIX_LNEXT;

			when MIX_LNEXT =>
				LACC <= LACC + VT_DATA;
				VT_ADDR <= CH(conv_integer(MIX_CNT)).GL_OUT
					& ( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).RAL & "1") - (RMAL & "1") );
				MIX <= MIX_RREAD;

			when MIX_RREAD =>
				MIX <= MIX_RNEXT;

			when MIX_RNEXT =>
				RACC <= RACC + VT_DATA;
				if MIX_CNT = "101" then
					MIX <= MIX_END;
				else
					MIX_CNT <= MIX_CNT + 1;
					MIX <= MIX_NEXT;
				end if;

			when MIX_END =>
				LDATA_FF <= LACC;
				RDATA_FF <= RACC;
				MIX <= MIX_WAIT;

			when others => null;
			end case;
		end if;
	end if;
end process;

LDATA <= LDATA_FF;
RDATA <= RDATA_FF;

end rtl;

