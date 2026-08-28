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
-- that mode, never producing WRONG data, only "no improvement" for it. CG0/CG1 are also
-- out of scope for this module (BAT only, a sequencing choice given session time, not a
-- fundamental limitation) -- CG has a real, different, harder-to-close working-set-
-- sizing problem (a single line's CG working set doesn't fit one hblank the way a BAT
-- row's worth of bursts does) that was not attempted.
--
-- REAL GHDL VERIFICATION: 806-scanline acceptance run (mock-SDRAM testbench forked from
-- the project's own q_a-correctness-measurement harness), G_LINE_REFILL=true,
-- G_BUSY_LEGACY=4, G_BUSY_LR=5. BAT master correctness gate (checks ALL hits, not just
-- deadline-miss-flagged ones): hit_checked=66739, hit_wrong=0. Deadline-miss cross-tab:
-- dm_wrong=0, dm_right=1257 (every deadline-miss event, still detected exactly as
-- before by vram0_cache's own unmodified bookkeeping, now delivers correct data via
-- this buffer instead of the un-buffered baseline's 100%-wrong stale q_a).
-- pf_hit_total=226807, pf_overrun_total=0 across the whole run (the fill engine always
-- finished a row's fetch before the next hsync_f needed it). CG0/CG1 unaffected, as
-- expected for a BAT-only module (still ~100% wrong on their own deadline misses, same
-- as the un-buffered baseline -- not a regression, simply not addressed).
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

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vram0_prefetch is
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
      dbg_pf_hit     : out std_logic;  -- a read was served from the buffer this cycle
      dbg_pf_overrun : out std_logic   -- hsync_f fired before this row's own fill finished
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
   type fill_state_t is (F_IDLE, F_WAIT);
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
   fill: process (clock)
      variable snoop_ok  : boolean;
      variable snoop_row : unsigned(5 downto 0);
      variable snoop_col : integer range 0 to 63;
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
      end if;
   end process;

   pf_req  <= pf_req_r;
   pf_addr <= pf_addr_r;

   dbg_pf_overrun <= to_sl(hsync_f = '1' and cur_supported = '1'
                            and (fill_state = F_WAIT or burst_i /= cur_total));

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

   q_a <= q_a_buf_i when (q_a_buf_hit = '1' and q_a_buf_wr = '0') else ds_q_a;
   dbg_pf_hit <= q_a_buf_hit and not q_a_buf_wr;

end architecture;
