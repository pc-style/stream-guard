#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# With full Xcode selected, plain `swift test` finds Testing.framework on its
# own. The Command Line Tools ship Testing.framework, but their SwiftPM passes
# neither the framework search path nor the rpaths its dylibs need
# (Testing.framework loads lib_TestingInterop.dylib from a sibling usr/lib
# directory that no default rpath covers). Inject both here, on the command
# line, so the flags also reach the test runner module SwiftPM synthesizes:
# target-level flags in Package.swift cannot reach that module, which makes
# its `canImport(Testing)` false and silently runs zero tests.
FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TESTING_LIBS="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

case "$(xcode-select -p 2>/dev/null || true)" in
*CommandLineTools*)
    if [ -d "$FRAMEWORKS/Testing.framework" ]; then
        exec swift test \
            -Xswiftc -F"$FRAMEWORKS" \
            -Xlinker -F"$FRAMEWORKS" \
            -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
            -Xlinker -rpath -Xlinker "$TESTING_LIBS" \
            "$@"
    fi
    ;;
esac

exec swift test "$@"
