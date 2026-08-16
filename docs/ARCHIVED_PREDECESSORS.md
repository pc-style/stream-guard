# Archived predecessor review

On 2026-08-16, the complete default and non-default branch trees of two predecessor
repositories were reviewed before archival. Their git histories and branches remain in
the archived repositories; this project remains the canonical successor.

## `pc-style/PII-Stream-Guard` (public)

The predecessor explored Vision OCR, Accessibility scanning, delayed masking,
protected recording, remote processing, benchmarking, and synthetic regression
scenarios. The useful design lesson retained here is to fail closed and expose a
verifiable protected preview. No source or assets were copied: the repository has no
license, its committed frame fixtures were not sufficiently attributable for
redistribution, and some notes were generated or AI-authored. Its raw-frame remote
server mode, including its `0.0.0.0` setup, was intentionally not transferred or
promoted. The successor instead keeps screen contents local and does not use OCR or a
remote API.

## `pc-style/stream` (private)

The prototype compared a bundled YOLO/CoreML detector and redaction renderer using a
synthetic latency harness. It reinforced the value of measuring model load, inference,
render, and end-to-end latency separately, and of failing closed when inference fails.
No implementation, benchmark artifact, media, test page, binary, dataset, or model was
transferred. The repository has no license, and the provenance and redistribution
rights of its model/export and generated vendor artifacts could not be established
from repository history. Reported measurements were therefore not carried forward as
successor claims.
