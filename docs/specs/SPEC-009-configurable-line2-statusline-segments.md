---
title: configurable line2 statusline segments
type: spec
status: complete
author: Jack Kaloger
date: 2026-07-20
tags: []
related:
- related-to: SPEC-001
- related-to: SPEC-006
---<!-- intent: make statusline line2 a configurable, ordered list of toggle-able segments (model, context, cost, usage limits, and extras) sourced from Claude Code's stdin JSON, replacing the hardcoded model-name-only render -->

# Configurable line2 statusline segments

Today line2 shows exactly one thing: the model display name, optionally wrapped
in a 256-color SGR (`main.zig:100-104`). This spec turns line2 into a
configurable, ordered strip of toggle-able **segments** assembled from the
Claude Code statusline JSON on stdin — context usage, session cost, usage
limits, and a set of smaller extras — while keeping the current model-only
output as the default.

## Overview

line2 becomes a pure string builder over already-parsed stdin data, exactly
like SPEC-006's HUD row and the existing `line2.color` styling: segment strings
carrying SGR escapes flow through `rows.assembleRows` to stdout unchanged. No
new kitty escapes, no cursor movement — just bytes on the existing second row.

```
<sprite row 0>  <L1: shell prompt>
<sprite row 1>  Opus 4.8  45% (12.3k/200k)  $1.42  5h 23%
<sprite row 2>  <L3: user command>
```

The render is driven by a new `[line2]` config: an ordered `segments` list
(each name toggles a segment on and fixes its position), a parallel `colors`
array, and a `separator`. Absent data hides its segment cleanly.

## Relationship to SPEC-006

SPEC-006 (doom-style HUD) and this spec both assemble a config-driven segment
strip, and they **coexist**:

- **SPEC-009 (this spec)** is the *general* segment engine bound to **line2**:
  a flat list of plainly-formatted segments (`Opus 4.8  45%  $1.42`) with
  per-segment palette colors. It is the everyday, themable-by-config line.
- **SPEC-006** is a *themed skin* — a Doom HUD (depleting health bar, ammo-style
  cost, reverse-video model panel) that can occupy any of L1–L3. Its segment
  semantics (health = headroom, glyph bars, thresholds) are deliberately
  Doom-flavoured.

They are cross-linked (`related-to`), share no code by mandate, and neither
supersedes the other. If a future iteration wants one segment abstraction, that
convergence is its own spec — not assumed here. Where both could target line2
(SPEC-006 with `hud.row = 2`), SPEC-006's existing "HUD row wins outright" rule
already governs: an enabled HUD on row 2 replaces line2 rendering entirely, so
the two never both draw the same row.

## Segments

Segments render left to right in `segments` order, joined by `separator`
(default two spaces). Each segment sources one or more fields from the stdin
JSON; a segment whose data is **absent or null** is hidden — dropped entirely,
no placeholder, no doubled separator (matching SPEC-006). All segments hidden →
empty line2 (same as an unset `lineN.command`).

Segment names and their render forms:

- **model** — `model.display_name`. The parser default `"unknown"` is data, not
  absence, and still renders; only a genuinely empty name hides it. Default
  segment list is `["model"]`, preserving today's output.
- **context** — context-window usage. Prefer Claude's precalculated
  `context_window.used_percentage` for the percentage. When
  `total_input_tokens` and `context_window_size` are both present, append the
  raw counts: `45% (12.3k/200k)`. Percentage null but counts present →
  `12.3k/200k`. Neither present → hidden. Token counts render with a `k`
  suffix (one decimal, trimmed) above 1000, else the raw integer.
- **cost** — `$<total>` from `cost.total_cost_usd`, two decimals (`$1.42`).
  Absent → hidden. (Resets to `$0.00` on `/clear`, per Claude's semantics —
  reported faithfully, not suppressed.)
