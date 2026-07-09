---
title: "statusline-sprite: configurable Zig statusline with context sprite"
type: spec
status: complete
author: "unknown"
date: 2026-07-09
tags: []
related: []
---# statusline-sprite

A single self-contained Zig binary that renders a Claude Code statusline with a
context-usage-driven sprite.

## Overview

Claude Code invokes one command for its statusline. The binary reads the
statusline JSON on stdin, uploads a sprite image to the terminal via the kitty
graphics protocol, and prints three text rows to stdout.

The sprite occupies the left of all three rows; text sits beside the top rows.
The sprite's face changes with context-window usage: as the session consumes its
context, the face advances through configurable damage tiers.

## Layout

Three rows, sprite on the left:

```
<sprite row 0>  <L1: shell prompt>
<sprite row 1>  <L2: claude info>
<sprite row 2>  <L3: user slot>
```

- **L1 — shell prompt.** Runs a user-configured command (e.g. `starship prompt`)
  and renders its stdout. Works with any prompt tool.
- **L2 — claude info.** Session info from the stdin JSON; v1 shows the model
  display name.
- **L3 — user slot.** Runs a user-configured command and renders its stdout. A
  generic escape hatch.

When no sprite renders, the three text rows print without sprite prefixes.

## Sprite

- **Protocol:** kitty graphics protocol only. Virtual image placement (no cursor
  movement) plus a `box_rows × box_cols` grid of Unicode placeholder cells
  (`U+10EEEE` + row/col diacritics). tmux passthrough wrapping when `$TMUX` or
  `$TERM` indicate tmux or screen.
- **Assets:** face PNGs loaded from disk; paths configurable so users supply
  their own sprite sets.
- **Tier selection:** context-window fill maps to a face tier. Read
  `total_input_tokens` from the JSON, falling back to
  `used_percentage × context_window_size` when absent; clamp to the tier range.
  Tier count and token scale are configurable.
- **Image id per tier:** one image id per tier so a tier change swaps ids rather
  than repainting behind a cached id. Prior image and placements under an id are
  deleted before re-transmit.
- **TTY target:** graphics escapes write to the pane tty (resolve via `tmux
  display -p '#{pane_tty}'` under tmux, else `/dev/tty`). Best-effort: on failure
  the binary still emits placeholders or degrades to text-only rows.

## Configuration

TOML at `~/.config/statusline-sprite/config.toml` (XDG; honour
`$XDG_CONFIG_HOME`). Built-in defaults let the binary run with no config file.

Fields (draft):

- `sprite.dir` / per-tier `sprite.faces` — face PNG path(s).
- `sprite.tiers` — number of damage tiers.
- `sprite.scale_tokens` — full context size damage scales across.
- `sprite.box_rows` / `sprite.box_cols` — placeholder grid geometry.
- `line1.command` — shell-prompt command.
- `line3.command` — user-slot command.

## Non-goals (v1)

- No iTerm2 inline-images protocol; no ASCII/text-face fallback beyond printing
  text rows without a sprite.
- No git, cache, or dev-environment probes on the text rows.

## Resolved decisions (was: open questions)

- **Target toolchain:** Zig 0.16.0 (the installed toolchain). `zig build` builds;
  `zig build test` runs the unit suite.
- **Default tier count & token scale:** `sprite.tiers = 5` (matches the five
  bundled test faces `face0..face4`), `sprite.scale_tokens = 200000`. Tier index
  = floor(tokens / scale_tokens * tiers), clamped to `[0, tiers-1]`.
- **Default sprite dir:** `./test-sprites` (bundled faces `face{0..4}.png`), so
  the binary runs with no config. Overridable via `sprite.dir` / `sprite.faces`.
- **Degradation contract:** if the terminal is not kitty-capable or no target tty
  can be opened, skip graphics entirely and print the three text rows with no
  sprite prefix. Graphics failures are always non-fatal.
- **L1/L3 subprocess contract:** commands run bare via `sh -c "<command>"` (no
  stdin JSON piped in) with a 1s wall-clock timeout. On timeout, non-zero exit,
  or empty stdout, the row renders empty. Only the first line of stdout is used.
