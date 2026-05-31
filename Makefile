.PHONY: build run test live-test live-test-deps benchmark-pipelines clean

INFO_PLIST := Resources/Info.plist
BUILD_FLAGS := -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(INFO_PLIST)

build:
	swift build $(BUILD_FLAGS)

run: build
	swift run $(BUILD_FLAGS) StreamGuard

test:
	swift run $(BUILD_FLAGS) StreamGuardTestRunner

VENV_E2E := .venv-e2e
E2E_PYTHON := $(VENV_E2E)/bin/python

live-test-deps:
	test -d $(VENV_E2E) || python3 -m venv $(VENV_E2E)
	$(E2E_PYTHON) -m pip install -U pip
	$(E2E_PYTHON) -m pip install -r scripts/requirements-e2e.txt
	$(E2E_PYTHON) -m playwright install chromium

live-test: build live-test-deps
	$(E2E_PYTHON) scripts/e2e-live-test.py

benchmark-pipelines: build live-test-deps
	$(E2E_PYTHON) scripts/benchmark-pipelines.py

clean:
	swift package clean
