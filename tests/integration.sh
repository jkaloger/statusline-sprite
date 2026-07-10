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

# Count non-overlapping occurrences of a fixed pattern in a (binary) file.
count_pat() { grep -a -o -F -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' '; }

# The dir where a target's state-/anim-/heartbeat-/daemon- files live.
state_dir() { echo "$1/statusline-sprite"; }
anim_manifest() { ls "$1"/anim-* 2>/dev/null | head -n1; }
heartbeat_file() { ls "$1"/heartbeat-* 2>/dev/null | head -n1; }

# Prove a daemon is live: after the statusline has exited, only the daemon writes
# to the tty, and it emits bare `a=t` on its timer. Poll for the count to grow
# (up to ~4s). ps/pgrep are sandbox-blocked, so liveness is inferred from writes.
prove_daemon_alive() {
    local file="$1" c0 c1 i
    c0="$(count_pat "$file" 'a=t')"
    for ((i = 0; i < 40; i++)); do
        sleep 0.1
        c1="$(count_pat "$file" 'a=t')"
        [ "$c1" -gt "$c0" ] && return 0
    done
    return 1
}

# Reap a target's daemon(s): remove the manifest (the daemon's deterministic
# stop) and wait until tty writes cease (a=t count stable across one interval),
# so no daemon is left running unbounded and later byte counts are stable.
reap_daemon() {
    local state="$1" file="$2" prev cur i
    rm -f "$state"/anim-* 2>/dev/null
    prev=""
    for ((i = 0; i < 40; i++)); do
        cur="$(count_pat "$file" 'a=t')"
        [ "$cur" = "$prev" ] && return 0
        prev="$cur"
        sleep 0.25
    done
    return 0
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

echo "== case 8: animated tier via fake tmux -- static frame 0 + daemon, state-gated =="
# SPEC-007: an animated tier transmits frame 0 as the STATIC sequence (a=d/a=t/a=p,
# never a=f/a=a) and hands motion to a resident daemon that cycles frames with
# bare a=t. The daemon writes to the SAME fake tty, so byte assertions isolate the
# statusline's transmit by its a=p/a=d markers (the daemon emits neither) and take
# an immediate snapshot before the daemon can clobber frame-0 bytes. Every daemon
# is reaped between runs so none runs unbounded and later counts stay stable.
mkdir -p "$WORK/xdg8/statusline-sprite"
cat > "$WORK/xdg8/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$WORK/sprites/anim"]
EOF
TTY8="$WORK/tty8"
STATE8="$(state_dir "$WORK/state8")"
: > "$TTY8"

# Run 1 (state miss): static frame-0 transmit + manifest + heartbeat + daemon.
printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY8" HOME="$WORK/home8" XDG_CONFIG_HOME="$WORK/xdg8" XDG_STATE_HOME="$WORK/state8" > "$WORK/out8a" || fail "case 8 run 1: non-zero exit ($?)"
cp "$TTY8" "$WORK/snap8a"   # snapshot before the daemon clobbers frame-0 bytes
assert_three_lines "$WORK/out8a" "case 8 run 1"
[ -s "$TTY8" ] || fail "case 8 run 1: no graphics bytes reached the fake tty"
grep -aq 'a=d,' "$WORK/snap8a" || fail "case 8 run 1: missing a=d delete"
grep -aq 'a=t,' "$WORK/snap8a" || fail "case 8 run 1: missing a=t transmission"
grep -aq 'a=p,' "$WORK/snap8a" || fail "case 8 run 1: missing a=p placement"
grep -aq 'i=103' "$WORK/snap8a" || fail "case 8 run 1: expected image id 103 for tier 3"
# Retired kitty-animation escapes must NEVER appear (neither statusline nor daemon).
grep -aq 'a=f,' "$TTY8" && fail "case 8 run 1: a=f must never be emitted"
grep -aq 'a=a,' "$TTY8" && fail "case 8 run 1: a=a must never be emitted"
# Manifest exists with ABSOLUTE frame paths and the tier's image id.
MAN8="$(anim_manifest "$STATE8")"
[ -n "$MAN8" ] && [ -f "$MAN8" ] || fail "case 8 run 1: no manifest written"
grep -q '^frame = /' "$MAN8" || fail "case 8 run 1: manifest frame paths are not absolute"
grep -q '^image_id = 103' "$MAN8" || fail "case 8 run 1: manifest image_id is not 103"
# Heartbeat exists.
HB8="$(heartbeat_file "$STATE8")"
[ -n "$HB8" ] && [ -f "$HB8" ] || fail "case 8 run 1: no heartbeat written"
# A daemon was spawned: bare a=t keeps landing after the statusline exited.
prove_daemon_alive "$TTY8" || fail "case 8 run 1: no live daemon transmitting after statusline exit"
echo "  ok: static frame 0 (a=d/a=t/a=p, i=103, no a=f/a=a), manifest+heartbeat, live daemon"

