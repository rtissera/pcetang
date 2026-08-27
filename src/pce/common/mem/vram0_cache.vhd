-- SPDX-License-Identifier: GPL-3.0-or-later

-- VRAM0 external-memory cache/refill controller.
--
-- PCE PORT (2026-08-27): despite the name below, this file is shared -- Primer 25K uses it
-- too (EXT_VRAM0=>1 there is required, not optional, same as Nano 20K -- see
-- pcetang_primer25k.vhd's header). Talks to sdram.sv's port A on Primer 25K, sdram32.sv's
-- on Nano 20K; both were widened to 16 bits alongside this file, see "port A width" below.
--
-- Why this exists: GW2AR-18C's on-chip BSRAM cannot hold VRAM0 alongside the rest of the
-- engine (docs/PORTING.md, "Nano 20K's ceiling"). VRAM0 moves to external SDRAM via port
-- A of whichever controller the board has instead. The VDC (huc6270.vhd) has no
-- wait-state input anywhere and real hardware's video timing cannot stall -- confirmed by reading huc6260.vhd: H_CNT/
-- V_CNT run unconditionally off raw CLK, not gated by DCK_CE, so stalling the VDC's
-- internal counters to wait for a slow access would corrupt the raster rather than pause
-- it. So this module presents VRAM0's EXISTING plain synchronous single-port interface
-- (address_a/data_a/wren_a/q_a, matching src/common/mem/bram_gowin.vhd's `dpram` exactly)
-- -- huc6270.vhd needs NO changes at all. Only pce_top.vhd's VRAM0 instantiation swaps,
-- behind a generic, so Console 60K/Primer 25K keep the on-chip `dpram` unchanged.
--
-- Real budget per access is a WHOLE dot-clock period, not one CLK cycle: RAM_A is
-- combinational from SLOT, which only changes on DCK_CE, so an address is held stable for
-- the entire inter-DCK_CE window (4/6/8 CLK cycles = 92.6/139/185 ns at 43.2 MHz) before
-- huc6270.vhd consumes RAM_DI at the NEXT DCK_CE edge. A cache miss can therefore do a
-- real, correct refill within the dot in the common case instead of returning stale data.
-- Only the tightest case -- 10.7 MHz dot clock, sprite fetch (SG0..SG3, zero idle slots) --
-- may not always make it; that is instrumented (dbg_deadline_miss), not silently assumed
-- away. See docs/ARCHITECTURE.md's VRAM0 section for real measured numbers.
--
-- Cache: direct-mapped, 512 lines, each line = 4 consecutive VRAM0 words (an 8-byte
-- SDRAM-line-aligned group). Index = address(10:2), tag = address(14:11), word-within-
-- line = address(1:0). This exploits the real address arithmetic in huc6270.vhd: BG_OFS_Y
-- (2:0)/SPR_LINE(3:0) select the row within a character/sprite cell and increment by 1
-- per scanline, so consecutive scanlines address consecutive words in the SAME line --
-- one line serves 4 scanlines' worth of BAT/CG/sprite-plane fetches.
--
-- PCE PORT (2026-08-27), port A width: both controllers' port A were 8 bits wide -- a
-- 16-bit VRAM0 word needed two full sequential REQ/WAIT handshakes (byte_seq's old 7-state
-- SEQ_REQ_LO/.../SEQ_WAIT_HI_LO shape), ~163 ns of pure protocol overhead per word on top
-- of the real SDRAM access time. Both controllers' RAM_A_DI/RAM_A_DO are now 16 bits
-- (sdram.sv via a new wide_acc flag gating its shared DQM byte-mask logic; sdram32.sv
-- directly, since port A there has no write-sharing with port B to disturb) -- see their
-- headers. byte_seq below now does ONE handshake per word (SEQ_REQ/SEQ_WAIT_RISE/
-- SEQ_WAIT_FALL/SEQ_DONE).
--
-- STORAGE: 4 separate dpram(9,18) instances, one per word-within-line position -- 16 data
-- bits plus the valid bit at bit 16 (bit 17 padding, see below), so a write to one word
-- never disturbs the other 3 words physically, and the valid bit comes back in the SAME
-- read as the data. A 512x4-bit `tag_mem` (one tag per line, dpram(9,4)) is the only other
-- metadata.
--
-- This storage shape went through three real gw_sh-diagnosed failures before landing here
-- -- each a genuine finding, not a guess corrected by inspection:
--   1. A first version kept per-word valid as a separate plain VHDL signal array (2048
--      individually clock-enabled flip-flops, each needing its own dynamic 512-way index
--      decode) instead of folding it into the way memories. Real cost: 96 SSRAM units +
--      7726 LUT + 2343 registers, and it was the direct cause of 1545 real timing
--      violations (uniform ~24.3 ns delay on every one -- the signature of one shared
--      high-fanout net, not many congested paths).
--   2. data_width=17 for the folded valid+data ways is not a native Gowin BSRAM width
--      (native widths are 1/2/4/8/9/16/18/32/36) -- fell back to LUT storage entirely.
--      Fixed by padding to 18 (bit 17 unused).
--   3. The real, dominant cause, found only by a real bisection (not inspection): this
--      module's ways originally used port B as a second, INDEPENDENTLY-ADDRESSED write
--      port (for refill installs, at seq_idx, while port A -- live access -- wrote at
--      address_a). True dual-port write at two different addresses is not inferable from
--      src/common/mem/bram_gowin.vhd's shared-variable `dpram` template at all -- the
--      fallback isn't a mild spill to distributed RAM, it's the SAME 2048-flip-flop/
--      per-bit-decode shape as failure 1, just reached a different way (58,735 LUT,
--      0 BSRAM, 0 SSRAM, confirmed by synthesizing this module standalone with every port
--      as a real pin so nothing could be constant-folded away). A secondary, independent
--      contributor: the port-A conditional muxes on way_data_a/way_wren_a (a chain of
--      "when way_of(address_a) = k else" comparisons) also kept the ways out of BSRAM
--      even with the dual-write-port issue fixed alone -- fixing only one of the two
--      left it broken, which is why an earlier one-hot-only attempt showed no change.
--      Fixed by both: reducing to a SINGLE write port (port A only -- the refill install
--      now steals port A for the one cycle it needs, seq_idx instead of address_a, which
--      is harmless since q_a is only consumed at the next DCK_CE, 4-8 cycles away and
--      address_a is stable across the whole dwell), and a one-hot `way_sel` replacing the
--      computed-index compares so way_data_a's write value has no conditional at all.
--
-- Correctness invariants (unchanged in substance throughout all of the above -- the
-- storage moved, the rules didn't):
--   1. A write only clears the OTHER 3 words' valid bits if the line's tag actually
--      CHANGES. Sequential fills (DESR/CPU_VRAM_ADDR auto-increment, the dominant VRAM
--      write pattern) walk word 0,1,2,3 of one line in order; clearing unconditionally
--      would make every write invalidate the ones before it. On a tag change, the write
--      and the three clears happen as four parallel single-cycle writes (one to each
--      way's own port A, all at the same index, same cycle) -- not a sequence, and not a
--      read-modify-write, because each way is a separate physical memory. With `way_sel`
--      one-hot, this needs no conditional on the data path either: a word being
--      invalidated writes don't-care data with valid='0' via the same unconditional
--      expression as a real write.
--   2. A refill captures (index, tag, way) at launch and installs its result via port A
--      (stealing it for one cycle, see above) only if the line's tag (checked through
--      tag_mem's own dedicated port B) still matches, that word's valid bit is currently
--      0 (checked through the SAME dedicated port B read, seq_idx-addressed -- NOT port
--      A's own output, which reflects the LIVE access's address, not seq_idx; reading
--      port A's output here was a real bug present from the first working version of this
--      invariant through the storage rewrite above, caught only once port B was freed up
--      as a read port by the dual-write-port fix), and no write is committing THIS CYCLE
--      AT ALL (not just to the same index/way -- port A can only serve one writer per
--      cycle, so any live write defers any install, unconditionally; see the
--      refill_can_install wiring for why deferring is always safe/self-correcting).
--      This closes several races at once: a tag change mid-refill, a write landing on
--      the same word its own miss triggered a refill for, a same-cycle write/install
--      collision on the same address, and -- found only once port A became the shared
--      single write port for BOTH paths -- a write to an unrelated address contending
--      for that same one port the same cycle.
--   3. Writes are write-through, queued through a depth-4 FIFO (not a single register)
--      with address coalescing -- measured from the SLOT tables that sustained CPU tile
--      upload (VM="00" BG fetch: CPU slots every 2 dots = 185 ns at 10.7 MHz) can arrive
--      faster than one drain completes when it queues behind an in-flight refill, and
--      this is the NORMAL case for real games, not a corner one.
--
-- Port allocation:
--   way_k port A: the only writer. Live access (address_a) normally; diverted to seq_idx
--     for exactly the one cycle a refill install commits (q_a_i holds through that cycle,
--     see cache_ctrl -- safe because address_a doesn't change mid-dwell).
--   way_k port B: read-only, dedicated to the sequencer's own valid-bit check for
--     invariant 2 (seq_idx-addressed, wren_b tied low).
--   tag_mem port A: the only writer (live access, write-through only -- refills never
--     change tag, see invariant 2). tag_mem port B: read-only, the sequencer's
--     tag-still-matches check (seq_idx-addressed).
--
-- CDC: this module lives entirely in the core clock domain (same CLK as huc6270.vhd) and
-- drives sdram32's RAM_A_* ports directly, exactly like src/boards/tang_nano20k/bringup/
-- nano20k_sdram_test.vhd's proven pattern -- REQ held until WAIT is OBSERVED high, then
-- held until WAIT falls, THEN the result is captured.
--
-- Signal ownership (each written by exactly one process -- a signal written from two
-- processes is a real VHDL multi-driver bug, not just a style issue, caught once already
-- in an earlier draft of this file): cache_ctrl owns req_*/q_a_i/refill_pending/
-- refill_addr/refill_started; byte_seq owns seq_*/ram_a_*/drain_ptr; write_fifo owns
-- fifo_*. Cross-process references are reads only.
--
-- NOT VERIFIED ON HARDWARE. GHDL-tested against synthetic access patterns (sim/
-- tb_vram0_cache.vhd) before integration, same discipline as the sprite-line-buffer fix.
--
-- REAL BUG FOUND AND FIXED (2026-08-26): ram_a_rd_n was driven as `not seq_is_write`
-- (two call sites, byte_seq's SEQ_REQ_LO/SEQ_REQ_HI states) -- inverted against BOTH real
-- controllers this module talks to. sdram.sv:166 (`we <= RAM_A_RD_n`) and sdram32.sv:286
-- (`we <= a_rd_n_d`) independently agree on RAM_A_RD_n: 0=read, 1=write. The inverted
-- polarity meant every real write-drain issued a READ command and every real read-refill
-- issued a WRITE -- VRAM0 external memory would never have worked on real hardware.
-- GHDL simulation never caught this because tb_vram0_cache.vhd's mock SDRAM responder
-- mirrors the same (wrong) polarity assumption as this file, so both sides agreed with
-- each other while disagreeing with the real controllers. Fixed by removing the `not`.
-- No dbg_deadline_miss/dbg_fifo_overflow instrumentation existed to catch this at runtime
-- either -- both debug outputs are tied to `open` in pce_top.vhd's gen_vram0_ext block on
-- every board using this module today. Found via an Opus research pass cross-reading this
-- file against both real consumer controllers directly, not from a hardware report.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vram0_cache is
   port (
      clock      : in  std_logic;                      -- core clock (CLK / clk_pce)
      dck_ce     : in  std_logic;                       -- VDC_CLKEN: marks a new access

      address_a  : in  std_logic_vector(14 downto 0);   -- VRAM0 word address (32K words)
      data_a     : in  std_logic_vector(15 downto 0);
      wren_a     : in  std_logic;
      q_a        : out std_logic_vector(15 downto 0);

      -- sdram32 port A -- same clock domain as `clock`; the crossing into clk_sdram
      -- happens inside sdram32 itself, same as every other consumer of that port.
      ram_a_addr : out std_logic_vector(20 downto 0);
      ram_a_req  : out std_logic;
      ram_a_rd_n : out std_logic;
      -- PCE PORT (2026-08-27): widened 8->16 bits, matching sdram.sv/sdram32.sv's port A
      -- width fix -- see byte_seq below and both controllers' headers. One handshake now
      -- moves a whole VRAM0 word instead of two.
      ram_a_di   : out std_logic_vector(15 downto 0);
      ram_a_do   : in  std_logic_vector(15 downto 0);
      ram_a_wait : in  std_logic;

      -- Instrumentation, not function: both pulse for one `clock` cycle on the event they
      -- name. Wire to spare LEDs/a counter on a real bring-up; see docs/PORTING.md.
      dbg_deadline_miss : out std_logic;   -- a refill did not complete before the next DCK_CE
      dbg_fifo_overflow : out std_logic    -- the write FIFO was full when a new write arrived
   );
end entity;

architecture rtl of vram0_cache is

   function to_sl(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function;

   component dpram is
      generic (
         addr_width    : integer := 8;
         data_width    : integer := 8;
         mem_init_file : string  := " ";
         disable_value : std_logic := '1'
      );
      port (
         clock     : in  std_logic;
         address_a : in  std_logic_vector(addr_width-1 downto 0);
         data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
         enable_a  : in  std_logic := '1';
         wren_a    : in  std_logic := '0';
         q_a       : out std_logic_vector(data_width-1 downto 0);
         cs_a      : in  std_logic := '1';
         address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
         data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
         enable_b  : in  std_logic := '1';
         wren_b    : in  std_logic := '0';
         q_b       : out std_logic_vector(data_width-1 downto 0);
         cs_b      : in  std_logic := '1'
      );
   end component;

   subtype idx_t is unsigned(8 downto 0);
   subtype tag_t is unsigned(3 downto 0);

   function idx_of(a : std_logic_vector(14 downto 0)) return idx_t is
   begin
      return unsigned(a(10 downto 2));
   end function;
   function tag_of(a : std_logic_vector(14 downto 0)) return tag_t is
   begin
      return unsigned(a(14 downto 11));
   end function;
   function way_of(a : std_logic_vector(14 downto 0)) return integer is
   begin
      return to_integer(unsigned(a(1 downto 0)));
   end function;

   -- 4 ways: way k holds word-position k of every line. Bit 16 = valid, 15:0 = data, bit
   -- 17 padding (unused -- 18 is a native Gowin BSRAM width, 17 is not; see header).
   type way_addr_t is array (0 to 3) of std_logic_vector(8 downto 0);
   type way_data_t is array (0 to 3) of std_logic_vector(17 downto 0);
   signal way_addr_a, way_addr_b : way_addr_t;
   signal way_wren_a             : std_logic_vector(0 to 3);
   signal way_data_a             : way_data_t;
   signal way_q_a, way_q_b       : way_data_t;

   signal tag_addr_a, tag_addr_b : std_logic_vector(8 downto 0);
   signal tag_wren_a             : std_logic;
   signal tag_data_a             : std_logic_vector(3 downto 0);
   signal tag_q_a, tag_q_b       : std_logic_vector(3 downto 0);

   -- Registered view of the address a read/write targeted, aligned with the 1-cycle
   -- latency of the way/tag dprams (address presented this cycle, q_a/hit valid next
   -- cycle).
   signal req_addr_d  : std_logic_vector(14 downto 0) := (others => '0');
   signal req_valid_d : std_logic := '0';
   signal req_wr_d    : std_logic := '0';
   signal req_wdata_d : std_logic_vector(15 downto 0) := (others => '0');

   -- True when a live write's target line has a different tag than what's currently
   -- stored there -- drives the "clear the other 3 words' valid bits" side of invariant
   -- 1. Combinational, compared against the LIVE address_a/wren_a: RAM_A is held stable
   -- for the whole inter-DCK_CE dwell before RAM_WE ever pulses (huc6270.vhd's SLOT mux),
   -- so tag_q_a has already settled to the correct value by the time a write's wren_a
   -- fires -- a live, undelayed compare is correct, no extra register stage needed.
   signal tag_changed_live : std_logic;

   signal way_sel : std_logic_vector(0 to 3);   -- one-hot decode of address_a's word bits
   signal hit : std_logic;

   -- Write FIFO: depth 4, address-coalescing. Owned solely by write_fifo.
   constant FIFO_DEPTH : integer := 4;
   type fifo_addr_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(14 downto 0);
   type fifo_data_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(15 downto 0);
   signal fifo_addr  : fifo_addr_t;
   signal fifo_data  : fifo_data_t;
   signal fifo_valid : std_logic_vector(0 to FIFO_DEPTH-1) := (others => '0');

   -- Byte sequencer: services either a write-drain (popped from the FIFO) or a read
   -- refill (the word that just missed), one at a time. Writes have priority -- losing a
   -- write is worse than a slow refill, and real VRAM write bursts and dense BG/SPR fetch
   -- do not overlap in practice (DMA/CPU-heavy writes run during BURST/vblank, when the
   -- BAT/CG/sprite fetch slots are not active). Owned solely by byte_seq (drain_ptr
   -- included).
   -- PCE PORT (2026-08-27): collapsed from 7 states (two full 8-bit handshakes per 16-bit
   -- word) to 5 -- one handshake, now that ram_a_di/do are 16 bits wide. See byte_seq.
   type seq_state_t is (SEQ_IDLE, SEQ_REQ, SEQ_WAIT_RISE, SEQ_WAIT_FALL, SEQ_DONE);
   signal seq_state : seq_state_t := SEQ_IDLE;
   signal seq_is_write  : std_logic := '0';
   signal seq_addr      : std_logic_vector(14 downto 0) := (others => '0');
   signal seq_wdata     : std_logic_vector(15 downto 0) := (others => '0');
   signal seq_rdata     : std_logic_vector(15 downto 0) := (others => '0');
   signal seq_idx       : idx_t := (others => '0');
   signal seq_tag       : tag_t := (others => '0');
   signal seq_way       : integer range 0 to 3 := 0;
   signal seq_fifo_slot : integer range 0 to FIFO_DEPTH-1 := 0;
   signal drain_ptr     : integer range 0 to FIFO_DEPTH-1 := 0;

   -- Pending-refill tracking for the CURRENT access (the one huc6270.vhd is waiting on).
   -- Owned solely by cache_ctrl.
   signal refill_pending : std_logic := '0';
   signal refill_addr    : std_logic_vector(14 downto 0) := (others => '0');
   signal refill_started : std_logic := '0';

   signal q_a_i : std_logic_vector(15 downto 0) := (others => '0');

   -- True the cycle a completed refill is ready to install -- shared by the port-A write
   -- wiring so the guard is computed once, not duplicated.
   signal refill_can_install : std_logic;

begin

   gen_ways: for k in 0 to 3 generate
      way_k: dpram
      generic map (addr_width => 9, data_width => 18)
      port map (
         clock     => clock,
         address_a => way_addr_a(k),
         data_a    => way_data_a(k),
         wren_a    => way_wren_a(k),
         q_a       => way_q_a(k),
         address_b => way_addr_b(k),
         data_b    => (others => '0'),
         wren_b    => '0',
         q_b       => way_q_b(k)
      );
   end generate;

   tag_mem: dpram
   generic map (addr_width => 9, data_width => 4)
   port map (
      clock     => clock,
      address_a => tag_addr_a,
      data_a    => tag_data_a,
      wren_a    => tag_wren_a,
      q_a       => tag_q_a,
      address_b => tag_addr_b,
      data_b    => (others => '0'),
      wren_b    => '0',
      q_b       => tag_q_b
   );

   ------------------------------------------------------------------ port A: live access
   gen_way_sel: for k in 0 to 3 generate
      way_sel(k) <= '1' when unsigned(address_a(1 downto 0)) = k else '0';
   end generate;

   -- SINGLE write port (see header, storage failure 3). The refill install steals port A
   -- for the one cycle it needs; harmless because q_a is only consumed at the next
   -- DCK_CE, 4-8 cycles away, and address_a is stable across the whole dwell.
   gen_way_a_wiring: for k in 0 to 3 generate
      way_addr_a(k) <= std_logic_vector(seq_idx) when refill_can_install = '1'
                       else address_a(10 downto 2);
      way_data_a(k) <= '0' & '1' & seq_rdata when refill_can_install = '1'
                       else '0' & way_sel(k) & data_a;
      way_wren_a(k) <= (refill_can_install and to_sl(seq_way = k))
                       or ((not refill_can_install) and wren_a
                           and (way_sel(k) or tag_changed_live));
   end generate;

   tag_addr_a <= address_a(10 downto 2);
   tag_data_a <= std_logic_vector(tag_of(address_a));
   tag_wren_a <= wren_a and tag_changed_live;
   tag_changed_live <= to_sl(unsigned(tag_q_a) /= tag_of(address_a));

   -- hit still compares against req_addr_d (address_a delayed one cycle by cache_ctrl
   -- below) -- lines up with way_q_a/tag_q_a's own one-cycle dpram read latency for
   -- whichever access last triggered a miss-check.
   hit <= way_q_a(way_of(req_addr_d))(16)
          and to_sl(unsigned(tag_q_a) = tag_of(req_addr_d));

   q_a <= q_a_i;

   ------------------------------------------------------------------ cache_ctrl
   -- Owns: req_addr_d/req_valid_d/req_wr_d/req_wdata_d, q_a_i, refill_pending,
   -- refill_addr, refill_started, dbg_deadline_miss.
   process (clock)
   begin
      if rising_edge(clock) then
         req_addr_d  <= address_a;
         req_valid_d <= dck_ce;
         req_wr_d    <= wren_a;
         req_wdata_d <= data_a;

         -- Hold q_a_i through any cycle in which the refill install has diverted port A's
         -- address away from the live access -- way_q_a reflects seq_idx that cycle, not
         -- req_addr_d. Safe to hold: address_a is stable for the whole inter-DCK_CE dwell,
         -- so the value held is the same one the next cycle would re-read.
         if refill_can_install = '1' then
            null;
         elsif req_wr_d = '1' then
            q_a_i <= req_wdata_d;
         else
            q_a_i <= way_q_a(way_of(req_addr_d))(15 downto 0);
         end if;

         -- Detect a fresh miss on a read; latch it as the pending refill target.
         if req_valid_d = '1' and req_wr_d = '0' and hit = '0' and refill_pending = '0' then
            refill_pending <= '1';
            refill_addr    <= req_addr_d;
            refill_started <= '0';
         end if;
         if seq_state = SEQ_REQ and seq_is_write = '0' and seq_addr = refill_addr then
            refill_started <= '1';
         end if;
         if seq_state = SEQ_DONE and seq_is_write = '0' and seq_addr = refill_addr then
            refill_pending <= '0';
         end if;

         -- Deadline-miss instrumentation and give-up: a NEW access arrived while the
         -- previous one's refill was still outstanding (whether or not it had even
         -- started). The sequencer keeps running to completion regardless; this only
         -- stops treating it as "still needed for the access that requested it."
         dbg_deadline_miss <= dck_ce and refill_pending;
         if dck_ce = '1' and refill_pending = '1' then
            refill_pending <= '0';
         end if;
      end if;
   end process;

   ------------------------------------------------------------------ write_fifo
   -- Owns: fifo_addr, fifo_data, fifo_valid, dbg_fifo_overflow.
   process (clock)
      variable found   : boolean;
      variable free    : integer range 0 to FIFO_DEPTH;
      variable free_i  : integer range 0 to FIFO_DEPTH-1;
   begin
      if rising_edge(clock) then
         dbg_fifo_overflow <= '0';

         if wren_a = '1' then
            found := false;
            for i in 0 to FIFO_DEPTH-1 loop
               if fifo_valid(i) = '1' and fifo_addr(i) = address_a then
                  fifo_data(i) <= data_a;   -- coalesce: newest value wins
                  found := true;
               end if;
            end loop;
            if not found then
               free := FIFO_DEPTH;
               for i in 0 to FIFO_DEPTH-1 loop
                  if fifo_valid(i) = '0' and free = FIFO_DEPTH then
                     free := i;
                  end if;
               end loop;
               if free /= FIFO_DEPTH then
                  free_i := free;
                  fifo_addr(free_i)  <= address_a;
                  fifo_data(free_i)  <= data_a;
                  fifo_valid(free_i) <= '1';
               else
                  -- Full and no matching entry to coalesce into: the sequencer is
                  -- draining slower than writes are arriving. Documented, bounded risk
                  -- (see header) -- flagged, not silently dropped without a trace.
                  dbg_fifo_overflow <= '1';
               end if;
            end if;
         end if;

         if seq_state = SEQ_DONE and seq_is_write = '1' then
            fifo_valid(seq_fifo_slot) <= '0';
         end if;
      end if;
   end process;

   ------------------------------------------------------------------ byte_seq
   -- Owns: seq_*, drain_ptr, ram_a_addr/req/rd_n/di.
   process (clock)
      variable pick       : integer range 0 to FIFO_DEPTH-1;
      variable found_pick : boolean;
   begin
      if rising_edge(clock) then
         ram_a_req <= '0';

         case seq_state is
            when SEQ_IDLE =>
               found_pick := false;
               for n in 0 to FIFO_DEPTH-1 loop
                  pick := (drain_ptr + n) mod FIFO_DEPTH;
                  if fifo_valid(pick) = '1' and not found_pick then
                     found_pick    := true;
                     seq_fifo_slot <= pick;
                     seq_addr      <= fifo_addr(pick);
                     seq_wdata     <= fifo_data(pick);
                     seq_is_write  <= '1';
                     drain_ptr     <= (pick + 1) mod FIFO_DEPTH;
                     seq_state     <= SEQ_REQ;
                  end if;
               end loop;
               if not found_pick and refill_pending = '1' and refill_started = '0' then
                  seq_addr     <= refill_addr;
                  seq_is_write <= '0';
                  seq_state    <= SEQ_REQ;
               end if;

            -- PCE PORT (2026-08-27): one REQ/WAIT round trip moves the whole 16-bit word
            -- now (ram_a_di/do widened -- see both controllers' headers), replacing the
            -- old two-full-handshake low-byte/high-byte sequence. seq_addr's own bit 0 is
            -- always 0 (word-aligned), so the address is unchanged from the old low-byte
            -- launch.
            when SEQ_REQ =>
               seq_idx    <= idx_of(seq_addr);
               seq_tag    <= tag_of(seq_addr);
               seq_way    <= way_of(seq_addr);
               ram_a_addr <= "00000" & seq_addr & '0';
               ram_a_rd_n <= seq_is_write;
               ram_a_di   <= seq_wdata;
               ram_a_req  <= '1';
               seq_state  <= SEQ_WAIT_RISE;
            when SEQ_WAIT_RISE =>               -- wait for the controller to observe REQ
               ram_a_req <= '1';
               if ram_a_wait = '1' then
                  seq_state <= SEQ_WAIT_FALL;
               end if;
            when SEQ_WAIT_FALL =>               -- then wait for it to complete
               if ram_a_wait = '0' then
                  seq_rdata <= ram_a_do;
                  seq_state <= SEQ_DONE;
               end if;

            when SEQ_DONE =>
               seq_state <= SEQ_IDLE;

         end case;
      end if;
   end process;

   -- Sequencer's own dedicated read port (B) on both memories -- never contends with the
   -- live access on port A, and never writes (invariant 2's refill install goes through
   -- port A, see above). Driven from SEQ_REQ onward (seq_idx captured there), giving
   -- the whole REQ/WAIT round trip -- far more than the 1 cycle either read needs to
   -- settle -- before SEQ_DONE needs the result.
   tag_addr_b <= std_logic_vector(seq_idx);
   gen_way_b_wiring: for k in 0 to 3 generate
      way_addr_b(k) <= std_logic_vector(seq_idx);
   end generate;

   -- Port A has exactly one write source at a time: the live write always wins over a
   -- refill install, not just when they target the same (index, way). Both share port A
   -- (see the port-A wiring above), and a naive "only defer on a same-address collision"
   -- guard leaves a real gap: a write to a COMPLETELY UNRELATED address landing on the
   -- same cycle as some other refill's SEQ_DONE would still lose port A to the install
   -- (way_addr_a/way_data_a unconditionally route to the refill's target for every way
   -- that cycle), silently dropping the write's immediate cache-array update. The write
   -- itself is never lost long-term (write_fifo captures it unconditionally off wren_a,
   -- independent of this signal, so it still reaches sdram32), but a read of that address
   -- before the FIFO drains and something re-triggers a refill for it would see stale
   -- data -- a real, if narrow, gap, added to sim/tb_vram0_cache.vhd's case 5.
   -- Deferring on any wren_a is safe and self-correcting the same way a same-address
   -- collision already was: the sequencer's SEQ_DONE -> SEQ_IDLE transition and
   -- refill_pending's clear both happen unconditionally regardless of whether the install
   -- actually landed, so a deferred install just means that address misses again (and
   -- re-refills) the next time it's read, not a stuck or lost state.
   refill_can_install <= to_sl(seq_state = SEQ_DONE and seq_is_write = '0')
      and to_sl(unsigned(tag_q_b) = seq_tag)
      and not way_q_b(seq_way)(16)
      and not wren_a;

end architecture;
