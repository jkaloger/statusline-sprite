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
