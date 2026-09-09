library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.HUC6280_PKG.all;

entity HUC6280_CPU is
	generic (
		-- Debug probes (MPR_DBG / TAM_DBG / TLOAD_DBG / SEL_DBG and the 192-bit
		-- TLOAD_BUF shift register behind them) cost real timing: they hang heavy
		-- fanout off the microcode outputs MC.LOAD_T, ALU_OUT, IR and STATE, and on
		-- Primer 25K CD that pushed the MCODE -> PSG write path to -0.938 ns and 428
		-- setup violations. They were built for the HuCard black-screen hunt, which is
		-- closed (777ba38), so they are OFF unless a board asks for them.
		--
		-- This is a GENERIC and not a top-level tie-off on purpose: 984d3ce established
		-- on this exact repo that tying an unused debug path off at the top level does
		-- NOT prune it (it cost Primer 25K 721 and Nano 20K 20 violations). A generic
		-- constant folds at elaboration and the logic genuinely disappears.
		DBG_PROBES : integer := 0
	);
	port( 
		CLK		: in std_logic;
		RST_N		: in std_logic;
		CE			: in std_logic;
		  
		A_OUT		: out std_logic_vector(20 downto 0);
		DI			: in std_logic_vector(7 downto 0);
		DO			: out std_logic_vector(7 downto 0);
		WE_N  	: out std_logic;
		RDY		: in std_logic;
		NMI_N		: in std_logic;  
		IRQ1_N	: in std_logic;
		IRQ2_N	: in std_logic;
		IRQT_N	: in std_logic;
		
		VDCNUM	: in std_logic;

		MCYCLE  	: out std_logic;
		CS  		: out std_logic
	;
		-- PCE PORT (2026-09-07): the MPR bank registers, exposed read-only.
		-- Hardware executes `jsr $4003` correctly (verified: the CPU received the exact
		-- bytes 20 03 40 from ROM 0x0477-0x0479) but lands in physical bank $ED. Logical
		-- $4000-$5FFF maps through MPR2, which `lda #$01 / tam #$04` set five instructions
		-- earlier, and MPR resets to all zeros -- so something WROTE $ED there. This makes
		-- the register file directly observable instead of inferred from CPU_A.
		MPR_DBG	: out std_logic_vector(63 downto 0);
		-- PCE PORT (2026-09-07): TAM execution evidence. The boot path executes EXACTLY
		-- 7 TAMs before `jsr $4003` (2 in the reset stub, 5 in LE454), and every A value
		-- it writes is <= $05 -- so the $A0 seen in the MPR readback CANNOT come from this
		-- code. TAM_CNT says whether the write-enable fired at all and how often, which
		-- separates "the write never lands" from "the write lands and the storage or the
		-- read select is wrong".
		TAM_DBG	: out std_logic_vector(31 downto 0);
		-- PCE PORT (2026-09-09): the measurement that separates the last two candidate
		-- mechanisms for the T corruption. Run 21 proved T holds $53 (the TAM OPCODE)
		-- instead of the operand bitmask, but that has two readings and the MPR/TAM dump
		-- cannot tell them apart:
		--   (a) control fired EARLY -- MC.LOAD_T asserted on the opcode-fetch cycle
		--   (b) data arrived LATE   -- LOAD_T fired correctly but DI still held the
		--                              opcode because the fetch had not completed
		-- Recording A_OUT alongside DI settles it: if the captured address is the OPCODE
		-- address, it is (a) and the microcode is at fault; if it is the OPERAND address,
		-- it is (b) and the memory bridge handed over stale data without stalling the CPU.
		-- Four most recent T-loads, newest in the low slot, 48 bits each:
		-- IR | DI | ADDR_BUS(15:0) | ALU_OUT | STATE(4:0) | LOAD_T(2:0).
		TLOAD_DBG	: out std_logic_vector(191 downto 0);
		-- One-cycle strobe on every commit into T. Lets the BOARD latch its own view of
		-- the ROM bridge at the exact instant the CPU commits, so "what the CPU took" and
		-- "what the bridge was presenting" can be compared directly instead of inferred.
		TLOAD_STB	: out std_logic;
		-- PCE PORT (2026-09-09): resolves a hard contradiction between two existing
		-- probes. The trap says CPU_A(20:13) = $ED, but A_OUT(20:13) is
		-- `x"FF" when MC.ADDR_BUS="101" else MPR_SEL`, and the MPR array read back
		-- A0 A0 00 00 A0 00 A0 00 at that same instant -- no register holds $ED. A mux
		-- cannot output a value none of its inputs hold, so one of those two probes is
		-- wrong. This exports the MUX OUTPUT and its SELECT alongside the array, so the
		-- three can be compared directly:
		--   MPR_SEL = $ED while the array holds none  -> the read select is broken
		--   MPR_SEL = A0 while A_OUT still shows $ED  -> the fault is after the mux
		--   MPR_SEL matches the array at that index   -> the ARRAY probe is the liar
		-- SEL_DBG: MPR_SEL(8) | ADDR_BUS(15:13)(3) | MC.ADDR_BUS(3) | A_OUT(20:13)(8)
		SEL_DBG	: out std_logic_vector(21 downto 0));
