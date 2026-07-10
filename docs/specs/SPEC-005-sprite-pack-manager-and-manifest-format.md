---
title: sprite pack manager and manifest format
type: spec
status: draft
author: Jack Kaloger
date: 2026-07-10
tags: []
related:
- related-to: SPEC-001
---
<!-- intent: specify a sprite pack format (pack.toml + PNGs) and CLI subcommands to install, list, preview, and remove packs. -->

# Sprite pack manager and manifest format

Shareable sprite packs for statusline-sprite. A pack is a directory — distributed
as a git repo — containing a `pack.toml` manifest plus face PNGs. The existing
binary grows argv subcommands to install, list, preview, and remove packs, and
config gains `sprite.pack = "<name>"` to select an installed pack by name.

## Overview

Today faces resolve from raw paths: `sprite.faces` (explicit list) or
`sprite.dir` + the `face<N>.png` convention (`config.deriveFaces`). Sharing a
sprite set means copying files around and hand-editing paths. Packs fix that:
one `install` command pulls a repo into a registry directory, one config line
selects it. Raw `dir`/`faces` paths remain fully supported.

Packs are data only: a manifest and PNGs. Nothing in a pack is ever executed.

## CLI dispatch

The binary is statusline-invoked with JSON on stdin and no argv. Subcommands
coexist by argv presence:

- **No args** → statusline mode, exactly as today. Claude Code's invocation is
  untouched; stdin JSON path unchanged.
- **First arg = subcommand** → pack-manager mode. Stdin is never read.

```
statusline-sprite install <source> [--force]
statusline-sprite list
statusline-sprite preview <pack>
statusline-sprite remove <pack>
statusline-sprite help
```

Unknown subcommand → usage to stderr, exit 2. Subcommand errors → message to
stderr, exit 1. Success output to stdout. Statusline mode keeps its "never
fail" contract; subcommand mode is a normal CLI and may exit non-zero.

## Pack registry directory

Packs live under the XDG data dir, mirroring the existing config-path logic
(`config.resolveConfigPath`):

- `$XDG_DATA_HOME/statusline-sprite/packs/<name>` when `XDG_DATA_HOME` is set
  and non-empty,
- else `$HOME/.local/share/statusline-sprite/packs/<name>`.

`<name>` comes from the manifest's `name` field, not the repo name. Names are
restricted to `[a-z0-9._-]`, must not start with `.`, max 64 bytes — rules out
path traversal and hidden-dir tricks by construction.

## Manifest format: `pack.toml`

Lives at the pack root. Parsed with the same line-oriented TOML subset as
`config.zig` (tables, quoted strings, integers, single-line string arrays);
unknown tables/keys ignored, so future fields don't break old binaries.

```toml
[pack]
name = "doomguy"                    # required; registry dir name
description = "DOOM status face"    # optional
author = "id Software fan"          # optional
license = "CC-BY-4.0"               # optional but list warns when absent
attribution = "Sprites by ..."      # optional; shown by list/preview

[sprite]
tiers = 5                           # required; >= 1
faces = ["ouch0.png", "ouch1.png",  # optional; relative paths, one per tier
         "ouch2.png", "ouch3.png", "ouch4.png"]
fps = 8                             # optional; reserved for SPEC-002 animation
frames = 4                          # optional; reserved for SPEC-002 animation
```

- **Face resolution.** When `faces` is present it must have exactly `tiers`
  entries. When absent, the `face<N>.png` naming convention applies (same
  convention as `config.deriveFaces`), N in `0..tiers-1`, relative to the pack
  root.
- **Path safety.** Face entries must be relative, no `..` components, no
  leading `/`. Violations fail validation.
- **Animation forward-compat.** `fps`/`frames` are parsed and stored but unused
  in this spec; SPEC-002 defines their semantics (frame files
  `face<N>-<F>.png`). Validation here checks only that they are positive
  integers when present.

## Manifest validation

Runs at install time (hard gate) and lazily at render/preview time (soft):