- **Default box geometry:** `sprite.box_rows = 3`, `sprite.box_cols = 6`.

## Task breakdown

Each task is TDD (failing test first) and dispatched to a subagent. Zig unit
tests live in `test` blocks; `zig build test` runs them. Pure logic
(config/JSON/tier/escape building/row assembly) is unit-tested; end-to-end
behaviour is covered by an integration test that runs the built binary.

- **T1 — Test harness & module skeleton.** Wire `build.zig` so `zig build test`
  runs unit tests across the source modules. Create module files
  (`config.zig`, `statusline.zig`, `tier.zig`, `kitty.zig`, `rows.zig`) with
  stubs and one trivial passing test each, imported from `main.zig`'s test refs.
  AC: `zig build` and `zig build test` both succeed.

- **T2 — Statusline JSON parsing (`statusline.zig`).** Parse the stdin JSON into a
  struct exposing `model_display_name`, optional `total_input_tokens`, optional
  `used_percentage`, optional `context_window_size`. Tolerant of missing/extra
  fields. AC: sample Claude JSON parses; model display name extracted; missing
  token fields yield nulls, not errors.

- **T3 — Config model, TOML parse & defaults (`config.zig`).** Built-in defaults
  (per Resolved decisions). Load `$XDG_CONFIG_HOME/statusline-sprite/config.toml`
  else `~/.config/...`. Parse the draft fields. Missing file → defaults; partial
  file → overrides merged over defaults. AC: no file → defaults; a file
  overriding `sprite.dir`/`sprite.tiers`/`line1.command` merges correctly;
  `$XDG_CONFIG_HOME` honoured.

- **T4 — Tier selection (`tier.zig`).** `selectTier(tokens, scale_tokens, tiers)`
  and the fallback `tokensFrom(statusline)` = `total_input_tokens` else
  `used_percentage/100 * context_window_size`. Clamp to `[0, tiers-1]`. AC: 0
  tokens → tier 0; ≥ scale_tokens → top tier; boundary crossing moves the tier;
  fallback path computes from percentage when tokens absent.

- **T5 — Kitty graphics escapes (`kitty.zig`).** Pure string builders: base64
  chunked PNG transmit (`a=t`) under a given image id, delete prior image+
  placements for an id (`a=d`), virtual placement (`a=p`, unicode placeholder),
  and the `box_rows × box_cols` U+10EEEE placeholder grid with row/col
  diacritics. tmux passthrough wrapping toggled by an `is_tmux` flag. AC: escapes
  contain the documented control keys; chunking splits large payloads; tmux flag
  wraps with `\ePtmux;` passthrough and doubles `\e`; placeholder grid has the
  right cell count and diacritics.

- **T6 — Text row assembly (`rows.zig`).** Run L1/L3 via `sh -c` with 1s timeout
  (empty on failure/timeout/empty), take L2 = model display name, assemble three
  rows. When a sprite renders, each row is prefixed with its placeholder cell
  columns; when not, rows print bare. AC: given fake command outputs, three rows
  assemble in order; failing/timing-out command → empty segment; sprite vs no
  sprite prefixing correct.

- **T7 — Main wiring, TTY target & degradation (`main.zig`).** Read stdin JSON,
  load config, pick tier, resolve target tty (tmux `pane_tty` else `/dev/tty`),
  best-effort transmit + placement to the tty, print exactly three rows to
  stdout. All graphics failures non-fatal. AC (integration, runs the built
  binary): given sample stdin JSON prints exactly three lines to stdout; runs
  with no config file; still prints three rows when the graphics target can't be
  opened; `sprite.dir` override is respected.

## Acceptance criteria

- Given Claude statusline JSON on stdin, the binary prints exactly three rows.
- With a valid config and a kitty terminal, the face tier matching current
  context usage is uploaded and appears left of the text rows.
- Crossing a tier boundary in context usage changes the displayed face.
- With no config file, the binary runs on built-in defaults.
- With image upload failing, the three text rows still print.
- Sprite PNG paths are overridable via config.
