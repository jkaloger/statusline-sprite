---
title: event-reactive sprite states
type: spec
status: draft
author: Jack Kaloger
date: 2026-07-10
tags: []
related:
- related-to: SPEC-001
---
<!-- intent: spec for sprite states that react to session events (tool errors, idle, turn completion), overriding the token-tier face temporarily -->

# Event-reactive sprite states

Sprite reacts to session events, not just token tiers. Tool error flashes a
`hurt` face; long idle shows `sleep`; a clean turn flashes `happy`. Event state
overrides the tier face for a bounded time, then decays back.

## Overview

SPEC-001 maps context-window fill to a damage tier; the face only changes with
token usage. This spec adds a second, transient signal channel with two
sources:

1. **Statusline stdin JSON** — fields beyond `model`/`context_window`:
   `session_id`, `transcript_path`, `cost`, `exceeds_200k_tokens`. v1 of this
   spec consumes `session_id` (state-file key) and `transcript_path` (event
   source).
2. **Transcript JSONL** — the file at `transcript_path`. Each statusline
   invocation tails it from a saved byte offset and scans new lines for events.

The binary stays stateless-in-process. Cross-invocation state (transcript
offset, active event state, expiry) lives in a small per-session file under
`$XDG_STATE_HOME/statusline-sprite/`.

## Event states

Three built-in states, each backed by an optional PNG in the sprite pack:

| State  | Trigger                                                      | Lifetime                            |
|--------|--------------------------------------------------------------|-------------------------------------|
| `hurt` | tool result with an error flag in new transcript lines        | `events.ttl_seconds` after trigger  |
| `happy`| assistant turn completed with no error in that turn           | `events.ttl_seconds` after trigger  |
| `sleep`| transcript untouched for > `events.idle_seconds`              | ambient; clears when activity resumes |

- **Precedence:** `hurt` > `happy` > `sleep`. Timed states (`hurt`/`happy`)
  always beat the ambient `sleep`. If multiple timed events fire in one scan,
  the highest-precedence one wins; a new trigger of the same or higher
  precedence resets the expiry.
- **Decay:** timed states expire by wall clock (`expires_at_ms` in the state
  file). Once expired, the tier face resumes. No render counting — invocation
  cadence is Claude-driven and not observable enough to be a stable unit.
- **Missing PNG = state ignored.** State detection still runs (offset advances)
  but face resolution falls through to the tier face. A pack with no `events/`
  dir behaves exactly as today.

## Event detection

Transcript tail scan, per invocation:

- Load state file. If `offset > file size` (rotated/replaced transcript), reset
  `offset = max(0, size - max_tail_bytes)`.
- Read at most `events.max_tail_bytes` (default 256 KiB) from `offset`; if the
  unread region exceeds the cap, skip ahead so only the newest cap is scanned.
- Split on `\n`; parse each complete line as JSON with unknown fields ignored.
  Lines that fail to parse, or parse to shapes we don't recognise, are skipped
  silently — the transcript format is not ours and will drift. A trailing
  partial line is not consumed; the offset stops before it.
- Detection is structural, not schema-exact: a line counts as a **tool error**
  when it contains a tool-result payload with a true error flag
  (e.g. `is_error: true` on a `tool_result` content item); as a **turn
  completion** when an assistant message ends its turn without a preceding
  error in the same scan window.
