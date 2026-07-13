# PII Guard

PII Guard gives you a delayed, protected screen-sharing preview on macOS. Share the **PII Guard Preview** window instead of your display. If visible Accessibility text matches an email, phone number, payment card, PESEL, IP address, or custom phrase, the preview turns black immediately.

Everything runs locally. PII Guard uses ScreenCaptureKit, Accessibility text geometry, and optional on-device Vision OCR in the Safe preset. It never sends screen contents anywhere.

## Install

PII Guard isn't signed with a paid Apple Developer certificate yet, so it has to be built locally. You only need macOS 13 or newer and Xcode Command Line Tools, not full Xcode.

Resolve the current main-branch commit once, build it locally, verify the staged app, replace the installed app with rollback protection, and launch PII Guard with one command:

```sh
curl -fsSL https://install.pcstyle.dev/stream-guard.sh | bash
```

The installer prints the exact commit it resolved before building. For a reproducible install, download the script and run it with `PII_GUARD_REF=<40-character-commit-sha>`.

The app is installed at `/Applications/PII Guard.app`. On first launch, use **Open Privacy Settings** until Accessibility and Screen Recording both show as allowed, then start the protected preview. If permission stays stuck after reinstalling, remove older PII Guard entries from both privacy lists and open the app again.

## Use it

1. Open PII Guard and grant both permissions.
2. Start the protected preview; the default tuning is suitable for normal use.
3. Wait until both the controls and preview say the preview is safe to share.
4. Share the **PII Guard Preview** window in Zoom, Meet, OBS, or another streaming app.

Delay, resolution, frame rate, detection rules, clearance mode, and editable custom phrases remain available under **Show advanced settings**. Closing the controls does not close or hide the preview.

The app can record the protected delayed preview to MP4. Recordings are saved wherever you choose in the save dialog.

## Build from source

```sh
git clone https://github.com/pc-style/stream-guard.git
cd stream-guard
./scripts/test.sh
swift run PIIGuardVerifier
./scripts/package.sh
```

`scripts/test.sh` runs `swift test`, adding the framework search path and rpaths the Command Line Tools need for Swift Testing. With full Xcode selected it is equivalent to plain `swift test`.

The packaged app is written to `dist/PII Guard.app`. The companion CLI is written to `dist/pii-guard` and supports `status`, `start`, `stop`, `permission`, `check <text>`, and `check --stdin`. Prefer stdin for sensitive values so they do not appear in shell history or process arguments:

```sh
printf '%s' 'private text' | dist/pii-guard check --stdin
```

## Privacy

PII Guard processes capture frames, Accessibility text, and Safe-preset OCR on your Mac. It has no analytics, accounts, cloud processing, or remote API calls. Coverage failures remain masked or blocked rather than being treated as clean.

## Website

The launch site is plain HTML, CSS, and JavaScript at the repository root. Vercel can deploy it without a build command.
