#!/bin/bash
# Real-press smoke for Peak's ONE live desktop action (FLOW's 'Code Window' menu item, AXPress) against an ISOLATED,
# non-production FLOW instance, with text proof: an Accessibility read of that FLOW's window list before and after.
#
#   peak/scripts/real_press_smoke.sh --pid <isolated FLOW pid> | --bundle <its non-production bundle id> \
#       --package <the .flowaipkg that FLOW has open> [--mode press|stop] [--app "<Peak build>.app"] [--arm-ms N] [--keep-root]
#   peak/scripts/real_press_smoke.sh ... --check-only     # only the target checks (refusals), launches nothing
#
# REFUSES production FLOW (exit 3) before anything runs: bundle id com.forceiq.flowai (any case), the app at
# /Applications/FLOW.app, any running /Applications/FLOW.app or com.forceiq.flowai process, or a pid listed in
# FORCEIQ_PEAK_PROTECTED_PIDS. The same pids are handed to Peak (FORCEIQ_PEAK_PROTECTED_PIDS), whose presser and locator
# refuse production FLOW again (PeakCore ProductionGuard) and accept only the target (FORCEIQ_PEAK_FLOW_TARGET_PID/_BUNDLE).
#
# What it does: a scratch GOAT_PEAK_ROOT under ~/ForceIQ/peak-tmp with settings.json {desktopActions: true,
# hiddenDisplays: [], globallyHidden: false} (Peak ignores a settings.json without the last two), a scratch package folder
# holding only a symlink named for the demo client ("Sample Skater (<package>).flowaipkg" -> --package), then a demo
# Peak instance of the build in live mode (FORCEIQ_PEAK_DESKTOP_LIVE=1, FORCEIQ_PEAK_DEMO_TOUR=live-flow). It checks that
# Peak logged `desktop mode=live` (the flag read on), reads FLOW's windows, taps Peak's own Run (AX, Peak's button only),
# and reads FLOW's windows again.
#   --mode press: PASS = no 'Code Window' window before, Peak logged the press, a 'Code Window' window after.
#   --mode stop:  closes an open 'Code Window' window in the isolated FLOW first, taps Peak's STOP while the press is
#                 armed; PASS = STOPPED phase=before_press, no press logged, no 'Code Window' window after.
# Afterwards it quits its demo Peak (its own pid), deletes the scratch root (the symlink only; never the package) and
# leaves the proof in --out (default ~/ForceIQ/peak-tmp/real-press-<mode>-<time>). It never touches the installed Peak
# (~/ForceIQ/peak), its settings or the engine, never activates, quits or opens any FLOW, and takes no screen captures.
set -uo pipefail
PROD_BUNDLE=com.forceiq.flowai
PROD_APP=/Applications/FLOW.app
HERE="$(cd "$(dirname "$0")" && pwd)"
PID_ARG="" BUNDLE_ARG="" PKG="" MODE=press APP="$HERE/../build/ForceIQ Peak.app" ARM="" OUT="" KEEP=0 CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pid) PID_ARG="$2"; shift 2 ;;
    --bundle) BUNDLE_ARG="$2"; shift 2 ;;
    --package) PKG="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --arm-ms) ARM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --keep-root) KEEP=1; shift ;;
    --check-only) CHECK=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
refuse() { echo "REFUSED: $*"; exit 3; }
[ -n "$PID_ARG$BUNDLE_ARG" ] || { echo "usage: --pid <pid> | --bundle <id> --package <pkg> [--mode press|stop]" >&2; exit 2; }
case "$MODE" in press|stop) ;; *) echo "--mode is press or stop" >&2; exit 2 ;; esac

