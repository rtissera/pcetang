-- SPDX-License-Identifier: GPL-3.0-or-later

-- PCE PORT (2026-08-28): VDC-side BAT prefetch buffer for VRAM0. Sits BETWEEN huc6270's
-- RAM_A/RAM_DI/RAM_DO/RAM_WE and vram0_cache's address_a/q_a/data_a/wren_a, transparently
-- answering q_a for BAT reads that hit a resident, prefetched row instead of racing
-- vram0_cache's live-refill deadline. That deadline is missed on 100% of genuine cache
-- misses, every time, with visibly wrong pixel data, independently GHDL-measured twice:
-- huc6270 consumes q_a for an access one cycle before the cache's own miss-check for
-- that same access even becomes valid, so no refill can land in time at any SDRAM speed.
-- This module exists to route BAT traffic around that deadline entirely (q_a leaves the
-- critical path during active display), not to fix vram0_cache's own refill timing in
-- place -- vram0_cache remains completely unmodified in its refill-vs-deadline behavior;
-- see its own G_PREFETCH generic comment for the one new, additive, opt-in channel it
-- gained to serve this module's prefetch requests.
--
-- WHY A PURE ADDRESS MATCH, NOT A SLOT/DOT_CNT RECONSTRUCTION: huc6270.vhd's real
-- BG_RAM_ADDR is purely combinational off BG_X/OFS_X/OFS_Y/SCREEN -- RAM_A already IS
-- the address huc6270 wants, live, every dwell, whether or not this module is present.
-- So the CONSUMPTION side never needs to know it is looking at a BAT dwell specifically
-- -- it just needs to know "is address_a, whatever access produced it, an address I
-- have fresh, correct content for right now". Answering that content-addressably (per-
-- entry tag+valid, kept live-fresh by snooping every wren_a, not gated to "looks like a
-- BAT address") is not just simpler than reconstructing SLOT -- it is provably correct
-- for ANY access that happens to target a buffered word, not just genuine BAT ones,
-- because the buffer is nothing more than an always-fresh mirror of specific real VRAM0
-- addresses (see the header note on the match/snoop functions below for the one
-- caveat: SCREEN changing live invalidates the whole buffer, since the address<->
-- (row,col) decode itself is SCREEN-dependent).
--
-- WHY NO BXR/OFS_X DEPENDENCE AT ALL: the buffer always prefetches a tile ROW'S WHOLE
-- virtual width (32 or 64 tiles, i.e. every column the SCREEN(1:0) field can address),
-- not just the active/visible window huc6270 will actually walk this line. A live BXR
-- write only changes WHICH SUBSET of that already-fully-buffered row huc6270 reads this
-- line (via wraparound) -- since the buffer always holds the WHOLE row regardless, a
-- BXR write can never invalidate anything the buffer already covers, and needs no
-- snoop of its own. Only a BYR write changes WHICH ROW is needed, hence the byr_dbg
-- edge-detect below. Real cost of fetching the whole 64-wide virtual row even when
-- SCREEN(1:0)="00" (32 real columns) would be double the necessary bursts -- not
-- attempted here since width is decoded from the live SCREEN(1:0) field, only the
-- ACTUAL virtual width for the current mode is ever fetched.
--
-- SCOPE, disclosed: SCREEN(1:0) = "10"/"11" (the 128-tile/7-bit-col-field virtual width)
-- is NOT supported -- the module cleanly disables itself (never matches, never fetches)
-- whenever screen_dbg(1:0) is one of those two encodings, falling through to
-- vram0_cache's own existing (already-measured, already-accepted-baseline) behavior for
-- that mode, never producing WRONG data, only "no improvement" for it. CG0/CG1 support
-- is the G_CG_PREFETCH extension below -- see its own header block.
--
-- REAL GHDL VERIFICATION (BAT only, pre-CG-extension baseline): 806-scanline acceptance
-- run (mock-SDRAM testbench forked from the project's own q_a-correctness-measurement
-- harness), G_LINE_REFILL=true, G_BUSY_LEGACY=4, G_BUSY_LR=5. BAT master correctness
-- gate (checks ALL hits, not just deadline-miss-flagged ones): hit_checked=66739,
-- hit_wrong=0. Deadline-miss cross-tab: dm_wrong=0, dm_right=1257 (every deadline-miss
-- event, still detected exactly as before by vram0_cache's own unmodified bookkeeping,
-- now delivers correct data via this buffer instead of the un-buffered baseline's
-- 100%-wrong stale q_a). pf_hit_total=226807, pf_overrun_total=0 across the whole run
-- (the fill engine always finished a row's fetch before the next hsync_f needed it).
--
-- REAL GW_SH TIMING DELTA (correction/completion of the commit message's own PnR
-- numbers -- those reported the POST-change Fmax only, not the before/after delta):
-- comparing against the LAST COMMITTED build's own PnR artifact (commit f5c23ed,
-- already in the repo, VRAM0_LINE_REFILL=1 but no prefetch engine) against this
-- change's own gw_sh run --
-- clk_pce:   baseline Fmax 43.787 MHz (margin ~2.17% over the 42.857 MHz constraint)
--            -> 43.029 MHz after this change (margin ~0.40%). This change is a REAL,
--            non-trivial consumer of clk_pce's margin (~1.77 percentage points), not a
--            free addition -- still 0 setup/hold violations, but materially closer to
--            the constraint than before. Worth knowing before adding anything else to
--            clk_pce's timing budget on this board.
-- clk_sdram: baseline Fmax 120.454 MHz (margin ~0.38%) -> 150.248 MHz after this change
--            (margin ~25.2%) -- a real INCREASE, opposite of what added logic would
--            naively predict. Not independently root-caused (plausibly a PnR
--            placement/optimization-order side effect of the overall netlist changing
--            shape, not something this module's own logic explains) -- reported as
--            measured, not further investigated.
--
-- REQUIRES G_LINE_REFILL=true AND G_PREFETCH=true on the paired vram0_cache instance
-- (see that generic's own comment) -- a pf request always expects a real 4-word line
-- answer.
--
-- ============================================================================
-- G_CG_PREFETCH EXTENSION (2026-08-29): CG0/CG1 tile-pattern prefetch, chained after
-- this row's own BAT fill, sharing this module's existing fill FSM/burst counter/pf_*
-- handshake rather than adding a second engine (kept to one state machine deliberately
-- -- Primer 25K's clk_pce margin is already down to 0.40% from the BAT engine alone,
-- so minimizing added clk_pce-domain combinational depth mattered more than code
-- separation).
--
-- WHY THIS IS FEASIBLE DESPITE CG0/CG1 BEING OUT OF SCOPE FOR THE BAT ENGINE ABOVE:
-- huc6270.vhd's own BG_RAM_ADDR (CG0/CG1 case) is exactly
-- `BG_BAT_CC & "0"/"1" & BG_OFS_Y(2 downto 0)` -- i.e. {character code, plane, row-
-- within-tile}. The character code is not knowable from screen geometry alone (the
-- reason the BAT-only engine above never attempted CG), but it IS knowable the instant
-- a BAT row is resident: buf_data above already mirrors every code this scanline's up-
-- to-64 tiles use, valid for the WHOLE 8-scanline tile-row band (pending_row only
-- changes every 8 scanlines -- see `predict`'s own OFS_Y(8 downto 3) decode). So by the
-- time any scanline in that band starts consuming CG0/CG1, its tiles' codes have
-- already been resident in buf_data for up to 8 scanlines. What's NOT knowable that far
-- ahead is BG_OFS_Y(2 downto 0) (row-within-tile) itself, since it increments every
-- single scanline (unlike the tile row, which only changes every 8th) -- so unlike
-- BAT's fill, which only re-runs ~1/8 of scanlines, this extension's fill pass re-runs
-- EVERY scanline, using whichever row `predict` computes for the upcoming line.
--
-- REAL BUDGET (measured, not estimated): a real GHDL instrumentation pass (this
-- session, forked from the same acceptance harness cited above) measured BAT's own
-- fill-completion-to-next-hsync_f slack at a real, reproducible 2553 clk_pce cycles
-- (worst case = best case = average across 99 real row-refetches in an 806-scanline
-- run; the other 707 hsync_f events are same-row no-ops, not fetches, corroborated by
-- pf_overrun_total=0) -- out of a 2730-cycle scanline, with BAT's own 16-burst fetch
-- costing ~177 cycles. This extension's own worst case is 64 columns x 2 planes = 128
-- more bursts (~1408 cycles at the same ~11 cycles/burst) -- comfortably inside the
-- 2553-cycle slack on the one scanline in 8 that also does a real BAT refetch, and
-- inside an even larger ~2700-cycle budget on the other 7. Timing-cycle budget is NOT
-- the constraint (a >1.4x safety margin, not a photo finish) -- Primer 25K's already-
-- thin clk_pce Fmax margin (fabric/routing, not cycle count) is the real open question,
-- decided empirically by gw_sh, not by this comment.
--
-- WHY DIRECT-MAPPED, NOT A SECOND CONTENT-ADDRESSABLE MIRROR LIKE BAT'S OWN BUFFER:
-- BAT's buffer is indexed by SCREEN COLUMN, a field address_a encodes directly, so its
-- match is a cheap field-extract-and-compare. CG0/CG1's real address encodes CHARACTER
-- CODE, not column -- answering "do I have this code cached, and at what buffer slot"
-- with an associative (CAM-style) search over up to 64 live codes would be a wide
-- comparator tree squarely on clk_pce's critical path, unacceptable at a 0.40% margin.
-- Direct-mapped avoids the search entirely: index = code(4 downto 0) & plane (6 bits,
-- 64 entries), tag = code(10 downto 5) (6 bits) -- one equality compare per lookup,
-- same shape as a real cache way. Two live codes sharing the same low 5 bits simply
-- evict each other (a conflict miss, falling through to ds_q_a exactly like any other
-- access this module doesn't cover) -- never a correctness cost, only "no improvement"
-- for that one access, same disclosed-tradeoff shape as BAT's own SCREEN(1:0)="10"/"11"
-- scope exclusion above.
--
-- CORRECTNESS INVARIANT (non-negotiable per this feature's own design review): a stale
-- HIT is a new bug (wrong pixels on a tile that no longer applies); a MISS is always
-- safe (identical to today's un-buffered baseline).
--
-- REAL BUG FOUND + FIXED (2026-08-29, GHDL): the first version of this design tracked
-- row-within-tile with a single GLOBAL register (cg_row_valid_for), advanced only once
-- a full 128-slot pass completed, on the theory that this mirrors BAT's own coarse
-- "screen_changed invalidates everything" gate. It doesn't: BAT's per-entry buf_tag
-- stores the TILE ROW each entry was actually fetched under, so match_comb compares
-- each entry against ITS OWN fetch-time row, robust to a partially-drained refill
-- (some entries already new, some still old -- each still correctly self-describes).
-- A single global flag has no such per-entry truth: a column that isn't re-visited
-- during a given CG pass (buf_valid(cg_i/2)='0' that iteration, or bit 11 set) keeps
-- WHATEVER stale (code, plane, row) content it held from a PRIOR pass, valid bit and
-- all -- yet the global flag still advances to "this row is current" the moment the
-- LAST slot is reached, regardless of whether that specific entry was ever refreshed.
-- A live BYR rewrite is exactly the scenario that exposes this: real GHDL correctness
-- run, mid-frame BYR rewrite window, cg_hit_checked=200 cg_hit_wrong=35 (17.5%) --
-- confirmed by an ds_q_a diagnostic dump as genuinely wrong (vram0_cache's own correct
-- answer overridden by stale CG data), not a testbench artifact.
--
-- FIX: no global flag at all. cg_tag now stores {code(10 downto 5), row(2 downto 0)}
-- per entry (9 bits, not 6) -- exactly BAT's own "each entry self-describes what it
-- actually is" discipline, applied to CG's own (code, plane, row) key instead of
-- BAT's (tile row, column) key. A lookup's tag+row compare can only hit an entry that
-- was ACTUALLY fetched for that exact (code, plane, row) triple; an unrefreshed
-- leftover from a prior pass simply carries the OLD row in its own tag and can never
-- tag-match a NEW-row query by coincidence of timing, only by the addresses genuinely
-- being for the same content (which is correct to serve). This also means an entry
-- never needs bulk invalidation on a BAT-row adopt or a SCREEN change -- CG's own
-- (code, plane, row) -> data mapping doesn't depend on which BAT column the code came
-- from, or on SCREEN(1:0) at all, so a still-tag-matching entry is still genuinely
-- correct content regardless of what else changed elsewhere; only a live WRITE to that
-- exact VRAM0 address (Check B below) can make it wrong, and that path already
-- invalidates on tag+row match directly, no global gate involved.
--
-- Verified, not just argued: see this file's own commit history / session memory for
-- the GHDL cg_hit_wrong=0 acceptance run against this fixed design, including the
-- mid-frame BYR-rewrite and SCREEN-change stress windows that exposed the original bug.
--
-- Defaults false (G_CG_PREFETCH : boolean := false), same "compile-time generic,
-- synthesis constant-folds it away" discipline vram0_cache.vhd's own G_LINE_REFILL/
-- G_PREFETCH already established (that file's own comment: "is a compile-time generic,
-- not a runtime mux -- synthesis constant-folds away"). Every new write this extension
-- makes to cg_data/cg_tag/cg_valid is itself guarded by `if G_CG_PREFETCH then ...
-- end if` -- when false, cg_valid can be proven to never leave its all-0 reset value,
-- so cg_match_comb's read side (left unguarded for simplicity) always computes a miss
-- and is prunable by the same reasoning, without needing every read site separately
-- gated too.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vram0_prefetch is
   generic (
      -- See the G_CG_PREFETCH EXTENSION header block above.
      G_CG_PREFETCH : boolean := false
   );
   port (
      clock   : in std_logic;
      hsync_f : in std_logic;   -- real per-scanline boundary pulse (VCE HSYNC_F)

      -- Real huc6270 register taps (see huc6270.vhd's own OFS_Y_DBG/BYR_DBG/SCREEN_DBG).
      screen_dbg : in std_logic_vector(2 downto 0);
      ofs_y_dbg  : in std_logic_vector(8 downto 0);
      byr_dbg    : in std_logic_vector(8 downto 0);

      -- Upstream: huc6270's own RAM_A(14:0)/RAM_DO/RAM_WE/RAM_DI.
      address_a : in  std_logic_vector(14 downto 0);
      data_a    : in  std_logic_vector(15 downto 0);
      wren_a    : in  std_logic;
      q_a       : out std_logic_vector(15 downto 0);

      -- Downstream: vram0_cache's own address_a/data_a/wren_a/q_a -- pure pass-through,
      -- vram0_cache remains the sole authority for every write and every non-BAT-hit
      -- read (CPU/DMA/SATB/sprite traffic, and any BAT read this buffer doesn't cover).
      ds_address_a : out std_logic_vector(14 downto 0);
      ds_data_a    : out std_logic_vector(15 downto 0);
      ds_wren_a    : out std_logic;
      ds_q_a       : in  std_logic_vector(15 downto 0);

      -- vram0_cache's G_PREFETCH pf_* channel (byte_seq's third, lowest-priority client).
      pf_addr  : out std_logic_vector(14 downto 0);
      pf_req   : out std_logic;
      pf_rdata : in  std_logic_vector(63 downto 0);
      pf_done  : in  std_logic;

      -- Instrumentation, not function (same discipline as vram0_cache's own dbg_*):
      dbg_pf_hit     : out std_logic;  -- a read was served from the BAT buffer this cycle
      dbg_pf_overrun : out std_logic;  -- hsync_f fired before this row's own fill finished

      -- G_CG_PREFETCH's own instrumentation, same discipline, meaningless (held '0')
      -- when the generic is false.
      dbg_cg_hit     : out std_logic;  -- a read was served from the CG buffer this cycle
      dbg_cg_overrun : out std_logic   -- hsync_f fired before this row's CG pass finished
   );
end entity;

architecture rtl of vram0_prefetch is

   function to_sl(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function;

   -- 64-entry, per-word-tagged BAT row buffer (see header: content-addressable, not
   -- SCREEN/OFS_X-relative). Only entries 0..(2**width_bits - 1) are ever meaningfully
   -- used for a given SCREEN(1:0); the rest simply sit invalid/stale-from-a-different-
   -- width, harmless (never matched -- see decode below, out-of-range columns for the
   -- CURRENT width can't even be formed from a real address).
   type buf_data_t is array (0 to 63) of std_logic_vector(15 downto 0);
   type buf_tag_t  is array (0 to 63) of unsigned(5 downto 0);
   signal buf_data  : buf_data_t := (others => (others => '0'));
   signal buf_tag   : buf_tag_t  := (others => (others => '0'));
   signal buf_valid : std_logic_vector(0 to 63) := (others => '0');

   -- ---------------------------------------------------------------- predict (owns:
   -- pending_row/pending_wbits/pending_supported/restart_req, byr_dbg_prev)
   signal byr_dbg_prev    : std_logic_vector(8 downto 0) := (others => '0');
   signal screen_dbg_prev : std_logic_vector(2 downto 0) := (others => '0');
   signal pending_row       : unsigned(5 downto 0) := (others => '0');
   signal pending_wbits     : integer range 5 to 6 := 5;
   signal pending_supported : std_logic := '0';
   signal restart_req       : std_logic := '0';   -- sticky, cleared by `fill` once adopted
   -- Owned by `snoop` (which already computes the screen_dbg/screen_dbg_prev compare for
   -- its own purposes); READ by `fill`, which is buf_valid's sole writer -- see that
   -- signal's own comment for why this indirection exists (two processes driving the
   -- same signal, even conditionally, is a real VHDL multi-driver bug: an early version
   -- of this file made exactly that mistake -- twice, once on buf_valid and once on
   -- buf_data -- caught only via real GHDL simulation showing the affected bits reading
   -- back as 'X' permanently; resolved std_logic drivers disagreeing, one process
   -- holding one value forever while another writes a different one, resolve to 'X',
   -- not the intended value. Both `buf_valid` and `buf_data` now have exactly one
   -- writer -- `fill` -- for this reason).
   signal screen_changed : std_logic := '0';

   -- ---------------------------------------------------------------- fill (owns:
   -- fill_state, cur_row/cur_wbits/cur_supported/cur_total, burst_i, pf_addr/pf_req,
   -- buf_data/buf_tag/buf_valid's WRITE side -- sole writer of all three, see above)
   type fill_state_t is (F_IDLE, F_WAIT, F_CG_WAIT);
   signal fill_state : fill_state_t := F_IDLE;
   signal cur_row       : unsigned(5 downto 0) := (others => '0');
   signal cur_wbits     : integer range 5 to 6 := 5;
   signal cur_supported : std_logic := '0';
   -- Deliberately 0, not 8/16: makes "burst_i = cur_total" (this target is fully
   -- drained) trivially true at power-up (0=0), so the very first real hsync_f's
   -- adoption in `fill` below is not a special case -- see that process's own comment.
   signal cur_total     : integer range 0 to 16 := 0;
   signal burst_i       : integer range 0 to 16 := 0;
   signal pf_addr_r : std_logic_vector(14 downto 0) := (others => '0');
   signal pf_req_r  : std_logic := '0';

   -- ---------------------------------------------------------------- match (owns:
   -- m_addr_d1/m_wr_d1, q_a_buf_i/q_a_buf_hit/q_a_buf_wr)
   signal m_addr_d1 : std_logic_vector(14 downto 0) := (others => '0');
   signal m_wr_d1    : std_logic := '0';
   signal m_match_d1 : std_logic;
   signal m_data_d1  : std_logic_vector(15 downto 0);
   signal q_a_buf_i   : std_logic_vector(15 downto 0) := (others => '0');
   signal q_a_buf_hit : std_logic := '0';
   signal q_a_buf_wr  : std_logic := '0';

   -- ---------------------------------------------------------------- G_CG_PREFETCH
   -- (owns: cg_data/cg_tag/cg_valid's WRITE side (`fill`, sole writer, same discipline
   -- as buf_*), pending_cg_row (`predict`), cg_i/cg_done/cur_cg_row (`fill`)). See the
   -- header block above for the index/tag scheme and the correctness invariant this
   -- buffer relies on -- in particular, WHY there is no global "current row" register:
   -- each entry's own tag includes the row it was fetched for (real bug found+fixed
   -- with an earlier, global-flag version of this design -- see header).
   type cg_data_t is array (0 to 63) of std_logic_vector(15 downto 0);
   -- code(10 downto 5) & row(2 downto 0) -- per-entry, NOT a global register (see
   -- header's "REAL BUG FOUND + FIXED" section for why a global flag is unsafe here).
   type cg_tag_t  is array (0 to 63) of unsigned(8 downto 0);
   signal cg_data  : cg_data_t := (others => (others => '0'));
   signal cg_tag   : cg_tag_t  := (others => (others => '0'));
   signal cg_valid : std_logic_vector(0 to 63) := (others => '0');

   signal pending_cg_row : unsigned(2 downto 0) := (others => '0');
   signal cur_cg_row     : unsigned(2 downto 0) := (others => '0');
   -- Linear iteration index over a pass: column = cg_i/2, plane = cg_i mod 2. 128 slots
   -- (64 columns x 2 planes) per pass, one pass per scanline (unlike BAT, whose target
   -- only changes every 8th).
   signal cg_i    : integer range 0 to 127 := 0;
   -- Trivially true at power-up (mirrors cur_total/burst_i's own "0=0" reasoning above)
   -- so the very first real hsync_f's CG pass-start check isn't a special case.
   signal cg_done : std_logic := '1';

   signal cg_match_d1 : std_logic;
   signal cg_data_d1  : std_logic_vector(15 downto 0);
   signal q_a_cg_i    : std_logic_vector(15 downto 0) := (others => '0');
   signal q_a_cg_hit  : std_logic := '0';

begin

   ------------------------------------------------------------------ pass-through
   -- Writes (and any read this buffer doesn't serve) always reach vram0_cache
   -- unchanged -- it remains the sole authority for storage/correctness of everything
   -- outside this buffer's own narrow BAT-row mirror.
   ds_address_a <= address_a;
   ds_data_a    <= data_a;
   ds_wren_a    <= wren_a;

   ------------------------------------------------------------------ write snoop (Check B)
   -- Live CPU/DMA write to a VRAM0 address this buffer currently mirrors: refresh that
   -- entry's DATA in place (strictly better than invalidating -- keeps the hit, avoids
   -- an unnecessary re-fetch) rather than merely invalidating. Content-addressed, same
   -- decode as the match side below -- no "is this plausibly a BAT address" gate is
   -- needed (see header): if buf_tag/buf_valid says this raw address is mirrored, the
   -- mirror must track the real, current content of that raw address regardless of
   -- which slot the ACCESS that triggered the write came from. The actual Check-B write
   -- itself lives in `fill` below (sole writer of buf_data, see that signal's own
   -- comment) -- this process only computes the screen_changed flag `fill` reacts to.
   snoop: process (clock)
   begin
      if rising_edge(clock) then
         -- SCREEN(1:0)/(2) changing live re-shapes the address<->(row,col) decode itself
         -- -- a stale entry tagged under the OLD decode would be meaningless (not just
         -- stale-content) under the NEW one. Signals `fill` (buf_valid's SOLE writer,
         -- see that signal's own declaration comment) to whole-buffer-invalidate; not
         -- expected to be exercised by real games mid-frame in the common case, but real
         -- hardware does allow a live MWR write -- disclosed limitation: entries written
         -- in the narrow window right around such a change are not proven race-free the
         -- way Check B/C proved BYR is (not independently checked this session).
         screen_changed <= to_sl(screen_dbg /= screen_dbg_prev);
         screen_dbg_prev <= screen_dbg;
      end if;
   end process;

   ------------------------------------------------------------------ predict
   -- Recomputes the target row whenever EITHER a new scanline's hblank starts
   -- (hsync_f, the common/steady-state case -- huc6270's own OFS_Y register at this
   -- instant still holds the CURRENTLY-DISPLAYED line's value) OR a live BYR write is
   -- observed (byr_dbg changes -- Check C's race: a raster-split game rewriting BYR
   -- mid-frame must immediately re-target, not wait for the next hsync_f). Both cases
   -- reuse the SAME real update rule huc6270.vhd itself uses (huc6270.vhd's own OFS_Y
   -- update process): NEW_OFS_Y := (byr_changed ? BYR : OFS_Y); predicted :=
   -- NEW_OFS_Y + 1 -- ALWAYS +1, both branches (the one real exception, the very first
   -- active line of a frame skipping the +1, is a disclosed, self-healing, once-per-
   -- frame edge case).
   --
   -- G_CG_PREFETCH also latches pending_cg_row <= nxt(2 downto 0) here, in the SAME
   -- branch -- huc6270.vhd's own BG_RAM_ADDR uses the identical BG_OFS_Y(2 downto 0)
   -- for CG0/CG1's row-within-tile, so it inherits the exact same BYR-race handling
   -- for free rather than needing its own re-derivation.
   predict: process (clock)
      variable pre_val : unsigned(8 downto 0);
      variable nxt      : unsigned(8 downto 0);
      variable masked   : unsigned(8 downto 0);
      variable byr_changed : boolean;
   begin
      if rising_edge(clock) then
         byr_dbg_prev <= byr_dbg;
         byr_changed  := (byr_dbg /= byr_dbg_prev);

         if hsync_f = '1' or byr_changed then
            if byr_changed then
               pre_val := unsigned(byr_dbg);
            else
               pre_val := unsigned(ofs_y_dbg);
            end if;
            nxt := pre_val + 1;
            if screen_dbg(2) = '0' then
               masked := '0' & nxt(7 downto 0);
            else
               masked := nxt;
            end if;
            pending_row <= masked(8 downto 3);

            if G_CG_PREFETCH then
               pending_cg_row <= nxt(2 downto 0);
            end if;

            if screen_dbg(1 downto 0) = "00" then
               pending_wbits <= 5; pending_supported <= '1';
            elsif screen_dbg(1 downto 0) = "01" then
               pending_wbits <= 6; pending_supported <= '1';
            else
               pending_supported <= '0';
            end if;

            restart_req <= '1';
         elsif fill_state = F_IDLE and cur_row = pending_row
               and cur_wbits = pending_wbits and cur_supported = pending_supported then
            -- `fill` has already adopted the latest target and finished (or there was
            -- nothing new to adopt) -- clear the sticky request. Left set otherwise, so
            -- `fill` (which only samples it from F_IDLE) never misses one.
            restart_req <= '0';
         end if;
      end if;
   end process;

   ------------------------------------------------------------------ fill
   -- Issues ceil(width/4) 4-word line-refill bursts (via vram0_cache's pf_* channel,
   -- lowest priority behind write-drain and genuine cache-miss-refill -- see
   -- vram0_cache.vhd's own G_PREFETCH comment) to populate buf_data/buf_tag/buf_valid
   -- for the current predicted row. A restart mid-burst is deferred to the next F_IDLE
   -- (never aborts an in-flight pf_req -- an abandoned burst's eventual data is still
   -- real, correct content for whatever row it was issued under, just possibly no
   -- longer the target -- no correctness cost, only a few cycles of possibly-redundant
   -- bandwidth).
   --
   -- G_CG_PREFETCH chains a CG pass into the SAME FSM/burst counter once BAT itself is
   -- fully drained (burst_i = cur_total) each cycle: F_IDLE's third priority tier below,
   -- lowest of the three, so a genuine BAT adopt/burst always preempts it. See the
   -- header block above for the index/tag/address scheme and why each cg_tag entry
   -- carries its own row (no global "current row" register).
   fill: process (clock)
      variable snoop_ok  : boolean;
      variable snoop_row : unsigned(5 downto 0);
      variable snoop_col : integer range 0 to 63;
      variable idx_v     : unsigned(5 downto 0);
      variable cg_snoop_code  : unsigned(10 downto 0);
      variable cg_snoop_plane : std_logic;
      variable cg_snoop_row   : unsigned(2 downto 0);
      variable cg_snoop_idx   : integer range 0 to 63;
   begin
      if rising_edge(clock) then
         if screen_changed = '1' then
            -- Sole writer of buf_valid (see its own declaration comment) -- reacts to
            -- `snoop`'s screen_changed flag by invalidating everything and forcing a
            -- cold restart, regardless of what state the FSM was in. Safe to interrupt
            -- an in-flight F_WAIT this way (unlike an ordinary restart_req, which
            -- defers until drained): the in-flight burst's own eventual buf_valid/
            -- buf_tag/buf_data writes, whenever pf_done lands, target the SAME indices
            -- this clear just reset -- worst case that one word briefly reads valid
            -- again under the OLD decode for a couple of cycles before `predict`'s own
            -- next trigger re-targets it, no different in kind from the disclosed
            -- limitation already noted at screen_changed's own declaration site.
            buf_valid  <= (others => '0');
            burst_i    <= 0;
            -- cur_total<=0 alongside burst_i<=0 keeps "burst_i=cur_total" (fully
            -- drained) trivially true next cycle -- same reasoning as cur_total's own
            -- power-up default, see that signal's declaration comment -- so F_IDLE's
            -- adopt branch isn't blocked the way an earlier version of this file's
            -- power-up case was.
            cur_total  <= 0;
            fill_state <= F_IDLE;
            -- G_CG_PREFETCH deliberately does NOT touch cg_valid/cg_i/cg_done here:
            -- CG's (code, plane, row) -> data mapping doesn't depend on SCREEN(1:0) at
            -- all (see header), so an existing entry is still genuinely correct content
            -- regardless of this decode change -- nothing to invalidate.
         else
         case fill_state is
            when F_IDLE =>
               if restart_req = '1' and (cur_row /= pending_row or cur_wbits /= pending_wbits
                     or cur_supported /= pending_supported) and burst_i = cur_total then
                  -- Fully drained the OLD target and a NEW one is pending: adopt it.
                  cur_row       <= pending_row;
                  cur_wbits     <= pending_wbits;
                  cur_supported <= pending_supported;
                  if pending_wbits = 5 then cur_total <= 8; else cur_total <= 16; end if;
                  burst_i <= 0;
                  -- G_CG_PREFETCH does NOT invalidate cg_valid here either: an entry
                  -- fetched under the OLD BAT row's codes is still correct content for
                  -- its own (code, plane, row) triple (see header) -- it simply won't
                  -- be the SET of codes this scanline's tiles use, same as any other
                  -- direct-mapped miss for a code that isn't resident. Nothing to do.
               elsif cur_supported = '1' and burst_i < cur_total then
                  if cur_wbits = 5 then
                     pf_addr_r <= "0000" & std_logic_vector(cur_row)
                                  & std_logic_vector(to_unsigned(burst_i*4, 5));
                  else
                     pf_addr_r <= "000" & std_logic_vector(cur_row)
                                  & std_logic_vector(to_unsigned(burst_i*4, 6));
                  end if;
                  pf_req_r   <= '1';
                  fill_state <= F_WAIT;
               elsif G_CG_PREFETCH and burst_i = cur_total and cur_supported = '1'
                     and cg_done = '0' then
                  if buf_valid(cg_i/2) = '1' and buf_data(cg_i/2)(11) = '0' then
                     -- Real BG_RAM_ADDR CG0/CG1 formula (huc6270.vhd): code(10:0) &
                     -- plane & row(2:0). Burst-aligned to a 4-word line refill (row(2)
                     -- picks which half of the tile's 8-row plane the burst covers);
                     -- the wanted word is picked out of the returned 4 in F_CG_WAIT
                     -- below via row(1 downto 0).
                     pf_addr_r  <= std_logic_vector(buf_data(cg_i/2)(10 downto 0))
                                   & to_sl(cg_i mod 2 = 1)
                                   & cur_cg_row(2) & "00";
                     pf_req_r   <= '1';
                     fill_state <= F_CG_WAIT;
                  elsif cg_i = 127 then
                     -- Nothing to fetch for this last slot (invalid/disabled column) --
                     -- the pass is still complete.
                     cg_i    <= 0;
                     cg_done <= '1';
                  else
                     cg_i <= cg_i + 1;
                  end if;
               elsif G_CG_PREFETCH and burst_i = cur_total and cur_supported = '1'
                     and cg_done = '1' and cur_cg_row /= pending_cg_row then
                  -- Previous row's CG pass fully drained and a new row-within-tile is
                  -- pending (the common case, every scanline) -- adopt it. buf_data is
                  -- guaranteed fresh here: this branch is only reachable once BAT's own
                  -- burst_i has reached cur_total, i.e. any in-flight BAT adopt for
                  -- THIS row has already fully drained.
                  cur_cg_row <= pending_cg_row;
                  cg_i       <= 0;
                  cg_done    <= '0';
               end if;
            when F_WAIT =>
               pf_req_r <= '1';
               if pf_done = '1' then
                  for k in 0 to 3 loop
                     buf_data(burst_i*4 + k)  <= pf_rdata((k*16+15) downto k*16);
                     buf_tag(burst_i*4 + k)   <= cur_row;
                     buf_valid(burst_i*4 + k) <= '1';
                  end loop;
                  pf_req_r   <= '0';
                  burst_i    <= burst_i + 1;
                  fill_state <= F_IDLE;
               end if;
            when F_CG_WAIT =>
               pf_req_r <= '1';
               if pf_done = '1' then
                  idx_v := unsigned(std_logic_vector(buf_data(cg_i/2)(4 downto 0))
                                     & to_sl(cg_i mod 2 = 1));
                  -- Static-bounds case select, not a dynamic slice (matches F_WAIT's
                  -- own for-loop above: every bit-range here is locally static, cheap
                  -- and unambiguous for synthesis -- cur_cg_row(1 downto 0) only picks
                  -- WHICH of the 4 fixed slices to use).
                  case cur_cg_row(1 downto 0) is
                     when "00" => cg_data(to_integer(idx_v)) <= pf_rdata(15 downto 0);
                     when "01" => cg_data(to_integer(idx_v)) <= pf_rdata(31 downto 16);
                     when "10" => cg_data(to_integer(idx_v)) <= pf_rdata(47 downto 32);
                     when others => cg_data(to_integer(idx_v)) <= pf_rdata(63 downto 48);
                  end case;
                  -- Per-entry tag: code(10 downto 5) & the row THIS fetch is actually
                  -- for (cur_cg_row) -- not a global "current row" flag (see header's
                  -- "REAL BUG FOUND + FIXED"). Self-describing: a lookup can only hit
                  -- this entry for the exact (code, plane, row) it was fetched under.
                  cg_tag(to_integer(idx_v))   <= unsigned(buf_data(cg_i/2)(10 downto 5))
                                                  & cur_cg_row;
                  cg_valid(to_integer(idx_v)) <= '1';
                  pf_req_r   <= '0';
                  fill_state <= F_IDLE;
                  if cg_i = 127 then
                     cg_i    <= 0;
                     cg_done <= '1';
                  else
                     cg_i <= cg_i + 1;
                  end if;
               end if;
         end case;
         end if;

         -- Check B write-content-refresh, sole owner of buf_data (see this signal's own
         -- declaration comment). Unconditional every cycle, independent of
         -- fill_state/screen_changed above -- positioned textually AFTER the F_WAIT
         -- capture write above so that on the rare cycle both target the SAME index
         -- (a live write landing on a word `fill` is capturing this same cycle), THIS
         -- write wins (last sequential assignment to a signal in one process is the one
         -- that takes effect) -- the live write is the fresher value, consistent with
         -- Check B's own intent.
         if screen_dbg(1 downto 0) = "00" then
            snoop_ok := true; snoop_row := unsigned(address_a(10 downto 5));
            snoop_col := to_integer(unsigned(address_a(4 downto 0)));
         elsif screen_dbg(1 downto 0) = "01" then
            snoop_ok := true; snoop_row := unsigned(address_a(11 downto 6));
            snoop_col := to_integer(unsigned(address_a(5 downto 0)));
         else
            snoop_ok := false; snoop_row := (others => '0'); snoop_col := 0;
         end if;
         if wren_a = '1' and snoop_ok and buf_valid(snoop_col) = '1'
               and buf_tag(snoop_col) = snoop_row then
            buf_data(snoop_col) <= data_a;
         end if;

         -- G_CG_PREFETCH's own write snoop: unlike BAT's Check B (refresh in place),
         -- this simply INVALIDATES a matching entry -- simpler, and sufficient to meet
         -- the correctness invariant (a miss is always safe). VRAM0's address space is
         -- flat and uniform, so decoding a raw written address into (code, plane, row)
         -- needs no SCREEN(1:0)-dependent branch the way BAT's own snoop_ok above does.
         if G_CG_PREFETCH then
            cg_snoop_code  := unsigned(address_a(14 downto 4));
            cg_snoop_plane := address_a(3);
            cg_snoop_row   := unsigned(address_a(2 downto 0));
            cg_snoop_idx   := to_integer(unsigned(std_logic_vector(cg_snoop_code(4 downto 0))
                                                   & cg_snoop_plane));
            if wren_a = '1' and cg_valid(cg_snoop_idx) = '1'
                  and cg_tag(cg_snoop_idx) = (cg_snoop_code(10 downto 5) & cg_snoop_row) then
               cg_valid(cg_snoop_idx) <= '0';
            end if;
         end if;
      end if;
   end process;

   pf_req  <= pf_req_r;
   pf_addr <= pf_addr_r;

   dbg_pf_overrun <= to_sl(hsync_f = '1' and cur_supported = '1'
                            and (fill_state = F_WAIT or burst_i /= cur_total));
   dbg_cg_overrun <= to_sl(G_CG_PREFETCH and hsync_f = '1' and cg_done = '0');

   ------------------------------------------------------------------ match (consumption)
   -- Two-register-stage pipeline, deliberately matching vram0_cache's own
   -- req_addr_d->hit->q_a_i depth exactly (address_a presented cycle N; this module's
   -- own answer AND vram0_cache's ds_q_a both become valid at N+2), so the final mux
   -- below is a same-cycle select, not a cross-latency one.
   match: process (clock)
   begin
      if rising_edge(clock) then
         m_addr_d1 <= address_a;
         m_wr_d1   <= wren_a;
         q_a_buf_i   <= m_data_d1;
         q_a_buf_hit <= m_match_d1;
         q_a_buf_wr  <= m_wr_d1;
         q_a_cg_i    <= cg_data_d1;
         q_a_cg_hit  <= cg_match_d1;
      end if;
   end process;

   match_comb: process (m_addr_d1, screen_dbg, buf_valid, buf_tag, buf_data)
      variable row : unsigned(5 downto 0);
      variable col : integer range 0 to 63;
      variable ok  : boolean;
   begin
      if screen_dbg(1 downto 0) = "00" then
         ok := true; row := unsigned(m_addr_d1(10 downto 5));
         col := to_integer(unsigned(m_addr_d1(4 downto 0)));
      elsif screen_dbg(1 downto 0) = "01" then
         ok := true; row := unsigned(m_addr_d1(11 downto 6));
         col := to_integer(unsigned(m_addr_d1(5 downto 0)));
      else
         ok := false; row := (others => '0'); col := 0;
      end if;

      if ok and buf_valid(col) = '1' and buf_tag(col) = row then
         m_match_d1 <= '1';
         m_data_d1  <= buf_data(col);
      else
         m_match_d1 <= '0';
         m_data_d1  <= (others => '0');
      end if;
   end process;

   -- G_CG_PREFETCH's own combinational match, same m_addr_d1 pipeline stage as BAT's
   -- above (no separate address pipeline needed -- see this extension's header). Left
   -- unguarded by G_CG_PREFETCH itself (see that generic's own declaration comment):
   -- cg_valid is provably always '0' when the generic is false, since every write to it
   -- is individually guarded, so this always computes a miss and is prunable by the
   -- same constant-folding reasoning, without an extra guard here too.
   cg_match_comb: process (m_addr_d1, cg_valid, cg_tag, cg_data)
      variable code  : unsigned(10 downto 0);
      variable plane : std_logic;
      variable row   : unsigned(2 downto 0);
      variable idx   : integer range 0 to 63;
   begin
      code  := unsigned(m_addr_d1(14 downto 4));
      plane := m_addr_d1(3);
      row   := unsigned(m_addr_d1(2 downto 0));
      idx   := to_integer(unsigned(std_logic_vector(code(4 downto 0)) & plane));

      -- Per-entry tag compare (code_hi & row) -- see header's "REAL BUG FOUND + FIXED":
      -- no global "current row" gate, each entry self-describes exactly what it is.
      if cg_valid(idx) = '1' and cg_tag(idx) = (code(10 downto 5) & row) then
         cg_match_d1 <= '1';
         cg_data_d1  <= cg_data(idx);
      else
         cg_match_d1 <= '0';
         cg_data_d1  <= (others => '0');
      end if;
   end process;

   -- Priority: a genuine BAT hit always wins (matches this module's original,
   -- independently-verified behavior byte-for-byte when G_CG_PREFETCH is false); CG is
   -- checked only when BAT itself didn't match; otherwise fall through to vram0_cache's
   -- own answer, unchanged from today.
   q_a <= q_a_buf_i when (q_a_buf_hit = '1' and q_a_buf_wr = '0') else
          q_a_cg_i  when (q_a_cg_hit  = '1' and q_a_buf_wr = '0') else
          ds_q_a;
   dbg_pf_hit <= q_a_buf_hit and not q_a_buf_wr;
   dbg_cg_hit <= q_a_cg_hit and not q_a_buf_hit and not q_a_buf_wr;

end architecture;
