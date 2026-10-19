#!/bin/bash
# Cua live smoke: Peak's ONE live desktop action (FLOW's 'Tools > Code Window' menu item) made through the Cua backend
# (cua-driver invoke_menu, ~/ForceIQ/.venv-peak-cua) against an ISOLATED, non-production FLOW, with text proof: an
# Accessibility read of that FLOW's window list before and after, and Peak's own log lines.
#
#   peak/scripts/cua_live_smoke.sh --pid <isolated FLOW pid> | --bundle <its non-production bundle id> \
#       --package <the .flowaipkg that FLOW has open> [--mode press|stop] [--app "<Peak build>.app"] [--keep-root]
#   peak/scripts/cua_live_smoke.sh ... --check-only     # only the target checks (refusals), launches nothing
#
# Same refusals as real_press_smoke.sh (exit 3 before anything runs): bundle com.forceiq.flowai (any case), the app at
# /Applications/FLOW.app, any running production FLOW pid, a pid in FORCEIQ_PEAK_PROTECTED_PIDS.
# What it does: a scratch GOAT_PEAK_ROOT under ~/ForceIQ/peak-tmp with settings.json {desktopActions: true, cuaActions:
# true, hiddenDisplays: [], globallyHidden: false}, a package folder holding only a symlink named for the demo client,
# then a demo Peak of the build with FORCEIQ_PEAK_DESKTOP_LIVE=1 and FORCEIQ_PEAK_CUA_LIVE=1. It checks Peak logged
# `desktop mode=live` and `desktop cua=on`, taps Peak's Run, waits for the Cua approval card and checks nothing ran yet,
# then taps the card's Run.
#   --mode press: PASS = no 'Code Window' window before, one Cua press logged, a 'Code Window' window after.
#   --mode stop:  the child is held in flight (FORCEIQ_PEAK_CUA_SMOKE_HOLD_MS=3000, after its checks, before Cua is
#                 imported); STOP is tapped while it runs. PASS = Peak logged the Cua STOP with stop_latency_ms <= 100,
#                 the child process is gone, no press, no 'Code Window' window after.
# Afterwards it quits its own demo Peak (its pid), deletes the scratch root (symlink only) and leaves the proof in --out
# (default ~/ForceIQ/peak-tmp/cua-live-<mode>-<time>). With FORCEIQ_PEAK_CUA_PROOF_DIR set, Peak also saves ONE
# window-only, redacted capture of the isolated FLOW (strict: every text line blacked out except menu words).
# It never touches the installed Peak, its settings or the engine, and never activates, quits or opens any FLOW.
set -uo pipefail
PROD_BUNDLE=com.forceiq.flowai
PROD_APP=/Applications/FLOW.app
HERE="$(cd "$(dirname "$0")" && pwd)"
PID_ARG="" BUNDLE_ARG="" PKG="" MODE=press APP="$HERE/../build/ForceIQ Peak.app" OUT="" KEEP=0 CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pid) PID_ARG="$2"; shift 2 ;;
    --bundle) BUNDLE_ARG="$2"; shift 2 ;;
    --package) PKG="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
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
[ -f "$APP/Contents/Resources/cua/peak_cua_runner.py" ] || { echo "the build has no Cua runner (rebuild)" >&2; exit 2; }
[ -x "$HOME/ForceIQ/.venv-peak-cua/bin/python" ] || { echo "no Cua venv (peak/cua/install.sh)" >&2; exit 2; }
case "$(cd "$APP/.." && pwd)" in "$HOME/ForceIQ/peak"|"$HOME/ForceIQ/peak/"*) echo "refusing the installed Peak; use a build" >&2; exit 2 ;; esac
mkdir -p "$HOME/ForceIQ/peak-tmp/cua"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$TMPDIR/cua-live-$MODE-$TS}"
ROOT="$TMPDIR/cua-live-root-$MODE-$TS"
PKGS="$ROOT/flow-packages"
mkdir -p "$OUT" "$PKGS"
python3 -c 'import json,sys; json.dump({"desktopActions": True, "cuaActions": True, "hiddenDisplays": [], "globallyHidden": False}, open(sys.argv[1], "w"))' "$ROOT/settings.json"
ln -s "$PKG" "$PKGS/Sample Skater ($(basename "$PKG" .flowaipkg)).flowaipkg"
LOG="$ROOT/logs/peak.log"
{ echo "target: $TLINE"; echo "mode: $MODE"; echo "scratch root: $ROOT"; echo "settings.json: $(cat "$ROOT/settings.json")"; echo "app: $APP"; } > "$OUT/run.txt"
wait_log() { for _ in $(seq 1 "${2:-400}"); do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 0.05; done; return 1; }
count_cw() { sed -nE 's/.*code_window_windows=([0-9]+).*/\1/p' "$1" | tail -1; }
cua_kids() { pgrep -P "$PEAK" -f peak_cua_runner.py 2>/dev/null; }
fail() { echo "FAIL: $*" | tee "$OUT/verdict.txt"; exit 1; }

if [ "$MODE" = stop ]; then "$AX" close-code-window "$TPID" | tee "$OUT/close-before.txt"; sleep 1; fi
"$AX" windows "$TPID" > "$OUT/ax-before.txt" || exit $?
[ "$(count_cw "$OUT/ax-before.txt")" = 0 ] || fail "a 'Code Window' window is already open before the run"

