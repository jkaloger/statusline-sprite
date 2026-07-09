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

SAMPLE_JSON='{"session_id":"abc-123","cwd":"/tmp","model":{"id":"claude-opus-4","display_name":"Opus 4.8"},"total_input_tokens":120000,"context_window_size":200000}'
MODEL_NAME="Opus 4.8"

# Base non-kitty environment: no KITTY_WINDOW_ID, dumb TERM, no TMUX.
run_binary() {
    env -u KITTY_WINDOW_ID -u TMUX -u TERM_PROGRAM TERM=dumb "$@" "$BIN"
}

assert_three_lines() {
    local file="$1" label="$2"
    local n
    n="$(wc -l < "$file" | tr -d ' ')"
    [ "$n" -eq 3 ] || fail "$label: expected 3 lines, got $n (output: $(cat "$file" | tr '\n' '|'))"
}

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

echo "ALL INTEGRATION ASSERTIONS PASSED"
exit 0
