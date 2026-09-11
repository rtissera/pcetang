# Announcement strategy

Written 2026-09-11. Purpose: get pcetang in front of the FPGA-gaming and PC Engine
communities without tripping self-promotion rules, without overclaiming, and without
the attribution mistake that reliably sinks this kind of post.

---

## 0. Rules research — what is verified and what is not

**I could not read the linked r/fpgagaming guidelines post directly.** Reddit is
network-blocked from the environment this was researched in (`www.reddit.com` and
`old.reddit.com` both refused, as did the `.json` endpoint and two third-party
mirrors). So the specific post
`r/fpgagaming/comments/184g1hz/important_update_selfpromotion_guidelines_on/` was
**not** read verbatim, and nothing below should be treated as a quotation from it.

What *was* verified, via search results summarising the subreddit's earlier
self-promotion META post:

- r/fpgagaming **allows and encourages** individuals and businesses to share
  announcements or substantial updates about relevant projects. It is deliberately more
  permissive than most subreddits.
- **"Don't spam"** — if there is nothing new to share, wait until there is. Do not
  repost the same project or information every day/week/month.
- It is **trust-based**: moderators rely on posters to use judgement rather than
  enforcing a hard ratio.

**Action before posting: read the guidelines post yourself** and reconcile it with this
file. Specifically check three things this research could not settle: (a) whether a
particular post flair is required, (b) whether monetisation links (Patreon/Ko-fi) are
restricted, and (c) whether there is a stated frequency limit. The plan below avoids
(b) and (c) by construction, so only (a) is likely to need a change.

Rules for the other subreddits listed in §4 could not be retrieved either, for the same
reason. Each one is marked with the confidence level of its note. **Check each
subreddit's own sidebar before posting** — this is a five-minute job and the difference
between a post that lands and one that is removed.

---

## 1. Blockers — do these before posting anything

These are ordered. Each is a real reason a reader bounces or the post goes badly.

1. **The repo is PRIVATE.** `gh repo view` reports `"visibility":"PRIVATE"`. Every draft
   below links it. Make it public, or remove every link and the post loses its point.
2. **`README.md` says the project does not exist yet.** Current text, verbatim:
   *"Status: research and planning only. Nothing has been synthesized yet."* Anyone who
   follows the link from a video of a game running reads that line and concludes the
   post is vapour. Rewrite the README around the current state before announcing. This
   is the single highest-value 20 minutes in this whole plan.
3. **`docs/STATUS.md` is stale** (last updated 2026-09-09). It predates 720p60 output,
   the 4:3 aspect fix, and everything learned about CD on 09-11. It is otherwise an
   excellent document — blunt about verified-vs-builds — and is worth linking directly
   from the post as a credibility signal. Update it first.
4. **Attribution must be in the post body, not only in the repo.** See §3.

---

## 2. The honest claim

Verified on real hardware, Tang Console 60K:

- HuCard games boot and play — `1943 Kai`, `Raiden` confirmed
- 720p60 HDMI, stable lock, correct 4:3 aspect
- PSG audio, described as "very good if not perfect"
- Two controllers, on-screen display (SELECT + Right)

Builds clean (`gw_sh`, 0 errors, 0 timing violations) on Console 60K, Primer 25K and
Nano 20K — but **only Console 60K has ever run a game.**

In progress, **not** to be claimed as working:

- CD-ROM². The syscard boots off the emulated drive and the full SCSI boot sequence now
  matches a reference implementation (beetle-pce-fast) command-for-command and
  byte-for-byte — TEST UNIT READY, four GETDIRINFOs, three READ(6)s, six sectors
  delivered. **Games still do not boot.** Say "in progress", never "works".
- Arcade Card and SuperGrafx are compiled out.

**Headline to use:**
> PC Engine / TurboGrafx-16 core for Sipeed Tang FPGA boards — HuCard games running on
> Tang Console 60K

**Never write "TurboGrafx-CD works" until a CD game boots.** The FPGA community checks.
Overclaiming once costs more credibility than waiting a week costs reach, and the CD
milestone is a second, bigger post you would otherwise be spending now (§7).

---

## 3. Attribution — the thing that actually sinks these posts

This core is a port. The RTL is `TurboGrafx16_MiSTer` (Sorgelig / srg320), and the
integration layer is nand2mario's TangCore/nestang. Both GPL-3.0. `THIRD_PARTY_LICENSES.md`
already records this properly.

**Put the credit in the post body, above the fold, in your own words** — not buried in a
repo file, and not as an afterthought at the bottom. The FPGA scene is small and
protective of porters' work; a post that reads as if you wrote a PC Engine core from
scratch will be corrected in the comments, and that correction becomes the top comment.
Leading with the credit turns the same fact into goodwill.

Suggested phrasing, adapt freely:

