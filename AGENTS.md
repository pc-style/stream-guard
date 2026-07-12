The role of this file is to describe common mistakes and confusion points that agents
might encounter as they work in this project. If you ever encounter something in the
project that surprises you, please alert the developer working with you and indicate
that this is the case in this file to help prevent future agents from having the same issue.

An enabled macOS privacy row can belong to a previous ad-hoc build. When an installed
build still gets permission prompts, remove the old PII Guard entries from Accessibility
and Screen Recording before testing the current build.

With only the Command Line Tools selected (no Xcode), plain `swift test` cannot run
Swift Testing: SwiftPM omits the `-F` framework search path, the CLT Testing.framework
has a broken rpath to lib_TestingInterop.dylib, and target-level flags in Package.swift
never reach the synthesized test runner module, whose `canImport(Testing)` then compiles
false so `swift test` exits 0 having run zero tests (a silent false green). Use
`./scripts/test.sh`, which passes the flags globally on the command line, and confirm
tests ran by checking for the "Test run" lines in the output.
