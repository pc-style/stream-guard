#!/usr/bin/env bash
set -euo pipefail
LABEL="dev.pcstyle.stream-guard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/Stream Guard.app"
printf 'uninstalled Stream Guard app and LaunchAgent\n'
