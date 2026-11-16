#!/bin/bash
# Build "ForceIQ Peek.app" into peak/build/ (modeled on the GOAT app's build.sh). Builds only: never installs, never
# launches, never adds a login item. SwiftPM scratch + TMPDIR live under ~/ForceIQ/ (override PEAK_SCRATCH / PEAK_TMPDIR).
set -euo pipefail
cd "$(dirname "$0")"
SCRATCH="${PEAK_SCRATCH:-$HOME/ForceIQ/peak-derived/$(basename "$(cd .. && pwd)")}"
export TMPDIR="${PEAK_TMPDIR:-$HOME/ForceIQ/peak-tmp}"
CACHE="${PEAK_SPM_CACHE:-$HOME/ForceIQ/peak-derived/swiftpm-cache}"
mkdir -p "$SCRATCH" "$TMPDIR" "$CACHE"
nice -n 10 swift build -c release --scratch-path "$SCRATCH" --cache-path "$CACHE" --product ForceIQPeak
BIN="$(swift build -c release --scratch-path "$SCRATCH" --cache-path "$CACHE" --show-bin-path)"
APPB="build/ForceIQ Peek.app"
rm -rf "$APPB.new" && mkdir -p "$APPB.new/Contents/MacOS" "$APPB.new/Contents/Resources"
cp "$BIN/ForceIQPeak" "$APPB.new/Contents/MacOS/ForceIQPeak"
cp Info.plist "$APPB.new/Contents/Info.plist"
# The app icon (the eyes mark; scripts/make_icon.py writes it). It is also the About panel art: the standard About panel shows it.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APPB.new/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APPB.new/Contents/PkgInfo"
# BOB Motion ForceIQ-Peek-BOB-v1 (h264-black, 64 + 128 px, + its state data). See Resources/ASSETS.md for source + MD5s.
# Missing -> the app shows the labelled vector placeholder.
[ -d Resources/bob ] && cp -R Resources/bob "$APPB.new/Contents/Resources/bob"
# BOB Motion ForceIQ-Peek-3PO-v1 (3PO chat droid): MANIFEST.json, rig/3po.usdz (live RealityKit rig), hevc_alpha 64 px
# loops + transitions, the neutral still. See Resources/ASSETS.md. Missing -> rendered loops -> the static droid mark.
[ -d Resources/threepo ] && cp -R Resources/threepo "$APPB.new/Contents/Resources/threepo"
# Cua child (desktop actions, Cua backend; gated off by default): the runner Peek spawns with ~/ForceIQ/.venv-peak-cua.
mkdir -p "$APPB.new/Contents/Resources/cua" && cp cua/peak_cua_runner.py "$APPB.new/Contents/Resources/cua/peak_cua_runner.py"
# The Claude watcher relay (spec §3): the app installs it into ~/Library/Application Support/ForceIQPeek/
# and merges its hooks into ~/.claude/settings.json while the agents module is on.
mkdir -p "$APPB.new/Contents/Resources/relay" && cp relay/peek-hook relay/peek-hook.py "$APPB.new/Contents/Resources/relay/"
# KeyboardShortcuts' localized strings (SwiftPM resource bundle).
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APPB.new/Contents/Resources/"; done
# Metal glow: compiled only when this Mac's Xcode has the Metal toolchain; otherwise the native SwiftUI glow is used.
if xcrun -f metal >/dev/null 2>&1 && xcrun metal -c Shaders/GhostGlow.metal -o "$TMPDIR/GhostGlow.air" >/dev/null 2>&1 \
   && xcrun metallib "$TMPDIR/GhostGlow.air" -o "$APPB.new/Contents/Resources/default.metallib" >/dev/null 2>&1; then
  echo "metal glow: compiled"
else
  echo "warning: Metal toolchain not available (xcodebuild -downloadComponent MetalToolchain); Peek uses the native SwiftUI glow" >&2
fi
rm -f "$TMPDIR/GhostGlow.air"
# Signing: the per-Mac identity from the private overlay (same file GOAT's build.sh reads), else ad-hoc.
IDENT=""; [ -f ../overlay/codesign-identity ] && IDENT="$(head -1 ../overlay/codesign-identity | tr -d '\r')"
if [ -n "$IDENT" ]; then
  codesign --force --deep --sign "$IDENT" --identifier com.forceiq.peak --timestamp=none "$APPB.new" >/dev/null
else
  echo "warning: no overlay/codesign-identity on this Mac: ad-hoc signature" >&2
  codesign --force --deep --sign - --identifier com.forceiq.peak "$APPB.new" >/dev/null
fi
rm -rf "$APPB" && mv "$APPB.new" "$APPB"
echo "built: $(pwd)/$APPB"