> The PC Engine RTL is srg320's TurboGrafx16_MiSTer core; the ROM-loading, joypad and OSD
> layer is nand2mario's TangCore. My work is the port: Gowin BSRAM/SDRAM mapping, the
> HDMI path, the BL616 companion protocol, and a from-scratch SCSI/CD bridge so CHD
> images can be served over UART. GPL-3.0 throughout.

---

## 4. Venues, order and cadence

Do **not** post everywhere on the same day. Stagger over ~a week: it avoids looking like
a spam campaign, and it lets you fix whatever the first audience finds before the
bigger ones see it.

| # | Venue | When | Format | Rules note (confidence) |
|---|---|---|---|---|
| 1 | **TangCore GitHub Discussions** (`nand2mario/tangcore`) | Day 0 | Short technical post | Upstream courtesy. Tell the author before the world. **High confidence this is correct etiquette**; it costs nothing and he may amplify it. |
| 2 | **r/fpgagaming** | Day 1 | Video + text post | Self-promo allowed for substantial updates; don't spam. *(verified via search, not from the linked post — see §0)* |
| 3 | **Sipeed / Tang Discord + forum** | Day 1 | Same video, board-specific framing | Vendor community, receptive to new cores for their hardware. *(low confidence on written rules — read before posting)* |
| 4 | **r/PCEngine** / **r/TurboGrafx16** | Day 3 | Reframed for the *games*, not the FPGA | Retro-console subs care that games run, not about BSRAM budgets. Lead with the footage. *(low confidence — check sidebar for self-promo rules)* |
| 5 | **PCEngineFX forum** (pcenginefx.com) | Day 3 | Forum thread, hardware/homebrew section | The main PC Engine community. Long-form is welcome there; forums reward detail that Reddit punishes. *(low confidence — read the board's rules)* |
| 6 | **r/FPGA** | Day 5 | Technical framing | Skew the writeup toward the engineering (the FIFO show-ahead bug is a genuinely good story). *(low confidence — this sub dislikes pure promo; lead with technical substance)* |
| 7 | **r/EmuDev** | Day 5 | The debugging writeup | Dev audience; the beetle-reference-trace methodology is the draw. *(low confidence)* |
| 8 | **Mastodon / Bluesky / X** | Day 1 onward | Short clip + link | No gatekeeping; use for the clip. |

**Crossposting mechanics:** prefer a *native* post per venue over Reddit's crosspost
button. Each audience wants a different first sentence, and a crosspost shows the
original's title, which will be wrong for at least half of them. The video link can be
identical everywhere.

**Cadence after launch:** one post per real milestone. The next one is CD (§7). Nothing
in between — that is precisely the "don't just post the same project every week"
failure mode.

---

## 5. Media plan

### 5.1 Capture

Best quality: **HDMI capture device + OBS** on the PC. The core outputs 720p60 over
HDMI, so a cheap USB HDMI capture stick records it natively with no camera artefacts.

Fallback if no capture hardware: film the screen with a phone on a tripod, lights off,
shutter/frame-rate matched as well as the phone allows. Acceptable for a first
announcement — several well-received core announcements have used exactly this — but
the capture stick is worth ordering before the CD post.

**Record more than you need**: several minutes of each game, plus the boot sequence and
the OSD. Re-shooting after the board is reflashed for the next debug round is annoying.

### 5.2 Shot list

1. Board on the desk, powered, cables visible — establishes this is real hardware, not
   an emulator. Hold ~3s.
2. TangCore menu → selecting a ROM → game boots. **Do not cut this.** The boot is the
   proof; a hard cut to gameplay reads as a video of an emulator.
3. `1943 Kai` gameplay, ~30s, with sound.
4. `Raiden` gameplay, ~20s.
5. OSD opening over a running game (SELECT + Right).
6. Optional, honest-framing: the syscard CD screen, explicitly captioned
   "CD-ROM² — boots the BIOS, games not yet running".

### 5.3 Video structure (~2:30, YouTube)

| Time | Content |
|---|---|
| 0:00-0:10 | Cold open: game already running, sound up. No logo, no intro. |
| 0:10-0:30 | Title card: what it is, which board, that it is open source. |
| 0:30-0:50 | Credit card: MiSTer TurboGrafx16 RTL + TangCore (§3). |
| 0:50-1:50 | Gameplay: boot sequence, two games, OSD. |
| 1:50-2:15 | Honest status: what works, what does not, per-board table from STATUS.md. |
| 2:15-2:30 | Repo link, invitation to test on Primer 25K / Nano 20K. |

Title: `PC Engine on a Tang FPGA — HuCard games running on Console 60K`
Thumbnail: board in frame + recognisable game art + "PC Engine on Tang" in large type.
Description: repo link, credits with links, timestamps, hardware list.

### 5.4 Short version

30-60s vertical cut of the boot + best gameplay, for Shorts/Reels/Mastodon. Reddit
autoplays short native video better than YouTube embeds — consider uploading the short
natively to Reddit *and* linking YouTube in the body.

---

## 6. Draft post copy

### 6.1 r/fpgagaming (primary)

**Title:**
`PC Engine / TurboGrafx-16 core for Sipeed Tang boards — HuCard games running on Tang Console 60K`

**Body:**

> I've been porting a PC Engine core to the Sipeed Tang FPGA boards, and it now boots and
> plays HuCard games on a Tang Console 60K. Video above — that's real hardware over HDMI,
> not an emulator.
>
> **Credit where it's due:** the PC Engine RTL is srg320's
> [TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer), and the
> ROM-loading / joypad / OSD layer is nand2mario's
> [TangCore](https://github.com/nand2mario/tangcore). My work is the port: Gowin
> BSRAM/SDRAM mapping, the HDMI output path, the BL616 companion protocol, and a
> from-scratch SCSI/CD bridge. GPL-3.0 throughout.
>
> **What works** (verified on real hardware, Console 60K):
> - HuCard games boot and play — 1943 Kai, Raiden
> - 720p60 HDMI, stable, correct 4:3 aspect
> - PSG audio, two controllers, in-game OSD
>
> **What doesn't, yet:**
> - CD-ROM² is in progress. The syscard boots off the emulated drive and the SCSI boot
>   sequence now matches mednafen/beetle-pce-fast command-for-command, but games don't
>   boot yet.
> - Arcade Card and SuperGrafx are compiled out.
> - Primer 25K and Nano 20K build clean with zero timing violations but have never had a
>   game run on them. If you own either, I'd genuinely like a tester.
>
> Repo: <link>. There's a [STATUS.md](<link>) that's deliberately blunt about what's
> verified on hardware versus what merely compiles.
>
> Happy to answer anything about the port.

### 6.2 r/FPGA / r/EmuDev variant

Same facts, different lead — open with the engineering, not the announcement:

> **Title:** `A show-ahead FIFO bug that only appears when you feed it one byte at a time`
>
> Porting a PC Engine core to Gowin FPGAs, the CD path corrupted every byte the CPU read.
> The donor RTL instantiates its SCSI FIFO with `LPM_SHOWAHEAD = "ON"` — `q` is valid on
> the same cycle `rdempty` falls. My reimplementation read through a block RAM with a
> *registered* output, so `empty` deasserted one cycle before `q` held the data.
>
> It never showed up on the original hardware because the host bursts a whole 2048-byte
> sector in at once, so the read pointer always trails and `q` has long settled. My
> bridge feeds one byte per UART time, so the FIFO is empty at *every* byte and the race
> hits every one. The symptom: the BIOS read `0xf2` where `0x01` was written, took it as
> a track number, asked for track 152, and spun in a REQUEST SENSE loop forever.
>
> [...testbench, fix, link...]

This is a genuinely good post on its own merits and will outperform a promo post in
those subs.

### 6.3 PC Engine communities (r/PCEngine, PCEngineFX)

Lead with the games and the hardware, not the FPGA:

> **Title:** `HuCard games running on a $40-ish FPGA board — PC Engine core for Sipeed Tang`
>
> Not a MiSTer and not trying to be. [...] Video, what works, what doesn't [...]

### 6.4 TangCore Discussions (post this first)

> Hi — I've been building a PC Engine core on top of TangCore and it now runs HuCard
> games on a Console 60K. Wanted to show you before posting it more widely, and to say
> thanks: the iosys/BL616 layer did exactly what your `doc/dev.md` said it would. [...]

---

## 7. Comment-thread prep

Have honest answers ready. These *will* be asked:

- **"Does CD work?"** — No, not yet. The BIOS boots and the SCSI layer is verified
  against a reference emulator, but no CD game boots. Being straight about this is the
  whole reason the post is credible.
- **"Why not just use MiSTer?"** — Different price point and different hardware; this is
  a port to boards people already own, not a replacement.
- **"Which board should I buy?"** — Console 60K is the only one that has run a game.
  Don't let anyone buy hardware on the strength of a clean build.
- **"Is this upstreamed to TangCore?"** — Answer honestly about current fork status.
- **"Accuracy vs MiSTer?"** — Same RTL, so broadly the same; differences will be in the
  memory/timing port, and there are known open bugs (suspected VDC collision issues,
  slight speed fluctuation). Say so.

Budget real time to reply in the first 6 hours. On Reddit, an author who answers
technical questions in-thread is most of what turns a post into a well-received one.

---

## 8. The next announcement

Save these for the CD post, which will be a much stronger story than this one:

- A CD game booting (Dungeon Explorer II or Prince of Persia)
- CD audio playing
- The debugging narrative: reference-tracing a working emulator to find where a hardware
  implementation diverges — instrumenting beetle-pce-fast, diffing the SCSI command
  sequence, finding a 17-bit counter that should have been 20

Do not post a CD update until a game actually boots. That is the milestone people are
waiting for and it only lands once.
