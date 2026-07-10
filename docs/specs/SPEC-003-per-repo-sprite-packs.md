---
title: per-repo sprite packs
type: spec
status: draft
author: Jack Kaloger
date: 2026-07-10
tags: []
related:
- related-to: SPEC-001
- related-to: SPEC-005
---
# Per-repo sprite packs

Select a sprite config per repository, so different projects show different
sprites. Builds on SPEC-001.

## Overview

Claude Code's statusline JSON carries `cwd` and `workspace.project_dir`. Use
`workspace.project_dir` (falling back to `cwd`) as the repo identity and
resolve an effective `[sprite]` config for it. Resolution layers, highest
precedence first:

1. **Repo-local override** — `.statusline-sprite.toml` in the project root.
   Only its `[sprite]` section is honoured.
2. **Pack map** — `[packs]` table in the global config, mapping path globs to
   sprite dirs or pack names.
3. **Global default** — the existing global `[sprite]` (which itself merges
   over built-in defaults).

Layers merge per-key: a layer overrides only the `[sprite]` keys it sets;
unset keys fall through to the next layer. A repo-local file setting only
`dir` still inherits `tiers`/`scale_tokens`/`box_cols` from the matched pack
or global config. Everything outside `[sprite]` — `line1`/`line3` commands,
`line2` color — always comes from the global config; per-repo sources never
touch it.

All per-repo resolution is best-effort: missing project dir, unreadable
repo-local file, non-matching globs, or a pack dir that doesn't exist all
fall through silently to the next layer. The binary never fails because of
per-repo config.

## Repo identity from stdin JSON

`statusline.zig` currently extracts model + context-window fields only. Add:

- `cwd: ?[]const u8` — top-level `cwd`.
- `project_dir: ?[]const u8` — nested `workspace.project_dir`.

Both optional; missing fields yield null, not errors (same contract as the
token fields). Repo dir for resolution = `project_dir` orelse `cwd`. Both
null → skip layers 1 and 2 entirely.

## Repo-local override: `.statusline-sprite.toml`

Read `<project_dir>/.statusline-sprite.toml` via the existing line-oriented
TOML parser. Honour only `[sprite]` keys: `dir`, `faces`, `tiers`,
`scale_tokens`, `box_cols`. Every other table and key is ignored.

**Security.** Cloned repos are untrusted. Repo-local config must never cause
command execution — `[line1].command` / `[line3].command` are explicitly
discarded, not merely unsupported: the repo-local loader whitelists `[sprite]`
rather than reusing the full `applyKey`. The only effect a hostile repo can
have is pointing `sprite.dir`/`faces` at a file path; reads stay size-capped
(existing 1 MiB `readFileAlloc` limit) and the worst case is a garbage image
or no sprite.

**Paths.** Relative `dir`/`faces` paths resolve against the project root, so
a repo can ship its sprites in-tree (e.g. `dir = ".sprites"`). Absolute and
`~/`-prefixed paths also work.

## Pack map: `[packs]` in the global config

New global-config table mapping path globs (quoted keys) to values:

```toml
[packs]
"~/work/*" = "corporate"
"~/oss/zig-*" = "doomguy"
"/data/repos/legacy" = "~/sprites/legacy-pack"
```

- **Value is a dir path** when it contains `/` or starts with `~` or `.`;
  it becomes the effective `sprite.dir` (tilde-expanded).
- **Value is a pack name** otherwise; it resolves to
  `$XDG_DATA_HOME/statusline-sprite/packs/<name>` (else
  `~/.local/share/statusline-sprite/packs/<name>`). SPEC-005 (pack manager)
  will install into that layout; until then a manually created dir at that
  path works — this spec stays functional with plain dirs and takes no
  dependency on SPEC-005.
- If the resolved dir does not exist, the pack layer contributes nothing and
  resolution falls through to global.
