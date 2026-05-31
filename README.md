# Stream Guard

Local macOS menu-bar app that watches your screen, runs on-device OCR (Apple Vision), and triggers blackout protection when PII or blocklisted phrases appear.

All processing stays on your Mac — no cloud OCR or telemetry.

## Requirements

- macOS 13+
- [Xcode Command Line Tools](https://developer.apple.com/download/all/) only (`xcode-select --install`) — full Xcode.app is **not** required

## Build and run

```bash
make build
make run          # menu-bar app (🛡 icon)
make test         # unit checks via StreamGuardTestRunner (no XCTest)
make live-test    # opens a fixture and measures live screen OCR time-to-armed
```

Grant **Screen Recording** when prompted. If permission was just granted, restart the app once (Apple requirement).

## Configuration

On first launch, defaults are copied to:

`~/Library/Application Support/StreamGuard/blocklist.json`

Edit that file to add phrases, toggle phone/email detection, hysteresis, and OBS settings. Changes reload automatically.

## Status page

While the app is running: [http://127.0.0.1:8765/](http://127.0.0.1:8765/) — JSON at `/status`, WebSocket events at `/events`.

## OBS (optional)

Set `"obs": { "enabled": true, ... }` in `blocklist.json`. Create a **BLACKOUT** scene in OBS; the app switches program scene on ARMED and restores the previous scene on CLEAR.

For viewer-safe delayed output, use the OBS companion script in `obs/stream_guard_protector.lua`. It creates a delayed protected scene and a `STREAM_GUARD_BLACKOUT` source that Stream Guard can toggle before unsafe delayed frames reach viewers. See `docs/OBS_PROTECTOR.md`.

## Tests

`make test` runs the `StreamGuardTestRunner` executable — a plain Swift test harness with `PASS`/`FAIL` output and a non-zero exit code on failure. No XCTest or full Xcode required.

`make live-test` runs the full live end-to-end harness (no XCTest, no manual menu clicks):

```bash
make live-test
```

First run creates `.venv-e2e` and installs Playwright + Chromium (`make live-test-deps`). The harness:

1. Launches Stream Guard and auto-starts monitoring
2. Opens **one** Playwright Chromium window and navigates in place (no tab spam)
3. For each pipeline mode (default: `yodo-ocr`, `roi`, `full`) and HTML fixture in `test-fixtures/`:
   - Switch mode via `POST /control/mode/*`
   - Navigate to the sensitive page → time until `armed` + overlay visible (match must look correct)
   - Navigate to `safe-control.html` → time until `clear` + overlay hidden
4. Print a summary table and write a log to `.stream-guard-test-logs/`

Override modes: `STREAM_GUARD_E2E_MODES=yodo-ocr make live-test`

Requires Screen Recording permission for Stream Guard. Keep the Playwright window visible on screen for capture. Do not open the status page during the run (it pollutes OCR).

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

[MIT](LICENSE)