- **session_limit** — the 5-hour rolling window: `5h <pct>%` from
  `rate_limits.five_hour.used_percentage`. `rate_limits` is present only for
  Claude.ai Pro/Max sessions after the first API response, and each window may
  be independently absent — so this segment is hidden for API-key users and
  early in a session. `resets_at` (unix seconds) is available but not rendered
  in v1 (see Non-goals).
- **weekly_limit** — the 7-day rolling window: `7d <pct>%` from
  `rate_limits.seven_day.used_percentage`. Same Pro/Max-only absence rule as
  session_limit.
- **extras** (all opt-in, all hide when their field is absent):
  - **lines** — `+<added>/-<removed>` from `cost.total_lines_added` /
    `cost.total_lines_removed`.
  - **duration** — session wall-clock from `cost.total_duration_ms`, rendered
    compact (`45s`, `12m`, `1h03m`).
  - **effort** — `effort.level` verbatim (`high`); present only for
    reasoning-effort models.
  - **style** — `output_style.name` (hidden when `"default"`, which is noise).
  - **version** — Claude Code `version` string.
  - **fast** — the literal `fast` when `fast_mode` is true, else hidden.
  - **thinking** — the literal `think` when `thinking.enabled` is true, else
    hidden.
  - **vim** — `vim.mode` (`NORMAL`/`INSERT`/…); present only in vim mode.
  - **pr** — `PR#<number>` from `pr.number`, optionally suffixed with a
    review-state marker; present only while an open PR is found.
  - **agent** — `agent.name`; present only under `--agent`.

Unknown names in `segments` are ignored (matching `config.zig`'s
tolerant-parse convention), so a config referencing a segment this build does
not know simply skips it.

## Styling

- `colors` is a parallel array indexed by **segment position** in `segments` —
  the `tier_fps` precedent. Entry `i` colors segment `i`. Each entry is either a
  256-color palette index (`0`–`255`) or the sentinel `-1`, which means "unstyled"
  (terminal default). A short array leaves trailing segments unstyled too.
  **Positions must be preserved**, so `colors` parses to `[]const ?u8` via a
  position-preserving parser (`-1` → null): the existing `parseIntArray(u8, …)`
  drops unparsable tokens and would silently *reindex* every later color, so it
  is NOT reused here. There is no in-band sentinel inside `u8` (all of `0`–`255`
  are valid indices), which is why the `-1`→null mapping lives at parse time.
- Each colored segment emits `\x1b[38;5;<n>m…\x1b[0m`, resetting after its own
  span so color never leaks into the separator or the next segment (matching
  SPEC-006 and the current `line2.color`).
- **Backward compatibility with `line2.color`:** when `segments` is unset,
  line2 renders the model name alone, and the existing `line2.color` (if set)
  colors it — byte-identical to today. When `segments` *is* set, the `colors`
  array governs; `line2.color`, if also present, supplies the color for a
  `model` segment that has no explicit `colors` entry (so an existing
  `color = 213` user who only adds `segments` keeps their colored model).

## Data

New parsing in `src/statusline.zig`. Today's `Raw`/`Statusline` carry
`model.display_name` and three `context_window` fields. This spec extends them,
all optional and absence-tolerant like the existing fields, adding:

- `cost`: `total_cost_usd: ?f64`, `total_lines_added: ?u64`,
  `total_lines_removed: ?u64`, `total_duration_ms: ?u64`
- `rate_limits`: `five_hour.used_percentage: ?f64`,
  `seven_day.used_percentage: ?f64` (the nested objects and `resets_at` parsed
  but `resets_at` unused in v1)
- `effort.level: ?[]const u8`, `output_style.name: ?[]const u8`,
  `version: ?[]const u8`, `fast_mode: ?bool`, `thinking.enabled: ?bool`,
  `vim.mode: ?[]const u8`, `pr.number: ?u64`, `pr.review_state: ?[]const u8`,
  `agent.name: ?[]const u8`

