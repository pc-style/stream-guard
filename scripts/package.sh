#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/PII Guard.app"

cd "$ROOT"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PIIGuard "$APP/Contents/MacOS/PIIGuard"
cp .build/release/pii-guard "$ROOT/dist/pii-guard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.pcstyle.piiguard.cli "$ROOT/dist/pii-guard"
codesign --verify --strict --verbose=2 "$ROOT/dist/pii-guard"
codesign --force --sign - --identifier dev.pcstyle.piiguard \
  -r='designated => identifier "dev.pcstyle.piiguard"' "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
chmod +x "$ROOT/dist/pii-guard"
echo "$APP"
