#!/usr/bin/env bash
# Integration test for statusline-sprite.
#
# Builds the binary and drives it end-to-end in a non-kitty environment,
# asserting the three-row contract and graceful degradation. This is the
# integration entrypoint; also wired as `zig build integration`.
#
# The binary prints exactly three lines: two internal '\n' separators plus a
# single trailing '\n', i.e. exactly three '\n' bytes. We capture output to
# files (command substitution strips trailing newlines) and count with wc -l.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BIN="$REPO_ROOT/zig-out/bin/statusline-sprite"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/statusline-sprite-it.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== building =="
zig build || fail "zig build failed"
[ -x "$BIN" ] || fail "binary not found/executable at $BIN"

SAMPLE_JSON='{"session_id":"abc-123","cwd":"/tmp","model":{"id":"claude-opus-4","display_name":"Opus 4.8"},"context_window":{"total_input_tokens":120000,"context_window_size":200000}}'
# 120000 of 200000 across 5 tiers selects tier 3 => image id 103; zero tokens
# selects tier 0 => image id 100 (see tier.selectTier and main's `100 + tier`).
LOW_JSON='{"session_id":"abc-123","cwd":"/tmp","model":{"id":"claude-opus-4","display_name":"Opus 4.8"},"context_window":{"total_input_tokens":0,"context_window_size":200000}}'
MODEL_NAME="Opus 4.8"

# Base non-kitty environment: no KITTY_WINDOW_ID, dumb TERM, no TMUX.
run_binary() {
    env -u KITTY_WINDOW_ID -u TMUX -u TERM_PROGRAM TERM=dumb "$@" "$BIN"
}

# tmux-mode environment with a fake `tmux` on PATH: the binary resolves its
# graphics target by running `tmux display -p ... '#{pane_tty}'`, and the fake
# answers with $FAKE_TTY -- so graphics escapes land in a regular file we can
# inspect. First arg is that capture file; remaining args are extra env pairs.
run_tmux() {
    local tty_file="$1"
    shift
    env -u KITTY_WINDOW_ID -u TERM_PROGRAM TERM=dumb \
        PATH="$WORK/bin:$PATH" TMUX="/tmp/fake,123,0" TMUX_PANE='%7' \
        FAKE_TTY="$tty_file" "$@" "$BIN"
}

assert_three_lines() {
    local file="$1" label="$2"
    local n
    n="$(wc -l < "$file" | tr -d ' ')"
    [ "$n" -eq 3 ] || fail "$label: expected 3 lines, got $n (output: $(cat "$file" | tr '\n' '|'))"
}

mtime_of() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

# Fixtures shared by the graphics cases: an animated face directory (three
# frames) built from the repo's test sprites, and the fake tmux shim.
mkdir -p "$WORK/sprites/anim" "$WORK/bin"
cp "$REPO_ROOT/test-sprites/face0.png" "$WORK/sprites/anim/0.png"
cp "$REPO_ROOT/test-sprites/face1.png" "$WORK/sprites/anim/1.png"
cp "$REPO_ROOT/test-sprites/face2.png" "$WORK/sprites/anim/2.png"
cat > "$WORK/bin/tmux" <<'EOF'
#!/bin/sh
echo "$FAKE_TTY"
EOF
chmod +x "$WORK/bin/tmux"

echo "== case 1: three lines + model name (non-kitty) =="
HOME1="$WORK/home1"
printf '%s' "$SAMPLE_JSON" | run_binary HOME="$HOME1" XDG_CONFIG_HOME="$WORK/xdg1" > "$WORK/out1" || fail "case 1: non-zero exit ($?)"
assert_three_lines "$WORK/out1" "case 1"
L2="$(sed -n '2p' "$WORK/out1")"
case "$L2" in
    *"$MODEL_NAME"*) : ;;
    *) fail "case 1: line 2 ('$L2') does not contain model name '$MODEL_NAME'" ;;
esac
echo "  ok: 3 lines, L2 contains '$MODEL_NAME'"

