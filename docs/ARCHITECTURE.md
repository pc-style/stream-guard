# Stream Guard Architecture

Stream Guard is a macOS menu-bar app that captures the screen, runs on-device OCR (Apple Vision), detects PII and blocklisted phrases, and triggers protective actions.

## Pipeline

```
ScreenCaptureKit → frame diff gate → downscale (1280px) → Vision OCR (.fast)
  → rolling text merge → PII regex + Aho-Corasick + fuzzy match
  → hysteresis (CLEAR | SUSPECT | ARMED) → blackout overlay + web status + OBS
```

## Build

Requires Xcode Command Line Tools only (no Xcode.app):

```bash
make build
make run
make test
```

Info.plist is embedded at link time for screen capture permission strings and LSUIElement menu-bar mode.

## Configuration

User config: `~/Library/Application Support/StreamGuard/blocklist.json`

Hot-reloads on file change. Defaults ship in `Resources/blocklist.default.json`.

## Status UI

While running, open `http://127.0.0.1:8765/` for live state via HTTP `/status` and WebSocket `/events`.

## OBS

Set `obs.enabled` to `true` in config. On ARMED, switches to `blackoutScene`; on CLEAR, restores the previous program scene.
