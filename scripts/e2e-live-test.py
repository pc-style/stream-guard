#!/usr/bin/env python3
"""End-to-end live latency harness for Stream Guard (no XCTest, no Xcode.app).

Uses Playwright to drive a single Chromium tab through HTML fixtures.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from playwright.sync_api import Page

ROOT = Path(__file__).resolve().parent.parent
STATUS_URL = os.environ.get("STREAM_GUARD_STATUS_URL", "http://127.0.0.1:8765/status")
CONTROL_BASE_URL = STATUS_URL.replace("/status", "/control")
CONTROL_START_URL = f"{CONTROL_BASE_URL}/start"
FIXTURE_DIR = ROOT / "test-fixtures"
CLEAR_PAGE = FIXTURE_DIR / "safe-control.html"
FIXTURE_PAGES = [
    "fake-terminal.html",
    "card-fixture.html",
    "split-frame.html",
]
# Pipeline modes exercised via POST /control/mode/* (same routes as the status page).
PIPELINE_MODES = [
    mode.strip()
    for mode in os.environ.get("STREAM_GUARD_E2E_MODES", "yodo-ocr,roi,full").split(",")
    if mode.strip()
]
MODE_ROUTES = {
    "full": "full",
    "roi": "roi",
    "yodo": "yodo",
    "yodo-ocr": "yodo-ocr",
}
MODE_PIPELINE_NAMES = {
    "full": "fullFrame",
    "roi": "roiCascade",
    "yodo": "yodoMask",
    "yodo-ocr": "yodoOCR",
}
# Any of these substrings in lastMatch is acceptable for the fixture.
EXPECTED_MATCH_SUBSTRINGS: dict[str, list[str]] = {
    "fake-terminal.html": ["(555) 123-4567", "5551234567"],
    "card-fixture.html": ["555.987.6543", "5559876543"],
    "split-frame.html": ["555 123-4567", "5551234567", "555123-4567"],
}
TIMEOUT_S = float(os.environ.get("STREAM_GUARD_TEST_TIMEOUT", "20"))
POLL_S = float(os.environ.get("STREAM_GUARD_TEST_POLL", "0.05"))
SETTLE_S = float(os.environ.get("STREAM_GUARD_SETTLE", "2.0"))
LOG_DIR = ROOT / ".stream-guard-test-logs"
BUILD_FLAGS = [
    "-Xlinker",
    "-sectcreate",
    "-Xlinker",
    "__TEXT",
    "-Xlinker",
    "__info_plist",
    "-Xlinker",
    str(ROOT / "Resources" / "Info.plist"),
]


@dataclass
class FixtureResult:
    mode: str
    name: str
    arm_ms: float | None
    clear_ms: float | None
    last_match: str | None
    arm_ok: bool
    clear_ok: bool
    match_ok: bool
    note: str = ""


def log(msg: str, log_file: Path) -> None:
    line = f"{datetime.now().strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with log_file.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def post_control(path: str) -> None:
    urllib.request.urlopen(
        urllib.request.Request(f"{CONTROL_BASE_URL}/{path}", method="POST"),
        timeout=2,
    ).read()


def fetch_status() -> dict | None:
    try:
        with urllib.request.urlopen(STATUS_URL, timeout=1.5) as resp:
            return json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return None


def now_ms() -> float:
    return time.time() * 1000


def file_uri(path: Path) -> str:
    return path.resolve().as_uri()


def e2e_python() -> str:
    venv_python = ROOT / ".venv-e2e" / "bin" / "python"
    if venv_python.exists():
        return str(venv_python)
    return sys.executable


def ensure_playwright(log_file: Path) -> None:
    py = e2e_python()
    if py == sys.executable:
        log("hint: run `make live-test-deps` to create .venv-e2e with playwright", log_file)
    try:
        subprocess.run([py, "-c", "import playwright"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        log("playwright missing — run: make live-test-deps", log_file)
        raise SystemExit(1) from None


class PlaywrightSession:
    def __init__(self, log_file: Path) -> None:
        self.log_file = log_file
        self._playwright = None
        self._browser = None
        self._context = None
        self.page: Page | None = None

    def __enter__(self) -> PlaywrightSession:
        from playwright.sync_api import sync_playwright

        self._playwright = sync_playwright().start()
        self._browser = self._playwright.chromium.launch(headless=False)
        self._context = self._browser.new_context(
            viewport={"width": 1440, "height": 900},
            device_scale_factor=1,
        )
        self.page = self._context.new_page()
        log("playwright: chromium started (one tab, navigated in place)", self.log_file)
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
        log(f"playwright: navigated to {path.name}", self.log_file)


def launch_app(log_file: Path) -> subprocess.Popen:
    env = os.environ.copy()
    env["STREAM_GUARD_AUTO_START"] = "1"
    binary = ROOT / ".build" / "debug" / "StreamGuard"
    if binary.exists():
        cmd = [str(binary)]
        log(f"launching {binary.name} with STREAM_GUARD_AUTO_START=1", log_file)
    else:
        cmd = ["swift", "run", *BUILD_FLAGS, "StreamGuard"]
        log("launching via swift run with STREAM_GUARD_AUTO_START=1", log_file)
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc


def wait_for_status(log_file: Path, timeout_s: float = 30) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if fetch_status() is not None:
            log("status endpoint is up", log_file)
            return True
        time.sleep(0.2)
    return False


def wait_for_monitoring(log_file: Path, timeout_s: float = 30) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = fetch_status()
        if status and status.get("monitoring") is True:
            log("monitoring is active", log_file)
            return True
        time.sleep(0.2)
    return False


def ensure_monitoring(log_file: Path) -> bool:
    status = fetch_status()
    if status and status.get("monitoring") is True:
        return True
    log("POST /control/start", log_file)
    try:
        urllib.request.urlopen(
            urllib.request.Request(CONTROL_START_URL, method="POST"),
            timeout=2,
        )
    except urllib.error.URLError:
        pass
    return wait_for_monitoring(log_file)


def wait_until(predicate, timeout_s: float, log_file: Path, label: str) -> tuple[bool, dict | None]:
    deadline = time.time() + timeout_s
    last: dict | None = None
    last_line = ""
    while time.time() < deadline:
        last = fetch_status()
        if last is None:
            time.sleep(POLL_S)
            continue
        timing = ""
        if last.get("lastOCRLatencyMS") is not None:
            timing = (
                f" ocr={last.get('lastOCRLatencyMS'):.0f}ms"
                f" snap={last.get('lastSnapshotDurationMS')}"
                f" prep={last.get('lastPreprocessDurationMS')}"
            )
        pipeline = last.get("pipelineMode")
        pipeline_bit = f" pipeline={pipeline}" if pipeline else ""
        line = (
            f"  poll {label}: state={last.get('state')} "
            f"overlay={last.get('overlayVisible')} "
            f"match={last.get('lastMatch') or '—'}{pipeline_bit}{timing}"
        )
        if line != last_line:
            log(line, log_file)
            last_line = line
        if predicate(last):
            return True, last
        time.sleep(POLL_S)
    return False, last


def is_clear(status: dict) -> bool:
    return status.get("state") == "clear" and status.get("overlayVisible") is False


def is_armed(status: dict) -> bool:
    return status.get("state") == "armed" and status.get("overlayVisible") is True


def match_is_expected(fixture_name: str, last_match: str | None) -> bool:
    if not last_match:
        return False
    expected = EXPECTED_MATCH_SUBSTRINGS.get(fixture_name)
    if not expected:
        return True
    return any(fragment in last_match for fragment in expected)


def set_pipeline_mode(mode: str, log_file: Path) -> bool:
    route = MODE_ROUTES.get(mode)
    if route is None:
        log(f"FAIL: unknown pipeline mode {mode!r}", log_file)
        return False
    log(f"POST /control/mode/{route} ({MODE_PIPELINE_NAMES.get(mode, mode)})", log_file)
    try:
        post_control(f"mode/{route}")
    except urllib.error.URLError as error:
        log(f"FAIL: mode switch: {error}", log_file)
        return False
    time.sleep(0.25)
    status = fetch_status()
    expected = MODE_PIPELINE_NAMES.get(mode)
    if status and expected and status.get("pipelineMode") != expected:
        log(
            f"WARN: pipelineMode is {status.get('pipelineMode')!r}, expected {expected!r}",
            log_file,
        )
    return True


def prepare_mode(mode: str, browser: PlaywrightSession, log_file: Path) -> bool:
    if not set_pipeline_mode(mode, log_file):
        return False
    browser.goto(CLEAR_PAGE)
    time.sleep(SETTLE_S)
    ok, _ = wait_until(is_clear, TIMEOUT_S, log_file, f"{mode}-baseline-clear")
    if not ok:
        log(f"FAIL: could not reach clear before {mode} fixtures", log_file)
    return ok


def run_fixture(
    mode: str,
    name: str,
    path: Path,
    browser: PlaywrightSession,
    log_file: Path,
) -> FixtureResult:
    label = f"{mode}/{name}"
    log(f"--- {label} ---", log_file)

    log("navigate: clear page (baseline)", log_file)
    browser.goto(CLEAR_PAGE)
    time.sleep(SETTLE_S)
    ok, _ = wait_until(is_clear, TIMEOUT_S, log_file, "baseline-clear")
    if not ok:
        return FixtureResult(
            mode,
            name,
            None,
            None,
            None,
            False,
            False,
            False,
            "never reached clear before test",
        )

    log(f"navigate: sensitive page {path.name}", log_file)
    t_open = now_ms()
    browser.goto(path)

    armed_ok, armed_status = wait_until(is_armed, TIMEOUT_S, log_file, "to-armed")
    arm_ms = (now_ms() - t_open) if armed_ok else None
    last_match = armed_status.get("lastMatch") if armed_status else None
    if armed_ok:
        snap = armed_status.get("lastSnapshotDurationMS") if armed_status else None
        prep = armed_status.get("lastPreprocessDurationMS") if armed_status else None
        ocr = armed_status.get("lastOCRLatencyMS") if armed_status else None
        log(
            f"ARM latency: {arm_ms:.1f} ms (match={last_match}) "
            f"[ocr={ocr}ms snap={snap}ms prep={prep}ms]",
            log_file,
        )
    else:
        log(f"FAIL: did not arm within {TIMEOUT_S}s", log_file)

    match_ok = armed_ok and match_is_expected(name, last_match)
    if armed_ok and not match_ok:
        log(f"FAIL: unexpected match {last_match!r} for {name}", log_file)

    log("navigate: clear page (recovery)", log_file)
    t_clear_open = now_ms()
    browser.goto(CLEAR_PAGE)

    clear_ok, _ = wait_until(is_clear, TIMEOUT_S, log_file, "to-clear")
    clear_ms = (now_ms() - t_clear_open) if clear_ok else None
    if clear_ok:
        log(f"CLEAR latency: {clear_ms:.1f} ms", log_file)
    else:
        log(f"FAIL: did not clear within {TIMEOUT_S}s", log_file)

    return FixtureResult(
        mode,
        name,
        arm_ms,
        clear_ms,
        last_match,
        armed_ok,
        clear_ok,
        match_ok,
    )


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_file = LOG_DIR / f"e2e-live-{run_id}.log"

    log("Stream Guard E2E live latency test (Playwright)", log_file)
    log(f"log file: {log_file}", log_file)
    log(f"pipeline modes: {', '.join(PIPELINE_MODES)}", log_file)

    ensure_playwright(log_file)

    subprocess.run(["pkill", "-x", "StreamGuard"], check=False)
    time.sleep(1)

    proc = launch_app(log_file)
    try:
        if not wait_for_status(log_file):
            log("FAIL: app/status never came up", log_file)
            return 1
        if not ensure_monitoring(log_file):
            log(
                "FAIL: monitoring never started (grant Screen Recording, restart app, rerun)",
                log_file,
            )
            return 1

        results: list[FixtureResult] = []
        with PlaywrightSession(log_file) as browser:
            for mode in PIPELINE_MODES:
                log(f"=== pipeline mode: {mode} ===", log_file)
                if not prepare_mode(mode, browser, log_file):
                    for page_name in FIXTURE_PAGES:
                        results.append(
                            FixtureResult(
                                mode,
                                page_name,
                                None,
                                None,
                                None,
                                False,
                                False,
                                False,
                                "mode prep failed",
                            )
                        )
                    continue
                for page_name in FIXTURE_PAGES:
                    path = FIXTURE_DIR / page_name
                    if not path.exists():
                        log(f"skip missing fixture: {page_name}", log_file)
                        continue
                    results.append(run_fixture(mode, page_name, path, browser, log_file))
                    time.sleep(0.5)

        log("", log_file)
        log("=== SUMMARY ===", log_file)
        failures = 0
        for r in results:
            arm = f"{r.arm_ms:.1f} ms" if r.arm_ms is not None else "FAIL"
            clear = f"{r.clear_ms:.1f} ms" if r.clear_ms is not None else "FAIL"
            status = "PASS" if r.arm_ok and r.clear_ok and r.match_ok else "FAIL"
            if status == "FAIL":
                failures += 1
            row = f"{r.mode}/{r.name}"
            log(
                f"{status}  {row:32}  arm={arm:>10}  clear={clear:>10}  match={r.last_match or '—'}",
                log_file,
            )
            if r.note:
                log(f"       note: {r.note}", log_file)

        if failures:
            log(f"{failures} fixture(s) failed", log_file)
            return 1
        log("all fixtures passed", log_file)
        return 0
    finally:
        log("stopping StreamGuard", log_file)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
