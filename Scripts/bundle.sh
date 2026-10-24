#!/bin/bash
# Assembles build/Plugboard.app from the compiled binary and Resources/, then signs it.
#
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
#   SIGN_IDENTITY="Developer ID Application: …"  sign for distribution (hardened runtime).
#                                                 Without it the app is signed ad hoc,
#                                                 which is fine on the Mac that built it.
#   ARCHS="arm64"                                 passed through to Scripts/build.sh

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Plugboard.app"
CONTENTS="$APP/Contents"

"$ROOT/Scripts/build.sh" "$CONFIG"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "▸ Drawing the app icon"
    mkdir -p "$ROOT/.build-swiftc/tools"
    swiftc -O -sdk "$(xcrun --show-sdk-path)" "$ROOT/Scripts/make-icon.swift" -o "$ROOT/.build-swiftc/tools/make-icon"
    "$ROOT/.build-swiftc/tools/make-icon" "$ROOT"
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build-swiftc/$CONFIG/Plugboard" "$CONTENTS/MacOS/Plugboard"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
for lproj in "$ROOT"/Resources/*.lproj; do
    cp -R "$lproj" "$CONTENTS/Resources/"
done
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Stamp the build number from the date, so every build is distinguishable in About.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "▸ Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/Resources/Plugboard.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "✓ $APP"
