# PII Guard

PII Guard gives you a delayed, protected screen-sharing preview on macOS. Share the **PII Guard Preview** window instead of your display. If visible Accessibility text matches an email, phone number, payment card, PESEL, IP address, or custom phrase, the preview turns black immediately.

Everything runs locally. PII Guard uses ScreenCaptureKit for the delayed preview and Accessibility for text detection. It doesn't use OCR or send screen contents anywhere.

> [!IMPORTANT]
> **Status: beta.** Detection is limited to text that apps expose through macOS Accessibility. Treat the preview's safety status—not the presence of the app—as the condition for sharing. The current compatibility target is macOS 13 or newer with Swift 6.1 tooling.

## Install

PII Guard isn't Developer ID signed or notarized, so it has to be built and ad-hoc signed locally. You only need macOS 13 or newer and Xcode Command Line Tools, not full Xcode.

There is no tagged release yet. Download the installer from an immutable commit, verify its SHA-256 digest, and make it build that same commit:

```sh
REF=aae8d32bca238625ad05ee72e9251e0ff222ddc3
EXPECTED=ace8212e4606fb922638362075cd526fb2b9c42dbe579a78c54072739c5e0088
SCRIPT="$(mktemp -t pii-guard-install)"
curl -fsSL "https://raw.githubusercontent.com/pc-style/stream-guard/$REF/install.sh" -o "$SCRIPT"
printf '%s  %s\n' "$EXPECTED" "$SCRIPT" | shasum -a 256 -c -
PII_GUARD_REF="$REF" bash "$SCRIPT"
rm -f "$SCRIPT"
```

The installer verifies the requested 40-character source commit after fetching it, builds and checks the app bundle, and replaces an existing installation with rollback protection. The checksum covers the installer script; there are no signed release artifacts yet. Review and update both `REF` and `EXPECTED` deliberately when upgrading.

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

The app processes capture frames and Accessibility text on your Mac. It has no analytics, accounts, cloud processing, OCR, or remote API calls. Custom phrases stay in local macOS preferences. Optional MP4 recordings contain the protected delayed preview and are written only to the location you choose.

PII Guard blacks out the entire preview when a match or inconclusive scan occurs; it does not redact individual regions. Apps that don't expose readable Accessibility text are treated as unsupported, so check the status shown in the app before sharing. The project does not guarantee that every sensitive value will match a detector.

## Provenance and license

The repository retains its original `stream-guard` name; the current app and command-line tool are named **PII Guard**. This is the canonical implementation and has no successor. The source is available under the [MIT license](LICENSE).

## Website

The launch site is plain HTML, CSS, and JavaScript at the repository root. Vercel can deploy it without a build command. Unlike the app, the website loads third-party font and animation assets in the browser.
