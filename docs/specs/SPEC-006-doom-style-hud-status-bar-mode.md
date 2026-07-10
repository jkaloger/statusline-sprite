---
title: doom-style HUD status bar mode
type: spec
status: draft
author: Jack Kaloger
date: 2026-07-10
tags: []
related:
- related-to: SPEC-001
---
<!-- intent: specify a text-mode Doom-style HUD row (health bar, cost counter, model panel) rendered from stdin JSON alongside the sprite -->

# Doom-style HUD status bar mode

An opt-in HUD row that renders session stats as a retro status strip next to the
sprite: context headroom as a health bar, session cost as an ammo-style
counter, model display name as a panel. Text-mode only — Unicode block
characters plus 256-color ANSI on one of the existing three text rows.

## Overview

The sprite already plays the Doom mugshot: damage tiers advance as context
fills. The HUD completes the metaphor. One configured row (default L3) is
replaced by a segment strip assembled from the stdin JSON, e.g.:

```
<sprite row 0>  <L1: shell prompt>
<sprite row 1>  <L2: claude info>
<sprite row 2>  HP ████████░░░░ 63%  AMMO $1.42  [Opus 4.5]
```

The HUD is a pure string builder over already-parsed data. It rides the
existing pipeline unchanged: `rows.assembleRows` concatenates arbitrary bytes
per line, so a segment string carrying SGR escapes flows through to stdout
exactly like the existing `line2.color` styling.

## Rendering mode

Text-mode HUD: Unicode blocks (`█`, `░`) and SGR `38;5;<n>` color on a text
row. Not image composition — see Non-goals for the rejected pixel-art
alternative.

- Colors are 256-color palette indices (`u8`), matching the existing
  `line2.color` precedent. One config shape for all color knobs.
- The HUD emits `\x1b[0m` after each colored span so it never leaks styling
  into the gap or a following segment.
- No cursor movement, no extra kitty escapes: the HUD is bytes on an existing
  stdout row.

## Segments

Segments render left to right in config order, joined by two spaces. A segment
whose data is absent from the stdin JSON is hidden — dropped entirely, no
placeholder, no doubled separator. All segments absent → empty row (same as an
unset `lineN.command`).

- **health** — context headroom as a depleting bar. `health = 100 −
  used_percentage`, where usage comes from the same source chain the tiers use:
  `total_input_tokens / context_window_size`, falling back to
  `used_percentage` directly; clamp to `[0, 100]`. Format: `HP <bar> <pct>%`
  with the bar `bar_width` cells wide, `round(health/100 × bar_width)` filled
  `█` cells, remainder `░`. Bar and percentage colored by threshold: health >
  `warn` → `color_ok` (green), ≤ `warn` → `color_warn` (yellow), ≤ `critical`
  → `color_critical` (red). Hidden when neither token count + window size nor
  a percentage is available.
- **cost** — `AMMO $<total>` with `cost.total_cost_usd` formatted to two
  decimals. Unstyled (terminal default). Hidden when the field is absent.
- **model** — `[<model.display_name>]`, rendered reverse-video (SGR 7) as a
  panel. Hidden when the name is empty (parser default `"unknown"` still
  renders — an unknown model is data, not absence).

Health depletes (Doom health drops as damage lands) rather than fills; the
sprite's damage tiers and the bar move in the same direction, so a bloodied
face always sits next to a short red bar.

## Row interaction

`hud.row` selects which of L1–L3 the HUD occupies (default 3, the generic user
slot). **The HUD row wins outright**: when `hud.enabled = true`, that row's
existing config is ignored — `lineN.command` is not spawned at all (no
subprocess whose output gets discarded), and `line2.color`/model rendering is
skipped if `row = 2`. Merging was rejected: two producers on one row means
unpredictable width and duplicate model display when `row = 2`; replacement is
deterministic and keeps the existing lineN semantics untouched for the other
two rows.

## Width budget

The binary does not truncate; the budget is a design target. Defaults:
sprite `box_cols = 6` + gap 2 + health (`3 + bar_width + 5` = 20) + 2 + cost
(~10) + 2 + model (~12) ≈ 52 cells — comfortable in an 80-column terminal.
`bar_width` is the pressure valve for narrow panes. Cell math counts each
block character as one column (all used blocks are single-width).

## Data

All fields come from the existing stdin JSON. Already parsed in
`src/statusline.zig`: `model.display_name`, `context_window.total_input_tokens`,
`context_window.used_percentage`, `context_window.context_window_size`.

**Addition required:** `cost.total_cost_usd` (optional `f64`, top-level `cost`
object, tolerant of absence like the other optionals).

## Configuration

New `[hud]` table in `config.toml`; all fields have defaults so `enabled =
true` alone yields a working HUD:

```toml
[hud]
enabled = false                          # default off; existing users see no change
row = 3                                  # which text row the HUD replaces (1..3)
segments = ["health", "cost", "model"]   # order = render order; unknown names ignored
bar_width = 12                           # health bar cells
health_warn = 50                         # health % at/below which bar turns warn color
health_critical = 20                     # health % at/below which bar turns critical color
color_ok = 46                            # 256-color palette indices
color_warn = 226
color_critical = 196
```

Parsing follows the existing `config.zig` conventions: unknown keys ignored,
out-of-range values ignored (keep default) — `row` outside `1..3`, thresholds
outside `0..100`, `bar_width = 0`. `segments` reuses the existing
single-line string-array parser (`parseStringArray`).

## Non-goals (v1)

