#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Stream Guard.app"
BIN="$ROOT/.build/debug/StreamGuard"
INFO="$ROOT/Resources/Info.plist"
RESOURCES="$APP/Contents/Resources"

swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp "$BIN" "$APP/Contents/MacOS/StreamGuard"
cp "$INFO" "$APP/Contents/Info.plist"
cp "$ROOT/obs/stream_guard_protector.lua" "$RESOURCES/stream_guard_protector.lua"
cp "$ROOT/Sources/StreamGuard/Resources/blocklist.default.json" "$RESOURCES/blocklist.default.json"
cp "$ROOT/Sources/StreamGuard/Resources/status.html" "$RESOURCES/status.html"
chmod +x "$APP/Contents/MacOS/StreamGuard"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
test -x "$APP/Contents/MacOS/StreamGuard"
printf '%s\n' "$APP"
