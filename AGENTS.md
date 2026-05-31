# Agent Instructions

- Never use npm. Always use Bun for JavaScript tooling.
- Prefer the Apple Command Line Tools path for macOS work; do not assume the full Xcode GUI app is installed.

## macOS Build Workflow

This project is a Swift Package Manager app and can be built without Xcode.app.

- Use `make build` for the normal debug build.
- Use `swift build` or `swift build -c release` when invoking SwiftPM directly.
- Use `make run` to launch the app through the existing build flags.
- Use `make test` for the Swift test runner.
- Expect `xcodebuild -version` to fail when only Command Line Tools are selected. That is not a blocker for this repo.

Useful local checks:

```sh
xcode-select -p
swift --version
clang --version
xcrun --find notarytool
```

The expected CLI-only developer directory is:

```sh
/Library/Developer/CommandLineTools
```

## Avoid Full-Xcode-Only Features

Keep the app buildable with Command Line Tools unless the user explicitly chooses to install Xcode.app.

- Do not add an `.xcodeproj` or `.xcworkspace` as the required build path.
- Do not introduce xibs, storyboards, or Interface Builder workflows.
- Do not require asset catalogs unless you also provide a CLI-compatible fallback; `actool` is not available in Command Line Tools.
- Keep app metadata in plist files and SwiftPM resources.
- Prefer command-line signing and distribution steps with `codesign`, `spctl`, and `xcrun notarytool` when packaging is needed.

If a future task needs full Xcode-only tools, call that out before making the change and offer a CLI-compatible alternative when practical.
