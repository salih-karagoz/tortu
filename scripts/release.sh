#!/bin/bash
# Builds, signs, notarises and packages Tortu for distribution.
#
# Requires a "Developer ID Application" identity in the keychain and a
# notarytool keychain profile. Neither is in this repository; see RELEASING.md.
set -euo pipefail

PROFILE="${TORTU_NOTARY_PROFILE:-TortuNotary}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"

cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen gerekli: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
[ -n "$VERSION" ] || { echo "project.yml icinde MARKETING_VERSION yok"; exit 1; }
DMG="$DIST/Tortu-$VERSION.dmg"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

# archive plus exportArchive rather than a plain build: a development build
# carries com.apple.security.get-task-allow, and the notary service rejects
# any executable that asks for it.
echo "==> [1/6] arsiv olusturuluyor"
xcodebuild -project Tortu.xcodeproj -scheme Tortu -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$BUILD/Tortu.xcarchive" \
  archive >/dev/null

echo "==> [2/6] Developer ID olarak disa aktariliyor"
xcodebuild -exportArchive -archivePath "$BUILD/Tortu.xcarchive" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
  -exportPath "$BUILD/export" >/dev/null

APP="$BUILD/export/Tortu.app"
[ -d "$APP" ] || { echo "Tortu.app disa aktarilamadi"; exit 1; }

codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "HATA: get-task-allow hala pakette, notarizasyon reddeder"; exit 1
fi

# The app is notarised on its own first, so that a ticket is stapled into the
# bundle. Stapling only the disk image would leave a copy dragged out of it
# relying on an online check, which fails for anyone offline.
echo "==> [3/6] uygulama notarize ediliyor"
ditto -c -k --keepParent "$APP" "$BUILD/Tortu.zip"
xcrun notarytool submit "$BUILD/Tortu.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> [4/6] DMG hazirlaniyor"
STAGING="$BUILD/staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Tortu" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "==> [5/6] DMG notarize ediliyor"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> [6/6] Gatekeeper kontrolu"
spctl -a -vv -t exec "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"

echo
echo "hazir: $DMG"
shasum -a 256 "$DMG"
