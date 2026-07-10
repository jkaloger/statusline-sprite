---
title: client-side animated sprites via background animator daemon
type: spec
status: draft
author: Jack Kaloger
date: 2026-07-10
tags: []
related:
- related-to: SPEC-002
- related-to: SPEC-001
---

<!-- intent: spec for client-side sprite animation via a resident background daemon that re-transmits frames with a=t; supersedes SPEC-002's terminal-side a=f/a=a model, which Ghostty does not support -->

# Client-side animated sprites via a background animator daemon

Supersedes SPEC-002. Keeps SPEC-002's frame model (a tier is a directory of
`0.png`, `1.png`, ... PNG frames), its config surface (`fps`, `tier_fps`,
`max_frames`), its frame resolver (`frames.zig`), and its refresh-state module
(`state.zig`). Replaces the animation delivery: instead of uploading all
frames once and asking the terminal to loop them (`a=f`/`a=a`), a small
resident daemon re-transmits the current frame with `a=t` to a stable image id
on a real timer. **The load-bearing assumption — that re-transmitting `a=t`
to an already-displayed image id repaints its Unicode-placeholder cells with no
placement (`a=p`) or placeholder-text re-emit — is now confirmed. Spike S1
resolved to outcome (a): a bare same-id `a=t` repaints the placeholder cells
with no `a=p` and no placeholder-text re-emit, under Ghostty-under-tmux
(verified 2026-07-10; only the tmux environment was tested).** The design
holds. Spike S2 (detached spawn + `--animate` re-entry) is now also resolved
(2026-07-10) → GO, so both preconditions are met and the design is clear to
advance to `accepted`.

## Why SPEC-002 does not work

SPEC-002 assumed terminal-side playback: transmit frames with `a=f`, run the
loop with `a=a,s=3,v=1`, let the terminal advance frames on its own timer. That
model is correct for kitty, but the target terminal here is **Ghostty**, and
Ghostty does not implement the kitty animation protocol at all.

Evidence gathered while debugging a "sprite is static" report:

- The binary emits a correct animation sequence — `frames=8`, `gap_ms=67`,
  order `delete → a=t → 7×a=f → root-gap → run → a=p`, correct tmux
  ESC-doubling (verified via the runtime debug log and the `buildGraphicsPayload`
  unit tests).
