# Stream Guard Architecture

Stream Guard is a macOS menu-bar app that captures the screen, runs on-device OCR (Apple Vision), detects PII and blocklisted phrases, and triggers protective actions.

## Pipeline

```
ScreenCaptureKit → frame diff gate → downscale (1280px) → Vision OCR (.fast)
  → rolling text merge → OCR guard mode + PII regex + Aho-Corasick + fuzzy match
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

`filtering.mode` selects the OCR guard behavior:

- `blacklist` blocks built-in PII, legacy `phrases`, and custom blacklist entries.
- `whitelist` keeps built-in PII and legacy phrase protection, but prioritizes similarity-based whitelist suppression for known-safe OCR.
- `blurAll` is intentionally marked buggy and arms on any OCR token, so it can blur harmless content.

Each whitelist or blacklist entry carries a `minimumSimilarity` threshold. This lets near misses from Vision OCR, such as a damaged email or one missing character in a phrase, still match the intended rule without requiring cloud OCR or external services.

## Status UI

While running, open `http://127.0.0.1:8765/` for live state via HTTP `/status` and WebSocket `/events`.

## OBS

Set `obs.enabled` to `true` in config. On ARMED, switches to `blackoutScene`; on CLEAR, restores the previous program scene.
