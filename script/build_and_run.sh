#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/PII Guard.app"

pkill -f '/PII Guard.app/Contents/MacOS/PIIGuard' >/dev/null 2>&1 || true
"$ROOT_DIR/scripts/package.sh"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/PIIGuard" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate 'process == "PIIGuard"' ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.pcstyle.piiguard"' ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -f '/PII Guard.app/Contents/MacOS/PIIGuard' >/dev/null
    echo "PII Guard launched successfully"
    ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