- Ghostty + tmux shows the sprite but **never animates**.
- Ghostty maintainers confirm `a=f` (frame transmit) and `a=a` (animation
  control) are **not supported**
  (<https://github.com/ghostty-org/ghostty/discussions/5218>,
  <https://github.com/ghostty-org/ghostty/issues/8272>). Ghostty implements
  base kitty graphics only. Animation entered the kitty protocol in 0.20.0.

So `a=f`/`a=a` are dead on Ghostty: the terminal keeps displaying frame 0.

**What we have NOT proven.** The one observed "movement" — the sprite changing
on a token-tier crossing — is *not* evidence for same-id `a=t` repaint. A tier
change moves `image_id` to `100 + new_tier` (`main.zig:36`), so the terminal
draws a **different** image id via the full `delete → a=t → a=p` sequence
(`main.zig:346-384`) *and* the stdout placeholder grid is re-emitted with a new
`38;5;<id>` foreground (`kitty.zig:179`). The daemon's real path — **same** id,
**no** `delete`, **no** `a=p`, **no** stdout change — is exercised nowhere today
and by nothing observed. Ghostty forum reports suggest same-id `a=t` re-transmit
updates a displayed image, but this must be confirmed for our exact case
(Unicode placeholder, no placement re-emit, through tmux passthrough) before the
architecture is trusted. See spike S1.

## Why a daemon

The statusline binary is invocation-per-refresh: Claude Code runs it, it prints,
it exits. It cannot animate between invocations. Claude Code re-invokes the
statusline only on its own cadence (throttled to ~300 ms and event-driven, so
~3 fps and irregular). Driving frame advance from statusline invocations alone
caps animation at that rate and makes it stutter with activity.

A resident background process is the only way to advance frames faster than the
Claude Code refresh cycle. The daemon owns a real `sleep(gap_ms)` loop and
re-transmits the current frame to the pane tty, independent of Claude Code.

This reverses SPEC-002's "No resident process" non-goal deliberately.

## Preconditions (spikes — resolve before `accepted`)

Two throwaway spikes gate the whole design. Neither ships; both produce a
go/no-go answer folded back into this spec.

- **S1 — Same-id `a=t` repaint. RESOLVED (2026-07-10) → outcome (a).** In
  Ghostty-under-tmux (passthrough): placed an image under an id via the current
  static path, then from a separate process looped bare `a=t,i=<same id>` with
  *different* frame bytes and observed that the on-screen placeholder cells
  repaint **without** any `a=p` or placeholder-text re-emit. This is outcome
  (a). Only the tmux environment was tested (bare-Ghostty not run; the spec's
  ACs are scoped to Ghostty-under-tmux). Outcomes were: (a) repaints → design
  holds *(this is what occurred)*; (b) repaints only if `a=p` re-emitted →
  daemon must also send `a=p` each tick (still no payload, cheap) — amend the
  daemon loop; (c) never repaints without re-drawing the placeholder cells →
  client cycling is unviable, reconsider.
- **S2 — Detached spawn + `--animate` re-entry on this toolchain. RESOLVED
  (2026-07-10) → GO.** Verified on Zig 0.16.0 (macOS) with a standalone spike:
  `std.process.spawn` with `.ignore` stdio (dup2's `/dev/null` onto the child's
  fds 0/1/2) and no `child.wait()` produces a detached child that survives parent
  exit, reparents to launchd/pid 1 (no zombie), and does not hold the parent's
  tty/stdout. The child calls `setsid()` itself at startup for a new session, and
  argv is reachable via `init.minimal.args`. Mechanism detailed under Detach.

Additionally, the **bare-Ghostty "no image at all"** defect (open question
below) is a prerequisite for the bare-Ghostty ACs; until fixed, this spec's ACs
are scoped to **Ghostty-under-tmux**, which is the user's actual environment.

## Architecture

```
Claude Code --runs--> statusline (one-shot)
                         |  ensures daemon alive, refreshes manifest, touches heartbeat EVERY invocation,
                         |  transmits frame 0 + placement ONLY when state-gated (first run / tier change / TTL),
                         |  prints placeholder rows
                         v
                      animator daemon (resident, one per graphics target)
                         loop: read manifest -> transmit frame k via bare a=t -> sleep(gap) -> k=(k+1)%N
                         exits when heartbeat stale, tty write fails, or manifest gone
```

### Statusline responsibilities (per invocation)

1. Resolve tier, frames, fps, gap, tty target, tmux flag — as today.
2. **Touch the heartbeat file** for this target (see Lifecycle) — on **every**
   invocation for an animated tier, *including the graphics state-hit path*.
   This is an explicit change to `tryGraphics`'s early return (`main.zig:281-285`),
   which today writes nothing on a hit.
3. **Frame-0 transmit stays state-gated.** Emit the static
   `delete → a=t(frame 0) → a=p` sequence **only** on a state miss (first run,
   tier change, or TTL expiry) — exactly the existing gate. Do **not** transmit
   frame 0 on every invocation: `delete` wipes the placement and yanks the
   sprite back to frame 0 mid-animation, and re-writing every refresh races
   Claude Code's writes (the reason the gate exists — see `main.zig:217-222`).
   On the first run this makes the sprite visible before the daemon's first
   tick; thereafter the daemon is the sole steady-state writer.
4. **Animated tier:** refresh the manifest (absolute frame paths — see below),
   ensure the daemon is running. Never emit `a=f`/`a=a`; for a multi-frame tier
   the statusline builds the **static** sequence (frame 0 only), not
   `buildGraphicsPayload`'s animated branch (which still emits the retired
   escapes when `frames.len > 1` — `main.zig:340,346-371`).
5. **Static tier** (N=1, `fps=0`, or `animate=false`): today's path, no daemon.
   If a daemon exists for this target from a previous animated tier, the
   manifest update signals static and the daemon exits (or the tier-change
   frame-0 transmit + a stale heartbeat lets it TTL out).
6. Always: print the placeholder rows to stdout (unchanged stdout contract).

### The animator daemon

Same binary, launched detached in a hidden `--animate <manifest-path>` mode.

Loop:

1. Acquire the manifest lock, read the manifest, **release the lock before
   sleeping** (never hold it across `sleep`, or the statusline's manifest write
   blocks for up to a frame period every refresh).
2. Compute the current frame index; advance it each tick. The daemon owns the
   counter; a manifest signature change (tier/frames) resets it to 0.
3. Read that frame's PNG by **absolute path** (cache bytes, invalidated by the
   manifest's frame signature).
4. Re-transmit bare `a=t,i=<id>` with the frame's bytes (S1 outcome (a)
   confirmed: no `a=p` needed). No `delete`, no stdout, no placeholder text.
5. Check exit conditions (see Lifecycle).
6. `sleep(gap_ms)`.

### Animation manifest