reap_daemon "$STATE8" "$TTY8"

# Run 2 (state hit): heartbeat mtime advances, but NO new frame-0 transmit.
# a=p/a=d are emitted ONLY by the statusline, so their counts detect a transmit
# even with the daemon in the file; the snapshot is taken before run-2's daemon writes.
AP8_BEFORE="$(count_pat "$TTY8" 'a=p')"
AD8_BEFORE="$(count_pat "$TTY8" 'a=d')"
sleep 1                     # 1s so a heartbeat rewrite shows at second granularity
HB8_BEFORE="$(mtime_of "$HB8")"
printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY8" HOME="$WORK/home8" XDG_CONFIG_HOME="$WORK/xdg8" XDG_STATE_HOME="$WORK/state8" > "$WORK/out8b" || fail "case 8 run 2: non-zero exit ($?)"
cp "$TTY8" "$WORK/snap8b"   # snapshot before run-2's daemon writes
assert_three_lines "$WORK/out8b" "case 8 run 2"
AP8_AFTER="$(count_pat "$WORK/snap8b" 'a=p')"
AD8_AFTER="$(count_pat "$WORK/snap8b" 'a=d')"
[ "$AP8_AFTER" = "$AP8_BEFORE" ] || fail "case 8 run 2: state hit re-transmitted (a=p $AP8_BEFORE -> $AP8_AFTER)"
[ "$AD8_AFTER" = "$AD8_BEFORE" ] || fail "case 8 run 2: state hit re-transmitted (a=d $AD8_BEFORE -> $AD8_AFTER)"
HB8_AFTER="$(mtime_of "$HB8")"
[ "$HB8_AFTER" != "$HB8_BEFORE" ] || fail "case 8 run 2: heartbeat not touched on the state-hit path"
echo "  ok: state hit touched the heartbeat but emitted no new frame-0 transmit"

reap_daemon "$STATE8" "$TTY8"

# Run 3: tier change (0 tokens -> tier 0) re-transmits under image id 100.
printf '%s' "$LOW_JSON" | run_tmux "$TTY8" HOME="$WORK/home8" XDG_CONFIG_HOME="$WORK/xdg8" XDG_STATE_HOME="$WORK/state8" > "$WORK/out8c" || fail "case 8 run 3: non-zero exit ($?)"
cp "$TTY8" "$WORK/snap8c"
assert_three_lines "$WORK/out8c" "case 8 run 3"
grep -aq 'i=100' "$WORK/snap8c" || fail "case 8 run 3: tier change did not re-transmit under image id 100"
echo "  ok: tier change re-transmitted under the new image id"

reap_daemon "$STATE8" "$TTY8"

echo "== case 9: single-PNG tier via fake tmux -- static only, no daemon, state-gated =="
mkdir -p "$WORK/xdg9/statusline-sprite"
cat > "$WORK/xdg9/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$REPO_ROOT/test-sprites/face2.png"]
EOF
TTY9="$WORK/tty9"
STATE9="$(state_dir "$WORK/state9")"
: > "$TTY9"

printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY9" HOME="$WORK/home9" XDG_CONFIG_HOME="$WORK/xdg9" XDG_STATE_HOME="$WORK/state9" > "$WORK/out9a" || fail "case 9 run 1: non-zero exit ($?)"
assert_three_lines "$WORK/out9a" "case 9 run 1"
[ -s "$TTY9" ] || fail "case 9 run 1: no graphics bytes reached the fake tty"
grep -aq 'a=d,' "$TTY9" || fail "case 9 run 1: missing a=d delete"
grep -aq 'a=t,' "$TTY9" || fail "case 9 run 1: missing a=t transmission"
grep -aq 'a=p,' "$TTY9" || fail "case 9 run 1: missing a=p placement"
grep -aq 'a=f,' "$TTY9" && fail "case 9 run 1: single-PNG tier must not emit a=f"
grep -aq 'a=a,' "$TTY9" && fail "case 9 run 1: single-PNG tier must not emit a=a"
# Static tier: no daemon machinery at all.
[ -z "$(anim_manifest "$STATE9")" ] || fail "case 9: static tier wrote a manifest"
[ -z "$(heartbeat_file "$STATE9")" ] || fail "case 9: static tier wrote a heartbeat"
C9="$(count_pat "$TTY9" 'a=t')"
sleep 0.6
[ "$(count_pat "$TTY9" 'a=t')" = "$C9" ] || fail "case 9: a daemon is transmitting for a static tier"
echo "  ok: single-PNG tier emitted static escapes only, spawned no daemon"

