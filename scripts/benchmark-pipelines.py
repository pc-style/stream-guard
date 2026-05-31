#!/usr/bin/env python3
"""Benchmark Stream Guard pipeline modes against the live screen.

This is intentionally not XCTest/Xcode based. It launches the SwiftPM debug
binary, drives Chromium through local HTML fixtures, switches pipeline modes via
the local status server, and summarizes the metrics each mode actually exposes.
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from playwright.sync_api import Page

ROOT = Path(__file__).resolve().parent.parent
STATUS_URL = os.environ.get("STREAM_GUARD_STATUS_URL", "http://127.0.0.1:8765/status")
CONTROL_BASE_URL = STATUS_URL.replace("/status", "/control")
FIXTURE_DIR = ROOT / "test-fixtures"
CLEAR_PAGE = FIXTURE_DIR / "safe-control.html"
FIXTURE_PAGES = [
    "fake-terminal.html",
    "card-fixture.html",
    "split-frame.html",
]
MODES = ["full", "roi", "yodo-ocr", "yodo"]
MODE_NAMES = {
    "full": "fullFrame",
    "roi": "roiCascade",
    "yodo": "yodoMask",
    "yodo-ocr": "yodoOCR",
}
SAMPLE_SECONDS = float(os.environ.get("STREAM_GUARD_BENCH_SAMPLE_SECONDS", "4.0"))
POLL_SECONDS = float(os.environ.get("STREAM_GUARD_BENCH_POLL_SECONDS", "0.08"))
SETTLE_SECONDS = float(os.environ.get("STREAM_GUARD_BENCH_SETTLE_SECONDS", "1.0"))
TIMEOUT_SECONDS = float(os.environ.get("STREAM_GUARD_BENCH_TIMEOUT_SECONDS", "30"))
LOG_DIR = ROOT / ".stream-guard-test-logs"


@dataclass
class BenchResult:
    mode: str
    fixture: str
    samples: int
    ocr_frames_delta: int
    first_arm_ms: float | None
    first_mask_ms: float | None
    first_frame_ms: float | None
    first_pipeline_ms: float | None
    first_preprocess_done_ms: float | None
    first_ocr_started_ms: float | None
    first_ocr_done_ms: float | None
    first_state_transition_ms: float | None
    armed_frame_to_pipeline_ms: float | None
    armed_pipeline_to_preprocess_ms: float | None
    armed_preprocess_to_ocr_done_ms: float | None
    armed_ocr_done_to_armed_ms: float | None
    armed_frame_to_armed_ms: float | None
    median_ocr_ms: float | None
    p95_ocr_ms: float | None
    median_preprocess_ms: float | None
    median_roi_images: float | None
    median_text_coverage: float | None
    median_yodo_coverage: float | None
    max_yodo_coverage: float | None
    final_state: str | None
    final_match: str | None


def log(message: str, log_file: Path) -> None:
    line = f"{datetime.now().strftime('%H:%M:%S')} {message}"
    print(line, flush=True)
    with log_file.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def fetch_status() -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(STATUS_URL, timeout=1.5) as resp:
            return json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return None


def post_control(path: str) -> None:
    urllib.request.urlopen(
        urllib.request.Request(f"{CONTROL_BASE_URL}/{path}", method="POST"),
        timeout=2,
    ).read()


def wait_for_status(timeout_s: float = TIMEOUT_SECONDS) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if fetch_status() is not None:
            return True
        time.sleep(0.2)
    return False


def wait_for_monitoring(timeout_s: float = TIMEOUT_SECONDS) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = fetch_status()
        if status and status.get("monitoring") is True:
            return True
        time.sleep(0.2)
    return False


def ensure_monitoring() -> bool:
    status = fetch_status()
    if status and status.get("monitoring") is True:
        return True
    try:
        post_control("start")
    except urllib.error.URLError:
        pass
    return wait_for_monitoring()


def e2e_python() -> str:
    venv_python = ROOT / ".venv-e2e" / "bin" / "python"
    return str(venv_python) if venv_python.exists() else sys.executable


def ensure_playwright(log_file: Path) -> None:
    py = e2e_python()
    try:
        subprocess.run([py, "-c", "import playwright"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        log("playwright missing - run: make live-test-deps", log_file)
        raise SystemExit(1) from None


def file_uri(path: Path) -> str:
    return path.resolve().as_uri()


class Browser:
    def __init__(self, log_file: Path) -> None:
        self.log_file = log_file
        self._playwright = None
        self._browser = None
        self._context = None
        self.page: Page | None = None

    def __enter__(self) -> Browser:
        from playwright.sync_api import sync_playwright

        self._playwright = sync_playwright().start()
        self._browser = self._playwright.chromium.launch(headless=False)
        self._context = self._browser.new_context(
            viewport={"width": 1440, "height": 900},
            device_scale_factor=1,
        )
        self.page = self._context.new_page()
        log("playwright: chromium started", self.log_file)
        return self

    def __exit__(self, *_args) -> None:
        if self._context:
            self._context.close()
        if self._browser:
            self._browser.close()
        if self._playwright:
            self._playwright.stop()

    def goto(self, path: Path) -> None:
        assert self.page is not None
        self.page.goto(file_uri(path), wait_until="domcontentloaded")
        self.page.bring_to_front()


def launch_app(log_file: Path) -> subprocess.Popen:
    env = os.environ.copy()
    env["STREAM_GUARD_AUTO_START"] = "1"
    binary = ROOT / ".build" / "debug" / "StreamGuard"
    if not binary.exists():
        log("debug binary missing; run `make build` first", log_file)
        raise SystemExit(1)
    log("launching StreamGuard with STREAM_GUARD_AUTO_START=1", log_file)
    return subprocess.Popen(
        [str(binary)],
        cwd=ROOT,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def numeric_values(samples: list[dict[str, Any]], key: str) -> list[float]:
    values: list[float] = []
    for sample in samples:
        value = sample.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def percentile(values: list[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * percent)))
    return ordered[index]


def elapsed_since_start_ms(value: Any, start: float) -> float | None:
    if not isinstance(value, (int, float)):
        return None
    if float(value) < start:
        return None
    return max(0.0, (float(value) - start) * 1000)


def collect_samples(duration_s: float) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    deadline = time.time() + duration_s
    while time.time() < deadline:
        status = fetch_status()
        if status is not None:
            samples.append(status)
        time.sleep(POLL_SECONDS)
    return samples


def wait_until_clear(timeout_s: float = TIMEOUT_SECONDS) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = fetch_status()
        if status and status.get("state") == "clear" and status.get("overlayVisible") is False:
            return True
        time.sleep(POLL_SECONDS)
    return False


def benchmark_fixture(mode: str, fixture: Path, browser: Browser, log_file: Path) -> BenchResult:
    post_control(f"mode/{mode}")
    time.sleep(0.2)

    browser.goto(CLEAR_PAGE)
    time.sleep(SETTLE_SECONDS)
    if not wait_until_clear():
        raise RuntimeError(f"{fixture.name}: timed out waiting for clear state before benchmark sample")

    before = fetch_status() or {}
    before_ocr_frames = int(before.get("ocrFrames") or 0)
    start = time.time()
    browser.goto(fixture)
    samples = collect_samples(SAMPLE_SECONDS)

    first_arm_ms = None
    first_mask_ms = None
    first_frame_ms = None
    first_pipeline_ms = None
    first_preprocess_done_ms = None
    first_ocr_started_ms = None
    first_ocr_done_ms = None
    first_state_transition_ms = None
    armed_sample: dict[str, Any] | None = None
    for sample in samples:
        timestamp = sample.get("timestamp")
        if not isinstance(timestamp, (int, float)):
            continue
        elapsed_ms = max(0.0, (float(timestamp) - start) * 1000)
        if first_frame_ms is None:
            first_frame_ms = elapsed_since_start_ms(sample.get("lastFrameReceivedAt"), start)
        if first_pipeline_ms is None:
            first_pipeline_ms = elapsed_since_start_ms(sample.get("lastPipelineStartedAt"), start)
        if first_preprocess_done_ms is None:
            first_preprocess_done_ms = elapsed_since_start_ms(sample.get("lastPreprocessDoneAt"), start)
        if first_ocr_started_ms is None:
            first_ocr_started_ms = elapsed_since_start_ms(sample.get("lastOCRStartedAt"), start)
        if first_ocr_done_ms is None:
            first_ocr_done_ms = elapsed_since_start_ms(sample.get("lastOCRDoneAt"), start)
        if first_state_transition_ms is None:
            first_state_transition_ms = elapsed_since_start_ms(sample.get("lastStateTransitionAt"), start)
        if first_arm_ms is None and sample.get("state") == "armed":
            first_arm_ms = elapsed_ms
            armed_sample = sample
        if first_mask_ms is None and (sample.get("lastYODORegionCount") or 0) > 0:
            first_mask_ms = elapsed_ms

    after = samples[-1] if samples else (fetch_status() or {})
    ocr_frames_delta = int(after.get("ocrFrames") or 0) - before_ocr_frames
    ocr_values = numeric_values(samples, "lastOCRLatencyMS")
    preprocess_values = numeric_values(samples, "lastPreprocessDurationMS")
    roi_image_values = numeric_values(samples, "lastROIImageCount")
    text_coverage_values = numeric_values(samples, "lastTextRegionCoverage")
    yodo_coverage_values = numeric_values(samples, "lastYODOMaskCoverage")

    result = BenchResult(
        mode=MODE_NAMES[mode],
        fixture=fixture.name,
        samples=len(samples),
        ocr_frames_delta=ocr_frames_delta,
        first_arm_ms=first_arm_ms,
        first_mask_ms=first_mask_ms,
        first_frame_ms=first_frame_ms,
        first_pipeline_ms=first_pipeline_ms,
        first_preprocess_done_ms=first_preprocess_done_ms,
        first_ocr_started_ms=first_ocr_started_ms,
        first_ocr_done_ms=first_ocr_done_ms,
        first_state_transition_ms=first_state_transition_ms,
        armed_frame_to_pipeline_ms=armed_sample.get("lastFrameToPipelineMS") if armed_sample else None,
        armed_pipeline_to_preprocess_ms=armed_sample.get("lastPipelineToPreprocessMS") if armed_sample else None,
        armed_preprocess_to_ocr_done_ms=armed_sample.get("lastPreprocessToOCRDoneMS") if armed_sample else None,
        armed_ocr_done_to_armed_ms=armed_sample.get("lastOCRDoneToArmedMS") if armed_sample else None,
        armed_frame_to_armed_ms=armed_sample.get("lastFrameToArmedMS") if armed_sample else None,
        median_ocr_ms=median(ocr_values),
        p95_ocr_ms=percentile(ocr_values, 0.95),
        median_preprocess_ms=median(preprocess_values),
        median_roi_images=median(roi_image_values),
        median_text_coverage=median(text_coverage_values),
        median_yodo_coverage=median(yodo_coverage_values),
        max_yodo_coverage=max(yodo_coverage_values) if yodo_coverage_values else None,
        final_state=after.get("state"),
        final_match=after.get("lastMatch"),
    )
    log(format_result(result), log_file)
    return result


def format_ms(value: float | None) -> str:
    return "-" if value is None else f"{value:.0f}"


def format_pct(value: float | None) -> str:
    return "-" if value is None else f"{value * 100:.1f}%"


def format_result(result: BenchResult) -> str:
    return (
        f"{result.mode:10} {result.fixture:22} "
        f"samples={result.samples:2d} ocr_frames={result.ocr_frames_delta:2d} "
        f"arm_ms={format_ms(result.first_arm_ms):>5} "
        f"frame_ms={format_ms(result.first_frame_ms):>5} "
        f"pipe_ms={format_ms(result.first_pipeline_ms):>5} "
        f"ocr_done_ms={format_ms(result.first_ocr_done_ms):>5} "
        f"transition_ms={format_ms(result.first_state_transition_ms):>5} "
        f"mask_ms={format_ms(result.first_mask_ms):>5} "
        f"ocr_med={format_ms(result.median_ocr_ms):>5} "
        f"prep_med={format_ms(result.median_preprocess_ms):>5} "
        f"roi_imgs={format_ms(result.median_roi_images):>3} "
        f"text_cov={format_pct(result.median_text_coverage):>7} "
        f"yodo_cov={format_pct(result.median_yodo_coverage):>7} "
        f"state={result.final_state or '-'} match={result.final_match or '-'}"
    )


def write_summary(results: list[BenchResult], output_path: Path) -> None:
    payload = {
        "generatedAt": datetime.now().isoformat(timespec="seconds"),
        "sampleSeconds": SAMPLE_SECONDS,
        "pollSeconds": POLL_SECONDS,
        "results": [result.__dict__ for result in results],
    }
    output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_file = LOG_DIR / f"pipeline-benchmark-{run_id}.log"
    json_file = LOG_DIR / f"pipeline-benchmark-{run_id}.json"

    log("Stream Guard pipeline benchmark", log_file)
    log(f"log file: {log_file}", log_file)
    log(f"json file: {json_file}", log_file)

    ensure_playwright(log_file)
    subprocess.run(["pkill", "-x", "StreamGuard"], check=False)
    time.sleep(1)
    proc = launch_app(log_file)
    results: list[BenchResult] = []

    try:
        if not wait_for_status():
            log("FAIL: status endpoint never came up", log_file)
            return 1
        if not ensure_monitoring():
            log("FAIL: monitoring never started. Check Screen Recording permission.", log_file)
            return 1

        with Browser(log_file) as browser:
            for mode in MODES:
                log(f"=== mode: {MODE_NAMES[mode]} ===", log_file)
                for fixture_name in FIXTURE_PAGES:
                    fixture = FIXTURE_DIR / fixture_name
                    if fixture.exists():
                        results.append(benchmark_fixture(mode, fixture, browser, log_file))

        write_summary(results, json_file)
        log("", log_file)
        log("=== summary ===", log_file)
        for result in results:
            log(format_result(result), log_file)
        return 0
    finally:
        post_stop_error = None
        try:
            post_control("stop")
        except Exception as error:  # best-effort shutdown
            post_stop_error = error
        if post_stop_error:
            log(f"warning: POST /control/stop failed: {post_stop_error}", log_file)
        log("stopping StreamGuard", log_file)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
