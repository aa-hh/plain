# Plain handover

State on 22 October 2026, main at c5ca6a1. Read `AGENTS.md` first; its rules bind you.

## What Plain is

A native macOS 27 Markdown editor (SwiftUI, AppKit for the text view, windows and menus), rebuilt from the behaviour of Caret Beta 4.0.0-rc23, an Electron app. Caret's business parts (licence, purchase, analytics, updater, crash upload, Windows and Linux) are deliberately left out.

## Where things are

| File | What it holds |
|---|---|
| `AGENTS.md` | Modules, build and test commands, rules. |
| `PRODUCT.md` | Users, position, distribution, principles. Public product, "fast and quiet", Mac App Store. |
| `DESIGN.md` (root) | The visual system: colours, type, spacing, components. Source of truth is `Sources/PlainCore/DesignTokens.swift`. |
| `.impeccable/design.json` | Machine-readable companion to root `DESIGN.md` for the impeccable design skill. Regenerate it whenever root `DESIGN.md` changes. |
| `docs/DESIGN.md` | How the code is built: modules, threads, state files, every deviation from the spec, release speed numbers. |
| `docs/caret-behaviour-spec.md` | 1,672-line behaviour and looks spec of Caret. Part 1 editor, 2 preview, 3 app shell, 4 visual. Describes behaviour only. |
| `README.md` | Build, test, run. |

## Verify the current state

```bash
swift build
swift test
swift test -c release --filter PerformanceTests
bash scripts/build-app.sh && codesign --verify --deep --strict build/Plain.app
```

Last results: `swift test` exit 0 (all suites pass; the speed tests skip outside release builds). The signed app passes the strict signature check.

## Known issues

- `EditorPerformanceTests/testKeystrokeAndLoad` is flaky. Loading a 1 MB file with its visible part styled measured 224 to 302 ms against a 300 ms limit, and 960 ms on a heavily loaded machine. Rerun at low load (`uptime`) before treating a failure as a slowdown.
- Mac App Store sandbox conflicts, not started: Git marks run `/usr/bin/git`; the `plain` command needs a user-made symlink in `/usr/local/bin`; folder access and file watching need security-scoped bookmarks that persist across launches.
- Not yet tried in the running app: popups closing on focus loss, middle-click to close a tab, Ctrl+Tab, the preview modes, PDF and HTML export, keyboard focus into the Files sidebar.
- Typewriter mode adds half a window of space above the first line by design. It is saved in `~/Library/Application Support/Plain/state/silent-preferences.json` and toggled with ⌘⌥T.

## How the build was run

Fable scoped the work into tracks and Opus agents built each track in its own git worktree; the work was merged on branch `plain-build` (fast-forwarded into main, branch kept) and reviewed twice. The work order, review notes, Caret screenshots and the recovered Caret source lived in a temporary session folder that has since been emptied. Nothing from them is needed: the spec holds what the build used.

## Tools on this Mac

- Ghidra 12.1.4 at `/Volumes/Space/tools/ghidra_12.1.4_PUBLIC`, JDK 21 at `/Volumes/Space/tools/jdk-21.0.12.1+1/Contents/Home`. The REA reverse-engineering MCP server uses them; its settings are the `rea` entry in `~/.claude.json`.
- The impeccable skill's launcher script is not executable on this Mac; read `PRODUCT.md` and root `DESIGN.md` directly.

## Repo facts

- No git remote. Nothing is pushed.
- Branches: `main` (current), `plain-build` (same commits, kept).
- `.claude/worktrees/` is empty and can be deleted.
- Caret's own settings remain in `~/Library/Application Support/Caret Beta`; Plain's are in `~/Library/Application Support/Plain`.

## Working with Alec

- Commit only when asked; never on main without being asked.
- Never run AppleScript (`osascript`, JavaScript for Automation) without asking each time.
- Plain words, no invented terms, no unexplained acronyms. Never report "done" without running the checks above and showing their output.
- Never copy Caret's code, CSS, themes, icons, font data, welcome text, name or branding.