`used_percentage` is Claude's input-only figure
(`input + cache_creation + cache_read`); v1 consumes the precalculated field
directly and does not recompute it. If a later iteration computes it from
`current_usage`, it must use that same input-only formula to match.

## Configuration

Extended `[line2]` table in `config.toml`; every field defaults so an existing
config (or none) yields today's output:

```toml
[line2]
color = 213                                   # existing: colors the model when segments is unset,
                                              #   or the model segment lacking a colors entry
segments = ["model", "context", "cost"]       # order = render order; unknown names ignored; unset = ["model"]
colors = [213, -1, 46]                         # parallel palette indices by position; -1 = unstyled
separator = "  "                               # default two spaces
```

Parsing follows `config.zig` conventions: `segments` via the existing
`parseStringArray`, `separator` via `parseString`, `color` unchanged. `colors`
needs a **new position-preserving parser** (call it `parseOptIntArray`) that
maps `-1` to null and any other unparsable token to null *without dropping the
position* — reusing `parseIntArray(u8, …)` is wrong because it silently drops
bad tokens and reindexes the rest. Unknown keys ignored.

## Non-goals (v1)

- **No doom/HUD theming** — health bars, ammo counters, reverse-video panels
  live in SPEC-006. This spec ships flat text segments only.
- **No truecolor** (`38;2;r;g;b`); 256-color palette indices only, matching
  `line2.color`.
- **No `resets_at` rendering** (no "resets in 2h" countdown); the field is
  parsed but unused. Revisit if users want a countdown.
- **No width-aware truncation or terminal-width detection**; the segment list
  is the pressure valve for narrow panes, as in SPEC-006.
- **No per-segment format strings / custom labels**; each segment's format is
  fixed in v1. `segments` order + `colors` are the only knobs.
- **No application to line1/line3** (command-driven) or a `[line3]`-style
  segment engine; this spec is scoped to line2.

## Resolved decisions

- **Coexist with SPEC-006, cross-linked.** General segment engine (this) vs.
  Doom HUD skin (SPEC-006); neither supersedes. HUD-on-row-2 replacement rule
  keeps them from double-drawing line2.
- **Parallel `colors` array** (`[]const ?u8`), indexed by segment position,
  with `-1` = unstyled. Needs a new position-preserving parser
  (`parseOptIntArray`); `parseIntArray` is unusable here because dropping a bad
  token would reindex later colors.
- **`segments` unset ⇒ `["model"]`**, and `line2.color` keeps coloring the
  model — the default output is byte-identical to today.
- **Absent data hides the segment**, no placeholders, no doubled separator;
  all-hidden ⇒ empty line2.
- **Prefer Claude's `used_percentage`**; do not recompute in v1.
- **Pro/Max-only `rate_limits` segments hide gracefully** for API-key users
  and early in a session.

## Open questions

- Should `context` show percentage-only by default (`45%`) with counts behind a
  separate `context_verbose` toggle, rather than always appending `(x/y)`?
  Leaning always-append when data present; revisit if the line gets crowded.
- Is `$0.00` on a fresh session (or post-`/clear`) worth showing, or should
  `cost` hide below a threshold? Shipping always-show for honesty; decide at
  review.

## Task breakdown

Each task is TDD (failing test first). Unit tests in `test` blocks; `zig build
test` runs them. Segment building is pure and fully unit-testable; end-to-end
behaviour extends the existing integration coverage.

- **T1 — Extend stdin parsing (`statusline.zig`).** Add the optional `cost`,
  `rate_limits`, `effort`, `output_style`, `version`, `fast_mode`, `thinking`,
  `vim`, `pr`, and `agent` fields to `Raw` and flatten them onto `Statusline`,
  all absence-tolerant. AC: JSON carrying each object parses to the expected
  optionals; a missing object or field yields null (not an error); the existing
  `statusline.zig` tests pass unchanged; top-level look-alikes are not picked up
  (mirrors the existing "top-level token fields are ignored" test).

