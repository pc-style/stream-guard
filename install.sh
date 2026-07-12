#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/pc-style/stream-guard.git"
APP_NAME="PII Guard.app"
INSTALL_DIR="/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pii-guard.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "PII Guard requires macOS." >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Opening Apple's installer..."
  xcode-select --install >/dev/null 2>&1 || true
  echo "Finish the installation window. This script will continue automatically."

  for _ in {1..360}; do
    if xcode-select -p >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Command Line Tools installation didn't finish. Run this command again when it is complete." >&2
  exit 1
fi

for command in git swift codesign plutil ditto; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing $command. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  fi
done

echo "Downloading PII Guard..."
git clone --depth 1 --quiet "$REPO_URL" "$WORK_DIR/source"

echo "Building PII Guard locally..."
"$WORK_DIR/source/scripts/package.sh"

echo "Installing PII Guard in /Applications..."
pkill -f '/PII Guard.app/Contents/MacOS/PIIGuard' >/dev/null 2>&1 || true
rm -rf "$INSTALL_PATH"
ditto "$WORK_DIR/source/dist/$APP_NAME" "$INSTALL_PATH"

codesign --verify --deep --strict "$INSTALL_PATH"
plutil -lint "$INSTALL_PATH/Contents/Info.plist" >/dev/null

echo "Installed $INSTALL_PATH"
echo "If macOS keeps asking for permission, remove old PII Guard rows from Accessibility and Screen Recording, then reopen the app."
open "$INSTALL_PATH"