- `pack.name` present and well-formed (charset rule above).
- `sprite.tiers >= 1`; `faces` length equals `tiers` when explicit.
- Every resolved face file exists in the pack.
- Every face file is ≤ 1 MB — matches the existing `readFileAlloc`
  `.limited(1 << 20)` cap in `main.readFace`, so nothing installable is later
  unloadable.
- Every face file starts with the 8-byte PNG signature
  (`89 50 4E 47 0D 0A 1A 0A`). Cheap; no decode.

Install-time failure: report every violation, delete the partial install, exit
1. Render-time failure (pack edited/broken after install): degrade to no
sprite, per the SPEC-001 degradation contract.

## Install

`statusline-sprite install github:user/repo` or a full git URL.

**Source resolution.** `github:user/repo` expands to
`https://github.com/user/repo.git`. Otherwise the source must match an
allow-listed scheme: `https://`, `ssh://`, `git@host:path`, or `file://`
(local path form also accepted — enables offline tests). Anything else is
rejected before git ever sees it: git's exotic transports (`ext::` in
particular) can execute arbitrary commands, so the allow-list is a security
boundary, not a convenience.

**Fetch = `git clone --depth 1` subprocess**, not a tarball download. Chosen
because:

- The binary gains no HTTP/TLS stack; a tarball fetch means bundling TLS +
  gzip + tar in Zig or shelling to `curl | tar`, two external tools instead of
  one.
- Works against any git host (GitHub, GitLab, sourcehut, private, `file://`),
  not just GitHub's tarball API.
- The binary already shells out (L1/L3 rows, tmux queries); a git subprocess
  fits the existing pattern. `git` is a safe prerequisite on any machine
  running Claude Code.