# ── 1. refusals on the arguments alone (no process is looked at) ──
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }
[ -n "$BUNDLE_ARG" ] && [ "$(lower "$BUNDLE_ARG")" = "$PROD_BUNDLE" ] && refuse "production FLOW (bundle $BUNDLE_ARG)"
if [ -n "$PID_ARG" ]; then
  [[ "$PID_ARG" =~ ^[0-9]+$ ]] && [ "$PID_ARG" -gt 0 ] || refuse "not a pid: $PID_ARG"
  for p in ${FORCEIQ_PEAK_PROTECTED_PIDS//,/ }; do [ "$p" = "$PID_ARG" ] && refuse "pid $PID_ARG is protected (production FLOW)"; done
fi

# ── 2. refusals against the running system: every production FLOW pid is protected ──
PROTECTED="$(echo ${FORCEIQ_PEAK_PROTECTED_PIDS//,/ } $(pgrep -f "^$PROD_APP/Contents/MacOS/" 2>/dev/null) | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | paste -sd, -)"
export FORCEIQ_PEAK_PROTECTED_PIDS="$PROTECTED"
if [ -n "$PID_ARG" ]; then
  for p in ${PROTECTED//,/ }; do [ "$p" = "$PID_ARG" ] && refuse "pid $PID_ARG is production FLOW"; done
  EXE="$(ps -p "$PID_ARG" -o comm= 2>/dev/null)"
  [ -n "$EXE" ] || { echo "no process $PID_ARG" >&2; exit 4; }
  case "$(lower "$EXE")" in "$(lower "$PROD_APP")"/*) refuse "pid $PID_ARG is $PROD_APP" ;; esac
fi
export TMPDIR="${PEAK_TMPDIR:-$HOME/ForceIQ/peak-tmp}"
mkdir -p "$TMPDIR"
AX="$TMPDIR/real_press_ax-$(shasum -a 256 "$HERE/real_press_ax.swift" | cut -c1-12)"
[ -x "$AX" ] || swiftc -O "$HERE/real_press_ax.swift" -o "$AX" >/dev/null || { echo "helper build failed" >&2; exit 5; }
TLINE="$("$AX" target "${PID_ARG:--}" "${BUNDLE_ARG:--}")"; RC=$?
echo "$TLINE"
[ $RC -eq 0 ] || exit $RC
TPID="$(sed -E 's/.*target pid=([0-9]+).*/\1/' <<<"$TLINE")"
TBUNDLE="$(sed -E 's/.* bundle=([^ ]+).*/\1/' <<<"$TLINE")"
[ "$(lower "$TBUNDLE")" = "$PROD_BUNDLE" ] && refuse "production FLOW (bundle $TBUNDLE)"
[ $CHECK -eq 1 ] && { echo "check-only: target accepted (pid $TPID, $TBUNDLE)"; exit 0; }

# ── 3. the run ──
[ -d "$PKG" ] && [ "${PKG##*.}" = flowaipkg ] || { echo "--package must be the .flowaipkg the isolated FLOW has open" >&2; exit 2; }
[ -x "$APP/Contents/MacOS/ForceIQPeak" ] || { echo "no Peak build at $APP (run peak/build.sh)" >&2; exit 2; }
case "$(cd "$APP/.." && pwd)" in "$HOME/ForceIQ/peak"|"$HOME/ForceIQ/peak/"*) echo "refusing the installed Peak; use a build" >&2; exit 2 ;; esac
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$TMPDIR/real-press-$MODE-$TS}"
ROOT="$TMPDIR/real-press-root-$MODE-$TS"
PKGS="$ROOT/flow-packages"
mkdir -p "$OUT" "$PKGS"
python3 -c 'import json,sys; json.dump({"desktopActions": True, "hiddenDisplays": [], "globallyHidden": False}, open(sys.argv[1], "w"))' "$ROOT/settings.json"
ln -s "$PKG" "$PKGS/Sample Skater ($(basename "$PKG" .flowaipkg)).flowaipkg"
LOG="$ROOT/logs/peak.log"
{ echo "target: $TLINE"; echo "mode: $MODE"; echo "scratch root: $ROOT"; echo "package link: $(ls "$PKGS")"; echo "app: $APP"; } > "$OUT/run.txt"
wait_log() { for _ in $(seq 1 "${2:-400}"); do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 0.05; done; return 1; }
count_cw() { sed -nE 's/.*code_window_windows=([0-9]+).*/\1/p' "$1" | tail -1; }

if [ "$MODE" = stop ]; then "$AX" close-code-window "$TPID" | tee "$OUT/close-before.txt"; sleep 1; fi
"$AX" windows "$TPID" > "$OUT/ax-before.txt" || exit $?
[ "$(count_cw "$OUT/ax-before.txt")" = 0 ] || { echo "FAIL: a 'Code Window' window is already open before the run" | tee "$OUT/verdict.txt"; exit 1; }

