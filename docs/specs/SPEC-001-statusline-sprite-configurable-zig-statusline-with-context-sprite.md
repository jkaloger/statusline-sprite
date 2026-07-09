---
title: "statusline-sprite: configurable Zig statusline with context sprite"
type: spec
status: accepted
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

## Open questions

- Target Zig version / toolchain.
- Default tier count and token scale.
- Degradation contract when the terminal lacks kitty graphics support.
- Whether L1/L3 commands receive the stdin JSON or run bare.
- Timeout and error handling for the configured L1/L3 subprocess commands.

## Acceptance criteria

- Given Claude statusline JSON on stdin, the binary prints exactly three rows.
- With a valid config and a kitty terminal, the face tier matching current
  context usage is uploaded and appears left of the text rows.
- Crossing a tier boundary in context usage changes the displayed face.
- With no config file, the binary runs on built-in defaults.
- With image upload failing, the three text rows still print.
- Sprite PNG paths are overridable via config.
