#!/bin/bash
# Peak idle-CPU check. Launches its OWN demo instance of a built Peak (never the installed app, never the coach's
# ~/ForceIQ/peak): GOAT_PEAK_ROOT is a fresh scratch root, the feed is the quiet desk (Ghost .idle, so every ambient
# animation is on), and the 3PO chat opens and sits idle (FORCEIQ_PEAK_DEMO_TOUR=3po-idle). Measures that PID only for
# SECONDS, quits it, and exits 1 if the average CPU is above the threshold.
#
#   peak/scripts/cpu_idle_check.sh [--app "peak/build/ForceIQ Peak.app"] [--mode expanded|collapsed]
#                                  [--tier rig|loops] [--max 2.0] [--seconds 30] [--settle 8]
#   peak/scripts/cpu_idle_check.sh --all     # rig + loops, expanded + collapsed: 4 runs, exit 1 if any fails
# Defaults: expanded (chat open, idle), max 2.0 % (collapsed: 0.5 %), 30 s, 8 s settle after the chat opens.
# --tier loops: the rendered-loops fallback (FORCEIQ_PEAK_3PO_RIG=0, what plays when the rig is off or fails), same limits.
# Scratch root and log: ~/ForceIQ/peak-tmp/cpu-check-<ts>/ (override PEAK_TMPDIR). Needs no engine data: demo mode.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/ForceIQ Peak.app"; MODE=expanded; TIER=rig; MAX=""; SECS=30; SETTLE=8; ALL=0; ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2;; --mode) MODE="$2"; shift 2;; --max) MAX="$2"; shift 2;;
    --tier) TIER="$2"; shift 2;; --all) ALL=1; shift;;
    --seconds) SECS="$2"; shift 2;; --settle) SETTLE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ "$ALL" = 1 ]; then
  REST=(); skip=0
  for a in "${ARGS[@]}"; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    case "$a" in --all) ;; --mode|--tier) skip=1;; *) REST+=("$a");; esac
  done
  rc=0
  for t in rig loops; do for m in expanded collapsed; do
    "$0" ${REST[@]+"${REST[@]}"} --tier "$t" --mode "$m" || rc=1
  done; done
  exit $rc
fi
case "$TIER" in rig|loops) ;; *) echo "--tier rig|loops" >&2; exit 2;; esac
[ -n "$MAX" ] || { [ "$MODE" = collapsed ] && MAX=0.5 || MAX=2.0; }
RIG_ENV=1; [ "$TIER" = loops ] && RIG_ENV=0
BIN="$APP/Contents/MacOS/ForceIQPeak"
[ -x "$BIN" ] || { echo "no Peak binary at $BIN (run peak/build.sh)" >&2; exit 2; }
ROOT="${PEAK_TMPDIR:-$HOME/ForceIQ/peak-tmp}/cpu-check-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$ROOT"
TOUR=3po-idle; [ "$MODE" = collapsed ] && TOUR=none
FORCEIQ_PEAK_3PO_RIG="$RIG_ENV" GOAT_PEAK_ROOT="$ROOT" FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_FEED=quiet FORCEIQ_PEAK_DEMO_TOUR="$TOUR" \
  "$BIN" > "$ROOT/stdout.log" 2>&1 &
PID=$!; disown "$PID" 2>/dev/null || true
# Launching a build registers it with LaunchServices and can make it the forceiq-peak:// handler (Raycast links would
# then open this build). On exit: quit it and unregister this build again, never the installed app.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP_ABS="$(cd "$APP" && pwd)"
cleanup() {
  kill "$PID" 2>/dev/null || true
  [ "$APP_ABS" = "$HOME/ForceIQ/peak/ForceIQ Peak.app" ] || "$LSREG" -u "$APP_ABS" 2>/dev/null || true
}
trap cleanup EXIT
LOG="$ROOT/logs/peak.log"
# Wait for the state under test: expanded → the chat is open and the droid has parked (rig or loops; or 20 s);
# collapsed → launch.
PARKED="3po rig parked"; [ "$TIER" = loops ] && PARKED="3po loops parked"
for _ in $(seq 1 100); do
  if [ "$MODE" = expanded ]; then grep -q "$PARKED\|3po avatar tier=still\|3po avatar tier=mark" "$LOG" 2>/dev/null && break
  else grep -q "^.* launch " "$LOG" 2>/dev/null && break; fi
  sleep 0.2
done
sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || { echo "Peak exited early; see $ROOT" >&2; exit 2; }
cpu_s() { ps -o time= -p "$PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
C0=$(cpu_s); T0=$(date +%s.%N)
top -l $((SECS + 1)) -s 1 -pid "$PID" -stats pid,cpu > "$ROOT/top.txt"
C1=$(cpu_s); T1=$(date +%s.%N)
AVG=$(awk -v a="$C0" -v b="$C1" -v t0="$T0" -v t1="$T1" 'BEGIN{printf "%.2f", (b-a)/(t1-t0)*100}')
TOP=$(awk -v p="$PID" '$1==p{print $2}' "$ROOT/top.txt" | tail -n "$SECS" | awk '{s+=$1; if($1>m)m=$1; n++} END{printf "avg=%.2f max=%.1f n=%d", s/n, m, n}')
GHOST=$(grep -o "ghost=[a-z]*" "$LOG" | tail -1 || true)
echo "peak cpu ($MODE, $TIER tier, idle, ${SECS}s, pid $PID, $GHOST): ${AVG}% by cpu time; top $TOP; max allowed ${MAX}%"
echo "scratch: $ROOT"
awk -v a="$AVG" -v m="$MAX" 'BEGIN{exit !(a <= m)}' && { echo PASS; exit 0; } || { echo "FAIL: ${AVG}% > ${MAX}%"; exit 1; }