echo "== case 2: no config file present (defaults) =="
printf '%s' "$SAMPLE_JSON" | run_binary HOME="$WORK/home2" XDG_CONFIG_HOME="$WORK/xdg2" > "$WORK/out2" || fail "case 2: non-zero exit ($?)"
assert_three_lines "$WORK/out2" "case 2"
echo "  ok: 3 lines with built-in defaults"

echo "== case 3: config.toml overriding sprite.dir =="
mkdir -p "$WORK/xdg3/statusline-sprite"
cat > "$WORK/xdg3/statusline-sprite/config.toml" <<EOF
[sprite]
dir = "$WORK/nonexistent-sprites"
EOF
printf '%s' "$SAMPLE_JSON" | run_binary HOME="$WORK/home3" XDG_CONFIG_HOME="$WORK/xdg3" > "$WORK/out3" || fail "case 3: non-zero exit ($?)"
assert_three_lines "$WORK/out3" "case 3"
echo "  ok: sprite.dir override respected, still 3 lines"

echo "== case 4: empty stdin does not crash =="
printf '' | run_binary HOME="$WORK/home2" XDG_CONFIG_HOME="$WORK/xdg2" > "$WORK/out4" || fail "case 4: non-zero exit on empty stdin ($?)"
assert_three_lines "$WORK/out4" "case 4"
echo "  ok: empty stdin yields 3 lines"

echo "== case 5: kitty-capable but graphics transmit fails (tty unavailable) =="
# TERM=xterm-kitty makes detectCaps report kitty-capable, so the code reaches
# the graphics path: it reads a real face PNG (sprite.dir -> repo test-sprites)
# and then tries to open /dev/tty for writing. In this non-interactive env that
# open fails, graphics degrades to no sprite, and the three text rows still
# print. run_binary already unsets TMUX/KITTY_WINDOW_ID; env's last TERM= wins.
mkdir -p "$WORK/xdg5/statusline-sprite"
cat > "$WORK/xdg5/statusline-sprite/config.toml" <<EOF
[sprite]
dir = "$REPO_ROOT/test-sprites"
EOF
printf '%s' "$SAMPLE_JSON" | run_binary TERM=xterm-kitty HOME="$WORK/home5" XDG_CONFIG_HOME="$WORK/xdg5" > "$WORK/out5" || fail "case 5: non-zero exit ($?)"
assert_three_lines "$WORK/out5" "case 5"
echo "  ok: kitty-capable + tty write fails, degrades to 3 lines"

echo "== case 6: animated face directory in a non-graphics env still prints 3 rows =="
mkdir -p "$WORK/xdg6/statusline-sprite"
cat > "$WORK/xdg6/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$WORK/sprites/anim"]
EOF
printf '%s' "$SAMPLE_JSON" | run_binary HOME="$WORK/home6" XDG_CONFIG_HOME="$WORK/xdg6" > "$WORK/out6" || fail "case 6: non-zero exit ($?)"
assert_three_lines "$WORK/out6" "case 6"
echo "  ok: animated dir + non-graphics env yields 3 lines"

echo "== case 7: empty face directory degrades to 3 rows =="
mkdir -p "$WORK/sprites/empty" "$WORK/xdg7/statusline-sprite"
cat > "$WORK/xdg7/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$WORK/sprites/empty"]
EOF
printf '%s' "$SAMPLE_JSON" | run_binary TERM=xterm-kitty HOME="$WORK/home7" XDG_CONFIG_HOME="$WORK/xdg7" > "$WORK/out7" || fail "case 7: non-zero exit ($?)"
assert_three_lines "$WORK/out7" "case 7"
echo "  ok: empty face dir yields 3 lines, no sprite"

echo "== case 8: animated tier via fake tmux tty -- transmit once, then state-gated =="
mkdir -p "$WORK/xdg8/statusline-sprite"
cat > "$WORK/xdg8/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$WORK/sprites/anim"]
EOF
TTY8="$WORK/tty8"
: > "$TTY8"

