#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Stream Guard.app"
DEST="$HOME/Applications/Stream Guard.app"
if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/package-app.sh" >/dev/null
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
printf '%s\n' "$DEST"