Subprocess rules: spawn `git` directly with an argv array — the URL is never
interpolated through `sh -c` (injection). Set `GIT_TERMINAL_PROMPT=0` so
private/nonexistent repos fail fast instead of hanging on a credential prompt.
No 1s timeout (that's the row-command contract, not this one); a generous
clone timeout (60s) guards against dead networks.

Install sequence:

1. Clone into a temp dir under `packs/` (e.g. `packs/.staging-<pid>`), depth 1,
   single branch.
2. Parse + validate `pack.toml` in the staging dir.
3. Delete `.git` — installed packs are immutable snapshots; no git state, no
   hooks, nothing executable retained. (Clone itself runs no hooks from the
   remote: hooks are not transferred by git.)
4. Rename staging dir to `packs/<name>` (atomic on same filesystem).
5. Print name, description, tier count, install path.

**Collisions:** if `packs/<name>` exists, fail with a message naming the
existing pack; `--force` removes it first. The manifest name decides the
directory, so two repos claiming `name = "doomguy"` collide loudly rather than
silently shadowing.

**Failure cleanup:** any error after step 1 removes the staging dir.

**Offline:** install is the only networked operation and fails with git's
error surfaced. `list`, `preview`, `remove`, and statusline mode never touch
the network.

## List

Scan `packs/`, parse each `pack.toml`, print one block per pack: name,
description, author, license (or `license: UNSPECIFIED` warning), tiers,
attribution. Directories with a missing/broken manifest are listed as
`<dir> (invalid: <reason>)` rather than hidden. Empty registry → friendly
"no packs installed" line, exit 0.

## Preview

`preview <pack>` resolves the pack (registry lookup + soft validation), then
renders every tier to the current terminal via the existing kitty pipeline:
`kitty.delete` + `kitty.transmit` + `kitty.virtualPlacement` +
`kitty.placeholderGrid` per tier, written to `/dev/tty` (tmux passthrough via
`kitty.wrapTmux` when detected — same `detectCaps` logic as statusline mode).
Each tier prints its placeholder grid beside a `tier N: <file>` label. Image
ids reuse the `100 + tier` scheme; preview runs standalone so no clash with a
live statusline matters, and ids stay ≤ 255 for the 256-color placeholder
encoding.

Non-kitty-capable terminal: print metadata + face file list and a note that
graphics were skipped; exit 0. Missing pack: exit 1.

## Remove

`remove <pack>` validates the name (same charset rule — no traversal), checks
`packs/<name>` exists, recursively deletes it. Not found → error, exit 1. No
confirmation prompt; the command is explicit enough.

## Configuration integration

New key in the existing `[sprite]` table:

```toml
[sprite]
pack = "doomguy"
```

Face-source precedence in statusline mode:

1. `sprite.faces` — explicit paths, wins as today.
2. `sprite.pack` — registry lookup; the pack manifest supplies tiers and face
   paths. Manifest is authoritative for asset layout: config `sprite.tiers`
   and `sprite.dir` are ignored while a pack resolves. `scale_tokens`,
   `box_cols`, and all line config stay user-controlled.
3. `sprite.dir` — the current convention-based fallback.

If the named pack is missing or its manifest fails soft validation, fall
through to no sprite (not to `dir`) — a half-configured pack should look
broken, not silently swap sprites — and the three text rows still print.
Statusline mode never exits non-zero over pack problems.

## Non-goals (v1)

- No `update` subcommand — update = `remove` + `install` (or `install
  --force`). Follows from stripping `.git`.
- No central pack index, search, or discovery.
- No version/ref pinning, checksums, or signature verification.
- No pack-authoring scaffold (`init` command).
- No animation playback — SPEC-002 owns `fps`/`frames` semantics; this spec
  only reserves and validates the fields.
- No interaction with per-repo packs (SPEC-003) beyond sharing the manifest
  format.

## Resolved decisions

- **Clone over tarball:** `git clone --depth 1` subprocess. No TLS/tar code in
  the binary, any git host works, subprocess pattern already exists. See
  Install.
- **Strip `.git` after clone:** installed packs are immutable data snapshots.
  Removes all executable surface and git state; costs only the future `update`
  fast-path, which is out of scope anyway.
- **Manifest name owns the directory:** collisions are explicit errors,
  resolved by `--force`. Repo name is irrelevant to identity.
- **Scheme allow-list before git:** `https://`, `ssh://`, `git@…`, `file://`,
  local path. Blocks `ext::`-style command-executing transports.
- **Pack beats `dir`, loses to `faces`:** explicit paths stay the ultimate
  override; a broken pack degrades to no sprite rather than falling back to
  `dir`.
- **Manifest parser reuses the config.zig TOML subset:** one parser dialect in
  the codebase; unknown keys ignored for forward compatibility.

## Open questions

- **Ref pinning syntax.** Allow `github:user/repo@<tag-or-branch>` (mapping to
  `git clone --branch <ref>`)? Cheap to add; deferred until someone needs a
  pinned pack.
- **Config `tiers` vs manifest `tiers`.** Currently manifest wins outright when
  a pack is selected. Should a user be able to under-drive a 10-tier pack with
  `tiers = 5`? Leaning no (mapping semantics get murky), but preview feedback
  may change this.
- **Registry-relative `dir`.** Should `sprite.dir` also accept a bare pack
  name for users who want convention naming without a manifest? Deferred;
  keeps `dir` semantics untouched.

## Task breakdown

Each task is TDD (failing test first). Pure logic (dispatch parsing, source
resolution, manifest parse/validation, path resolution) is unit-tested in
`test` blocks under `zig build test`; install/list/remove/preview flows are
covered by integration tests running the built binary against `file://` repos
created in a temp dir — fully offline.

- **T1 — argv dispatch (`main.zig` + `cli.zig`).** Pure
  `parseArgs(argv) → Mode` (statusline | install | list | preview | remove |
  help | usage-error) with option handling (`--force`). `main` routes on it;
  no-args path is byte-identical to today. AC: no args → statusline mode
  (integration: stdin JSON still yields three rows); `list` never reads stdin;
  unknown subcommand → usage on stderr, exit 2.

- **T2 — Data-dir & registry resolution (`pack.zig`).**
  `resolveDataDir(xdg_data_home, home)` mirroring `config.resolveConfigPath`;
  `packDir(name)`; pack-name validation (charset, length, no leading dot). AC:
  `XDG_DATA_HOME` honoured; `$HOME/.local/share` fallback; `../evil`, `.hidden`,
  `a/b` names rejected.

- **T3 — Manifest parse (`pack.zig`).** Parse `pack.toml` via the config.zig
  TOML subset into a `Manifest` struct: name, description, author, license,
  attribution, tiers, faces, fps, frames. Unknown keys ignored. AC: full
  manifest round-trips; minimal manifest (`name` + `tiers`) parses with nulls;
  missing `name` or `tiers` → error; `fps`/`frames` captured when present.

- **T4 — Manifest + asset validation (`pack.zig`).**
  `validate(manifest, pack_dir)`: faces length matches tiers; convention
  derivation when `faces` absent; path-safety on entries; per-file existence,
  ≤ 1 MB size, PNG signature. Collects all violations, not just the first. AC:
  valid fixture pack passes; missing face, oversized file, non-PNG bytes,
  `../escape.png`, absolute path each produce a named violation.

- **T5 — Source resolution (`pack.zig`).** `resolveSource(spec) → git URL`:
  `github:user/repo` expansion; https/ssh/scp-style/file/local-path
  passthrough; everything else rejected. AC: `github:a/b` →
  `https://github.com/a/b.git`; `ext::sh -c id` and `http://` rejected;
  `file:///tmp/x` and `/tmp/x` accepted.

- **T6 — Install flow (`pack.zig` + `main.zig`).** Staging-dir clone via git
  argv subprocess (`GIT_TERMINAL_PROMPT=0`, 60s timeout), validate, strip
  `.git`, atomic rename, cleanup on failure; collision + `--force` handling.
  AC (integration, `file://` fixture repos): valid pack installs to
  `packs/<name>` with no `.git`; invalid pack leaves no residue and exits 1;
  reinstall without `--force` fails naming the collision; with `--force`
  replaces; clone of a nonexistent path exits 1 with git's error surfaced.

- **T7 — `list` and `remove` (`main.zig` + `pack.zig`).** Registry scan with
  per-pack metadata, invalid-manifest annotation, empty-registry message;
  remove with name validation. AC (integration): two installed packs list with
  name/description/license/tiers; a broken-manifest dir shows as invalid;
  `remove` deletes exactly `packs/<name>`; removing an unknown pack exits 1.

- **T8 — `preview` (`main.zig`).** Per-tier render via existing
  `kitty.transmit`/`virtualPlacement`/`placeholderGrid`/`wrapTmux` to
  `/dev/tty`, labels per tier; text-only fallback on non-capable terminals.
  AC: capable-terminal path emits one transmit+placement per tier with ids
  `100..100+tiers-1` (unit-test the escape assembly); non-capable path prints
  metadata + face list, exit 0; unknown pack exits 1.

- **T9 — Config integration (`config.zig` + `main.zig`).** Parse
  `sprite.pack`; face resolution honours faces > pack > dir; pack path feeds
  `readFace` with manifest-derived tiers; missing/invalid pack → no sprite,
  rows still print. AC: config with `pack = "x"` and installed pack `x`
  renders that pack's face for the computed tier (integration); `faces` set
  alongside `pack` → `faces` wins; `pack` naming an uninstalled pack → three
  bare rows, exit 0.

## Acceptance criteria

- `statusline-sprite` with no args behaves exactly as before this spec.
- `install github:user/repo` (network) or `install file:///path/repo`
  (offline) places a validated pack at
  `~/.local/share/statusline-sprite/packs/<name>` with no `.git` directory.
- Installing a pack whose manifest or assets fail validation leaves the
  registry untouched and reports every violation.
- Installing over an existing name fails without `--force`, succeeds with it.
- `list` shows installed packs with manifest metadata and flags broken packs.
- `preview <pack>` renders each tier's face via the kitty protocol in a
  capable terminal and degrades to a text listing elsewhere.
- `remove <pack>` deletes only that pack's directory.
- `[sprite] pack = "<name>"` in config drives statusline faces from the
  installed pack; raw `dir`/`faces` configs keep working; a missing pack
  degrades to text-only rows, never a crash.
- No file from a pack is ever executed; install rejects non-allow-listed git
  transports.
