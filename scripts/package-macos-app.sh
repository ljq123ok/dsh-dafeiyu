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
# App icon: generate the .icns from the idle pet PNG (centered crop to square)
# if it is not already present under assets/ (dev builds regenerate).
ICNS="$ROOT/assets/DafeiyuHelper.icns"
if [ ! -f "$ICNS" ]; then
  echo "generating app icon..."
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/iconset"
  sips -c 195 195 "$ROOT/assets/pet/idle_front/idle_front_238.png" --out "$WORK/square.png" >/dev/null 2>&1
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/square.png" --out "$WORK/iconset/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z "$((size * 2))" "$((size * 2))" "$WORK/square.png" --out "$WORK/iconset/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$WORK/iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/DafeiyuHelper.icns"
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