- **Idle** uses the transcript file's mtime, not content: `now - mtime >
  idle_seconds` → `sleep`. No transcript read needed for this path.
- Save new offset + state after the scan. Whole event path is best-effort:
  unreadable transcript, missing `transcript_path`, or unwritable state dir
  disables events for that invocation, never breaks the statusline.

## Per-session state file

`$XDG_STATE_HOME/statusline-sprite/<session_id>.json` (fallback
`~/.local/state/statusline-sprite/`). Missing or corrupt file → fresh zero
state, never an error. `session_id` missing from stdin JSON → events disabled
for that invocation.

```json
{
  "offset": 48213,
  "state": "hurt",
  "expires_at_ms": 1783958400000
}
```

Writes go to a temp file in the same dir, then rename — atomic enough for the
single-writer case (Claude Code runs statusline invocations serially per
session). Concurrent sessions key different files. Last-writer-wins is
acceptable by design; no locking.

Stale files: session ids churn. Best-effort sweep on write — unlink sibling
state files with mtime older than 7 days.

## Face resolution & rendering

Slots in after tier selection in `main.zig` (today: `tier.selectTier` →
`image_id = 100 + tier_idx` → `readFace`):

1. Compute tier face as today.
2. If events enabled and an unexpired event state is active, try
   `<events.dir>/<state>.png` (default `events.dir` =
   `<sprite.dir>/events`). Readable → it replaces the tier face and the image
   id becomes `200 + state_index` (`hurt`=200, `happy`=201, `sleep`=202).
   Unreadable → tier face and tier id as if no state.
3. Everything downstream (transmit, placement, placeholder grid, row assembly)
   is unchanged; it just receives a different PNG + id.

Distinct id ranges (tiers 100..104, events 200..202) keep the existing
delete-before-retransmit contract and stay ≤ 255 for the palette-index
placeholder encoding.

## Configuration

New `[events]` table; defaults let it run with no config change:

```toml
[events]
enabled = true
ttl_seconds = 10        # hurt/happy display time
idle_seconds = 120      # inactivity before sleep
dir = ""                # "" = <sprite.dir>/events
max_tail_bytes = 262144
```

Parsed by the existing line-based TOML reader in `config.zig` (string/int keys
plus a new bool parser for `enabled`). Unknown keys ignored as today.

## Non-goals (v1)

- No event triggers from `cost` or `exceeds_200k_tokens` (listed as sources for
  later; the plumbing — parsed stdin fields — is in place after T1).
- No user-defined custom states or trigger expressions; the three built-ins and
  their thresholds only.
- No animation on event faces (SPEC-002 territory).
- No cross-session aggregation; state is strictly per `session_id`.

## Resolved decisions

- **Time-based decay only.** `ttl_seconds`, no render counting.
- **Fixed precedence** `hurt` > `happy` > `sleep`; not configurable in v1.
- **Idle via mtime**, not transcript content — free and robust to format drift.
- **Atomicity:** temp-file + rename per write; last-writer-wins; no locks.
- **Missing state PNG ignores the state** rather than erroring or falling back
  to another state's PNG.
- **Event scan failures are silent** and never degrade the three text rows.

## Open questions

- **Transcript JSONL schema.** Exact field names for tool errors and turn
  boundaries in Claude Code transcripts are not pinned by any public contract
  (believed: entries with `type`, nested `message.content[]` items where
  `tool_result` carries `is_error`). T4's matcher must be verified against a
  real transcript before its tests are finalised; design already assumes
  drift-tolerance (skip anything unrecognised).
- **`happy` trigger definition.** "Assistant turn completed without error in
  the scan window" is an approximation; if turn boundaries prove unreliable in
  the transcript, drop `happy` to post-v1 rather than misfire.
- **Sweep cost.** The 7-day stale-file sweep is one `readdir` per write; if the
  state dir grows large this may need a probabilistic (1-in-N) trigger.

## Task breakdown

Each task TDD (failing test first), unit-tested pure logic, integration via the
built binary, matching SPEC-001's harness (`zig build test`).

- **T1 — Stdin JSON extension (`statusline.zig`).** Add optional top-level
  `session_id`, `transcript_path`, `exceeds_200k_tokens`, and `cost`
  (`total_cost_usd`, `total_duration_ms`) to `Raw`/`Statusline`. AC: sample
  JSON with these fields populates them; JSON without them yields nulls;
  existing tests unaffected.

- **T2 — Config `[events]` table (`config.zig`).** Defaults per Configuration
  section; parse `enabled` (bool), `ttl_seconds`, `idle_seconds`,
  `max_tail_bytes` (ints), `dir` (string). AC: no `[events]` table → defaults;
  partial table merges; `enabled = false` parses; unknown keys ignored.

- **T3 — Session state file (`state.zig`).** Path resolver
  (`$XDG_STATE_HOME` else `$HOME/.local/state`), JSON read (missing/corrupt →
  zero state), atomic temp+rename write, stale-sibling sweep. AC: round-trip
  write/read; corrupt file → zero state, no error; path honours
  `XDG_STATE_HOME`; write creates parent dirs.

- **T4 — Transcript scan (`events.zig`, pure).** `scan(bytes) → ?Event` over a
  byte window: JSONL split, tolerant parse, tool-error and turn-completion
  matchers, trailing-partial-line handling, consumed-length return for offset
  advance. AC: window with an `is_error` tool result → `hurt`; clean
  turn-completion window → `happy`; unknown/garbage lines skipped without
  error; partial trailing line not consumed.

- **T5 — State machine (`events.zig`).** `resolve(prev_state, scan_event,
  transcript_mtime, now, cfg) → next_state`: precedence, expiry re-arm, decay
  to none, idle → `sleep`, activity clears `sleep`. AC: `hurt` beats `happy`
  beats `sleep`; expired timed state decays; re-trigger resets expiry; mtime
  older than `idle_seconds` yields `sleep` only when no timed state active.

- **T6 — Main wiring & face override (`main.zig`).** Load state, cap-limited
  tail read from saved offset, run T4/T5, persist state, override face path +
  image id (`200 + state_index`) when the state PNG is readable. All
  failures non-fatal. AC (integration, runs the built binary): transcript
  fixture with a tool error + `events/hurt.png` present → hurt face id
  transmitted; same fixture without the PNG → tier face; second invocation
  after `ttl_seconds` → tier face; no `transcript_path` in stdin → behaves
  exactly as pre-spec; three text rows always print.

## Acceptance criteria

- A tool error appearing in the transcript flashes the `hurt` face for
  `ttl_seconds`, then the tier face resumes.
- A transcript idle past `idle_seconds` shows `sleep`; new activity clears it.
- A sprite pack without an `events/` dir (or a specific state PNG) renders
  exactly as before this spec.
- Repeated invocations only read transcript bytes past the saved offset,
  bounded by `max_tail_bytes`.
- Unparseable or unrecognised transcript lines are skipped; the statusline
  never fails or garbles output because of transcript content.
- `[events]` absent from config → feature runs on defaults; `enabled = false`
  disables all event scanning and state writes.