- Optional `pack.toml` inside the resolved dir may carry a `[sprite]` section
  (`faces`, `tiers`, `scale_tokens`, `box_cols`; `dir` ignored — implied) so a
  pack with three faces can declare `tiers = 3`. Absent `pack.toml` → faces
  derived as `<dir>/face<N>.png` via existing `deriveFaces` with inherited
  tier count.

The current parser drops quoted keys (`parseString` handles values only), so
`[packs]` parsing must accept quoted keys and preserve **file order** into an
ordered pattern list on `Config` (e.g. `packs: []const Pack` where
`Pack = struct { pattern: []const u8, value: []const u8 }`).

## Glob matching rules

- `*` matches any run of characters, **including** `/` — `"~/work/*"`
  matches `~/work/client/repo`, not just direct children. No `**`, no `?`,
  no character classes.
- Patterns and the repo dir are tilde-expanded before matching (leading `~/`
  or bare `~` → `$HOME`; `~user` unsupported). Matching is byte-wise and
  case-sensitive; no path canonicalisation beyond tilde expansion.
- A pattern with no wildcard must match the whole path exactly.
- **Most-specific wins:** among matching patterns, the longest pattern (byte
  length, post-expansion) wins; ties break by file order. So
  `"~/work/special" = "doomguy"` beats `"~/work/*" = "corporate"` regardless
  of declaration order.

## Configuration

Global config gains one table:

- `[packs]` — quoted-glob → dir-or-pack-name map (above).

Repo root may contain:

- `.statusline-sprite.toml` — `[sprite]` section only.

Pack dir may contain:

- `pack.toml` — `[sprite]` section only, `dir` ignored.

No new keys in the existing `[sprite]`/`[lineN]` tables. No config → existing
behaviour, unchanged.

## Non-goals

- No `**`/`?`/class glob syntax; no regex.
- No per-repo `lineN` commands or `line2` color — per-repo sources set sprite
  fields only.
- No pack fetching, installing, listing, or naming registry — that is
  SPEC-005; this spec only defines the path a pack name resolves to.
- No config caching or file watching; resolution runs fresh per invocation
  like everything else.

## Resolved decisions

- **Repo identity:** `workspace.project_dir` orelse `cwd`, verbatim from the
  stdin JSON. No git-root discovery of our own.
- **Match rule:** longest matching pattern wins, ties by file order
  (documented above). Chosen over pure first-match so config order can't
  silently shadow a specific override with a broad glob.
- **Merge model:** per-key layering (defaults ← global `[sprite]` ← pack ←
  repo-local), consistent with the existing partial-TOML-over-defaults merge.
- **Repo-local trust boundary:** repo-local and pack config are read through a
  `[sprite]`-only whitelist loader; command/color keys are unreachable from
  those sources by construction.
- **Failure contract:** every per-repo step is non-fatal; any failure falls
  through one layer. Matches SPEC-001's degradation stance.
- **`*` crosses `/`:** repos nest (`~/work/client/repo`); segment-bounded `*`
  would force users to enumerate depth. Single simple rule instead.

## Open questions

- **Repo-local opt-out.** Should a global key (e.g. `[packs] repo_local =
  false`) let paranoid users disable reading `.statusline-sprite.toml` from
  repos entirely? Leaning yes but deferring until someone asks; the read-only
  whitelist keeps the risk to "wrong image".
- **Pack theming scope.** Should `pack.toml` eventually carry `line2.color`
  so a pack themes the model-name colour to match its sprite? Excluded for
  now (per-repo sources set sprite fields only) — revisit with SPEC-005.

## Task breakdown

Each task is TDD (failing test first) and dispatched to a subagent. Pure
logic (parsing, globbing, layering) unit-tested in `test` blocks; end-to-end
behaviour via the integration test that runs the built binary. `zig build
test` runs everything.