- **Pixel-art HUD via PNG tiles (rejected alternative).** Compositing a
  STBAR-style bitmap and placing it through kitty was considered and rejected:
  the statusline rows are text and `rows.zig` assembles text, so an image HUD
  would need a second placeholder grid and image id lifecycle, roughly
  doubling the kitty surface area for marginal visual gain; text blocks + ANSI
  get 90% of the look inside the existing pipeline. Revisit only if a v2 wants
  the authentic bezel.
- No truecolor (`38;2;r;g;b`) config; palette indices only, matching
  `line2.color`.
- No extra segments (git, session duration, output tokens); the segment list
  is the extension point but v1 ships exactly three.
- No multi-row HUD, no width-aware truncation, no terminal-width detection.
- No custom bar glyph or separator config.

## Resolved decisions

- **HUD row replaces, never merges.** See Row interaction; `lineN.command` on
  the HUD row is not executed.
- **Health = headroom, not usage.** The bar depletes as context fills,
  matching Doom health semantics and the sprite's damage direction.
- **Thresholds are health-remaining percentages**, not usage percentages
  (`health_warn = 50` means "warn at half health").
- **Absent data hides the segment**; no `--`/`?` placeholders. An all-hidden
  HUD renders an empty row.
- **256-color only**, `u8` palette indices, consistent with `line2.color`.
- **Fill glyphs fixed** at `█` (filled) / `░` (empty); `▓▒` sub-cell
  gradations left out of v1 (one glyph per cell keeps width math trivial).
- **Separator fixed** at two spaces, matching the sprite/text gap.

## Open questions

- Should tier selection and HUD health share one computed "usage" value
  (extract from `tier.tokensFrom` + `selectTier`) rather than the HUD
  recomputing the token→percentage chain? Leaning yes (single source of
  truth in `tier.zig`); decide at T3.
- `AMMO $1.42` mixes metaphor and currency. Alternative: label `$` only
  (`AMMO 142` in cents is cute but unreadable). Shipping `AMMO $<usd>` unless
  review objects.

## Task breakdown

Each task is TDD (failing test first). Unit tests in `test` blocks; `zig build
test` runs them. HUD string building is pure and fully unit-testable;
end-to-end behaviour extends the existing integration coverage.

- **T1 — Cost field parsing (`statusline.zig`).** Add optional `cost.total_cost_usd`
  to `Raw`/`Statusline` as `total_cost_usd: ?f64`. AC: JSON with
  `"cost": {"total_cost_usd": 1.4225}` parses to `1.4225`; missing `cost`
  object or missing field yields null, not an error; existing tests unchanged.

- **T2 — `[hud]` config (`config.zig`).** `Hud` struct with the documented
  defaults; parse `enabled`, `row`, `segments`, `bar_width`, `health_warn`,
  `health_critical`, `color_ok`, `color_warn`, `color_critical` (needs a bool
  parser; strings/ints/arrays reuse existing helpers). AC: no `[hud]` table →
  defaults with `enabled = false`; partial table merges over defaults;
  `row = 9`, `health_warn = 150`, `bar_width = 0` are ignored (defaults kept);
  `segments = ["cost"]` parses to a one-element list.

- **T3 — Health computation & bar rendering (`hud.zig`).** `healthPercent(sl)`
  → `?f64` from tokens/window with percentage fallback, clamped; `renderBar
  (allocator, health, width, thresholds, colors)` → colored `HP <bar> <pct>%`
  string. AC: 0% used → full green bar `100%`; 63% used → 63% health, correct
  filled-cell count for `bar_width = 12`; health at/below `warn` and
  `critical` switch to `color_warn`/`color_critical` (assert on `38;5;<n>`
  substrings and trailing `\x1b[0m`); no token data and no percentage → null.

- **T4 — Segment assembly (`hud.zig`).** `renderCost`, `renderModel`, and
  `renderHud(allocator, cfg.hud, sl)` assembling segments in config order,
  two-space joined, hidden when data absent, unknown segment names skipped.
  AC: default segment order yields `HP … AMMO $… [name]`; `total_cost_usd`
  null → no `AMMO` and no doubled separator; reordered `segments` reorders
  output; empty result when all data absent; unknown name in `segments` is
  ignored.

- **T5 — Main wiring & row replacement (`main.zig`).** When `hud.enabled`,
  substitute `renderHud` output for text line `hud.row − 1`; do not run that
  row's `lineN.command`; skip `line2.color`/model styling when `row = 2`.
  AC (integration, runs the built binary): with `hud.enabled = true` and
  sample JSON, stdout is exactly three lines and the HUD row contains `HP`,
  `AMMO`, and the model name; with `row = 3` and a `line3.command` configured,
  the command's output does not appear; with `enabled = false` (and by
  default), output is byte-identical to pre-HUD behaviour.

## Acceptance criteria

- With `hud.enabled = false` or no `[hud]` table, output is unchanged from
  current behaviour.
- With `hud.enabled = true` and full sample JSON, the configured row shows
  health bar, cost counter, and model panel in `segments` order.
- The health bar depletes and recolors green → yellow → red as context usage
  crosses the configured thresholds.
- A segment whose source field is absent from the stdin JSON is hidden; the
  remaining segments render without gaps or placeholders.
- The HUD row's `lineN.command` is never executed while the HUD occupies it;
  the other two rows keep their existing behaviour.
- HUD output degrades with the sprite: no sprite → bare text rows including
  the HUD row, exactly as other rows do today.