A per-target file in the state dir alongside `state-<key>`: `anim-<key>`.
Line-based `key = value` like `state.zig`. Contents: image id, `gap_ms`, tmux
flag, resolved **absolute** tty path, ordered **absolute** frame file paths,
frame signature. Frame paths must be absolute: a detached daemon's cwd is not
guaranteed to match the statusline's (and `cfg.sprite.dir` defaults to the
relative `"./test-sprites"` — `config.zig:52`; `frames.resolveTierFrames` builds
paths against `Io.Dir.cwd()` — `frames.zig:22,47`). The statusline resolves cwd
to absolute before writing the manifest.

The manifest is the statusline→daemon handoff and the source-of-truth the daemon
polls. Writing it reuses `state.zig`'s locked-write discipline. The heartbeat is
a **separate** file (see Lifecycle), not the manifest mtime.

## Daemon lifecycle

The hard part. Three concerns: singleton, liveness, cleanup.

- **Singleton per target.** At most one daemon per graphics target
  (`state.stateKey(tty, kitty_window_id, tmux_pane)` — `state.zig:46`). Enforced
  with an exclusive advisory lock on `daemon-<key>.lock` (reuse `state.Locked`'s
  flock pattern). A daemon that cannot take the lock exits immediately.
  **Spawn race:** two refreshes may both see no daemon and both spawn; both
  attempt the lock, the loser exits. The statusline's "ensure running" check is
  a non-blocking `flock` try on the lock file: held → a daemon is alive, do
  nothing; free → spawn one. This is TOCTOU-racy by construction; the
  loser-exits rule is what makes it safe, so it is specified, not incidental.
