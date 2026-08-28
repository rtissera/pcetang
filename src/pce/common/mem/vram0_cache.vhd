-- SPDX-License-Identifier: GPL-3.0-or-later

-- VRAM0 external-memory cache/refill controller.
--
-- PCE PORT (2026-08-27): despite the name below, this file is shared -- Primer 25K uses it
-- too (EXT_VRAM0=>1 there is required, not optional, same as Nano 20K -- see
-- pcetang_primer25k.vhd's header). Talks to sdram.sv's port A on Primer 25K, sdram32.sv's
-- on Nano 20K; both were widened to 16 bits alongside this file, see "port A width" below.
--
-- Why this exists: GW2AR-18C's on-chip BSRAM cannot hold VRAM0 alongside the rest of the
-- engine (NECTang's docs/PORTING.md, "Nano 20K's ceiling"). VRAM0 moves to external SDRAM via port
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
-- huc6270.vhd consumes RAM_DI at the NEXT DCK_CE edge.
--
-- PCE PORT (2026-08-27), CORRECTED, real GHDL sim, not the claim this paragraph used to
-- make: "a cache miss can therefore do a real, correct refill within the dot in the
-- common case" is FALSE AS IMPLEMENTED, not just in the tightest sprite-fetch case. The
-- miss-check itself lands one whole dot late structurally (dck_ce marks the END of a
-- dwell, not the start -- address_a only becomes the NEW dot's target the cycle AFTER
-- dck_ce, but req_valid_d, dck_ce delayed by exactly one register stage, still checks
-- against req_addr_d holding the ENDING dot's address). Real measured severity: even a
-- 12-line working set with ZERO cache conflicts (every miss is a first-touch compulsory
-- miss, the single best case this cache can ever see) returns WRONG data on 17-34% of
-- read dots over 16 passes, and `dbg_deadline_miss` fires at a similar rate -- neither is
-- wired to anything observable on any board (`open` in pce_top.vhd's gen_vram0_ext). This
-- is not fixable by re-timing the check alone: correcting the phase (add a second
-- register stage) makes the check land on time, but huc6270.vhd's `RAM_WE` only pulses on
-- a dwell's LAST cycle, so an earlier check cannot yet tell a write dot from a read dot --
-- spurious refill launches on what turn out to be write dots contend with genuine misses
-- for `refill_pending`'s single-entry queue (force-cleared every dck_ce), making REAL
-- traffic measurably worse in 5 of 6 realistic dwell/refresh configurations, not better.
-- Real total round-trip needed even with the phase corrected: ~13 cycles (BRAM read,
-- refill_pending set, SEQ_IDLE->SEQ_REQ, REQ on bus, WAIT rise, WAIT high, WAIT fall,
-- SEQ_DONE+install, way_q_a updated, q_a_i loaded) against 8 cycles even at the most
-- generous real dot clock -- worse with a refresh collision (`sdram.sv`'s STATE_IDLE
-- checks refresh first, preempting port A). No local edit to this file closes that gap;
-- it needs the same real prefetch/redesign work as the port-A throughput problem in
-- docs/ARCHITECTURE.md, not a re-timed comparator. See docs/ARCHITECTURE.md's VRAM0
-- section for the real measured numbers and the one real, safe, shippable fix this
-- investigation DID find (a separate, smaller bug -- q_a_i's install-diversion hold was
-- one cycle short, see cache_ctrl's `install_d`).
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
--      (stealing it for one cycle, see above). Two cases, both checked through tag_mem's
--      own dedicated port B (seq_idx-addressed -- NOT port A's own output, which reflects
--      the LIVE access's address, not seq_idx; reading port A's output here was a real bug
--      present from the first working version of this invariant through the storage
--      rewrite above, caught only once port B was freed up as a read port by the
--      dual-write-port fix): if the line's tag ALREADY matches (a same-tag compulsory
--      miss), install only if that word's valid bit is currently 0 -- protects a fresher
--      live write that raced in between miss-trigger and refill-complete from being
--      clobbered by stale fetched data. If the tag does NOT match (a genuine conflict
--      eviction), install unconditionally -- see the PCE PORT (2026-08-27) Bug 2 note at
--      refill_can_install's own definition for why the ORIGINAL version of this invariant
--      required an already-matching tag as a blanket precondition, which made every real
--      eviction impossible, not just slow (real silent data corruption, GHDL-confirmed,
--      fixed this session). Either way, no write is committing THIS CYCLE AT ALL (not
--      just to the same index/way -- port A can only serve one writer per cycle, so any
--      live write defers any install, unconditionally; see the refill_can_install wiring
--      for why deferring is always safe/self-correcting). This closes several races at
--      once: a tag change mid-refill, a write landing on the same word its own miss
--      triggered a refill for, a same-cycle write/install collision on the same address,
--      and -- found only once port A became the shared single write port for BOTH paths
--      -- a write to an unrelated address contending for that same one port the same
--      cycle. On a genuine eviction, the install also writes the NEW tag into tag_mem and
--      invalidates the OTHER 3 ways at that index (mirroring invariant 1's own "clear on
--      tag change" behavior, now applied to refills too, not just live writes) -- without
--      this, a later read of one of those other words would falsely HIT against the
--      PREVIOUS line's stale data.
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
--   tag_mem port A: the only writer -- live access (write-through) normally; diverted to
--     seq_idx on a genuine eviction install, same steal pattern as way_k port A above (see
--     invariant 2; this refill-writes-tag path did NOT exist before the 2026-08-27 Bug 2
--     fix). tag_mem port B: read-only, the sequencer's tag-still-matches check
--     (seq_idx-addressed).
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
--
-- PCE PORT (2026-08-28): "line refill" -- when the new G_LINE_REFILL generic is true
-- (default FALSE -- see its own declaration-site comment for why, and for the real
-- silent-corruption trap that default avoids), a read MISS fetches the WHOLE 4-word
-- cache line in one sdram.sv port-A transaction (new `ram_a_line_refill`/
-- `ram_a_line_do`, see that controller's own "line refill" header note), not just the
-- one missed word. sdram32.sv (Nano 20K) was NOT given this mechanism this session, so
-- this file must keep working, byte-for-byte, against sdram32.sv unchanged when
-- G_LINE_REFILL is left at its default.
--
-- CORRECTION (2026-08-28, real GHDL dbg_deadline_miss measurement, see
-- scratchpad/deadline_miss_rate_measurement.md): this does NOT close the per-access
-- deadline. cache_ctrl's own give-up logic ends every outstanding refill at exactly
-- dwell-1 cycles regardless of refill speed, so a genuine miss misses its deadline
-- whether it's a single-word legacy refill or this line refill -- measured 100% both
-- ways at this project's tested dwell. What this mechanism actually buys is fewer
-- misses triggered in the first place: 75.4% of consecutive BAT fetches land in the
-- SAME cache line within a scanline (real GHDL-measured, see
-- scratchpad/vram0_deadline_implementation_plans.md and
-- scratchpad/vram0_stride_measurement.md), so BAT's real measured miss rate drops
-- 17.2%->5.44% (3.16x fewer). CG0/CG1/sprites see ~0% within-scanline reuse, so this
-- doesn't reduce THIS scanline's misses for them, but does cut FUTURE-scanline miss
-- rate by a real measured 1.6-2.0x (well under the ~4x this file originally projected
-- below) by populating all 4 rows of a tile/sprite plane at once instead of one.
--
-- When G_LINE_REFILL, byte_seq (SEQ_IDLE's refill pick) always requests the LINE's own
-- word0 (`refill_addr(14 downto 2) & "00"`), not the exact word that missed -- fixed
-- order 0,1,2,3, not critical-word-first (see sdram.sv's header for why: two fixed
-- burst-of-2 halves, not one wrapping burst-of-4). On completion, ALL 4 ways install
-- atomically in one cycle (gen_way_a_wiring), not just the one `seq_way` a single-word
-- refill used to touch. `seq_way` itself stays in the file (still meaningful, still
-- driving the single-way install) for when G_LINE_REFILL is false -- see its own
-- declaration-site comment.
--
-- Invariant 2 (this file's own documented "don't clobber a fresher live write that
-- raced in" rule) had to be generalized PER WORD for this, not left keyed on a single
-- word -- a same-tag compulsory miss can have word 1 already holding a fresher live
-- write while word 0 does not, and the ORIGINAL single-way version of this guard had
-- no way to express that once 4 ways install at once. way_wren_a(k) now checks each
-- way's own way_q_b(k)(16) independently; refill_can_install itself keeps only the
-- preconditions genuinely shared by all 4 ways (SEQ_DONE, a real read, no live write
-- this cycle) -- see gen_way_a_wiring's own comment for the fuller reasoning. Caught in
-- review before this shipped, not found the hard way via GHDL like this file's other
-- three documented bugs -- but exactly the same CLASS of mistake (a blanket check
-- silently assumed the old single-word shape still applied), so recorded with the same
-- weight as the others rather than dropped as "just a design pass."
--
-- A second real bug, found and fixed while wiring the refill_started/refill_pending
-- handshake up to a line-based seq_addr for the first time: the ORIGINAL
-- `seq_state = SEQ_REQ ... and seq_addr = refill_addr` comparisons (both cache_ctrl
-- sites) assumed seq_addr was always refill_addr's own EXACT word -- true before this
-- change, false after (seq_addr is now the line's word0, refill_addr can be any of the
-- 4 words). Left as an exact match, refill_started/refill_pending would simply never
-- update whenever the missed word wasn't already word 0 of its line -- a real,
-- would-have-shipped bug (refill_pending stuck at '1' forever, blocking every future
-- miss on that access from ever being latched again), not a hypothetical. Fixed by
-- comparing on the LINE instead (`seq_addr(14 downto 2) = refill_addr(14 downto 2)`,
-- the same bits idx_of/tag_of already use) -- see cache_ctrl's own site for the fuller
-- note.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vram0_cache is
   generic (
      -- PCE PORT (2026-08-28): this file is shared between sdram.sv (Primer 25K) and
      -- sdram32.sv (Nano 20K) -- see the header's very first paragraph. Only sdram.sv
      -- was given the line-refill mechanism this session (RAM_A_LINE_REFILL/
      -- RAM_A_LINE_DO) -- sdram32.sv was NOT touched. Defaults to FALSE deliberately:
      -- this generic must be explicitly turned on at the instantiation site (pce_top.vhd,
      -- not touched this session either) once BOTH pce_top.vhd threads the new ports
      -- up to a real board top AND that board top wires them to a controller that
      -- actually implements line-refill. Left FALSE (the default), every line below
      -- gated on it reproduces the ORIGINAL single-word-refill file byte-for-byte --
      -- confirmed by running the ORIGINAL, unmodified scratchpad/tb_vram0_cache.vhd
      -- against this file with the default generic, see line_refill_verification.md's
      -- Stage 4b. Defaulting this to TRUE instead would be the real, silent-corruption
      -- trap: pce_top.vhd's EXISTING (unmodified) instantiation would then leave
      -- ram_a_line_do unconnected while byte_seq actually asserted ram_a_line_refill
      -- and tried to read it -- on Nano 20K (sdram32.sv, which cannot answer that
      -- request at all) this would silently install all-ZERO data into all 4 ways of
      -- every refilled line, exactly the class of silent corruption this file's
      -- header already documents three times over. FALSE-by-default makes that
      -- impossible: the new ports simply go unused unless a real integration
      -- explicitly opts in.
      G_LINE_REFILL : boolean := false;

      -- PCE PORT (2026-08-28): third, lowest-priority byte_seq client for
      -- vram0_prefetch.vhd's BAT prefetch engine (see that file's own header). Defaults
      -- FALSE for the same reason G_LINE_REFILL does: an instantiation that predates
      -- this feature leaves pf_req permanently '0' (its own safe default), so the new
      -- SEQ_IDLE branch below never fires and this file is byte-identical to a version
      -- that never had it. Requires G_LINE_REFILL=true too (a pf request always expects
      -- a real 4-word line answer, see pf_rdata) -- both generics are ANDed at every use
      -- site below, not just documented as a dependency.
      G_PREFETCH : boolean := false
   );
   port (
      clock      : in  std_logic;                      -- core clock (CLK / clk_pce)
      dck_ce     : in  std_logic;                       -- VDC_CLKEN: marks a new access

      address_a  : in  std_logic_vector(14 downto 0);   -- VRAM0 word address (32K words)
      data_a     : in  std_logic_vector(15 downto 0);
      wren_a     : in  std_logic;
      q_a        : out std_logic_vector(15 downto 0);

      -- PCE PORT (2026-08-28): G_PREFETCH's pf_* channel -- a third, lowest-priority
      -- byte_seq request source (below write-drain and a genuine cache-miss refill, see
      -- byte_seq's SEQ_IDLE below), used by vram0_prefetch.vhd to fetch a whole BAT row
      -- ahead of when huc6270 needs it. A pf-sourced completion never installs into this
      -- cache's own way_k/tag_mem (see refill_can_install) -- the fetched line belongs
      -- entirely to the caller's own buffer. Safe to leave unconnected (pf_req's default
      -- '0') when G_PREFETCH is false.
      pf_addr  : in  std_logic_vector(14 downto 0) := (others => '0');
      pf_req   : in  std_logic := '0';
      pf_rdata : out std_logic_vector(63 downto 0);
      pf_done  : out std_logic;

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
      -- PCE PORT (2026-08-28): 4-word cache-line refill -- see byte_seq below and
      -- sdram.sv's own "line refill" header note, and the G_LINE_REFILL generic's own
      -- comment for why this defaults OFF. Asserted for the whole REQ/WAIT round trip
      -- of a genuine read-miss refill (never a write-drain, see byte_seq's SEQ_REQ),
      -- only when G_LINE_REFILL. ram_a_line_do holds all 4 words of the completed
      -- line, valid the same cycle ram_a_wait falls for that request -- given a safe
      -- default so an instantiation that predates this feature (or targets sdram32.sv,
      -- which doesn't drive it) can legally leave it unconnected; safe specifically
      -- BECAUSE byte_seq never reads it at all when G_LINE_REFILL is false (its default),
      -- not merely because the default value looks harmless in isolation.
      ram_a_line_refill : out std_logic;
      ram_a_line_do     : in  std_logic_vector(63 downto 0) := (others => '0');

      -- Instrumentation, not function: both pulse for one `clock` cycle on the event they
      -- name. Wire to spare LEDs/a counter on a real bring-up; see NECTang's docs/PORTING.md.
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

   -- PCE PORT (2026-08-27), Bug 2 fix: true when the line CURRENTLY at seq_idx (read live
   -- via tag_q_b) does not carry seq_tag -- a genuine conflict eviction, not a compulsory
   -- miss within an already-resident line. Drives both the tag write and the
   -- invalidate-other-3-ways step below, mirroring invariant 1's live-write behavior.
   signal refill_tag_changed : std_logic;

   -- Write FIFO: depth 4, address-coalescing. Owned solely by write_fifo.
   constant FIFO_DEPTH : integer := 4;
   type fifo_addr_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(14 downto 0);
   type fifo_data_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(15 downto 0);
   signal fifo_addr  : fifo_addr_t;
   signal fifo_data  : fifo_data_t;
   signal fifo_valid : std_logic_vector(0 to FIFO_DEPTH-1) := (others => '0');

   -- Byte sequencer: services either a write-drain (popped from the FIFO) or a read
   -- refill, one at a time. Writes have priority -- losing a write is worse than a slow
   -- refill, and real VRAM write bursts and dense BG/SPR fetch do not overlap in
   -- practice (DMA/CPU-heavy writes run during BURST/vblank, when the BAT/CG/sprite
   -- fetch slots are not active). Owned solely by byte_seq (drain_ptr included).
   -- PCE PORT (2026-08-27): collapsed from 7 states (two full 8-bit handshakes per 16-bit
   -- word) to 5 -- one handshake, now that ram_a_di/do are 16 bits wide. See byte_seq.
   -- PCE PORT (2026-08-28): when G_LINE_REFILL, a read refill fetches the whole 4-word
   -- cache line (see byte_seq's SEQ_IDLE pick and sdram.sv's own "line refill" header
   -- note), not just the one missed word -- seq_rdata widens 16->64 bits to hold all 4
   -- words (word k in bits (k*16+15 downto k*16), matching ram_a_line_do's own
   -- convention) before the atomic 4-way install below. When G_LINE_REFILL is false
   -- (the default -- see its own comment), every one of these is byte-identical to the
   -- original file: seq_addr is the exact missed word, seq_rdata's low 16 bits hold
   -- ram_a_do, and `seq_way` (which word within the line originally missed) is exactly
   -- as meaningful as it always was, still driving a single-way install.
   type seq_state_t is (SEQ_IDLE, SEQ_REQ, SEQ_WAIT_RISE, SEQ_WAIT_FALL, SEQ_DONE);
   signal seq_state : seq_state_t := SEQ_IDLE;
   signal seq_is_write  : std_logic := '0';
   -- PCE PORT (2026-08-28): true for the whole REQ..DONE round trip of a G_PREFETCH
   -- pf_req-sourced fetch, so refill_can_install can exclude it (pf data never installs
   -- into way_k/tag_mem, see that signal) and pf_done can pulse only for its own
   -- requester. Always driven '0' by both the write-drain and genuine-refill picks in
   -- byte_seq, so this is byte-identical to a file without it whenever G_PREFETCH=false.
   signal seq_is_pf      : std_logic := '0';
   signal seq_addr      : std_logic_vector(14 downto 0) := (others => '0');
   signal seq_wdata     : std_logic_vector(15 downto 0) := (others => '0');
   signal seq_rdata     : std_logic_vector(63 downto 0) := (others => '0');
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

   -- PCE PORT (2026-08-27): 1-cycle-delayed copy of refill_can_install -- extends
   -- q_a_i's install-diversion hold to 2 cycles (see cache_ctrl). Owned solely by
   -- cache_ctrl, same as q_a_i itself.
   signal install_d : std_logic := '0';

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
   -- PCE PORT (2026-08-28), line-refill install, gated by G_LINE_REFILL (see its own
   -- declaration comment for why this defaults off): when true, a refill always
   -- fetches all 4 words of the line (see byte_seq), and the install writes REAL
   -- fetched data into every way it touches -- there is no more "invalidate the other
   -- 3 ways with don't-care data" branch (that only existed because the OLD design had
   -- real data for just the one missed word; strictly better now, since a genuine
   -- eviction populates all 4 ways with fresh, correct data instead of leaving 3 of
   -- them merely invalidated to take a compulsory miss again later). Per-way guard
   -- (advisor-caught correction to the original single-way version of this comment):
   -- invariant 2's "don't clobber a fresher live write that raced in" protection MUST
   -- be evaluated per word, not just for the one word that happened to trigger the
   -- miss -- on a same-tag compulsory miss, word 1 might already hold a fresher live
   -- write while word 0 does not, and a blanket 4-way install would silently clobber
   -- it. way_wren_a(k) below checks EACH way's own way_q_b(k)(16) (already read live
   -- every cycle via way_addr_b(k)<=seq_idx, no new read port needed) instead of a
   -- single seq_way-indexed check. On a genuine eviction (refill_tag_changed='1'),
   -- every way installs unconditionally (the old tag's data there is being
   -- deliberately overwritten, mirrors invariant 1's own "clear on tag change" for
   -- live writes, just with real data instead of a clear).
   --
   -- When G_LINE_REFILL is false (the default), every expression below collapses back
   -- to EXACTLY the original single-way form: only `seq_way` installs real data
   -- (seq_rdata's low 16 bits, the only word ever fetched), the other 3 ways get the
   -- original "invalidate" pattern on a genuine eviction and are otherwise untouched --
   -- confirmed byte-for-byte against the ORIGINAL, unmodified
   -- scratchpad/tb_vram0_cache.vhd, see line_refill_verification.md's Stage 4b. This
   -- is a compile-time generic, not a runtime mux -- synthesis constant-folds away
   -- whichever half is unused, at zero cost either way.
   gen_way_a_wiring: for k in 0 to 3 generate
      way_addr_a(k) <= std_logic_vector(seq_idx) when refill_can_install = '1'
                       else address_a(10 downto 2);
      -- PCE PORT (2026-08-28) BUG FOUND AND FIXED (before this ever left this session --
      -- caught by Stage 4b's real GHDL run against the ORIGINAL testbench, not shipped):
      -- an earlier version of this line used seq_rdata((k*16+15) downto k*16) for BOTH
      -- modes -- correct for G_LINE_REFILL (seq_rdata really does hold 4 packed words
      -- then), but wrong for legacy mode, where seq_rdata's fetched word is ALWAYS in
      -- bits 15:0 regardless of which way k it installs into (only ONE word is ever
      -- fetched, for k=seq_way specifically -- see SEQ_WAIT_FALL's own
      -- `seq_rdata(15 downto 0) <= ram_a_do`). The bug: for k=seq_way with seq_way>0,
      -- it read seq_rdata's UPPER, never-written bits instead -- real data went in
      -- correctly for the very first cycle via q_a_i's install-diversion bypass (which
      -- reads seq_rdata directly, not through the way memory), then every SUBSEQUENT
      -- read of that word came back 0000 (way_q_a's actual stored value), a real,
      -- would-have-shipped silent-corruption bug in the fallback path this generic
      -- exists specifically to keep safe.
      way_data_a(k) <= '0' & '1' & seq_rdata((k*16+15) downto (k*16))
                          when (refill_can_install = '1' and G_LINE_REFILL)
                       else '0' & '1' & seq_rdata(15 downto 0)
                          when (refill_can_install = '1' and not G_LINE_REFILL and seq_way = k)
                       else "00" & x"0000"
                          when (refill_can_install = '1' and not G_LINE_REFILL)
                       else '0' & way_sel(k) & data_a;
      way_wren_a(k) <= (refill_can_install and
                          ((to_sl(G_LINE_REFILL) and (refill_tag_changed or not way_q_b(k)(16)))
                           or (to_sl(not G_LINE_REFILL) and (to_sl(seq_way = k) or refill_tag_changed))))
                       or ((not refill_can_install) and wren_a
                           and (way_sel(k) or tag_changed_live));
   end generate;

   -- PCE PORT (2026-08-27), Bug 2 fix: tag_mem now has a real refill-driven write path --
   -- previously "tag_mem port A: the only writer (live access, write-through only --
   -- refills never change tag)" was the bug itself, not a real invariant (see the header's
   -- corrected write-up). Mirrors way_addr_a/way_data_a's own mux exactly.
   tag_addr_a <= std_logic_vector(seq_idx) when refill_can_install = '1'
                else address_a(10 downto 2);
   tag_data_a <= std_logic_vector(seq_tag) when refill_can_install = '1'
                else std_logic_vector(tag_of(address_a));
   tag_wren_a <= (refill_can_install and refill_tag_changed)
                or ((not refill_can_install) and wren_a and tag_changed_live);
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
         -- PCE PORT (2026-08-27), Bug found+fixed via real GHDL sim (dispatched
         -- diagnosis, not static reasoning -- see docs/ARCHITECTURE.md): the ORIGINAL
         -- 1-cycle hold below was one cycle too short. way_k's dpram has 1-cycle read
         -- latency: way_addr_a is diverted to seq_idx during the SAME cycle
         -- refill_can_install='1' (call it cycle N), so way_q_a doesn't actually REFLECT
         -- that diverted (seq_idx) read until cycle N+1 -- by which point
         -- refill_can_install has ALREADY dropped back to '0' (it's a one-cycle pulse),
         -- so the old code's `elsif`/`else` at N+1 loaded q_a_i from way_q_a believing it
         -- was a fresh read of req_addr_d, when it was actually still the stolen cycle's
         -- seq_idx read -- another cache line's data reaching the VDC. GHDL-confirmed:
         -- measured wrong words landing in q_a at the exact +1 offset this predicts,
         -- across multiple dwell/refresh-collision configurations. Fixed by extending
         -- the hold to cover N+1 too, via install_d (a 1-cycle-delayed copy of
         -- refill_can_install) -- safe for the same reason the original 1-cycle hold
         -- was: address_a is stable for the whole inter-DCK_CE dwell, so the value held
         -- across both N and N+1 is the same one a correct read would produce once
         -- way_q_a finally reflects req_addr_d again, at N+2.
         install_d <= refill_can_install;

         -- Hold q_a_i through any cycle in which the refill install has diverted port A's
         -- address away from the live access -- way_q_a reflects seq_idx that cycle, not
         -- req_addr_d. Safe to hold: address_a is stable for the whole inter-DCK_CE dwell,
         -- so the value held is the same one the next cycle would re-read.
         if refill_can_install = '1' or install_d = '1' then
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
         -- PCE PORT (2026-08-28): a refill's seq_addr is now the LINE's own word0 (see
         -- byte_seq's SEQ_IDLE pick), not necessarily refill_addr's own exact word --
         -- an exact `seq_addr = refill_addr` match would never fire whenever the
         -- missed word wasn't word 0 of its line, permanently stranding
         -- refill_pending='1' (a real bug this session's own design review caught
         -- while wiring the line-refill request up, not shipped). idx_of/tag_of don't
         -- depend on the word-within-line bits at all, so comparing on the LINE
         -- (top 13 address bits) is both correct and exactly what "this refill covers
         -- refill_addr's line" means once a refill is whole-line, not single-word.
         if seq_state = SEQ_REQ and seq_is_write = '0'
            and seq_addr(14 downto 2) = refill_addr(14 downto 2) then
            refill_started <= '1';
         end if;
         if seq_state = SEQ_DONE and seq_is_write = '0'
            and seq_addr(14 downto 2) = refill_addr(14 downto 2) then
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
   -- Owns: seq_*, drain_ptr, ram_a_addr/req/rd_n/di/line_refill.
   process (clock)
      variable pick       : integer range 0 to FIFO_DEPTH-1;
      variable found_pick : boolean;
   begin
      if rising_edge(clock) then
         ram_a_req         <= '0';
         ram_a_line_refill <= '0';

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
                     seq_is_pf     <= '0';
                     drain_ptr     <= (pick + 1) mod FIFO_DEPTH;
                     seq_state     <= SEQ_REQ;
                  end if;
               end loop;
               -- PCE PORT (2026-08-28): when G_LINE_REFILL, a read refill always targets
               -- the LINE's own word0 (bits 1:0 forced to "00"), not the specific word
               -- that missed -- see sdram.sv's header for why fixed order 0,1,2,3 was
               -- kept instead of critical-word-first (two fixed burst-of-2 halves, not
               -- one wrapping burst-of-4, so "start at the missed word" only helps for
               -- words 0/2). When G_LINE_REFILL is false (the default), seq_addr is
               -- exactly refill_addr, byte-identical to the original file. Write-drains
               -- above are completely unaffected either way -- still single-word, still
               -- the exact popped FIFO address.
               if not found_pick and refill_pending = '1' and refill_started = '0' then
                  if G_LINE_REFILL then
                     seq_addr <= refill_addr(14 downto 2) & "00";
                  else
                     seq_addr <= refill_addr;
                  end if;
                  seq_is_write <= '0';
                  seq_is_pf    <= '0';
                  -- PCE PORT (2026-08-28): marks a pick as taken so the new pf branch
                  -- below (lowest priority) never fires the same cycle as a genuine
                  -- miss refill -- found_pick previously only tracked the write-drain
                  -- loop above, since nothing else ever needed to check it.
                  found_pick   := true;
                  seq_state    <= SEQ_REQ;
               end if;

               -- PCE PORT (2026-08-28): G_PREFETCH's third, lowest-priority pick --
               -- see this generic's own comment and vram0_prefetch.vhd's header. Never
               -- taken while a write-drain or genuine miss refill is pending this same
               -- cycle (found_pick), and inert whenever G_PREFETCH or G_LINE_REFILL is
               -- false (pf_req's own default '0' would also gate it even without the
               -- generic checks, but the explicit AND documents the hard dependency).
               if not found_pick and G_PREFETCH and G_LINE_REFILL and pf_req = '1' then
                  seq_addr     <= pf_addr;
                  seq_is_write <= '0';
                  seq_is_pf    <= '1';
                  seq_state    <= SEQ_REQ;
               end if;

            -- PCE PORT (2026-08-27): one REQ/WAIT round trip moves the whole 16-bit word
            -- now (ram_a_di/do widened -- see both controllers' headers), replacing the
            -- old two-full-handshake low-byte/high-byte sequence. seq_addr's own bit 0 is
            -- always 0 (word-aligned), so the address is unchanged from the old low-byte
            -- launch.
            -- PCE PORT (2026-08-28): ram_a_line_refill asserted for a read (never a
            -- write-drain), ONLY when G_LINE_REFILL -- held through SEQ_WAIT_RISE too,
            -- mirroring ram_a_req's own held-then-defaulted-to-0 pattern exactly
            -- (sdram.sv only actually samples it at launch, but the interface contract
            -- is "hold for the whole request", same as ram_a_rd_n/ram_a_addr). When
            -- G_LINE_REFILL is false, the top-of-process default (ram_a_line_refill<='0')
            -- is simply never overridden here -- byte-identical to a file that never
            -- had this port at all.
            when SEQ_REQ =>
               seq_idx    <= idx_of(seq_addr);
               seq_tag    <= tag_of(seq_addr);
               seq_way    <= way_of(seq_addr);
               ram_a_addr <= "00000" & seq_addr & '0';
               ram_a_rd_n <= seq_is_write;
               ram_a_di   <= seq_wdata;
               ram_a_req  <= '1';
               if G_LINE_REFILL then
                  ram_a_line_refill <= not seq_is_write;
               end if;
               seq_state  <= SEQ_WAIT_RISE;
            when SEQ_WAIT_RISE =>               -- wait for the controller to observe REQ
               ram_a_req <= '1';
               if G_LINE_REFILL then
                  ram_a_line_refill <= not seq_is_write;
               end if;
               if ram_a_wait = '1' then
                  seq_state <= SEQ_WAIT_FALL;
               end if;
            when SEQ_WAIT_FALL =>               -- then wait for it to complete
               -- PCE PORT (2026-08-28): when G_LINE_REFILL, captures the whole 4-word
               -- line (ram_a_line_do), not just the one word ram_a_do carries -- see
               -- seq_rdata's own widened declaration. Harmless to always capture the
               -- line-refill path on a write-drain too, where it's simply never read
               -- back downstream. When G_LINE_REFILL is false, only seq_rdata's low 16
               -- bits are driven (from ram_a_do), byte-identical to the original file
               -- (seq_rdata's upper 48 bits are simply never read by anything in that
               -- mode -- gen_way_a_wiring's "not G_LINE_REFILL" branches never index
               -- past bit 15, see their own site).
               if ram_a_wait = '0' then
                  if G_LINE_REFILL then
                     seq_rdata <= ram_a_line_do;
                  else
                     seq_rdata(15 downto 0) <= ram_a_do;
                  end if;
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
   -- data -- a real, if narrow, gap, added as case 5 to NECTang's sim/tb_vram0_cache.vhd
   -- (that sibling project's testbench, not present in this repo).
   -- Deferring on any wren_a is safe and self-correcting the same way a same-address
   -- collision already was: the sequencer's SEQ_DONE -> SEQ_IDLE transition and
   -- refill_pending's clear both happen unconditionally regardless of whether the install
   -- actually landed, so a deferred install just means that address misses again (and
   -- re-refills) the next time it's read, not a stuck or lost state.
   -- PCE PORT (2026-08-27), Bug 2 FOUND AND FIXED: `and to_sl(unsigned(tag_q_b) = seq_tag)`
   -- used to be an unconditional precondition here -- requiring the tag to ALREADY match
   -- before an install was allowed. But a genuine conflict miss (a DIFFERENT tag currently
   -- occupying seq_idx -- the ONLY case a refill exists for in the first place, since a
   -- same-tag compulsory miss is the sole case that ever satisfied this) can, BY
   -- DEFINITION, never have a matching tag. So no conflict-miss refill could ever install
   -- -- confirmed via real GHDL simulation: a never-CPU-written word read back wrong 40/40
   -- times, the refill re-issuing forever without ever succeeding. Only address ranges a
   -- game happens to never evict (working set fits within one 4KB-cacheable window without
   -- two tags ever sharing an index) avoided the bug in practice; real games' VRAM
   -- footprint routinely exceeds that. This was silent data corruption, not a timing
   -- problem -- more serious than the deadlock this file's Bug 1 was.
   --
   -- Fixed: the tag precondition is now an OR, not an AND -- a genuine eviction
   -- (`refill_tag_changed`) is ALWAYS allowed to install (the old tag's data there is
   -- being deliberately overwritten, its previous valid state irrelevant); a same-tag
   -- compulsory miss still requires the target word not already valid (protects a fresher
   -- live write that raced in between miss-trigger and refill-complete from being clobbered
   -- by the stale fetched data -- the ORIGINAL, still-real reason for this term).
   --
   -- PCE PORT (2026-08-28), line-refill: when G_LINE_REFILL, the same-tag-vs-eviction
   -- OR above now gates only the SEQ_DONE/not-wren_a/not-write preconditions that are
   -- shared across all 4 ways -- the "target word not already valid" half of the OR
   -- moved into gen_way_a_wiring's own way_wren_a(k), evaluated per way against that
   -- way's own way_q_b(k)(16), not a single seq_way-indexed check (see that generate's
   -- own comment for why a blanket check would silently clobber a fresher live write
   -- to a DIFFERENT word of the same line than the one that originally missed). When
   -- G_LINE_REFILL is false (the default), the `to_sl(not G_LINE_REFILL) and (...)`
   -- term below reproduces the ORIGINAL blanket precondition exactly
   -- (`refill_tag_changed or not way_q_b(seq_way)(16)`), unchanged.
   refill_tag_changed <= to_sl(unsigned(tag_q_b) /= seq_tag);
   refill_can_install <= to_sl(seq_state = SEQ_DONE and seq_is_write = '0')
      and (to_sl(G_LINE_REFILL) or (refill_tag_changed or not way_q_b(seq_way)(16)))
      and not wren_a
      -- PCE PORT (2026-08-28): a G_PREFETCH pf_req-sourced completion never installs
      -- here -- it belongs entirely to the caller's own buffer (vram0_prefetch.vhd),
      -- not this cache's way_k/tag_mem. seq_is_pf is always '0' when G_PREFETCH=false
      -- (see its own declaration), so this term is a no-op then.
      and not seq_is_pf;

   -- PCE PORT (2026-08-28): G_PREFETCH's pf_* answer path. pf_rdata mirrors seq_rdata
   -- unconditionally (only meaningful the cycle pf_done pulses, same convention as
   -- ram_a_line_do/seq_rdata elsewhere in this file); pf_done pulses exactly one clock
   -- when byte_seq's CURRENT completion was this channel's own request.
   pf_rdata <= seq_rdata;
   pf_done  <= to_sl(seq_state = SEQ_DONE and seq_is_pf = '1');

end architecture;
