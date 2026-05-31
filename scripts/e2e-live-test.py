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
CONTROL_START_URL = STATUS_URL.replace("/status", "/control/start")
FIXTURE_DIR = ROOT / "test-fixtures"
CLEAR_PAGE = FIXTURE_DIR / "safe-control.html"
FIXTURE_PAGES = [
    "fake-terminal.html",
    "card-fixture.html",
    "split-frame.html",
]
TIMEOUT_S = float(os.environ.get("STREAM_GUARD_TEST_TIMEOUT", "20"))
POLL_S = float(os.environ.get("STREAM_GUARD_TEST_POLL", "0.15"))
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
    name: str
    arm_ms: float | None
    clear_ms: float | None
    last_match: str | None
    arm_ok: bool
    clear_ok: bool
    note: str = ""


def log(msg: str, log_file: Path) -> None:
    line = f"{datetime.now().strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with log_file.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


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
        line = (
            f"  poll {label}: state={last.get('state')} "
            f"overlay={last.get('overlayVisible')} "
            f"match={last.get('lastMatch') or '—'}"
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


def run_fixture(name: str, path: Path, browser: PlaywrightSession, log_file: Path) -> FixtureResult:
    log(f"--- fixture: {name} ---", log_file)

    log("navigate: clear page (baseline)", log_file)
    browser.goto(CLEAR_PAGE)
    time.sleep(SETTLE_S)
    ok, _ = wait_until(is_clear, TIMEOUT_S, log_file, "baseline-clear")
    if not ok:
        return FixtureResult(name, None, None, None, False, False, "never reached clear before test")

    log(f"navigate: sensitive page {path.name}", log_file)
    t_open = now_ms()
    browser.goto(path)

    armed_ok, armed_status = wait_until(is_armed, TIMEOUT_S, log_file, "to-armed")
    arm_ms = (now_ms() - t_open) if armed_ok else None
    last_match = armed_status.get("lastMatch") if armed_status else None
    if armed_ok:
        log(f"ARM latency: {arm_ms:.1f} ms (match={last_match})", log_file)
    else:
        log(f"FAIL: did not arm within {TIMEOUT_S}s", log_file)

    log("navigate: clear page (recovery)", log_file)
    t_clear_open = now_ms()
    browser.goto(CLEAR_PAGE)

    clear_ok, _ = wait_until(is_clear, TIMEOUT_S, log_file, "to-clear")
    clear_ms = (now_ms() - t_clear_open) if clear_ok else None
    if clear_ok:
        log(f"CLEAR latency: {clear_ms:.1f} ms", log_file)
    else:
        log(f"FAIL: did not clear within {TIMEOUT_S}s", log_file)

    return FixtureResult(name, arm_ms, clear_ms, last_match, armed_ok, clear_ok)


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_file = LOG_DIR / f"e2e-live-{run_id}.log"

    log("Stream Guard E2E live latency test (Playwright)", log_file)
    log(f"log file: {log_file}", log_file)

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
            for page_name in FIXTURE_PAGES:
                path = FIXTURE_DIR / page_name
                if not path.exists():
                    log(f"skip missing fixture: {page_name}", log_file)
                    continue
                results.append(run_fixture(page_name, path, browser, log_file))
                time.sleep(0.5)

        log("", log_file)
        log("=== SUMMARY ===", log_file)
        failures = 0
        for r in results:
            arm = f"{r.arm_ms:.1f} ms" if r.arm_ms is not None else "FAIL"
            clear = f"{r.clear_ms:.1f} ms" if r.clear_ms is not None else "FAIL"
            status = "PASS" if r.arm_ok and r.clear_ok else "FAIL"
            if status == "FAIL":
                failures += 1
            log(
                f"{status}  {r.name:24}  arm={arm:>10}  clear={clear:>10}  match={r.last_match or '—'}",
                log_file,
            )

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
