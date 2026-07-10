#!/usr/bin/env bash
# Daemon spawn/detach/singleton integration harness for SPEC-007 T1.
#
# Drives the built binary's hidden --animate and --ensure-daemon modes as real
# processes and asserts the T1 acceptance criteria on process liveness and fd
# inheritance. Also wired as `zig build daemon`.
#
# Liveness is probed with `kill -0` (alive/gone) rather than `ps`, which is
# BLOCKED in the sandbox ("operation not permitted"). Daemons stop
# deterministically when their manifest file is removed (the T1 alive-loop's
# exit condition); the harness also kills any pid it spawned on teardown so no
# orphan survives.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BIN="$REPO_ROOT/zig-out/bin/statusline-sprite"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/statusline-sprite-daemon.XXXXXX")"

# pids we spawn; killed on exit so nothing is orphaned.
SPAWNED=()

cleanup() {
    for p in "${SPAWNED[@]:-}"; do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

alive() { kill -0 "$1" 2>/dev/null; }

# Wait until `kill -0 $1` fails, up to $2 tenths of a second. Returns 0 if the
# pid is gone within the deadline, 1 otherwise.
wait_gone() {
    local pid="$1" tenths="$2" i
    for ((i = 0; i < tenths; i++)); do
        alive "$pid" || return 0
        sleep 0.1
    done
    return 1
}

echo "== building =="
zig build || fail "zig build failed"
[ -x "$BIN" ] || fail "binary not found/executable at $BIN"

# A per-test manifest lives at <dir>/anim-<key>; the daemon derives its lock as
# <dir>/daemon-<key>.lock, its heartbeat as <dir>/heartbeat-<key>, and its shared
# state lock as <dir>/state-<key>, all from that path.
hb_path() {  # manifest -> sibling heartbeat path (anim-<x> -> heartbeat-<x>)
    local man="$1"
    printf '%s/heartbeat-%s' "$(dirname "$man")" "$(basename "$man" | sed 's/^anim-//')"
}
touch_hb() { : > "$(hb_path "$1")"; }  # bump the heartbeat so the daemon stays alive

new_manifest() {
    local key="$1"
    local dir="$WORK/$key"
    mkdir -p "$dir"
    local man="$dir/anim-$key"
    printf 'placeholder\n' > "$man"
    touch_hb "$man"   # T5: without a fresh heartbeat the daemon TTL-exits
    echo "$man"
}

echo "== AC1: launching --animate twice for one target yields exactly ONE live daemon =="
MAN1="$(new_manifest 000000000000aaaa)"
"$BIN" --animate "$MAN1" & P1=$!; SPAWNED+=("$P1")
"$BIN" --animate "$MAN1" & P2=$!; SPAWNED+=("$P2")
# Give the loser time to hit lock contention and exit.
sleep 1
n=0
alive "$P1" && n=$((n + 1))
alive "$P2" && n=$((n + 1))
[ "$n" -eq 1 ] || fail "AC1: expected exactly 1 live daemon, got $n (P1=$P1 P2=$P2)"
echo "  ok: exactly one daemon survived the singleton race"
# Stop the survivor deterministically.
rm -f "$MAN1"
wait_gone "$P1" 20 && wait_gone "$P2" 20 || fail "AC1: daemon did not exit on manifest removal"
echo "  ok: survivor exited on manifest removal"

echo "== AC4+AC2: ensure-daemon detaches (no parent stdout held) and outlives its parent =="
MAN2="$(new_manifest 000000000000bbbb)"
PROXY_OUT="$WORK/proxy_pid"
# The S2 proxy: `parent | cat`. ensureDaemon spawns the child with stdout=/dev/null,
# so `cat` sees EOF the instant the --ensure-daemon parent exits -- NOT after the
# daemon's lifetime. If the daemon held the parent's stdout, this pipeline would
# block until the daemon dies; we bound it with a deadline.
( "$BIN" --ensure-daemon "$MAN2" | cat > "$PROXY_OUT" ) & PIPE=$!
if ! wait_gone "$PIPE" 30; then
    kill -9 "$PIPE" 2>/dev/null
    fail "AC4: 'ensure-daemon | cat' did not return promptly -> daemon holds parent stdout"
fi
echo "  ok: parent's stdout reader hit EOF promptly (daemon holds no parent fd)"

DPID="$(tr -d '[:space:]' < "$PROXY_OUT")"
[ -n "$DPID" ] || fail "AC2: ensure-daemon printed no spawned pid"
SPAWNED+=("$DPID")
# The parent (--ensure-daemon) has already exited; the daemon must still run.
alive "$DPID" || fail "AC2: daemon $DPID did not survive its parent's exit"
echo "  ok: daemon $DPID survives parent exit"

echo "== singleton via ensure-daemon: a second ensure with the lock held spawns nothing =="
sleep 0.3  # let the daemon settle on the lock
OUT2="$("$BIN" --ensure-daemon "$MAN2")"
[ -z "$OUT2" ] || fail "singleton: second ensure-daemon spawned a duplicate (pid '$OUT2')"
alive "$DPID" || fail "singleton: original daemon died unexpectedly"
echo "  ok: second ensure-daemon spawned no duplicate"

echo "== AC3: killing the lock holder lets a NEW daemon start =="
kill "$DPID" 2>/dev/null
wait_gone "$DPID" 20 || fail "AC3: could not kill the lock holder $DPID"
# Lock released on death; a fresh --animate must now acquire it and stay alive.
"$BIN" --animate "$MAN2" & P3=$!; SPAWNED+=("$P3")
sleep 0.6
alive "$P3" || fail "AC3: new daemon failed to start after the lock holder died"
echo "  ok: new daemon $P3 acquired the freed lock"
rm -f "$MAN2"
wait_gone "$P3" 20 || fail "AC3: replacement daemon did not exit on manifest removal"
echo "  ok: replacement daemon exited on manifest removal"

# --- T3: frame loop ---------------------------------------------------------
# The daemon re-transmits the current frame to a stable image id on its own
# timer via bare `a=t`. We point the manifest's tty at a regular file and
# capture the bytes: successive `a=t` transmissions with cycling frame payloads,
# an interval that tracks gap_ms without a restart, and never any `a=f`/`a=a`.

# Count non-overlapping occurrences of a fixed pattern in a (binary) file.
count_pat() { grep -a -o -F -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' '; }

# Rewrite a manifest atomically (temp + mv) so the daemon's locked read never
# sees a half-written file. Same frames/sig; only gap_ms varies here.
write_manifest() {
    local man="$1" gap="$2" tty="$3" f0="$4" f1="$5" f2="$6"
    # A large daemon_ttl_ms keeps this long-running test's daemon from TTL-exiting
    # (T5's heartbeat guard is exercised separately below).
    cat > "$man.tmp" <<EOF
image_id = 100
gap_ms = $gap
max_fps = 30
daemon_ttl_ms = 60000
tmux = 0
tty = $tty
frame_sig = deadbeef
frame = $f0
frame = $f1
frame = $f2
EOF
    mv -f "$man.tmp" "$man"
    touch_hb "$man"
}

echo "== T3: frame loop transmits cycling a=t frames at ~gap_ms, no a=f/a=a =="
T3DIR="$WORK/000000000000cccc"
mkdir -p "$T3DIR"
MAN3="$T3DIR/anim-000000000000cccc"
FAKE_TTY="$T3DIR/tty"
: > "$FAKE_TTY"
F0="$T3DIR/f0.bin"; F1="$T3DIR/f1.bin"; F2="$T3DIR/f2.bin"
# Distinct, short (<57B => single-line base64) contents so each frame's base64
# payload is unique and greppable.
printf 'FRAME-ZERO' > "$F0"
printf 'FRAME-ONEE' > "$F1"
printf 'FRAME-TWOO' > "$F2"
B0="$(base64 < "$F0" | tr -d '\n')"
B1="$(base64 < "$F1" | tr -d '\n')"
B2="$(base64 < "$F2" | tr -d '\n')"

# Phase 1: a fast interval.
write_manifest "$MAN3" 60 "$FAKE_TTY" "$F0" "$F1" "$F2"
"$BIN" --animate "$MAN3" & DP=$!; SPAWNED+=("$DP")
sleep 0.4                       # warmup: let the loop open the tty and settle
c_fast_start="$(count_pat "$FAKE_TTY" 'a=t')"
sleep 1.0
c_fast_end="$(count_pat "$FAKE_TTY" 'a=t')"
fast_delta=$((c_fast_end - c_fast_start))
echo "  fast(gap=60): $fast_delta transmissions in ~1.0s"
[ "$fast_delta" -ge 5 ] || fail "T3: expected many transmissions at gap=60, got $fast_delta"
# ~30fps max_fps floor bounds the rate; 1s can't exceed ~30 (+slack).
[ "$fast_delta" -le 45 ] || fail "T3: rate $fast_delta exceeds the max_fps ceiling"

echo "  -- cycling: all three distinct frame payloads appear --"
n0="$(count_pat "$FAKE_TTY" "$B0")"
n1="$(count_pat "$FAKE_TTY" "$B1")"
n2="$(count_pat "$FAKE_TTY" "$B2")"
echo "    frame payload counts: f0=$n0 f1=$n1 f2=$n2"
[ "$n0" -ge 1 ] && [ "$n1" -ge 1 ] && [ "$n2" -ge 1 ] || fail "T3: frames not cycling (f0=$n0 f1=$n1 f2=$n2)"

echo "  -- no kitty-animation escapes ever emitted --"
! grep -a -q -F -- 'a=f' "$FAKE_TTY" || fail "T3: daemon emitted a=f (retired)"
! grep -a -q -F -- 'a=a' "$FAKE_TTY" || fail "T3: daemon emitted a=a (retired)"

# Phase 2: slow the interval by rewriting the manifest WITHOUT restarting.
write_manifest "$MAN3" 300 "$FAKE_TTY" "$F0" "$F1" "$F2"
sleep 0.5                       # let the change take effect and the fast tail drain
c_slow_start="$(count_pat "$FAKE_TTY" 'a=t')"
sleep 1.0
c_slow_end="$(count_pat "$FAKE_TTY" 'a=t')"
slow_delta=$((c_slow_end - c_slow_start))
echo "  slow(gap=300): $slow_delta transmissions in ~1.0s (was $fast_delta at gap=60)"
[ "$slow_delta" -ge 1 ] || fail "T3: daemon stopped transmitting after the gap change"
[ "$slow_delta" -lt "$fast_delta" ] || fail "T3: larger gap_ms did not slow the interval ($slow_delta !< $fast_delta)"
echo "  ok: manifest gap change altered the interval with no restart"

# Stop the daemon via manifest removal (T1 exit condition) and confirm it dies.
rm -f "$MAN3"
wait_gone "$DP" 20 || fail "T3: daemon did not exit on manifest removal"
echo "  ok: frame-loop daemon exited on manifest removal"

# --- T5: lifecycle + tty safety ---------------------------------------------

# A single-frame manifest with an explicit daemon_ttl_ms and tty.
write_manifest_ttl() {
    local man="$1" ttl="$2" tty="$3" frame="$4"
    cat > "$man.tmp" <<EOF
image_id = 100
gap_ms = 100
max_fps = 30
daemon_ttl_ms = $ttl
tmux = 0
tty = $tty
frame_sig = feedface
frame = $frame
EOF
    mv -f "$man.tmp" "$man"
}

# Count APC opens (ESC _ G) that occur while a prior APC is still open (i.e. an
# ESC_G ... ESC\ unit split by another write), plus the total opens. A correct,
# serialized stream strictly alternates open/close so nested == 0.
count_nested() {
    perl -0777 -ne '
        my $depth=0; my $bad=0; my $opens=0; my $len=length($_);
        for (my $i=0; $i<$len-1; $i++) {
            next unless ord(substr($_,$i,1))==27;   # ESC
            my $n=substr($_,$i+1,1);
            if ($n eq "_" && substr($_,$i+2,1) eq "G") { $bad++ if $depth>0; $depth++; $opens++; $i+=2; }
            elsif ($n eq "\\") { $depth-- if $depth>0; $i+=1; }
        }
        print "$bad $opens";
    ' "$1"
}

echo "== T5: daemon exits within one daemon_ttl_ms after heartbeat refreshes stop =="
T5A="$WORK/00000000000d0001"; mkdir -p "$T5A"
MAN5="$T5A/anim-00000000000d0001"
TTY5="$T5A/tty"; : > "$TTY5"
FR5="$T5A/f.bin"; printf 'FRAME' > "$FR5"
write_manifest_ttl "$MAN5" 500 "$TTY5" "$FR5"
touch_hb "$MAN5"
"$BIN" --animate "$MAN5" & DT=$!; SPAWNED+=("$DT")
# Refresh for ~0.8s (> the 0.5s ttl): the daemon must stay alive while refreshed.
refreshed_alive=1
for _ in 1 2 3 4 5 6 7 8; do
    sleep 0.1
    touch_hb "$MAN5"
    alive "$DT" || { refreshed_alive=0; break; }
done
[ "$refreshed_alive" -eq 1 ] || fail "T5: daemon died while its heartbeat was being refreshed"
echo "  ok: daemon stayed alive across 0.8s of refreshes (> 0.5s ttl)"
# Stop refreshing: it must exit within ~one ttl (+ tick/process slack).
wait_gone "$DT" 15 || fail "T5: daemon did not exit within ~one ttl after refreshes stopped"
[ -f "$MAN5" ] || fail "T5: manifest vanished; TTL-exit not isolated from manifest removal"
echo "  ok: daemon TTL-exited within ~1.5s of the last refresh (manifest still present)"
rm -f "$MAN5"

echo "== T5: daemon exits when its tty is closed (write fails), not on manifest removal =="
T5B="$WORK/00000000000d0002"; mkdir -p "$T5B"
MANB="$T5B/anim-00000000000d0002"
FIFO="$T5B/tty.fifo"; mkfifo "$FIFO"
FRB="$T5B/f.bin"; printf 'FRAMEBYTES' > "$FRB"
# A reader keeps the FIFO open so the daemon's write-only open succeeds and its
# frames drain; closing it makes the next daemon write fail (BrokenPipe/EIO).
cat "$FIFO" > /dev/null & RPID=$!; SPAWNED+=("$RPID")
write_manifest_ttl "$MANB" 60000 "$FIFO" "$FRB"   # large ttl isolates the tty-death guard
touch_hb "$MANB"
"$BIN" --animate "$MANB" & DB=$!; SPAWNED+=("$DB")
sleep 0.6
alive "$DB" || fail "T5: daemon died before its tty was closed"
echo "  ok: daemon alive and writing while the FIFO reader is open"
kill "$RPID" 2>/dev/null            # close the reader -> next write hits a dead pipe
wait_gone "$DB" 20 || fail "T5: daemon did not exit after its tty was closed (spinning on a dead fd?)"
[ -f "$MANB" ] || fail "T5: manifest vanished; tty-death exit not isolated"
echo "  ok: daemon exited on tty-write failure with the manifest still present"
rm -f "$MANB"

echo "== T5: no interleaved/split APCs when daemon + statusline serialize on the shared lock =="
T5C="$WORK/00000000000d0003"; mkdir -p "$T5C"
MANC="$T5C/anim-00000000000d0003"
CAPFIFO="$T5C/tty.fifo"; mkfifo "$CAPFIFO"
CAP="$T5C/capture.bin"
# Frames large enough that one transmit is split across several write()s -- the
# case where an unlocked concurrent write would corrupt an APC.
FC0="$T5C/c0.bin"; FC1="$T5C/c1.bin"; FC2="$T5C/c2.bin"
head -c 100000 /dev/zero | tr '\0' 'A' > "$FC0"
head -c 100000 /dev/zero | tr '\0' 'B' > "$FC1"
head -c 100000 /dev/zero | tr '\0' 'C' > "$FC2"
cat "$CAPFIFO" > "$CAP" & CAPR=$!
write_manifest "$MANC" 33 "$CAPFIFO" "$FC0" "$FC1" "$FC2"   # gap 33 -> ~30fps (default max_fps)
touch_hb "$MANC"
"$BIN" --animate "$MANC" & DC=$!; SPAWNED+=("$DC")
# Three statusline-style writers on the SAME manifest -> the SAME state lock as
# the daemon; every tty write must serialize.
WPIDS=()
for _ in 1 2 3; do
    "$BIN" --lock-write "$MANC" 40 & wp=$!; WPIDS+=("$wp"); SPAWNED+=("$wp")
done
for p in "${WPIDS[@]}"; do wait "$p" 2>/dev/null; done
rm -f "$MANC"                         # stop the daemon
wait_gone "$DC" 20 || fail "T5: corruption-test daemon did not exit on manifest removal"
wait "$CAPR" 2>/dev/null              # reader EOFs once all writers + daemon close
locked_res="$(count_nested "$CAP")"; locked_nested="${locked_res%% *}"; locked_opens="${locked_res##* }"
echo "  shared-lock run: apc_opens=$locked_opens nested=$locked_nested"
[ "${locked_nested:-1}" -eq 0 ] || fail "T5: APC interleaving observed at default max_fps (nested=$locked_nested) -- lower max_fps"
echo "  ok: no interleaved/split APCs at default max_fps (daemon+statusline serialized on the shared lock)"

# Control (informational, not asserted): the same writers on DISTINCT locks are
# NOT serialized, so interleaving CAN appear -- confirms the check is sensitive.
CTLFIFO="$T5C/ctl.fifo"; mkfifo "$CTLFIFO"
CTLCAP="$T5C/ctl.bin"
cat "$CTLFIFO" > "$CTLCAP" & CTLR=$!
CWPIDS=()
for w in 1 2 3 4; do
    cman="$T5C/anim-00000000000ctl$w"
    write_manifest_ttl "$cman" 60000 "$CTLFIFO" "$FC0"
    touch_hb "$cman"
    "$BIN" --lock-write "$cman" 40 & cwp=$!; CWPIDS+=("$cwp"); SPAWNED+=("$cwp")
done
for p in "${CWPIDS[@]}"; do wait "$p" 2>/dev/null; done
wait "$CTLR" 2>/dev/null
ctl_res="$(count_nested "$CTLCAP")"; ctl_nested="${ctl_res%% *}"
echo "  control (distinct locks, no serialization): nested=$ctl_nested (expect > 0 if writes overlapped; informational)"

echo "== teardown: no orphaned daemons remain =="
orphans=0
for p in "${SPAWNED[@]}"; do
    alive "$p" && { orphans=$((orphans + 1)); echo "  still alive: $p"; }
done
[ "$orphans" -eq 0 ] || fail "teardown: $orphans daemon(s) still running"
echo "  ok: no orphaned daemons"

echo "ALL DAEMON ASSERTIONS PASSED"
exit 0
