---
title: animated sprite tiers via kitty animation protocol
type: spec
status: in-progress
author: Jack Kaloger
date: 2026-07-10
tags: []
related:
- related-to: SPEC-001
- related-to: SPEC-005
---
<!-- intent: spec for per-tier animated sprites driven by the kitty graphics animation protocol, terminal-side looping, no resident process -->

# Animated sprite tiers via kitty animation protocol

Extends SPEC-001. A tier can be a directory of PNG frames instead of a single
PNG. Frames upload once via kitty animation escapes (`a=f`), the terminal loops
them itself (`a=a`, per-frame gap). The binary stays invocation-per-refresh:
Claude Code runs it, it exits, the animation keeps playing.

## Overview

Today (`main.zig`) each refresh does delete → `transmit` (`a=t`) → `virtualPlacement`
(`a=p,U=1`) for the tier's single PNG, then prints placeholder rows. That model
breaks for animation: re-transmitting N frames every ~300 ms refresh is heavy,
and restarting the animation each refresh means the terminal never gets past
frame 0.

Fix: make the terminal own playback and make transmission conditional.

1. **Frame source.** Tier N resolves to `<dir>/face<N>/` (frames `0.png`,
   `1.png`, ... contiguous from 0) when that directory exists, else
   `<dir>/face<N>.png` as today. One frame → static path, zero animation
   escapes. Explicit `sprite.faces` entries may likewise name a directory.
2. **Transmit once.** On tier change (or first run), delete the image id,
   transmit frame 0 as the root image (`a=t`), append frames 1..N-1 with
   `a=f`, set per-frame gap from fps, start looping with `a=a,s=3,v=1`, emit
   the virtual placement. Image ids stay `100 + tier_idx` (≤ 255, per the
   256-color placeholder constraint in `kitty.placeholderGrid`).
3. **Refresh state.** A small state file records what was last transmitted to
   which terminal. When state matches (same tier, same frame signature, same
   fps), the refresh writes nothing to the tty — only the placeholder rows to
   stdout. The placement persists in the terminal; the animation keeps looping.
4. **Stdout contract unchanged.** Placeholder grid and row assembly
   (`rows.zig`) are identical for static and animated tiers. Animation is
   entirely a tty-side concern.

## Kitty animation escapes

New pure builders in `kitty.zig`, same style as `transmit`/`delete` (APC
`\x1b_G...\x1b\\`, `q=2` everywhere to suppress ACKs, base64 chunked at 4096
with `m=` continuation):

- **Frame transmission — `a=f`.** First chunk
  `a=f,f=100,i=<id>,z=<gap_ms>,q=2,m=<0|1>`; continuation chunks `m=` only,
  same as `a=t`. `z` is that frame's gap to the next frame in milliseconds.
  Creates a new frame when `r` is absent. (`r=<n>` edits an existing 1-based
  frame; `c=<n>` seeds a new frame from frame n's data; `x`/`y` offset the
  transmitted data — none of these are used here, every frame is a full
  image.)
- **Root frame gap — `a=a,i=<id>,r=1,z=<gap_ms>,q=2`.** The `a=t` root
  transmission is frame 1 and carries no gap; set it via animation control so
  frame 0 of the source displays as long as the others.
- **Run animation — `a=a,i=<id>,s=3,v=1,q=2`.** `s=3` runs with looping; `v=1`
  means loop infinitely (`v=0` ignored, `v=N` loops N-1 times).
- Gap: `gap_ms = round(1000 / fps)`, same value on every frame (uniform fps,
  no per-frame timing).

Escape order per (re)transmit: `delete` → `a=t` frame 0 → `a=f` frames 1..N-1
→ root gap → run → `virtualPlacement`.

### tmux passthrough

No new mechanism. Every APC (including `a=f`/`a=a`) is individually
`wrapTmux`-wrapped exactly as today; requires `allow-passthrough on` as before.
Chunk size stays 4096 base64 chars pre-wrap so wrapped escapes stay within
tmux's tolerance. Animation multiplies payload bytes by frame count — the
state-file gate is what keeps this off the per-refresh hot path, not smaller
chunks.

## Refresh state file

New module `state.zig`. Location:
`$XDG_STATE_HOME/statusline-sprite/state-<key>` else
`~/.local/state/statusline-sprite/state-<key>` (mirrors
`config.resolveConfigPath` shape).

- **Key** = hash of the graphics target identity: resolved tty path +
  `$KITTY_WINDOW_ID` (if set) + `$TMUX_PANE` (if set). Distinct panes/windows
  get distinct state.
