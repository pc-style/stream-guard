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

## Aden MCP / Codebase Map

Aden is installed for this repo as an MCP server and as the `aden` CLI. Treat it as the project map: it indexes Swift code, docs, and agent notes into a graph so agents can find the right symbol or doc section without manually reading the whole tree.

Use Aden when you need to understand or navigate existing code:

- before changing an unfamiliar area, ask a high-level question with `aden ask "how does <feature> work?"`
- to find code by text while preserving structure, use `aden grep "pattern"` instead of raw `grep`; Aden returns the enclosing symbol/anchor
- to find a specific type, function, or symbol, use `aden locate --symbol <Name>`
- before refactors, use `aden query --backlinks <anchor>` or `aden query --impact <anchor>` to check blast radius
- when a result gives an `aden://...` anchor, feed that anchor into `aden asm --from <anchor>` for a small context bundle
- after large external changes, generated files, or merges, refresh explicitly with `aden gen . --auto`

Prefer the MCP tools when available in the current client; otherwise run the equivalent shell command with `aden`. For subagents, explicitly tell them to use Aden because they may not inherit this instruction.

Do not use Aden as a replacement for real verification. After code changes, still run the project checks such as `make build`, `make test`, or focused Swift commands. Aden helps find and understand code; it does not prove runtime behavior.

Avoid committing Aden's generated graph artifacts. `.aden/store`, caches, and generated contracts are rebuildable. Commit only intentional repo guidance/config files such as `AGENTS.md`, `.adenignore`, `.agent/`, or durable `.aden/` configuration/hooks when they are deliberately part of the repo setup.

<!-- BEGIN aden:guidance (managed by `aden init` — edit outside this block) -->
## Using aden

**Use the aden MCP tools (or `aden <cmd>` on the shell) for ALL code navigation —
not raw `grep`/`find`/`cat`.** They are structure-aware (every result is tagged
with its enclosing symbol = the anchor you feed back into the graph) and far
cheaper in tokens than reading whole files. This applies to any subagents you
spawn too — tell them to use aden, since they do not inherit this guidance.

**The graph is fresh by construction.** Read tools (`ask`, `search`, `grep`,
`locate`, `query`, `asm`) auto-reindex any file changed since the last run. You do
**not** need `gen` before a session or after your own edits — only after large
*external* changes (cloning, a big merge, generated code).

| Goal | Tool |
| --- | --- |
| Structure-aware search (returns enclosing symbol = anchor) | `grep "pattern"` |
| Natural-language question over the code | `ask "how does X work?"` |
| Find a symbol's definition + call sites | `locate --symbol <name>` |
| Token-budgeted context bundle around an anchor | `asm <anchor>` |
| Blast radius — what references this | `query --backlinks <anchor>` |
| Blast radius — downstream reach | `query --impact <anchor>` |

**Flow:** `grep` → take the enclosing symbol → `asm`/`query` to traverse → `ask`
to explain. Validate with `check . --severity Forbid`; resync drift with `heal`.

See `.agent/templates/aden-guide.adoc` for the full reference.
<!-- END aden:guidance -->