env -u GOAT_OVERLAY -u FORCEIQ_PEAK_DESKTOP_DRYRUN FORCEIQ_PEAK_DEMO=1 GOAT_PEAK_ROOT="$ROOT" FORCEIQ_PEAK_DESKTOP_LIVE=1 \
  FORCEIQ_PEAK_FLOW_PACKAGES="$PKGS" FORCEIQ_PEAK_DEMO_TOUR=live-flow FORCEIQ_PEAK_NO_WARM=1 \
  FORCEIQ_PEAK_LIVE_ARM_MS="${ARM:-$([ "$MODE" = stop ] && echo 4000 || echo 1500)}" \
  FORCEIQ_PEAK_FLOW_TARGET_PID="$TPID" FORCEIQ_PEAK_FLOW_TARGET_BUNDLE="$TBUNDLE" FORCEIQ_PEAK_PROTECTED_PIDS="$PROTECTED" \
  "$APP/Contents/MacOS/ForceIQPeak" > "$OUT/peak-stdout.log" 2>&1 &
PEAK=$!
echo "peak demo pid: $PEAK" >> "$OUT/run.txt"
finish() {
  kill "$PEAK" 2>/dev/null; sleep 1; kill -0 "$PEAK" 2>/dev/null && kill -9 "$PEAK" 2>/dev/null
  [ -f "$LOG" ] && grep -E "desktop mode|smoke target|tour |dryrun|live step" "$LOG" > "$OUT/live-log.txt"
  if [ $KEEP -eq 0 ]; then rm -rf "$ROOT"; [ -e "$ROOT" ] && echo "scratch root NOT deleted: $ROOT" >> "$OUT/run.txt" || echo "scratch root deleted" >> "$OUT/run.txt"; fi
  [ -e "$PKG" ] && echo "package still present: $PKG" >> "$OUT/run.txt"
}
trap finish EXIT
wait_log "desktop mode=" 600 || { echo "FAIL: Peak never logged its desktop mode" | tee "$OUT/verdict.txt"; exit 1; }
grep -q "desktop mode=live" "$LOG" || { echo "FAIL: live mode did not read on ($(grep -o 'desktop mode=[a-z_]*' "$LOG"))" | tee "$OUT/verdict.txt"; exit 1; }
echo "flag: $(grep -o 'desktop mode=live' "$LOG" | head -1) (settings.json desktopActions=true read from the scratch root)" >> "$OUT/run.txt"
wait_log "waiting for an explicit Run tap" 600 || { echo "FAIL: no command card" | tee "$OUT/verdict.txt"; exit 1; }
sleep 0.7
grep -q "dryrun run" "$LOG" && { echo "FAIL: ran before the Run tap" | tee "$OUT/verdict.txt"; exit 1; }
"$AX" windows "$TPID" >> "$OUT/ax-before.txt"
"$AX" press-peak "$PEAK" "$APP" peak-command-run | tee "$OUT/run-tap.txt"
if [ "$MODE" = stop ]; then
  wait_log "press armed" 600 || { echo "FAIL: the press never armed" | tee "$OUT/verdict.txt"; exit 1; }
  sleep 0.5
  "$AX" press-peak "$PEAK" "$APP" STOP | tee "$OUT/stop-press.txt"
fi
wait_log "dryrun summary" 600 || { echo "FAIL: no summary" | tee "$OUT/verdict.txt"; exit 1; }
: > "$OUT/ax-after.txt"
for _ in $(seq 1 20); do
  "$AX" windows "$TPID" >> "$OUT/ax-after.txt"
  [ "$MODE" = press ] && [ "$(count_cw "$OUT/ax-after.txt")" != 0 ] && break
  sleep 0.25
done
B="$(count_cw "$OUT/ax-before.txt")" A="$(count_cw "$OUT/ax-after.txt")"
PRESSED="$(grep -c "press pressed=1" "$LOG")"
if [ "$MODE" = press ]; then
  [ "$B" = 0 ] && [ "$A" != 0 ] && [ "$PRESSED" = 1 ] && V=PASS || V=FAIL
  echo "$V: press mode: code_window_windows before=$B after=$A; Peak press lines=$PRESSED: $(grep -o 'press pressed=.*' "$LOG" | head -1)" | tee "$OUT/verdict.txt"
else
  grep -q "STOPPED phase=before_press" "$LOG" && [ "$PRESSED" = 0 ] && [ "$A" = 0 ] && V=PASS || V=FAIL
  echo "$V: stop mode: $(grep -o 'dryrun STOPPED phase=[a-z_]* step=[0-9]* latency_ms=[0-9]*' "$LOG" | head -1); press lines=$PRESSED; code_window_windows before=$B after=$A" | tee "$OUT/verdict.txt"
fi
echo "proof: $OUT"
[ "$V" = PASS ]