- **T1 — Statusline repo fields (`statusline.zig`).** Extract top-level `cwd`
  and nested `workspace.project_dir` as optionals. AC: sample JSON with both
  fields populates them; JSON without `workspace` or `cwd` yields nulls;
  existing tests unchanged.

- **T2 — `[packs]` parsing (`config.zig`).** Accept quoted keys in the
  `[packs]` table; collect into an ordered `packs` list on `Config`
  preserving file order. Unknown tables/keys still ignored. AC: three-entry
  `[packs]` parses in order with patterns and values intact; empty/absent
  `[packs]` → empty list; quoted keys elsewhere don't break existing tables.

- **T3 — Glob match + tilde expansion (pure fns, `config.zig` or new
  `packmatch.zig`).** `expandTilde(alloc, path, home)` and
  `globMatch(pattern, path)` with `*` crossing `/`; `selectPack(packs, dir,
  home)` applying longest-wins, tie = file order. AC: literal pattern needs
  exact match; `~/work/*` matches nested dirs under `$HOME/work`; longer
  pattern beats shorter regardless of order; equal lengths → first in file;
  no match → null.

- **T4 — Pack value resolution.** Classify value as dir path (`/`, `~`, `.`)
  vs pack name; pack name → `$XDG_DATA_HOME/statusline-sprite/packs/<name>`
  else `~/.local/share/...`. Pure resolver, testable like
  `resolveConfigPath`. Nonexistent resolved dir → null (fall through). If
  `<dir>/pack.toml` exists, parse its `[sprite]` via the whitelist loader
  with `dir` ignored. AC: `"corporate"` resolves under XDG data dir;
  `"~/sprites/x"` expands as a dir path; missing dir returns null; pack.toml
  `tiers` override picked up, its `dir` ignored.

- **T5 — Repo-local whitelist loader.** `loadRepoSprite(alloc, io,
  project_dir)` reads `<project_dir>/.statusline-sprite.toml`, applies only
  `[sprite]` keys, resolves relative `dir`/`faces` against `project_dir`.
  Returns a partial-sprite struct (all fields optional) or null. AC: file
  with `[sprite]` + `[line1] command` yields sprite fields and **no**
  command anywhere; relative `dir = ".sprites"` becomes
  `<project_dir>/.sprites`; missing file → null; oversized file → null.

- **T6 — Layered resolution.** `resolveSprite(alloc, io, cfg, project_dir,
  environ)` composing T3–T5: start from `cfg.sprite`, overlay matched pack
  (dir + pack.toml), overlay repo-local; per-key. AC: repo-local `dir` +
  pack `tiers` + global `scale_tokens` all coexist in the result; no
  project dir → global sprite unchanged; pack match with missing dir falls
  through to global.

- **T7 — Main wiring + integration (`main.zig`).** Feed
  `project_dir`/`cwd` from parsed stdin JSON into `resolveSprite`; use the
  effective sprite for tier/face/grid. AC (integration, runs the built
  binary): stdin JSON whose `workspace.project_dir` contains a
  `.statusline-sprite.toml` pointing at an alternate sprite dir renders from
  that dir; same JSON with a global `[packs]` glob match and no repo-local
  file uses the pack dir; no per-repo config → output identical to today;
  repo-local file containing `[line1] command` executes nothing.

## Acceptance criteria

- A repo with `.statusline-sprite.toml` setting `[sprite] dir` shows that
  sprite; another repo without it shows the global default, same binary,
  same global config.
- A `[packs]` glob mapping the repo's `project_dir` to a dir or pack name
  selects that pack when no repo-local file exists.
- Repo-local overrides beat pack matches beat global `[sprite]`, per key.
- The most specific (longest) matching glob wins over a broader one
  regardless of order in the config file.
- `~` in patterns and pack values expands against `$HOME`.
- No command or color key from a repo-local file or pack.toml is ever
  honoured; a hostile repo config can affect at most which image file is
  read.
- Every per-repo resolution failure degrades to the next layer; the three
  text rows always print.
