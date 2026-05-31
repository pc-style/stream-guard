# OBS Protector Setup

Stream Guard can protect viewers only if OBS streams a delayed copy of the risky source while Stream Guard watches the live source. A normal stream delay applied after OBS has rendered the scene does not hide the unsafe frames; it only shows them later.

This repo includes an OBS Lua companion script:

`obs/stream_guard_protector.lua`

It creates:

- `STREAM_GUARD_PROTECTED` scene: the scene you stream/record.
- A delayed copy of your selected live source.
- `STREAM_GUARD_BLACKOUT` source: a hidden full-screen color source above the delayed source.

When Stream Guard arms, it toggles `STREAM_GUARD_BLACKOUT` visible through obs-websocket. Because the source underneath is delayed, the blackout can appear before unsafe delayed frames reach viewers.

## Requirements

- OBS with obs-websocket v5 enabled (OBS 28+ includes it).
- No websocket password for the current Stream Guard client.
- Stream Guard and OBS on the same machine, or reachable over the configured host/port.

## OBS Steps

1. Open OBS.
2. Create or choose the source that represents the real live content you want to protect (for example, Display Capture, Window Capture, or a scene used as a source).
3. Go to `Tools -> Scripts`.
4. Press `+` and load `obs/stream_guard_protector.lua`.
5. In the script settings:
   - `Live source to delay`: choose the live source.
   - `Protected scene delay`: start with `3000` ms. Use more if OCR sometimes takes longer.
   - Keep `Leave blackout visible after setup` disabled.
6. Press `Create / update protected scene`.
7. Stream or record `STREAM_GUARD_PROTECTED`, not the original live scene.

Stream Guard should still monitor the live screen/source, not the delayed OBS program.

## Stream Guard Config

Edit:

`~/Library/Application Support/StreamGuard/blocklist.json`

Use source mode:

```json
"obs": {
  "enabled": true,
  "host": "127.0.0.1",
  "port": 4455,
  "controlMode": "source",
  "blackoutScene": "BLACKOUT",
  "protectedScene": "STREAM_GUARD_PROTECTED",
  "blackoutSource": "STREAM_GUARD_BLACKOUT"
}
```

`blackoutScene` remains for legacy scene switching. In `source` mode, Stream Guard toggles `blackoutSource` inside `protectedScene`.

## Delay Sizing

Set delay greater than your worst-case detection plus OBS reaction time:

```text
protected_delay >= detection_p95 + OBS_toggle_time + safety_margin
```

Practical starting points:

- `3000` ms for tuned full-frame OCR setups.
- `5000` ms if yodo/ROI OCR can take multiple passes.
- `10000` ms if false negatives are unacceptable.

## Notes

- The Lua script uses OBS's Render Delay filter (`gpu_delay`) on the selected live source.
- If OBS cannot create the Render Delay filter on your source, add OBS's `Render Delay` filter manually to that source, then keep the protected scene and blackout source names above.
- Source toggling is faster than switching whole scenes and avoids round-tripping through `GetCurrentProgramScene` on every arm.
