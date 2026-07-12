# PII Guard

PII Guard gives you a delayed, protected screen-sharing preview on macOS. Share the **PII Guard Preview** window instead of your display. If visible Accessibility text matches an email, phone number, payment card, PESEL, IP address, or custom phrase, the preview turns black immediately.

Everything runs locally. PII Guard uses ScreenCaptureKit for the delayed preview and Accessibility for text detection. It doesn't use OCR or send screen contents anywhere.

## Install

PII Guard isn't signed with a paid Apple Developer certificate yet, so it has to be built locally. You only need macOS 13 or newer and Xcode Command Line Tools, not full Xcode.

Install the Command Line Tools once:

```sh
xcode-select --install
```

Then download, build, install, clean up, and launch PII Guard with one command:

```sh
curl -fsSL https://install.pcstyle.dev/stream-guard.sh | bash
```

The app is installed at `/Applications/PII Guard.app`. On first launch, allow Accessibility and Screen Recording when macOS asks. If permission stays stuck after reinstalling, remove older PII Guard entries from both privacy lists and open the app again.

## Use it

1. Open PII Guard and grant both permissions.
2. Pick the delay, resolution, FPS, detection rules, and clearance mode.
3. Start the preview.
4. Share the **PII Guard Preview** window in Zoom, Meet, OBS, or another streaming app.

The app can record the protected delayed preview to MP4. Recordings are saved wherever you choose in the save dialog.

## Build from source

```sh
git clone https://github.com/pc-style/stream-guard.git
cd stream-guard
swift run PIIGuardVerifier
./scripts/package.sh
```

The packaged app is written to `dist/PII Guard.app`. The companion CLI is written to `dist/pii-guard` and supports `status`, `start`, `stop`, `permission`, and `check <text>`.

## Privacy

PII Guard processes capture frames and Accessibility text on your Mac. It has no analytics, accounts, cloud processing, OCR, or remote API calls. Apps that don't expose readable Accessibility text are treated as unsupported, so check the status shown in the app before sharing.
