#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/pc-style/stream-guard.git"
DEFAULT_REF="refs/heads/main"
INSTALL_REF="${PII_GUARD_REF:-$DEFAULT_REF}"
APP_NAME="PII Guard.app"
INSTALL_DIR="/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pii-guard.XXXXXX")"
STAGE_PATH="$INSTALL_DIR/.PII Guard.stage.$$"
BACKUP_PATH="$INSTALL_DIR/.PII Guard.backup.$$"

cleanup() {
  local status=$?
  set +e
  rm -rf "$WORK_DIR" "$STAGE_PATH"
  if [[ -e "$BACKUP_PATH" ]]; then
    if [[ $status -ne 0 ]]; then
      rm -rf "$INSTALL_PATH"
      mv "$BACKUP_PATH" "$INSTALL_PATH"
      printf '%s\n' "Installation did not complete; the previous app was restored." >&2
    else
      rm -rf "$BACKUP_PATH"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' "PII Guard requires macOS." >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  printf '%s\n' "Xcode Command Line Tools are required. Opening Apple's installer..."
  xcode-select --install >/dev/null 2>&1 || true
  printf '%s\n' "Finish the installation window. This script will continue automatically."

  for _ in {1..360}; do
    if xcode-select -p >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
fi

if ! xcode-select -p >/dev/null 2>&1; then
  printf '%s\n' "Command Line Tools installation didn't finish. Run this command again when it is complete." >&2
  exit 1
fi

for command in git swift codesign plutil ditto; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Missing %s. Install Xcode Command Line Tools with: xcode-select --install\n' "$command" >&2
    exit 1
  fi
done

printf 'Resolving PII Guard source revision %s...\n' "$INSTALL_REF"
git -C "$WORK_DIR" init --quiet source
git -C "$WORK_DIR/source" remote add origin "$REPO_URL"
git -C "$WORK_DIR/source" fetch --depth 1 --quiet origin "$INSTALL_REF"
git -C "$WORK_DIR/source" checkout --detach --quiet FETCH_HEAD
RESOLVED_REF="$(git -C "$WORK_DIR/source" rev-parse HEAD)"
if [[ "$INSTALL_REF" =~ ^[0-9a-fA-F]{40}$ ]] && [[ "${RESOLVED_REF,,}" != "${INSTALL_REF,,}" ]]; then
  printf 'Downloaded revision %s did not match requested revision %s.\n' "$RESOLVED_REF" "$INSTALL_REF" >&2
  exit 1
fi
printf 'Building verified source revision %s.\n' "$RESOLVED_REF"

printf '%s\n' "Building PII Guard locally..."
"$WORK_DIR/source/scripts/package.sh"

printf '%s\n' "Verifying staged PII Guard app..."
rm -rf "$STAGE_PATH" "$BACKUP_PATH"
ditto "$WORK_DIR/source/dist/$APP_NAME" "$STAGE_PATH"
codesign --verify --deep --strict "$STAGE_PATH"
plutil -lint "$STAGE_PATH/Contents/Info.plist" >/dev/null

printf '%s\n' "Installing PII Guard in /Applications..."
pkill -f '/PII Guard.app/Contents/MacOS/PIIGuard' >/dev/null 2>&1 || true
if [[ -e "$INSTALL_PATH" ]]; then
  mv "$INSTALL_PATH" "$BACKUP_PATH"
fi
mv "$STAGE_PATH" "$INSTALL_PATH"

codesign --verify --deep --strict "$INSTALL_PATH"
plutil -lint "$INSTALL_PATH/Contents/Info.plist" >/dev/null
open "$INSTALL_PATH"
rm -rf "$BACKUP_PATH"

printf 'Installed and launched verified revision %s at %s\n' "$RESOLVED_REF" "$INSTALL_PATH"
printf '%s\n' "If macOS keeps asking for permission, remove old PII Guard rows from Accessibility and Screen Recording, then reopen the app."
