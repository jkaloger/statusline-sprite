---
title: "fix daemon Claude Code pty write race corrupting animated sprites"
type: spec
status: draft
author: "Jack Kaloger"
date: 2026-07-11
tags: []
related: []
---

<!-- intent: fix the daemon↔Claude Code pty write race that corrupts animated sprites under Ghostty+tmux (base64 leaks as text). SPEC-007's "rarity + self-heal" mitigation lost in practice; this picks a real fix. -->

## Problem

Animated sprite corrupts: raw base64 APC payload prints as text in the pane.
Self-heals on redraw (window switch). Confirmed Ghostty-under-tmux.

Root cause CONFIRMED (visual proof, image #2): daemon frame write interleaves
byte-for-byte with Claude Code statusline write on the shared pane pty. Two
writers, no shared lock. CC bytes land mid-`\x1b_Ga=t...` → APC framing breaks →
base64 falls to ground state → printed as text, persists until next redraw.

Evidence:
- image #2: CC spinner text (`Julienning…`, `[53;`, `thinking with high effort`)
  spliced INTO sprite base64. Interleave, not truncation.
- leaked tail decodes to PNG tEXt `date:modify 2026-07-10T06:15:33Z` = luigi-2
  animated frame (16:15 AEST), single ~2.2KB chunk. Not the big-PNG path.
- SPEC-007 §"tty write safety" predicted this: frame b64 > `PIPE_BUF` (512B
  macOS) → write NOT atomic → interleave possible. Bet on rarity+self-heal.

## Why the obvious fix is blocked

Frame swap requires overwriting image store `<id>` pixels every tick. Cannot
send a tiny per-tick placement instead: placeholder cells encode `<id>` in a
`38;5;<id>` fg drawn by Claude Code's statusline text — daemon cannot repoint
them. Frame-select (`a=a,c=`) is tiny+atomic but needs kitty animation play,
unsupported by Ghostty (SPEC-002 died on this). So per-tick writes stay large.

Key asymmetry: the STATUSLINE binary's tty write does NOT race CC — CC waits
for the subprocess, collects stdout, then writes. Only the ASYNC daemon races.

## Options

1. **Statusline-driven frames (drop async pixel writes).** Advance frame from
   each statusline invocation (CC ~3/s), write APC before returning. Serialized
   with CC → race gone. Cost: fps capped at CC refresh (~1-3fps), jerky.
2. **Chunk each frame into ≤PIPE_BUF atomic writes.** Needs kitty to tolerate
   foreign bytes between chunks of one image — UNVERIFIED, likely unsafe.
3. **Lower max_fps only** (SPEC-007 fallback). Shrinks window, does not close.
4. **Self-heal harder**: daemon triggers a redraw after each frame. Hacky,
   flicker.

## Acceptance criteria

- Repro test: concurrent daemon+CC writes to one stream, assert emitted APC
  survives intact (fails on main).
- Under Ghostty+tmux, animated luigi runs with no base64 leak over N minutes.
- Static path + non-tmux path unaffected.

## Open

- Also fix (independent): big static PNG wraps all 361 chunks in ONE tmux
  passthrough (`main.zig` buildGraphicsPayload). Convention = one passthrough
  per chunk. Separate task.