sleep 1
M9_BEFORE="$(mtime_of "$TTY9")"
printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY9" HOME="$WORK/home9" XDG_CONFIG_HOME="$WORK/xdg9" XDG_STATE_HOME="$WORK/state9" > "$WORK/out9b" || fail "case 9 run 2: non-zero exit ($?)"
assert_three_lines "$WORK/out9b" "case 9 run 2"
M9_AFTER="$(mtime_of "$TTY9")"
[ "$M9_BEFORE" = "$M9_AFTER" ] || fail "case 9 run 2: static tier was re-transmitted on an unchanged refresh"
echo "  ok: second run wrote zero graphics bytes (no daemon; state gates static tiers)"

echo "== case 10: animate=false on an animated dir -- static frame 0 only, no daemon =="
mkdir -p "$WORK/xdg10/statusline-sprite"
cat > "$WORK/xdg10/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$WORK/sprites/anim"]
animate = false
EOF
TTY10="$WORK/tty10"
STATE10="$(state_dir "$WORK/state10")"
: > "$TTY10"

printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY10" HOME="$WORK/home10" XDG_CONFIG_HOME="$WORK/xdg10" XDG_STATE_HOME="$WORK/state10" > "$WORK/out10" || fail "case 10: non-zero exit ($?)"
assert_three_lines "$WORK/out10" "case 10"
[ -s "$TTY10" ] || fail "case 10: no graphics bytes reached the fake tty"
grep -aq 'a=t,' "$TTY10" || fail "case 10: missing a=t transmission"
grep -aq 'a=p,' "$TTY10" || fail "case 10: missing a=p placement"
grep -aq 'a=f,' "$TTY10" && fail "case 10: animate=false must not emit a=f"
grep -aq 'a=a,' "$TTY10" && fail "case 10: animate=false must not emit a=a"
[ -z "$(anim_manifest "$STATE10")" ] || fail "case 10: animate=false wrote a manifest"
[ -z "$(heartbeat_file "$STATE10")" ] || fail "case 10: animate=false wrote a heartbeat"
C10="$(count_pat "$TTY10" 'a=t')"
sleep 0.6
[ "$(count_pat "$TTY10" 'a=t')" = "$C10" ] || fail "case 10: a daemon is transmitting despite animate=false"
echo "  ok: animate=false rendered static frame 0, spawned no daemon"

echo "== case 11: fps=0 on an animated dir -- static frame 0 only, no daemon =="
mkdir -p "$WORK/xdg11/statusline-sprite"
cat > "$WORK/xdg11/statusline-sprite/config.toml" <<EOF
[sprite]
faces = ["$WORK/sprites/anim"]
fps = 0
EOF
TTY11="$WORK/tty11"
STATE11="$(state_dir "$WORK/state11")"
: > "$TTY11"

printf '%s' "$SAMPLE_JSON" | run_tmux "$TTY11" HOME="$WORK/home11" XDG_CONFIG_HOME="$WORK/xdg11" XDG_STATE_HOME="$WORK/state11" > "$WORK/out11" || fail "case 11: non-zero exit ($?)"
assert_three_lines "$WORK/out11" "case 11"
[ -s "$TTY11" ] || fail "case 11: no graphics bytes reached the fake tty"
grep -aq 'a=d,' "$TTY11" || fail "case 11: missing a=d delete"
grep -aq 'a=t,' "$TTY11" || fail "case 11: missing a=t transmission"
grep -aq 'a=p,' "$TTY11" || fail "case 11: missing a=p placement"
grep -aq 'i=103' "$TTY11" || fail "case 11: expected image id 103 for tier 3"
grep -aq 'a=f,' "$TTY11" && fail "case 11: fps=0 must not emit a=f"
grep -aq 'a=a,' "$TTY11" && fail "case 11: fps=0 must not emit a=a"
[ -z "$(anim_manifest "$STATE11")" ] || fail "case 11: fps=0 wrote a manifest"
[ -z "$(heartbeat_file "$STATE11")" ] || fail "case 11: fps=0 wrote a heartbeat"
C11="$(count_pat "$TTY11" 'a=t')"
sleep 0.6
[ "$(count_pat "$TTY11" 'a=t')" = "$C11" ] || fail "case 11: a daemon is transmitting despite fps=0"
echo "  ok: fps=0 rendered static frame 0, spawned no daemon"

echo "== teardown: reap any daemons; none should remain =="
# Every animated run above was reaped inline (manifest removed -> daemon exits);
# a final sweep guards against a straggler, and WORK removal on EXIT covers any
# daemon still mid-sleep (its manifest is gone, so its next tick exits).
reap_daemon "$STATE8" "$TTY8"
echo "  ok: daemons reaped via manifest removal (ps/pgrep are sandbox-blocked)"

echo "ALL INTEGRATION ASSERTIONS PASSED"
exit 0
