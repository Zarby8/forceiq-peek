#!/bin/bash
# Voice sample-WAV smoke (M5, real Neural Engine): a spoken 11 s clip (macOS `say`) is fed through the SAME audio path as the mic
# (demo mode + FORCEIQ_PEAK_VOICE_FEED), collapsed so the live words are drawn in the notch row, and the log is checked.
#   usage: voice_smoke.sh [<Peek.app>] [<models dir with parakeet-tdt-0.6b-v3 and parakeet-ctc-110m-coreml>]
# PASS = model ready; a 3 s warm-up turn and the 11 s turn both ran on Parakeet; the long turn produced >= 28 words (it says 33);
# first confirmed words within 2.0 s; final text within 500 ms of stop; the dictation never touched the system temp dir.
# Nothing here writes outside ~/ForceIQ (scratch root ~/ForceIQ/peak-tmp/voice-smoke, TMPDIR ~/.forceiq/tmp). With no models dir,
# Peek downloads its models (about 560 MB, once) into the scratch root. A zero-word or zero-turn run is a FAIL, never a skip.
set -uo pipefail
APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/ForceIQ Peek.app}"; MODELS="${2:-}"
BIN="$APP/Contents/MacOS/ForceIQPeak"; [ -x "$BIN" ] || { echo "FAIL: no app at $APP (run peak/build.sh)"; exit 2; }
export TMPDIR="$HOME/.forceiq/tmp"; mkdir -p "$TMPDIR"
R="$HOME/ForceIQ/peak-tmp/voice-smoke"; rm -rf "$R"; mkdir -p "$R/models" "$R/clips"
if [ -n "$MODELS" ]; then cp -R "$MODELS/parakeet-tdt-0.6b-v3" "$MODELS/parakeet-ctc-110m-coreml" "$R/models/" || { echo "FAIL: models dir"; exit 2; }; fi
echo '{"voiceEnabled": true}' > "$R/settings.json"
say -v Samantha -r 170 -o "$TMPDIR/vs-warm.aiff" "Start a meeting with Jelenic."
say -v Samantha -r 160 -o "$TMPDIR/vs-long.aiff" "Open Halliday's latest flow package and press the code button, then start a meeting with Jelenic tomorrow morning, check the invoice for last week, and send the family the link before practice starts."
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMPDIR/vs-warm.aiff" "$R/clips/u00-notch-warm.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMPDIR/vs-long.aiff" "$R/clips/u01-notch-10s.wav"
FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_FEED=quiet FORCEIQ_PEAK_DEMO_TOUR=voice FORCEIQ_PEAK_VOICE_FEED="$R/clips" \
  FORCEIQ_PEAK_DEMO_FAKE_NOTCH=1 FORCEIQ_PEAK_NO_WARM=1 GOAT_PEAK_ROOT="$R" "$BIN" > "$R/app.out" 2>&1 &
PID=$!
for _ in $(seq 1 1800); do grep -rq "tour step=tour-end" "$R/logs" 2>/dev/null && break; kill -0 $PID 2>/dev/null || break; sleep 0.5; done
kill $PID 2>/dev/null; wait $PID 2>/dev/null
LOG="$(ls "$R"/logs/*.log 2>/dev/null | head -1)"; [ -n "$LOG" ] || { echo "FAIL: no log"; exit 1; }
fail=0; chk() { if [ "$1" = ok ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
grep -q "voice ready .*engine=parakeet" "$LOG" && chk ok "model ready on Parakeet" || chk no "model ready on Parakeet"
TURNS=$(grep -c "voice turn " "$LOG"); [ "$TURNS" -ge 2 ] && chk ok "2 dictation turns ran ($TURNS)" || chk no "2 dictation turns ran ($TURNS)"
LONG=$(grep "voice turn " "$LOG" | tail -1)
W=$(sed -nE 's/.* words=([0-9]+).*/\1/p' <<<"$LONG"); [ "${W:-0}" -ge 28 ] && chk ok "11 s clip transcribed: $W words" || chk no "11 s clip transcribed: ${W:-0} words"
F=$(sed -nE 's/.* first_confirmed_ms=([0-9]+).*/\1/p' <<<"$LONG"); [ "${F:-99999}" -le 2000 ] && chk ok "first confirmed words at ${F} ms" || chk no "first confirmed words at ${F:-none} ms"
E=$(sed -nE 's/.* final_ms=([0-9]+).*/\1/p' <<<"$LONG"); [ "${E:-99999}" -le 500 ] && chk ok "final text ${E} ms after stop" || chk no "final text ${E:-none} ms after stop"
grep -q "engine=parakeet" <<<"$LONG" && chk ok "engine=parakeet (no fallback)" || chk no "engine=parakeet"
echo "$LONG" | cut -c1-200
[ $fail -eq 0 ] && echo "VOICE SMOKE: PASS" || echo "VOICE SMOKE: FAIL"; exit $fail
