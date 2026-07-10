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

Copy `config.example.toml` to `~/.config/statusline-sprite/config.toml` and point `sprite.dir` at a directory of tiered sprite PNGs. Each `[lineN]` section sets a shell command or color for that statusline row.

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