- **Contents** (line-based `key = value`, parsed like the minimal TOML reader):
  `tier`, `image_id`, `fps`, and a frame signature = frame count plus each
  frame's (size, mtime). Signature mismatch → re-transmit.
- **Flow:** read state → compare → on match, skip all tty writes; on mismatch
  or unreadable state, do the full escape sequence, then write state.
  State-write failure is non-fatal (worst case: re-transmit next refresh).
- Static single-PNG tiers use the same gate — a free improvement over
  SPEC-001's unconditional per-refresh re-transmit.
- **Stale state** (terminal restarted, image gone, state says transmitted):
  see Open questions.

## Configuration

New `[sprite]` fields, parsed by the existing minimal reader in `config.zig`
(needs one new primitive: single-line integer array, sibling of
`parseStringArray`):

```toml
[sprite]
dir = "/path/to/sprites"
tiers = 5
fps = 8                        # global frame rate for animated tiers
tier_fps = [8, 8, 10, 12, 16]  # optional per-tier override, indexed by tier
max_frames = 32                # sanity cap per tier
```

- `sprite.fps` — `u32`, default `8`. Effective fps for tier N =
  `tier_fps[N]` when present and in range, else `fps`. `fps = 0` or a
  zero entry → treat tier as static (frame 0 only).
- `sprite.tier_fps` — optional `[]u32`, shorter-than-tiers arrays fall back to
  global for missing indices.
- `sprite.max_frames` — `u32`, default `32`. Frames beyond the cap are
  ignored. Per-frame read reuses the existing 1 MiB `readFileAlloc` limit;
  worst case tty payload ≈ 32 MiB × 4/3 base64 — cap exists so a stray
  directory can't do worse.
- Backward compatible: absent fields default; a config with only SPEC-001
  fields behaves exactly as today.

## Frame resolution

Replaces `main.readFace` with a frames resolver (new `frames.zig` or grown
`config.zig`):

1. Determine tier path: `sprite.faces[tier]` if set, else `<dir>/face<N>`
   derivation.
2. If path (sans `.png`) is a directory: collect `0.png`, `1.png`, ...
   stopping at the first missing index, cap at `max_frames`. Empty directory →
   no sprite (same degradation as missing PNG today).
3. Else: single PNG as today.
4. One frame resolved → static path: `a=t` + placement only, no `a=f`, no
   `a=a`.

## Non-goals

- No GIF/APNG decoding — frames are individual PNGs on disk
  (`test-sprites/doomguy.gif` stays a source asset, not a runtime input).
- No delta/composed frames: `x`, `y`, `c` compose keys unused; every frame is
  a full image.
- No per-frame variable timing; uniform fps per tier.
- No terminal capability query (`a=q`) or ACK parsing; graphics stay
  fire-and-forget best-effort.
- No resident process, timers, or self-refresh; playback is 100% terminal-side.

## Resolved decisions

- **Directory wins.** If both `face2/` and `face2.png` exist, the directory is
  used. Deterministic, and a user adding frames shouldn't have to delete the
  old PNG first.
- **Frame numbering.** `0.png`-based, contiguous; a gap truncates the
  animation rather than erroring. Matches `face0..face4` zero-based
  convention.
- **State gates static tiers too.** Simpler main flow (one code path decides
  "transmit or not"), and drops redundant per-refresh uploads.
- **Loop forever.** `v=1` hardcoded; loop count not configurable.
- **`q=2` on every animation escape.** ACK leakage corrupts the shell, same
  reason as SPEC-001's delete/transmit.

## Open questions

- **Stale state after terminal restart.** New kitty window reuses a tty path;
  state says "transmitted" but the image is gone → sprite missing until the
  tier changes. Options: (a) accept, document `rm` of the state dir as the
  fix; (b) TTL — force re-transmit when state is older than N minutes
  (restarts the loop visibly once per TTL); (c) fold more identity into the
  key (kitty PID? boot time?). Leaning (b) with a generous default (10 min),
  needs a decision.
- **Protocol details to verify against kitty docs before T2:** exact key for
  setting the *root* frame's gap via `a=a` (spec'd here as `r=1,z=<gap>`), and
  whether `z` on the first `a=f` chunk is honoured when chunked (`m=1`).
