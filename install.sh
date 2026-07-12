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

for command in git swift codesign plutil ditto; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing $command. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  fi
done

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi

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
