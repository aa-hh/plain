# Plain handover

State on 26 October 2026, main at 69fb5fc. Read `AGENTS.md` first; its rules bind you.

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
| `docs/claude-markdown-reference.md` | Measured reference for the Claude desktop app's markdown renderer, from its shipped build. The source of the Claude theme's numbers. |
| `docs/caret-behaviour-spec.md` | 1,672-line behaviour and looks spec of Caret. Part 1 editor, 2 preview, 3 app shell, 4 visual. Describes behaviour only. |
| `README.md` | Build, test, run. |

## Verify the current state

```bash
swift build
swift test
swift test -c release --filter PerformanceTests
bash scripts/build-app.sh && codesign --verify --deep --strict build/Plain.app
```

Every build and test goes through `~/.claude/scripts/remote-run <command>` from inside the repo. It shares slots across every session on this Mac and on the mule. `AUDIOUT_REMOTE_LOCAL=1 ~/.claude/scripts/remote-run <command>` forces it to run here, which is the only way to get `build/Plain.app` on this machine; a plain `remote-run bash scripts/build-app.sh` builds on the mule and the app never comes back.

Last results: `swift test` exit 0. `swift test -c release --filter Performance` exit 0 on this Mac. The signed app passes the strict signature check.

## What was built on 26 October

Plain's preview was reworked to match the Claude desktop app's markdown renderer. Four specs were written, published as issues on the tracker, and implemented. The measured evidence for every number is in `docs/claude-markdown-reference.md`.

- **Claude and Claude Dark preview themes**, added to `Themes.builtIn` and written on every launch.
- **A code block header**: the language label and a copy button above every fenced code block, with the block's `data-block` moved to the wrapper so patching and scroll sync still work. Styled in `previewBaseCSS` so the three older themes are not left with an unstyled button.
- **The Claude heading scale**: h1 22px down to h6 14px, h4 semibold so it does not collapse into h3.
- **Plain opens on the Claude theme** when nothing is saved. A saved choice still wins.
- **A half-typed table renders as a table** while the caret is in it, and the caret now reaches the parser on a move as well as on an edit, so clicking or arrow-keying out of it clears it.

Two deliberate deviations from the measured reference are recorded in `docs/DESIGN.md`'s Deviations list: h4 takes semibold, and a paragraph whose every line holds a `|` is held as a table while the caret is in it.

## Open work

**The architecture review is the next thing to pick up.** Its report is at
`/private/var/folders/y4/jkjsf6cs5kd5v1vh_lz95vgc0000gn/T/architecture-review-2026-10-26.html`
and lists five candidates for the render path. In short:

1. Render into one buffer instead of 260,000 throwaway strings. Strong. Removes about 92 ms from the full-document render.
2. Move footnote numbering behind the parser's seam. Strong, and the top pick: it is a document-wide fact computed in the renderer and walked on every flush, and one changed block measures 25.83 ms against a 20 ms limit in a document with footnote definitions and an edit earlier in the text. No test covers that shape.
3. Delete the sanitiser's second pass. Strong. It costs 53 ms against the renderer's own 35 ms and re-does URL safety, escaping, tag casing and attribute quoting.
4. Let the Writer borrow the parser's units. Worth exploring. 0.19 ms, so a seam problem rather than a perf one.
5. Copy unescaped runs instead of one unit at a time. Speculative.

The issues on the tracker are #1 (provisional table), #2 (heading scale), #3 (default theme) and #4 (caret leaves). All four are implemented on main and still open; closing them is Alec's call.

## Known issues

