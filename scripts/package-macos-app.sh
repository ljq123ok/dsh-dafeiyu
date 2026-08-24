#!/usr/bin/env bash
# Package the Apple Silicon macOS helper into DafeiyuHelper.app so the helper
# runs with a real bundle identity (Bundle.main.bundleIdentifier != nil) — the
# prerequisite for UNUserNotificationCenter notification banners.
#
# Layout produced:
#   runtime/bin/darwin-arm64/DafeiyuHelper.app/
#     Contents/
#       Info.plist
#       MacOS/dsh-dafeiyu-helper          (the compiled Swift binary)
#       Resources/assets/…                (pet-manifest.json, pet/, sounds/)
#
# The plugin's helper-process.js prefers this .app over the bare binary, so the
# same repository works both as a dev checkout (bare binary) and packaged.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
APP="$ROOT/runtime/bin/darwin-arm64/DafeiyuHelper.app"
BIN="$APP/Contents/MacOS/dsh-dafeiyu-helper"

echo "building release helper..."
swift build --package-path "$ROOT/runtime/macos" -c release --arch arm64
BUILT="$ROOT/runtime/macos/.build/arm64-apple-macosx/release/DafeiyuHelper"

# In this repo the helper in the SwiftPM tree is the source; the deployment
# binary path may be a symlink (local plugin install links here).
BIN_SRC="$BUILT"

echo "assembling $APP..."
rm -rf "$APP"
mkdir -p "$(dirname "$BIN")" "$APP/Contents/Resources"
cp "$ROOT/runtime/macos/Info.plist" "$APP/Contents/Info.plist"
# ditto (not cp -R): excludes source extended attributes (com.apple.fileprovider.*),
# which make codesign reject the bundle with "detritus not allowed".
ditto "$ROOT/assets" "$APP/Contents/Resources/assets"
cp "$BIN_SRC" "$BIN"

PACKAGE_VERSION="$(node -p "require('$ROOT/package.json').version")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PACKAGE_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$APP/Contents/Info.plist"

echo "cleaning extended attributes (detritus-safe)..."
xattr -cr "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d com.apple.fileprovider.fpfs#P "$APP" 2>/dev/null || true
find "$APP" -name "._*" -delete 2>/dev/null || true

echo "signing (adhoc)..."
codesign --force --sign - "$APP"

echo "=== artifact ==="
ls -la "$APP/Contents/MacOS/" "$APP/Contents/Resources/assets/" | head -12
echo "=== bundle id ==="
defaults read "$APP/Contents/Info.plist" CFBundleIdentifier
echo "=== verify executable identity ==="
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Format" | head -3
echo "=== headless smoke out of the bundle ==="
printf '{"kind":"ping"}\n{"kind":"shutdown"}\n' | "$BIN" --headless 2>&1 | head -3
echo "OK: packaged $(basename "$APP")"