- **T2 — `[line2]` config (`config.zig`).** Extend the `Line2` struct with
  `segments: ?[]const []const u8`, `colors: ?[]const ?u8`, and
  `separator: ?[]const u8`, keeping `color`. `segments` reuses
  `parseStringArray`, `separator` reuses `parseString`. Add a new
  `parseOptIntArray` for `colors` that **preserves position**: `-1` → null, a
  valid `0`–`255` → that index, any other/unparsable token → null (never
  dropped). AC: no `segments` key → `segments`/`colors`/`separator` null,
  `color` behaviour unchanged; `colors = [213, -1, 46]` parses to
  `[213, null, 46]` (length 3, positions intact); an out-of-range token like
  `999` becomes null at its position, not dropped; the existing `line2 color`
  tests still pass; `defaults()` leaves all three new fields null.

- **T3 — Segment renderers (`line2.zig`).** A pure function per segment
  (`renderModel`, `renderContext`, `renderCost`, `renderSessionLimit`,
  `renderWeeklyLimit`, and the extras) taking the parsed `Statusline`, each
  returning an owned string or null (hidden). AC: each renderer produces its
  documented format from representative data; each returns null when its source
  field(s) are absent/null; `context` yields `45% (12.3k/200k)`,
  percentage-only, and counts-only per data availability; token `k`-formatting
  and `duration` compact-formatting have direct unit tests.

- **T4 — Line assembly (`line2.zig`).** `renderLine2(allocator, cfg.line2, sl)`
  resolving `segments` (default `["model"]`), dispatching to renderers in order,
  applying `colors[i]` (falling back to `line2.color` for `model`), joining with
  `separator`, hiding absent segments with no doubled separator, skipping
  unknown names. AC: default (no `segments`) yields the model name, colored by
  `line2.color` exactly as today; a three-segment config renders in order with
  per-position colors and `\x1b[0m` resets; a null-data segment drops with no
  double separator; all-absent → empty string; unknown segment name skipped.

- **T5 — Main wiring (`main.zig`).** Replace the inline line2 build
  (`main.zig:100-104`) with `line2.renderLine2(...)`, threading the fuller
  parsed `Statusline`. Ensure the `parsed == null` fallback still supplies a
  valid `Statusline`. AC (integration, runs the built binary): with no
  `segments` configured and sample JSON, stdout line 2 is byte-identical to
  pre-change output (model name, optional color); with
  `segments = ["model","context","cost"]` and full sample JSON, line 2 shows
  the model, `NN%`/counts, and `$N.NN` in order; rate-limit segments are absent
  from the line when the JSON has no `rate_limits`; output is still exactly
  three lines and degrades with the sprite exactly as other rows do.

- **T6 — Docs & config example.** Update `config.example.toml` and the README
  statusline section to document `segments`, `colors`, `separator`, the full
  segment-name catalogue, and the Pro/Max-only caveat on the limit segments.
  AC: `config.example.toml` shows a working multi-segment `[line2]`; the README
  lists every segment name and its source field.

## Acceptance criteria

- With no `[line2] segments` key (or no config), line2 output is byte-identical
  to current behaviour: the model name, optionally colored by `line2.color`.
- With `segments` set, line2 renders exactly those segments, in order, joined by
  `separator`, each colored by its parallel `colors` entry (or unstyled).
- Every listed segment (model, context, cost, session_limit, weekly_limit, and
  each extra) renders its documented format from representative stdin JSON.
- A segment whose source field is absent or null from the stdin JSON is hidden;
  remaining segments render with no gaps, placeholders, or doubled separators.
- Pro/Max-only `rate_limits` segments are hidden (not errored) for API-key
  sessions and before the first API response.
- Output remains exactly three lines and degrades with the sprite (no sprite →
  bare text rows) exactly as the other rows do today.