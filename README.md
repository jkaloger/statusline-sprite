<h1 align="center">
  🤠
  <br>statusline-sprite
</h1>
<p align="center">
    A Claude Code statusline that renders a sprite next to your status text using the kitty graphics protocol. The sprite changes as context window usage grows.
</p>

<img alt="doomguy" src="https://github.com/user-attachments/assets/14738443-7e6a-4ea9-93e8-3805eeaceb2c" />

## Build

```sh
just build      # debug build
just install    # release build -> ~/.local/bin
```

## Try it

```sh
just demo
```

## Configure

Copy `config.example.toml` to `~/.config/statusline-sprite/config.toml` and point `sprite.dir` at a directory of tiered sprite PNGs. `[line1]`/`[line3]` set a shell command for that row; `[line2]` is a configurable strip of segments (see below).

### Line2 segments

`[line2]` renders an ordered, toggle-able strip instead of a single hardcoded model name:

```toml
[line2]
segments = ["model", "context", "cost"]  # render order; unset defaults to model only
colors = [213, -1, 46]                   # per-position 256-color index; -1 = unstyled
separator = "  "                         # between segments (default: two spaces)
```

`colors` is matched by position to `segments`. `color` (the pre-existing top-level key) still colors the `model` segment whenever its position has no explicit `colors` entry — including the unset-`segments` default, so an existing `color`-only config keeps working unchanged. Unknown segment names are silently ignored, same as anywhere else in this project's config parsing. A segment hides itself when its underlying data is absent (e.g. `cost` before any turn has run).

Segment catalogue, `name` — source field(s) — rendered format:

- `model` — `model.display_name` — model name verbatim, e.g. `Opus 4.8`
- `context` — `context_window.used_percentage` / `total_input_tokens` / `context_window_size` — `45% (12.3k/200k)`; degrades to just the percentage or just the counts if only one half is present; hidden if both are missing
- `cost` — `cost.total_cost_usd` — `$1.42`
- `session_limit` — `rate_limits.five_hour.used_percentage` — `5h 23%`
- `weekly_limit` — `rate_limits.seven_day.used_percentage` — `7d 61%`
- `lines` — `cost.total_lines_added` / `total_lines_removed` — `+42/-7`; hidden unless both are present
- `duration` — `cost.total_duration_ms` — `45s`, `12m`, or `1h03m`
- `effort` — `effort.level` — verbatim, e.g. `high`
- `style` — `output_style.name` — verbatim; hidden when unset or `"default"`
- `version` — `version` — verbatim, e.g. `1.2.3`
- `fast` — `fast_mode` — literal `fast` when true; hidden otherwise
- `thinking` — `thinking.enabled` — literal `think` when true; hidden otherwise
- `vim` — `vim.mode` — verbatim, e.g. `NORMAL`
- `pr` — `pr.number` / `pr.review_state` — `PR#123 (approved)`, or `PR#123` without a review state
- `agent` — `agent.name` — verbatim, e.g. `reviewer`

`session_limit` and `weekly_limit` need Claude Code to have sent `rate_limits` at all: they're absent for API-key sessions, and absent early in a Claude.ai Pro/Max session until the first response comes back. Both segments simply stay hidden until then.

## Sprites

Sprites are PNG files (max 1 MB), one per tier, named `face0.png` through `face{tiers-1}.png` inside `sprite.dir`:

```
sprites/
  face0.png   # tier 0: empty context
  ...
  face4.png   # top tier: full context (tiers = 5)
```

The tier is `floor(tokens / scale_tokens * tiers)`, clamped to the top tier — so with the defaults (`tiers = 5`, `scale_tokens = 200000`) each face covers a 40k-token band. To use arbitrary paths instead of the naming convention, set an explicit list:

```toml
[sprite]
faces = ["/path/to/calm.png", "/path/to/worried.png", "/path/to/panic.png"]
```

If `faces` has fewer entries than tiers, the last entry is reused for the higher tiers. Each face is rendered in a box `box_cols` terminal cells wide, so roughly square images look best.

Then set it as your Claude Code statusline command in `~/.claude/settings.json`:

```json
{ "statusLine": { "type": "command", "command": "statusline-sprite" } }
```

## Animated sprites

A tier can animate. Make the tier a directory of numbered frames (`0.png`, `1.png`, …) instead of a single PNG. A single PNG stays static.

```toml
[sprite]
faces = ["/path/to/idle", "/path/to/busy"]   # each is a dir of 0.png, 1.png, ...
```

```
busy/
  0.png
  1.png
  2.png
```

A background daemon cycles the frames via the kitty graphics protocol, so sprites animate even on terminals that don't implement the kitty *animation* protocol. `fps` / `tier_fps` set the rate, capped by `max_fps`.

**Terminal support.** Animation is verified on Ghostty (under tmux, the primary target) and works on kitty. The older terminal-side animation escapes (`a=f` / `a=a`) are no longer used.

**The daemon.** One resident background process per pane, spawned automatically by the statusline. It auto-exits about `daemon_ttl_ms` (default 5000ms) after Claude Code stops refreshing — idle sessions stop animating and the daemon goes away; the next refresh respawns it. Closing the pane/terminal also stops it.

- Disable animation entirely with `animate = false` (renders static frame 0, no daemon).
- To kill a stuck daemon: it exits on its own within `daemon_ttl_ms`, or when its pane/terminal closes. To force it: `pkill -f 'statusline-sprite --animate'`.

---

Doom guy sprite © id Software, shown for demo purposes only — not covered by this project's MIT license.
