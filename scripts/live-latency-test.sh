#!/usr/bin/env bash
# Wrapper kept for compatibility — runs the full E2E harness.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-live-test.py" "$@"
