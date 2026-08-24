#!/usr/bin/env bash
# Package the Apple Silicon macOS helper into DafeiyuHelper.app so the helper
# runs with a real bundle identity (Bundle.main.bundleIdentifier != nil) — the
# prerequisite for UNUserNotificationCenter notification banners.
#
# IMPORTANT: this repository tree lives under a cloud-file-provider path
# (Documents/…), which stamps every newly created directory with
# com.apple.fileprovider.* / FinderInfo xattrs. codesign rejects those as
# "detritus", so the bundle is assembled and signed in a mktemp dir (outside
# the provider tree) and then copied into runtime/bin/ and signed once more —
# the copy does not carry provider xattrs.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
APP="$ROOT/runtime/bin/darwin-arm64/DafeiyuHelper.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGED="$WORK/DafeiyuHelper.app"

echo "building release helper..."
swift build --package-path "$ROOT/runtime/macos" -c release --arch arm64
BUILT="$ROOT/runtime/macos/.build/arm64-apple-macosx/release/DafeiyuHelper"

echo "assembling $APP (staged in $WORK)..."
rm -rf "$APP"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp "$ROOT/runtime/macos/Info.plist" "$STAGED/Contents/Info.plist"
ditto "$ROOT/assets" "$STAGED/Contents/Resources/assets"
cp "$ROOT/scripts/assets/DafeiyuHelper.icns" "$STAGED/Contents/Resources/DafeiyuHelper.icns"
cp "$BUILT" "$STAGED/Contents/MacOS/dsh-dafeiyu-helper"

PACKAGE_VERSION="$(node -p "require('$ROOT/package.json').version")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PACKAGE_VERSION" "$STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$STAGED/Contents/Info.plist"

echo "signing (adhoc, staged)..."
codesign --force --sign - "$STAGED"

echo "copying into runtime/bin..."
cp -R "$STAGED" "$APP"

echo "signing final (post-copy)..."
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"

echo "=== artifact ==="
ls -la "$APP/Contents/MacOS/" "$APP/Contents/Resources/" | head -8
echo "=== verify ==="
codesign --verify --deep -v "$APP"
defaults read "$APP/Contents/Info" CFBundleIdentifier
echo "=== headless smoke ==="
printf '{"kind":"ping"}\n{"kind":"shutdown"}\n' | "$APP/Contents/MacOS/dsh-dafeiyu-helper" --headless | head -3
echo "OK: packaged $(basename "$APP")"