- **`preview-full-html-ms` fails on the mule.** 479 to 497 ms there against a 500 ms limit, while this Mac measures 117 ms. `docs/DESIGN.md` records 129.2 ms and says that row ran on this Mac, which agrees. The limit is not machine-relative, which is the defect. Ruled out: SSH (the timer is inside the test process), the machine (the mule is faster at raw Swift, at short runs, and at JavaScriptCore), load, memory, a stale or unoptimised build (clean rebuild, verified `-O -whole-module-optimization`), the deployment target, and core scheduling. Every other Plain performance number is the same or faster on the mule, including `markdown_init_ms` at 293 ms against 306 here, which parses the identical document. The one untested explanation is the compiler patch difference: Swift 6.4.0.33.1 on the mule against 6.4.0.34.1 here, on macOS 26.5 against 27. Confirming it needs the same binary on both machines, which the OS gap blocks.
- **`preview-one-block-p95-ms` can exceed its 20 ms limit** in a document with footnote definitions and an edit earlier in the text. The existing test passes only because its fixture has neither. Fixed by architecture candidate 2.
- **`PDFExportTests` is flaky on a cold run.** It has a 5-second expectation and the first run after a build took 8.3 s for the whole suite. It passed on three later runs. Pre-existing.
- **`EditorPerformanceTests/testKeystrokeAndLoad` is flaky.** Loading a 1 MB file with its visible part styled measured 224 to 302 ms against a 300 ms limit, and 960 ms on a heavily loaded machine. Rerun at low load (`uptime`) before treating a failure as a slowdown.
- Mac App Store sandbox conflicts, not started: Git marks run `/usr/bin/git`; the `plain` command needs a user-made symlink in `/usr/local/bin`; folder access and file watching need security-scoped bookmarks that persist across launches.
- Not yet tried in the running app: popups closing on focus loss, middle-click to close a tab, Ctrl+Tab, PDF and HTML export, keyboard focus into the Files sidebar.
- Typewriter mode adds half a window of space above the first line by design. It is saved in `~/Library/Application Support/Plain/state/silent-preferences.json` and toggled with ⌘⌥T.

## State left on this Mac

Two of Plain's own state files were set so the app opens showing the new work. Both are reversible from the theme menu and the preview toggle:

- `~/Library/Application Support/Plain/state/preview.json` points the theme at `Themes/Claude.css`.
- `~/Library/Application Support/Plain/state/preview-modes-w1.json` is `"full"`.

## Tracker

`gh` is authenticated as `aa-hh`. The tracker is GitHub Issues on `aa-hh/plain`. A `ready-for-agent` label was added; the repo has no `docs/agents/issue-tracker.md`, so the to-spec and code-review skills ask for `/setup-matt-pocock-skills` before they will run. Work past that by passing the issue numbers directly.

## Tools on this Mac

- Ghidra 12.1.4 at `/Volumes/Space/tools/ghidra_12.1.4_PUBLIC`, JDK 21 at `/Volumes/Space/tools/jdk-21.0.12.1+1/Contents/Home`. The REA reverse-engineering MCP server uses them; its settings are the `rea` entry in `~/.claude.json`.
- The impeccable skill's launcher script is not executable on this Mac; read `PRODUCT.md` and root `DESIGN.md` directly.
- The disk filled once on 26 October and interrupted work. About 4 GB was free afterwards. If a command fails with a disk-space error, report it rather than deleting anything.

## Repo facts

- No git remote. Nothing is pushed. Branches: `main` (current), `plain-build` (same commits as an earlier point, kept).
- `.claude/worktrees/` is empty and can be deleted.
- Caret's own settings remain in `~/Library/Application Support/Caret Beta`; Plain's are in `~/Library/Application Support/Plain`.

## Working with Alec

- Commit only when asked; never on main without being asked.
- Never run AppleScript (`osascript`, JavaScript for Automation) without asking each time.
- Plain words, no invented terms, no unexplained acronyms. Never report "done" without running the checks above and showing their output.
- Never copy Caret's code, CSS, themes, icons, font data, welcome text, name or branding.
- Do not use Claude models for subagents. Alec asked for this on 26 October and it still stands. Step 5 Preview at high effort is the strongest non-Claude option here.
- Subagents work best in their own git worktree, with the full spec up front, and with a requirement to run the real test command and paste its output. Two review passes on 26 October each found real bugs the implementing agent had reported as done, so verify every claim yourself.