- **Liveness / heartbeat.** A dedicated `heartbeat-<key>` file, touched by the
  statusline on **every** invocation (including the state-hit path — see
  Statusline #2). The daemon exits if the heartbeat is older than
  `daemon_ttl_ms`. This bounds orphan lifetime to one TTL after Claude Code
  stops refreshing. **Idle caveat:** Claude Code is event-driven and an idle
  session may not refresh for longer than the TTL, killing the daemon and
  freezing the sprite until activity resumes (the next refresh respawns it).
  This is acceptable — an idle session need not animate — but it means AC "runs
  independent of CC cadence" holds only while CC is refreshing at all.
- **tty death.** If a frame `write()` fails (`EIO`/`ENXIO`/`EBADF` — terminal or
  pane gone), the daemon exits immediately rather than spinning on a dead fd.
- **Manifest gone.** If the manifest disappears, exit.

The heartbeat TTL is the primary orphan guard; tty-write failure and
missing-manifest are fast-path backups.

**Restarted-terminal aliasing (inherited from SPEC-001/002).** `stateKey` does
not distinguish a terminal restarted on the same tty path (`KITTY_WINDOW_ID`
restarts from 1 — `main.zig:169`). The daemon's lock/manifest/heartbeat share
this key, so a restart reuses them; the tty-write-failure guard kills the stale
daemon on its next failed write, and the heartbeat TTL backs that up. Documented,
not solved.

## Detach

The entrypoint is `pub fn main(init: std.process.Init) !void` on `std.Io`
(`main.zig:12`), toolchain **Zig 0.16** (per `build.zig`). Two consequences:

- **No in-process `fork()`.** Forking and continuing in-process is unsafe under
  `std.Io` (a thread-pool-backed IO would leave only the forking thread alive).
  This is now settled (S2): the daemon is a **fresh exec** of the same binary in
  `--animate` mode via `std.process.spawn` — which does a safe fork+`execvpe`
  inside `std` (allocates before fork, only exec's in the child), so there is no
  raw `std.posix.fork()` and no in-process fork-and-continue. Detachment is: pass
  `.stdin = .ignore, .stdout = .ignore, .stderr = .ignore` (dup2's `/dev/null`
  onto the child's fds 0/1/2, so it neither holds Claude Code's tty open nor
  writes stray bytes to stdout) and never call `child.wait()` — when the parent
  returns the child reparents to launchd/pid 1 (no zombie). New session: the
  **child** calls `setsid()` itself at startup (a fresh exec is not a group
  leader, so it succeeds); there is no spawn-side setsid option.
- **argv access. RESOLVED (S2).** `main` today reads only
  `init.minimal.environ` and stdin. The `--animate <manifest>` mode reads argv
  via `init.minimal.args` (a `std.process.Args`: `.iterate()` yields
  `[:0]const u8` with argv[0] first, or `.toSlice(arena)`). An `SL_SPRITE_ANIMATE
  =<manifest>` env handoff also works and remains available as an optional
  override, but is **not** a required fallback.
- **libc for `setsid`.** `setsid` is only reachable via libc (`std.c.setsid`;
  there is no `std.posix.setsid` nor a stable macOS syscall path). Darwin always
  links libSystem so it resolves today, but `build.zig` does **not** currently
  call `linkLibC`; the real binary must add an explicit `linkLibC()` to make the
  dependency explicit and portable.

## tty write safety

The daemon and Claude Code both write the pane tty. Claude Code periodically
rewrites the statusline text (placeholder cells + the `38;5;<id>` fg that carries
the image id). If a frame escape interleaves mid-write with a Claude Code write,
bytes corrupt.

Reality (not atomicity):

- Each frame is emitted in a **single `write()`** of one `a=t` APC (plus tmux
  wrapper). But this is **not atomic**: on macOS only writes ≤ `PIPE_BUF`
  (512 bytes) are atomic, and a ~600 B PNG base64-encodes to ~800 B plus APC
  framing plus tmux ESC-doubling — comfortably over 512 B, often > 1 KB. So a
  frame write **can** interleave with a Claude Code write and corrupt an APC,
  potentially leaving the terminal briefly in APC-parse state.
- The real mitigation is **rarity + self-heal**: corruption requires the daemon
  and CC to write in the same instant (CC ~3 writes/s, daemon ≤ `max_fps`), and
  a corrupt graphics APC is dropped by the terminal and corrected on CC's next
  full statusline redraw. `max_fps` (default 30, kept low) bounds the window.
- The daemon takes the **same `state.Locked` exclusive lock** around each write
  as the statusline does around its transmit (`main.zig:264`), so daemon and
  statusline writes are serialized against **each other** — this does not
  coordinate with Claude Code (which takes no lock), but removes the
  daemon-vs-statusline race entirely.
- The daemon writes **only image data** (`a=t,i=<id>`), never placeholder text,
  so it never competes for the cells CC draws — only the image store they
  reference.

If the T5 measurement shows corruption is observable at 30 fps, lower the
`max_fps` default and/or gate animation behind a config opt-in.

## Configuration

Reuses SPEC-002 fields (`fps`, `tier_fps`, `max_frames`). New:

```toml
[sprite]
animate = true       # master switch; false => static frame 0 (today's behaviour)
max_fps = 30         # hard cap on effective fps, bounds tty write frequency
daemon_ttl_ms = 5000 # heartbeat staleness before the daemon exits
```

- `animate` — `bool`, default `true`. `false` disables the daemon entirely;
  animated-dir tiers show frame 0 statically. Escape hatch for terminals or
  users that dislike the resident process.
- `max_fps` — `u32`, default `30`. Effective fps is clamped to this.
- `daemon_ttl_ms` — `u32`, default `5000`.

Backward compatible: absent fields default; a SPEC-001 single-PNG config never
spawns a daemon.

## Reused from SPEC-002 (already landed)

- `config.zig`: `fps`, `tier_fps`, `max_frames`, `effectiveFps`.
- `frames.zig`: `resolveTierFrames` — daemon and statusline both use it.
- `state.zig`: `stateKey`, `resolveStatePath`, `Locked` flock, `frameSignature`.
- `kitty.zig`: `transmit` (`a=t`), `delete`, `virtualPlacement`,
  `placeholderGrid`, `wrapTmux`.

## Dropped from SPEC-002

- `kitty.transmitFrame` (`a=f`), `setRootFrameGap`, `runAnimation` (`a=a`) — no
  longer used. Keep as tested dead code for a possible kitty-native fast path,
  or remove; decide in T-breakdown. Not emitted by the default path.
- `buildGraphicsPayload`'s animated branch (`main.zig:340,346-371`) must no
  longer be reached in the default flow — the statusline builds the static
  sequence for animated tiers (Statusline #4).
- The "terminal owns playback" model and the "no resident process" non-goal.

## Non-goals

- No GIF/APNG decoding — frames stay individual PNGs on disk.
- No delta/composed frames; every frame is a full `a=t` image.
- No kitty-native `a=f`/`a=a` path in the default flow (optional future fast path
  for detected kitty).
- No IPC beyond the manifest/heartbeat files; no socket, no signals for frame
  stepping.
- No attempt to coordinate tty writes with Claude Code (only with our own
  statusline, via the shared lock).

## Open questions

- **Bare-Ghostty "no image at all".** Separate defect: outside tmux Ghostty
  showed nothing (not even static). Suspected stale `state=hit` or `/dev/tty`
  targeting. Prerequisite for any bare-Ghostty AC; must be fixed or bare Ghostty
  stays out of scope. Investigate before scoping bare-Ghostty support.
- **S1 outcome — RESOLVED.** Daemon loop transmits bare `a=t` (no `a=p`);
  outcome (a) confirmed under Ghostty-under-tmux (2026-07-10).
- **Multiple Claude Code sessions / split panes.** Each target keyed separately,
  so each gets its own daemon; confirm the key is distinct per pane and the
  lock/manifest/heartbeat files don't collide.

## Task breakdown

Spikes S1 and S2 (above) run first and gate `accepted`. Each task is TDD where
the logic is pure; daemon lifecycle and tty behaviour need an integration harness
(spawn the built binary, assert on a captured pty and on process liveness).

- **T1 — Daemon spawn + detach + singleton** (depends on S2). Hidden
  `--animate <manifest>` mode; fork+exec detached (`setsid`, stdio→`/dev/null`,
  no parent wait) so it outlives the parent; take `daemon-<key>.lock` or exit.
  AC: launching twice for one target yields one live process; the daemon
  survives parent exit; killing the lock holder lets a new one start; the daemon
  does not hold the parent's tty open (parent's tty closes cleanly on exit).

- **T2 — Manifest + heartbeat read/write.** `anim.zig` (or grow `state.zig`):
  serialize the manifest (image id, gap, tmux, **absolute** tty + frame paths,
  signature) with the locked write; parse tolerantly; separate `heartbeat-<key>`
  touch. AC: round-trip; corrupt/missing → tolerant null; signature change
  detected; frame paths asserted absolute.

- **T3 — Daemon frame loop** (depends on S1, T2). Lock→read→unlock manifest →
  transmit frame k via bare `a=t` (S1 outcome (a): no `a=p`) → check exits →
  `sleep(gap)` →
  advance; re-read manifest each tick; clamp to `max_fps`; never hold the
  manifest lock across sleep. AC (integration): captured pty shows successive
  `a=t,i=<id>` with cycling frame bytes at ~the configured interval; a manifest
  fps change alters the interval without a restart; no `a=f`/`a=a` ever emitted.

- **T4 — Statusline integration.** Touch heartbeat every invocation (incl.
  state-hit path); keep frame-0 transmit state-gated; build the **static**
  sequence for animated tiers (no `a=f`/`a=a`); refresh manifest; ensure daemon.
  Static/`fps=0`/`animate=false`: today's path, no daemon. Degradation unchanged:
  any failure → text rows still print. AC (integration): animated tier spawns a
  daemon and the sprite advances; a state hit still touches the heartbeat but
  emits no frame-0 transmit; static tier and `animate=false` spawn none.

- **T5 — Lifecycle + tty safety.** Heartbeat TTL exit; exit on tty write error;
  exit on manifest removal; single-write frame emission under the shared lock;
  measure interleave corruption at `max_fps`. AC: daemon exits within one TTL
  after refreshes stop; exits when the captured pty is closed; no orphan after
  the harness tears down; corruption not observed at default `max_fps` (or the
  default is lowered until it isn't).

- **T6 — Config + docs.** `animate`, `max_fps`, `daemon_ttl_ms` in `config.zig`
  with defaults; update `config.example.toml`, README, and the terminal-support
  note (Ghostty animates via the daemon; kitty too; `a=f`/`a=a` retired). AC:
  defaults as stated; `animate=false` disables; example config documents the
  daemon and how to kill a stuck one.

## Acceptance criteria

Scope: **Ghostty-under-tmux** (the user's environment) unless the bare-Ghostty
defect is fixed first. ACs split into automatable (pty-capture harness) and
manual (real terminal, visual).

Automatable:

- The daemon emits successive `a=t,i=<id>` escapes with cycling frame bytes at
  ~the clamped configured interval; it never emits `a=f`/`a=a`.
- At most one animator daemon runs per graphics target; a second invocation
  never spawns a duplicate.
- The daemon exits within one `daemon_ttl_ms` after the statusline stops
  refreshing, on tty write failure, and on manifest removal — no orphaned
  processes spinning on a dead tty.
- A state hit touches the heartbeat but emits no frame-0 transmit; frame-0
  transmit occurs only on first run / tier change / TTL.
- A single-PNG tier, `fps = 0`, or `animate = false` spawns no daemon.
- Any failure to spawn or write degrades to a visible static frame 0 and the
  three text rows — never a crash, never a blank sprite where SPEC-001 showed
  one.
- A SPEC-001 config with single-PNG tiers runs unchanged.

Manual (real-terminal visual verification):

- In Ghostty-under-tmux, an animated-dir tier visibly advances frames on a real
  timer at the configured fps, independent of the Claude Code refresh cadence
  (while CC is refreshing at all).
- Crossing a tier boundary visibly swaps the animation to the new tier's frames
  under its image id.