HOLD=""; [ "$MODE" = stop ] && HOLD=3000
env -u GOAT_OVERLAY -u FORCEIQ_PEAK_DESKTOP_DRYRUN FORCEIQ_PEAK_DEMO=1 GOAT_PEAK_ROOT="$ROOT" FORCEIQ_PEAK_DESKTOP_LIVE=1 \
  FORCEIQ_PEAK_CUA_LIVE=1 FORCEIQ_PEAK_CUA_SMOKE_HOLD_MS="$HOLD" FORCEIQ_PEAK_CUA_PROOF_DIR="${FORCEIQ_PEAK_CUA_PROOF_DIR:-}" \
  FORCEIQ_PEAK_FLOW_PACKAGES="$PKGS" FORCEIQ_PEAK_DEMO_TOUR=live-flow FORCEIQ_PEAK_NO_WARM=1 FORCEIQ_PEAK_LIVE_ARM_MS=300 \
  FORCEIQ_PEAK_FLOW_TARGET_PID="$TPID" FORCEIQ_PEAK_FLOW_TARGET_BUNDLE="$TBUNDLE" FORCEIQ_PEAK_PROTECTED_PIDS="$PROTECTED" \
  "$APP/Contents/MacOS/ForceIQPeak" > "$OUT/peak-stdout.log" 2>&1 &
PEAK=$!
echo "peak demo pid: $PEAK" >> "$OUT/run.txt"
finish() {
  kill "$PEAK" 2>/dev/null; sleep 1; kill -0 "$PEAK" 2>/dev/null && kill -9 "$PEAK" 2>/dev/null
  [ -f "$LOG" ] && grep -E "desktop mode|desktop cua|smoke target|tour |dryrun|live step|cua " "$LOG" > "$OUT/live-log.txt"
  if [ $KEEP -eq 0 ]; then rm -rf "$ROOT"; [ -e "$ROOT" ] && echo "scratch root NOT deleted: $ROOT" >> "$OUT/run.txt" || echo "scratch root deleted" >> "$OUT/run.txt"; fi
  [ -e "$PKG" ] && echo "package still present: $PKG" >> "$OUT/run.txt"
}
trap finish EXIT
wait_log "desktop cua=" 600 || fail "Peak never logged its Cua mode"
grep -q "desktop mode=live" "$LOG" || fail "live mode did not read on ($(grep -o 'desktop mode=[a-z_]*' "$LOG"))"
grep -q "desktop cua=on" "$LOG" || fail "the Cua backend did not read on ($(grep -o 'desktop cua=[a-z]*' "$LOG"))"
echo "flags: desktop mode=live, desktop cua=on (scratch settings.json + env opt-ins)" >> "$OUT/run.txt"
wait_log "waiting for an explicit Run tap" 600 || fail "no command card"
sleep 0.7
grep -q "dryrun run" "$LOG" && fail "ran before the Run tap"
"$AX" press-peak "$PEAK" "$APP" peak-command-run | tee "$OUT/run-tap.txt"
wait_log "cua approval card shown" 600 || fail "no Cua approval card"
sleep 1.0
[ -z "$(cua_kids)" ] && ! grep -q "press pressed=1" "$LOG" || fail "Cua ran before the approval card's Run tap"
echo "approval card shown; no Cua child and no press 1 s later (waiting for the tap)" >> "$OUT/run.txt"
"$AX" windows "$TPID" >> "$OUT/ax-before.txt"
"$AX" press-peak "$PEAK" "$APP" peak-cua-run | tee "$OUT/card-run-tap.txt"
KID=""
if [ "$MODE" = stop ]; then
  for _ in $(seq 1 200); do KID="$(cua_kids | head -1)"; [ -n "$KID" ] && break; sleep 0.01; done
  [ -n "$KID" ] || fail "the Cua child never started"
  echo "cua child in flight: pid $KID ($(ps -o command= -p "$KID" | sed 's#.*/##'))" >> "$OUT/run.txt"
  sleep 0.8
  "$AX" press-peak "$PEAK" "$APP" STOP | tee "$OUT/stop-press.txt"
fi
wait_log "dryrun summary" 600 || fail "no summary"
sleep 0.5
: > "$OUT/ax-after.txt"
for _ in $(seq 1 20); do
  "$AX" windows "$TPID" >> "$OUT/ax-after.txt"
  [ "$MODE" = press ] && [ "$(count_cw "$OUT/ax-after.txt")" != 0 ] && break
  sleep 0.25
done
B="$(count_cw "$OUT/ax-before.txt")" A="$(count_cw "$OUT/ax-after.txt")"
PRESSED="$(grep -c "press pressed=1" "$LOG")"
CUA_PRESSED="$(grep -c "press pressed=1.*cua pressed" "$LOG")"
if [ "$MODE" = press ]; then
  [ "$B" = 0 ] && [ "$A" != 0 ] && [ "$PRESSED" = 1 ] && [ "$CUA_PRESSED" = 1 ] && V=PASS || V=FAIL
  echo "$V: press mode: code_window_windows before=$B after=$A; Cua press lines=$CUA_PRESSED: $(grep -o 'press pressed=.*' "$LOG" | head -1)" | tee "$OUT/verdict.txt"
else
  SL="$(sed -nE 's/.*stop_latency_ms=([0-9]+).*/\1/p' "$LOG" | head -1)"
  ALIVE=no; kill -0 "$KID" 2>/dev/null && ALIVE=yes
  [ -n "$SL" ] && [ "$SL" -le 100 ] && [ "$ALIVE" = no ] && [ "$PRESSED" = 0 ] && [ "$A" = 0 ] && V=PASS || V=FAIL
  echo "$V: stop mode: cua stop_latency_ms=${SL:-none}; child pid $KID alive after=$ALIVE; press lines=$PRESSED; code_window_windows before=$B after=$A; $(grep -o 'dryrun STOPPED phase=[a-z_]* step=[0-9]* latency_ms=[0-9]*' "$LOG" | head -1)" | tee "$OUT/verdict.txt"
fi
echo "proof: $OUT"
[ "$V" = PASS ]
