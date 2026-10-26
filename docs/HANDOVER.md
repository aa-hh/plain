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

Last results, 26 October on branch `claude/plain-handover-docs-8dc049`: `swift test` exit 0 and `swift test -c release --filter PerformanceTests` exit 0, both on the mule; `PreviewPerformanceTests` exit 0 on this Mac. The app was not rebuilt or signature-checked after the render changes.

## What was built on 26 October

Plain's preview was reworked to match the Claude desktop app's markdown renderer. Four specs were written, published as issues on the tracker, and implemented. The measured evidence for every number is in `docs/claude-markdown-reference.md`.

- **Claude and Claude Dark preview themes**, added to `Themes.builtIn` and written on every launch.
- **A code block header**: the language label and a copy button above every fenced code block, with the block's `data-block` moved to the wrapper so patching and scroll sync still work. Styled in `previewBaseCSS` so the three older themes are not left with an unstyled button.
- **The Claude heading scale**: h1 22px down to h6 14px, h4 semibold so it does not collapse into h3.
- **Plain opens on the Claude theme** when nothing is saved. A saved choice still wins.
- **A half-typed table renders as a table** while the caret is in it, and the caret now reaches the parser on a move as well as on an edit, so clicking or arrow-keying out of it clears it.

Two deliberate deviations from the measured reference are recorded in `docs/DESIGN.md`'s Deviations list: h4 takes semibold, and a paragraph whose every line holds a `|` is held as a table while the caret is in it.

## Open work

The architecture review's report is at
`/private/var/folders/y4/jkjsf6cs5kd5v1vh_lz95vgc0000gn/T/architecture-review-2026-10-26.html`
and lists five candidates for the render path. Candidates 1 and 2 are done on branch `claude/plain-handover-docs-8dc049`; the rest are open:

1. Done. The renderer writes a whole call's output into one buffer and turns it into a string through `NSString(characters:length:)`. A profile on the mule put 86% of the full-document render in `String(decoding:as: UTF16.self)`, which the standard library in macOS 26.5 runs one unit at a time; macOS 27 does not. That was the mule's 500 ms. `preview-full-html-ms` went from 497.9 to 79.5 ms on the mule and from 117 to 125 ms to 99.6 ms on this Mac.
2. Done. `MarkdownDocument` builds footnote numbers once per edit into `Snapshot.footnotes`, walking only blocks flagged as holding a reference; the renderer and `PreviewController` read them. `PreviewPerformanceTests/testOneChangedBlockWithFootnotes` covers the shape. On the mule it measured 19.32 ms before candidate 2, 12.03 ms after it, and 1.83 ms after candidate 1 too.
3. Delete the sanitiser's second pass. Strong. It costs 53 ms against the renderer's own 35 ms and re-does URL safety, escaping, tag casing and attribute quoting. `Sanitizer.swift` still calls `String(decoding:as: UTF16.self)` in five places, so on the mule it also pays the slow conversion candidate 1 removed from the renderer.
4. Let the Writer borrow the parser's units. Worth exploring. 0.19 ms, so a seam problem rather than a perf one.
5. Copy unescaped runs instead of one unit at a time. Speculative.

The issues on the tracker are #1 (provisional table), #2 (heading scale), #3 (default theme) and #4 (caret leaves). All four are implemented on main and still open; closing them is Alec's call.

## Known issues

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
