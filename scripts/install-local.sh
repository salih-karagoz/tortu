#!/bin/bash
# Builds Tortu and replaces the copy in /Applications, without notarising.
#
# For iterating. Notarisation only matters for a build that will travel to
# another Mac: a bundle copied here never carries the quarantine flag, so
# Gatekeeper does not check it. Use scripts/release.sh for anything you hand
# to someone else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Release}"
DERIVED="$ROOT/build/local"
APP="$DERIVED/Build/Products/$CONFIG/Tortu.app"

cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen gerekli: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

# ONLY_ACTIVE_ARCH: a Release build is universal by default, and compiling
# the second architecture of this module as well is both pointless here and
# heavy enough that the frontend has been killed part way through it.
echo "==> [1/4] $CONFIG derleniyor (yalnizca $(uname -m))"
# Kept in a log rather than on screen: `-quiet` still prints a spurious
# "failed with exit code 0" line, and the real errors are easier to read in
# one place when something does go wrong.
LOG="$ROOT/build/install-local.log"
mkdir -p "$ROOT/build"
if ! xcodebuild -project Tortu.xcodeproj -scheme Tortu -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=YES build > "$LOG" 2>&1; then
  grep -E "error: " "$LOG" | sort -u | head -20
  echo "tam gunluk: $LOG"
  exit 1
fi
[ -d "$APP" ] || { echo "derleme ciktisi yok: $APP"; exit 1; }

echo "==> [2/4] calisan kopya kapatiliyor"
osascript -e 'tell application "Tortu" to quit' >/dev/null 2>&1 || true
pkill -f "Tortu.app/Contents/MacOS/Tortu" >/dev/null 2>&1 || true
sleep 1

echo "==> [3/4] /Applications/Tortu.app degistiriliyor"
# Replaced whole rather than copied over: a stale file left inside the bundle
# invalidates the signature, and the failure shows up as a refusal to launch
# with nothing useful in the log.
rm -rf "/Applications/Tortu.app"
cp -R "$APP" /Applications/
codesign --verify --strict "/Applications/Tortu.app" \
  && codesign -dvv "/Applications/Tortu.app" 2>&1 | grep -E "Authority=|TeamIdentifier" || true

echo "==> [4/4] aciliyor"
open -a "/Applications/Tortu.app"
echo "hazir"