- **Non-kitty "capable" terminals.** `detectCaps` treats ghostty/wezterm as
  kitty-capable, but their animation (`a=f`/`a=a`) support is unverified.
  Without `a=q` we can't detect it. Likely fine — unknown keys are ignored and
  the root frame still displays statically — but confirm neither terminal
  echoes garbage on unknown `a=` values.
- **Claude Code refresh vs placement lifetime.** Assumed: a placement under a
  stable image id survives statusline re-renders (it does today for static
  images). If some terminal drops virtual placements when placeholder cells
  are rewritten, the state gate would need to always re-emit `a=p` (cheap, no
  payload) — decide during T6 integration.

## Task breakdown

Each task TDD (failing test first), `zig build test` green throughout. Pure
logic unit-tested; end-to-end via the integration test that runs the built
binary.

- **T1 — Config: fps fields (`config.zig`).** Add `fps`, `tier_fps`,
  `max_frames` to `Sprite` + defaults; implement `parseIntArray`; add
  `effectiveFps(cfg, tier_idx)`. AC: defaults are `fps=8`, `tier_fps=null`,
  `max_frames=32`; TOML overrides merge; `tier_fps` shorter than `tiers`
  falls back to global; `fps = 0` yields 0 (static signal); SPEC-001-only
  configs unchanged.

- **T2 — Animation escape builders (`kitty.zig`).** `transmitFrame(allocator,
  image_id, gap_ms, png_bytes, opts)` → chunked `a=f,f=100,i,z,q=2` APCs;
  `setRootFrameGap(allocator, image_id, gap_ms)` → `a=a,i,r=1,z,q=2`;
  `runAnimation(allocator, image_id)` → `a=a,i,s=3,v=1,q=2`. AC: control keys
  present with correct values; large payload chunks with `m=` and only the
  first chunk carries `a=f`/`z`; payload round-trips through base64; all carry
  `q=2`.

- **T3 — Frame resolution (`frames.zig`).** `resolveTierFrames(allocator, io,
  cfg, tier_idx)` → ordered frame path list per the rules above (dir wins,
  contiguous from `0.png`, `max_frames` cap, single-PNG fallback). AC: tmp
  dir with `face1/0.png..2.png` yields 3 paths in order; gap at `1.png`
  yields 1 path; dir + `face1.png` both present → dir; no dir → PNG path;
  neither → empty/null; cap enforced.

- **T4 — Animation payload assembly.** `buildAndWrite` grows a frames variant:
  given N frame byte-slices + gap_ms, emit delete → `a=t` → (N-1)×`a=f` →
  root gap → run → placement, each maybe-tmux-wrapped. N=1 or gap 0 → exactly
  today's static sequence (no `a=f`, no `a=a`). AC: escape order as spec'd;
  N=1 output contains no `a=f`/`a=a`; tmux flag wraps every APC.

- **T5 — Refresh state (`state.zig`).** Key derivation from (tty path,
  `KITTY_WINDOW_ID`, `TMUX_PANE`); signature from frame stat list;
  read/compare/write against `$XDG_STATE_HOME` else `~/.local/state`. AC: key
  stable for same inputs, distinct for different pane ids; round-trip
  write→read compares equal; changed mtime, frame count, tier, or fps →
  mismatch; missing/corrupt file → mismatch, no error.

- **T6 — Main wiring (`main.zig`).** Swap `readFace` for frame resolution,
  gate `tryGraphics` behind state comparison, write state after successful
  transmit. Degradation contract unchanged: any failure → text rows still
  print. AC (integration): three rows always; animated-dir tier writes
  `a=f`+`a=a` escapes to the graphics target on first run; immediate second
  run with unchanged inputs writes zero graphics bytes; tier change
  re-transmits under the new image id; single-PNG tier never emits `a=f`/`a=a`.

## Acceptance criteria

- A tier backed by a frame directory uploads all frames once and the terminal
  loops the animation without the binary running continuously.
- Per-refresh invocations with unchanged tier/frames/fps write no graphics
  escapes to the tty; the animation continues uninterrupted.
- Crossing a tier boundary swaps to the new tier's animation (or static face).
- A tier backed by a single PNG behaves byte-identically on the tty to a
  static face except for transmit frequency (state gate), and emits no
  animation escapes.
- `fps` and `tier_fps` control per-frame gap; per-tier value wins over global.
- Frame count is capped by `max_frames`; oversized/missing frames degrade to
  fewer frames or no sprite, never a crash.
- Under tmux, animation escapes are passthrough-wrapped and the animation
  plays in the host terminal.
- A SPEC-001 config with single-PNG tiers runs unchanged.