# Run 1: full animated transmission must land on the graphics target.
printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY8" HOME="$WORK/home8" XDG_CONFIG_HOME="$WORK/xdg8" XDG_STATE_HOME="$WORK/state8" > "$WORK/out8a" || fail "case 8 run 1: non-zero exit ($?)"
assert_three_lines "$WORK/out8a" "case 8 run 1"
[ -s "$TTY8" ] || fail "case 8 run 1: no graphics bytes reached the fake tty"
grep -aq 'a=t,' "$TTY8" || fail "case 8 run 1: missing a=t root transmission"
grep -aq 'a=f,' "$TTY8" || fail "case 8 run 1: missing a=f frame transmission"
grep -aq 'a=a,' "$TTY8" || fail "case 8 run 1: missing a=a animation control"
grep -aq 'i=103' "$TTY8" || fail "case 8 run 1: expected image id 103 for tier 3"
echo "  ok: first run transmitted animation escapes (a=t/a=f/a=a, i=103)"

# Run 2: unchanged inputs must write ZERO graphics bytes (state hit). The
# 1s sleep makes any rewrite visible in the file's second-granularity mtime.
sleep 1
M8_BEFORE="$(mtime_of "$TTY8")"
printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY8" HOME="$WORK/home8" XDG_CONFIG_HOME="$WORK/xdg8" XDG_STATE_HOME="$WORK/state8" > "$WORK/out8b" || fail "case 8 run 2: non-zero exit ($?)"
assert_three_lines "$WORK/out8b" "case 8 run 2"
M8_AFTER="$(mtime_of "$TTY8")"
[ "$M8_BEFORE" = "$M8_AFTER" ] || fail "case 8 run 2: graphics target was rewritten on an unchanged refresh"
echo "  ok: second run wrote zero graphics bytes (state hit)"

# Run 3: tier change (0 tokens -> tier 0) must re-transmit under image id 100.
printf '%s' "$LOW_JSON" | run_tmux "$TTY8" HOME="$WORK/home8" XDG_CONFIG_HOME="$WORK/xdg8" XDG_STATE_HOME="$WORK/state8" > "$WORK/out8c" || fail "case 8 run 3: non-zero exit ($?)"
assert_three_lines "$WORK/out8c" "case 8 run 3"
grep -aq 'i=100' "$TTY8" || fail "case 8 run 3: tier change did not re-transmit under image id 100"
echo "  ok: tier change re-transmitted under the new image id"

echo "== case 9: single-PNG tier via fake tmux tty -- static escapes only, state-gated =="
mkdir -p "$WORK/xdg9/statusline-sprite"
cat > "$WORK/xdg9/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$REPO_ROOT/test-sprites/face2.png"]
EOF
TTY9="$WORK/tty9"
: > "$TTY9"

printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY9" HOME="$WORK/home9" XDG_CONFIG_HOME="$WORK/xdg9" XDG_STATE_HOME="$WORK/state9" > "$WORK/out9a" || fail "case 9 run 1: non-zero exit ($?)"
assert_three_lines "$WORK/out9a" "case 9 run 1"
[ -s "$TTY9" ] || fail "case 9 run 1: no graphics bytes reached the fake tty"
grep -aq 'a=t,' "$TTY9" || fail "case 9 run 1: missing a=t transmission"
grep -aq 'a=p,' "$TTY9" || fail "case 9 run 1: missing a=p placement"
grep -aq 'a=f,' "$TTY9" && fail "case 9 run 1: single-PNG tier must not emit a=f"
grep -aq 'a=a,' "$TTY9" && fail "case 9 run 1: single-PNG tier must not emit a=a"
echo "  ok: single-PNG tier emitted static escapes only"

sleep 1
M9_BEFORE="$(mtime_of "$TTY9")"
printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY9" HOME="$WORK/home9" XDG_CONFIG_HOME="$WORK/xdg9" XDG_STATE_HOME="$WORK/state9" > "$WORK/out9b" || fail "case 9 run 2: non-zero exit ($?)"
assert_three_lines "$WORK/out9b" "case 9 run 2"
M9_AFTER="$(mtime_of "$TTY9")"
[ "$M9_BEFORE" = "$M9_AFTER" ] || fail "case 9 run 2: static tier was re-transmitted on an unchanged refresh"
echo "  ok: second run wrote zero graphics bytes (state gates static tiers too)"

echo "ALL INTEGRATION ASSERTIONS PASSED"
exit 0