end HUC6280_CPU;

architecture rtl of HUC6280_CPU is

	signal EN 				: std_logic;
	
	--Registers
	signal A 				: std_logic_vector(7 downto 0);
	signal X 				: std_logic_vector(7 downto 0);
	signal Y 				: std_logic_vector(7 downto 0);
	signal SP 				: std_logic_vector(7 downto 0);
	signal P    			: std_logic_vector(7 downto 0);
	signal PC    			: std_logic_vector(15 downto 0);
	signal AA				: std_logic_vector(15 downto 0);
	signal T 				: std_logic_vector(7 downto 0);
	signal DR 				: std_logic_vector(7 downto 0);
	signal SH 				: std_logic_vector(7 downto 0);
	signal DH 				: std_logic_vector(7 downto 0);
	signal LH 				: std_logic_vector(7 downto 0);
	signal MPR 				: MPR_t;
	
	--Instruction decoder
	signal IR 				: std_logic_vector(7 downto 0);
	signal STATE 			: unsigned(4 downto 0);
	signal MC 				: MCode_r;
	signal NEXT_IR 		: std_logic_vector(7 downto 0);
	signal NEXT_STATE 	: unsigned(4 downto 0);
	signal LAST_CYCLE 	: std_logic;
	signal BRANCH_TAKEN 	: std_logic;
	signal MEM_INST 		: std_logic;
	signal TALT 			: std_logic;
	
	--Buses
	signal ADDR_BUS 		: std_logic_vector(15 downto 0);
	signal MPR_OUT 		: std_logic_vector(7 downto 0);
	signal MPR_LAST 		: std_logic_vector(7 downto 0);
	signal MPR_SEL 		: std_logic_vector(7 downto 0);
	signal A_OUT_BANK 	: std_logic_vector(7 downto 0);
	signal TAM_CNT 		: unsigned(7 downto 0);
	type TLOAD_ENTRY_t is array(0 to 3) of std_logic_vector(47 downto 0);
	signal TLOAD_BUF 	: TLOAD_ENTRY_t := (others => (others => '0'));
	signal TLOAD_STB_I 	: std_logic := '0';

	--ALU
	signal ALU_CTRL 		: ALUCtrl_r;
	signal ALU_L 			: std_logic_vector(7 downto 0);
	signal ALU_OUT 		: std_logic_vector(7 downto 0);
	signal CO 				: std_logic;
	signal VO 				: std_logic;
	signal NO 				: std_logic;
	signal ZO 				: std_logic;
	signal MASK 			: std_logic_vector(7 downto 0);
	
	--Interrupts
	signal GOT_INT 		: std_logic;
	signal RES_INT 		: std_logic;
	signal NMI_INT 		: std_logic;
	signal IRQ1_INT 		: std_logic;
	signal IRQ2_INT 		: std_logic;
	signal IRQT_INT 		: std_logic;
	signal BRK_INT 		: std_logic;
	signal OLD_NMI_N 		: std_logic;
	signal NMI_SYNC 		: std_logic;
	signal NMI_ACTIVE 	: std_logic;

begin
	
	EN <= RDY and CE;

	NEXT_IR <= IR when (STATE /= "00000") else
				 x"00" when GOT_INT = '1' else 
				 DI; 

	
	process(IR, STATE, P, DR)
	begin
		BRANCH_TAKEN <= '0';
		if IR(4 downto 0) = "10000" and STATE = "00001" then
			case IR(7 downto 5) is
				when "000" => BRANCH_TAKEN <= not P(FLAG_N); -- BPL
				when "001" => BRANCH_TAKEN <=     P(FLAG_N); -- BMI
				when "010" => BRANCH_TAKEN <= not P(FLAG_V); -- BVC
				when "011" => BRANCH_TAKEN <=     P(FLAG_V); -- BVS
				when "100" => BRANCH_TAKEN <= not P(FLAG_C); -- BCC
				when "101" => BRANCH_TAKEN <=     P(FLAG_C); -- BCS
				when "110" => BRANCH_TAKEN <= not P(FLAG_Z); -- BNE
				when "111" => BRANCH_TAKEN <=     P(FLAG_Z); -- BEQ
				when others => BRANCH_TAKEN <= '0';
			end case; 
		elsif IR(3 downto 0) = "1111" and STATE = "00101" then
			if DR(to_integer(unsigned(IR(6 downto 4)))) = IR(7) then
				BRANCH_TAKEN <= '1';
			end if; 
		end if; 
	end process;
	
	MEM_INST <= '1' when DI = x"69" or DI = x"65" or DI = x"75" or DI = x"72" or DI = x"61" or DI = x"71" or DI = x"6D" or DI = x"7D" or DI = x"79" or 
								DI = x"29" or DI = x"25" or DI = x"35" or DI = x"32" or DI = x"21" or DI = x"31" or DI = x"2D" or DI = x"3D" or DI = x"39" or
								DI = x"09" or DI = x"05" or DI = x"15" or DI = x"12" or DI = x"01" or DI = x"11" or DI = x"0D" or DI = x"1D" or DI = x"19" or
								DI = x"49" or DI = x"45" or DI = x"55" or DI = x"52" or DI = x"41" or DI = x"51" or DI = x"4D" or DI = x"5D" or DI = x"59"
								else '0';

	
	process(MC, IR, STATE, BRANCH_TAKEN, P, MEM_INST, GOT_INT, A, LH)
	begin
		case MC.STATE_CTRL is
			when "00" => 
				if MEM_INST = '1' and P(FLAG_T) = '1' and STATE = "00000" and GOT_INT = '0' then
					NEXT_STATE <= "01000";
				else
					NEXT_STATE <= STATE + 1; 
				end if;
			when "01" => 
				if P(FLAG_D) = '0' then
					NEXT_STATE <= "00000";
				else
					NEXT_STATE <= STATE + 1;
				end if;
			when "10" => 
				if BRANCH_TAKEN = '1' then
					NEXT_STATE <= STATE + 1;
				else
					NEXT_STATE <= "00000";
				end if; 
			when "11" => 
				if A = x"00" and LH = x"00" then
					NEXT_STATE <= STATE + 1;
				else
					NEXT_STATE <= "01110";
				end if; 
			when others =>
				NEXT_STATE <= STATE;
		end case;
	end process;

	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			IR <= (others=>'0');
			STATE <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				IR <= NEXT_IR;
				STATE <= NEXT_STATE;
			end if;
		end if;
	end process; 

	LAST_CYCLE <= '1' when NEXT_STATE = "00000" else '0';
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			TALT <= '0';
		elsif rising_edge(CLK) then
			if EN = '1' then
				if STATE = "01101" then
					TALT <= '0';
				elsif STATE = "10011" then
					TALT <= not TALT;
				end if; 
			end if; 
		end if;
	end process;
	
	MCODE: entity work.HUC6280_MC
	port map (
		CLK		=> CLK,
		RST_N		=> RST_N,
		EN			=> EN,
		IR			=> NEXT_IR,
		STATE		=> NEXT_STATE,
		M			=> MC
	);
	
	process(MC, IR, STATE, TALT)
	begin
		ALU_CTRL <= MC.ALU_CTRL;
		if IR = x"E3" and (STATE = 16 or STATE = 17) then
			ALU_CTRL.secOp(2) <= TALT;
		elsif IR = x"F3" and (STATE = 14 or STATE = 15) then
			ALU_CTRL.secOp(2) <= TALT;
		end if;
	end process;
		
	process(IR)
	begin
		case IR(6 downto 4) is
			when "000"  => MASK <= x"01";
			when "001"  => MASK <= x"02";
			when "010"  => MASK <= x"04";
			when "011"  => MASK <= x"08";
			when "100"  => MASK <= x"10";
			when "101"  => MASK <= x"20";
			when "110"  => MASK <= x"40";
			when others => MASK <= x"80";
		end case; 
	end process;

	with MC.ALUBUS_CTRL select
		ALU_L <= DI     	when "0000",
					A        when "0001",
					X        when "0010",
					Y        when "0011",
					SP			when "0100",
					T        when "0101",
					SH       when "1000",
					DH       when "1001",
					LH	   	when "1010",
					MPR_OUT	when "1011",
					MASK     when "1100",
					x"00"		when others;
			
	ALU: entity work.ALU
	port map (
		CLK		=> CLK,
		EN			=> EN,
		L     	=> ALU_L,
		R     	=> DI,
		CTRL   	=> ALU_CTRL,
		BCD     	=> P(FLAG_D),
		CI   	 	=> P(FLAG_C),
		VI  		=> P(FLAG_V),
		NI  		=> P(FLAG_N),
		CO   		=> CO,
		VO    	=> VO,
		NO   		=> NO,
		ZO   		=> ZO,
		RES		=> ALU_OUT
	);

				  
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			A <= (others=>'0');
			X <= (others=>'0');
			Y <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				if MC.AXY_CTRL(0) = '1' then
					A <= ALU_OUT;
				end if; 
				if MC.AXY_CTRL(1) = '1' then
					X <= ALU_OUT;
				end if; 
				if MC.AXY_CTRL(2) = '1' then
					Y <= ALU_OUT;
				end if; 
			end if; 
		end if;
	end process;
				  
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			T <= (others=>'0');
			TLOAD_BUF <= (others => (others => '0'));
			TLOAD_STB_I <= '0';
		elsif rising_edge(CLK) then
			TLOAD_STB_I <= '0';
			-- synthesis folds this away entirely when DBG_PROBES = 0
			if EN = '1' then 
				case MC.LOAD_T is
					when "001" => T <= ALU_OUT;
					when "010" => T <= X;
					when "011" => T <= Y;
					when "100" => T <= DI;
					when others => null;
				end case;
				-- Record EVERY commit into T, not just the DI case. TAM's own microcode
				-- row (IR=$53, STATE=1, "[PC]->T") uses LOAD_T="001", which this CPU
				-- decodes as T <= ALU_OUT -- so a probe watching only "100" would never
				-- fire for the instruction under investigation.
				-- DI and ALU_OUT are captured together because they are different
				-- suspects: DI wrong means the fetch returned stale data; ALU_OUT wrong
				-- while DI is right means the ALU passthrough or its control is at fault.
				-- ADDR_BUS says which byte the CPU was addressing when it committed.
				if DBG_PROBES = 1 and MC.LOAD_T /= "000" then
					TLOAD_STB_I <= '1';
					TLOAD_BUF(0) <= IR & DI & ADDR_BUS & ALU_OUT & std_logic_vector(STATE) & MC.LOAD_T;
					for k in 1 to 3 loop
						TLOAD_BUF(k) <= TLOAD_BUF(k-1);
					end loop;
				end if;
			end if; 
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			SP <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				case MC.LOAD_SP is
					when "001" => 
						SP <= ALU_OUT;
					when "010"=> 
						SP <= std_logic_vector(unsigned(SP) + 1);
					when "011" => 
						SP <= std_logic_vector(unsigned(SP) - 1);
					when others => null;
				end case;
			end if; 
		end if;
	end process;
	
	--Status register
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			P <= "00000100";
		elsif rising_edge(CLK) then
			if EN = '1' then
				case MC.LOAD_P is
					when "001" =>  -- ALU
						P(FLAG_Z) <= ZO; 
						P(FLAG_N) <= NO;
					when "010" => 	-- BRK/interrupts
						P(FLAG_I) <= '1'; 
						P(FLAG_D) <= '0';	
					when "011" =>  -- RTI/PLP
						P <= DI; 
					when "100" => 
						case IR(7 downto 6) is
							when "00" => P(FLAG_C) <= IR(5); -- CLC/SEC 18/38
							when "01" => P(FLAG_I) <= IR(5); -- CLI/SEI 58/78
							when "10" => P(FLAG_V) <= '0';   -- CLV B8
							when "11" => P(FLAG_D) <= IR(5); -- CLD/SED D8/F8
							when others => null;
						end case;
					when "101" =>  -- ALU
						P(FLAG_C) <= CO; 
						P(FLAG_Z) <= ZO;
						P(FLAG_V) <= VO;
						P(FLAG_N) <= NO;
					when "110" => 	-- SET
						P(FLAG_T) <= '1'; 
					when "111" =>	-- clear T
						P(FLAG_T) <= '0'; 
					when others => null;
				end case;
				
				if NEXT_IR /= x"00" and STATE = "00000" then
					P(FLAG_T) <= '0';  
				end if;
			end if;
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			SH <= (others=>'0');
			DH <= (others=>'0');
			LH <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				case MC.LOAD_SDLH is
					when "01" => SH <= ALU_OUT;
					when "10" => DH <= ALU_OUT;
					when "11" => LH <= ALU_OUT;
					when others => null;
				end case;
			end if; 
		end if;
	end process;

	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			MPR(0) <= (others=>'0');
			MPR(1) <= (others=>'0');
			MPR(2) <= (others=>'0');
			MPR(3) <= (others=>'0');
			MPR(4) <= (others=>'0');
			MPR(5) <= (others=>'0');
			MPR(6) <= (others=>'0');
			MPR(7) <= (others=>'0');
			TAM_CNT <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				if IR = x"53" and LAST_CYCLE = '1' then	--TAMi
					for i in 0 to 7 loop
						if T(i) = '1' then
							MPR(i) <= A;
						end if;
					end loop;
					MPR_LAST <= A;
					if DBG_PROBES = 1 then
						TAM_CNT <= TAM_CNT + 1;
					end if;
				end if;
			end if; 
		end if;
	end process;
	
	gen_dbg_probes : if DBG_PROBES = 1 generate
		MPR_DBG <= MPR(7) & MPR(6) & MPR(5) & MPR(4) & MPR(3) & MPR(2) & MPR(1) & MPR(0);
		TAM_DBG <= std_logic_vector(TAM_CNT) & IR & T & A;
		TLOAD_DBG <= TLOAD_BUF(3) & TLOAD_BUF(2) & TLOAD_BUF(1) & TLOAD_BUF(0);
		TLOAD_STB <= TLOAD_STB_I;
		SEL_DBG <= MPR_SEL & ADDR_BUS(15 downto 13) & MC.ADDR_BUS & A_OUT_BANK;
	end generate;
	gen_no_dbg_probes : if DBG_PROBES /= 1 generate
		MPR_DBG   <= (others => '0');
		TAM_DBG   <= (others => '0');
		TLOAD_DBG <= (others => '0');
		TLOAD_STB <= '0';
		SEL_DBG   <= (others => '0');
	end generate;

	MPR_OUT <= MPR(0) when T(0) = '1' else
				  MPR(1) when T(1) = '1' else
				  MPR(2) when T(2) = '1' else
				  MPR(3) when T(3) = '1' else
				  MPR(4) when T(4) = '1' else
				  MPR(5) when T(5) = '1' else
				  MPR(6) when T(6) = '1' else
				  MPR(7) when T(7) = '1' else
				  MPR_LAST;

	--Data bus
	with MC.OUT_BUS select
		DO <= A when "0001",
				X when "0010",
				Y when "0011",
				T when "0100",
				P(7 downto 5) & (not GOT_INT) & P(3 downto 0) when "0101",
				PC(15 downto 8) when "0110",
				PC(7 downto 0) when "0111",
				x"00" when others;
		
	process(MC, RES_INT)
	begin
		WE_N <= '1';
		if MC.OUT_BUS /= "0000" and RES_INT = '0' then
			WE_N <= '0';
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			DR <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				DR <= DI;
			end if; 
		end if;
	end process;
	
	AG: entity work.HUC6280_AG
	port map (
		CLK   		=> CLK,
		RST_N   		=> RST_N,
		CE   			=> EN,
		PC_CTRL   	=> MC.LOAD_PC,
		ADDR_CTRL	=> MC.ADDR_CTRL,
		GOT_INT		=> GOT_INT,
		DI 			=> DI,
		X     		=> X, 
		Y     		=> Y, 
		DR    		=> DR,
		PC     		=> PC, 
		AA     		=> AA
	);
	
	--Interrupts
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			OLD_NMI_N <= '1';
			NMI_SYNC <= '0';
		elsif rising_edge(CLK) then
			if RES_INT = '0' then
				OLD_NMI_N <= NMI_N;
				if NMI_N = '0' and OLD_NMI_N = '1' and NMI_SYNC = '0' then
					NMI_SYNC <= '1';
				elsif NMI_ACTIVE = '1' and LAST_CYCLE = '1' and EN = '1' then
					NMI_SYNC <= '0';
				end if;
			end if;
		end if;
	end process; 
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			RES_INT <= '1';
			NMI_INT <= '0';
			IRQ1_INT <= '0';
			IRQ2_INT <= '0';
			IRQT_INT <= '0';
			GOT_INT <= '1';
			NMI_ACTIVE <= '0';
		elsif rising_edge(CLK) then
			if RDY = '1' and CE = '1' then
				NMI_ACTIVE <= NMI_SYNC;
				
				if LAST_CYCLE = '1' and EN = '1' then
					if GOT_INT = '0' then
						GOT_INT <= ((not IRQ1_N or not IRQ2_N or not IRQT_N) and not P(FLAG_I)) or NMI_ACTIVE;
						if NMI_ACTIVE = '1' then
							NMI_ACTIVE <= '0';
						end if;
					else
						GOT_INT <= '0';
					end if;
					
					RES_INT <= '0';
					NMI_INT <= NMI_ACTIVE;
					IRQ1_INT <= not IRQ1_N and not P(FLAG_I);
					IRQ2_INT <= not IRQ2_N and not P(FLAG_I);
					IRQT_INT <= not IRQT_N and not P(FLAG_I);
				end if;
			end if;
		end if;
	end process; 
	
	BRK_INT <= '1' when IR = x"00" and GOT_INT = '0' else '0';

	--Address bus
	process(MC, PC, AA, SP, SH, DH, X, Y, STATE, IR, RES_INT, NMI_INT, BRK_INT, IRQ1_INT, IRQ2_INT, IRQT_INT, VDCNUM)
	begin
		case MC.ADDR_BUS is
			when "000" => 
				ADDR_BUS <= PC; 
			when "001"=> 
				ADDR_BUS <= AA;
			when "010" => 
				ADDR_BUS <= x"21" & SP;
			when "011" => 
				ADDR_BUS <= x"20" & AA(7 downto 0);
			when "100" => 
				ADDR_BUS(15 downto 4) <= x"FFF";
				if RES_INT = '1' then
					ADDR_BUS(3 downto 0) <= "111" & STATE(0);		--FFFE/F
				elsif NMI_INT = '1' then
					ADDR_BUS(3 downto 0) <= "110" & STATE(0);		--FFFC/D
				elsif BRK_INT = '1' then
					ADDR_BUS(3 downto 0) <= "011" & STATE(0);		--FFF6/7
				elsif IRQT_INT = '1' then
					ADDR_BUS(3 downto 0) <= "101" & STATE(0);		--FFFA/B
				elsif IRQ1_INT = '1' then
					ADDR_BUS(3 downto 0) <= "100" & STATE(0);		--FFF8/9
				elsif IRQ2_INT = '1' then
					ADDR_BUS(3 downto 0) <= "011" & STATE(0);		--FFF6/7
				else
					ADDR_BUS(3 downto 0) <= "111" & STATE(0);		--
				end if;
			when "101"=> 
				ADDR_BUS(15 downto 2) <= x"00" & "000" & VDCNUM & "00";
				case IR(5 downto 4) is
					when "00" =>   ADDR_BUS(1 downto 0) <= "00";
					when "01" =>   ADDR_BUS(1 downto 0) <= "10";
					when others => ADDR_BUS(1 downto 0) <= "11";
				end case;
			when "110"=> 
				ADDR_BUS <= SH & X;
			when "111"=> 
				ADDR_BUS <= DH & Y;
			when others => null;
		end case;
	end process;
	
	A_OUT(12 downto 0) <= ADDR_BUS(12 downto 0);
	-- PCE PORT (2026-09-07): explicit 8-way mux instead of
	--     MPR(to_integer(unsigned(ADDR_BUS(15 downto 13))))
	-- The donor form is a DYNAMICALLY INDEXED read of an 8x8 array that is written by
	-- eight one-hot enables -- a register-file shape that synthesis tools infer
	-- inconsistently (distributed RAM, LUT-ROM, or flops). It simulates perfectly in
	-- GHDL, and on real GW5A hardware the bank registers read back masked: the CPU
	-- writes MPR0=$FF/MPR1=$F8/MPR2=$01/MPR3=$02 and the trace shows A0/A0/00/00, so
	-- `jsr $4003` lands in nonexistent bank $ED instead of ROM bank 1.
	-- MPR_OUT below reads the SAME array through an explicit mux and is not implicated,
	-- which is what points at the indexed form rather than at the array itself.
	-- Same function, no dynamic index, nothing for the inference heuristics to guess at.
	MPR_SEL <= MPR(0) when ADDR_BUS(15 downto 13) = "000" else
	           MPR(1) when ADDR_BUS(15 downto 13) = "001" else
	           MPR(2) when ADDR_BUS(15 downto 13) = "010" else
	           MPR(3) when ADDR_BUS(15 downto 13) = "011" else
	           MPR(4) when ADDR_BUS(15 downto 13) = "100" else
	           MPR(5) when ADDR_BUS(15 downto 13) = "101" else
	           MPR(6) when ADDR_BUS(15 downto 13) = "110" else
	           MPR(7);

	-- Mirrored into a readable signal: A_OUT is a port and VHDL-93 cannot read it back,
	-- and SEL_DBG needs exactly what the port is being driven with.
	A_OUT_BANK <= x"FF" when MC.ADDR_BUS = "101" else MPR_SEL;
	A_OUT(20 downto 13) <= A_OUT_BANK;

	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			CS <= '0';
		elsif rising_edge(CLK) then
			if EN = '1' then
				if IR(6 downto 0) = "1010100" and STATE = "00001" then
					CS <= IR(7);
				end if; 
			end if; 
		end if;
	end process;
	
	MCYCLE <= MC.MEM_CYCLE;
	
end rtl;
	