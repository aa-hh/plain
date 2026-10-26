# Plain

A macOS Markdown editor in SwiftUI, with AppKit for the text view, windows and menus. One Swift package at the repo root.

## Modules

Every module is a target under `Sources/`, with tests under `Tests/<Target>Tests/`.

- `PlainVendor`: the downloaded KaTeX, Prism, emoji list and Roboto Mono files, reached through `VendorFiles`. No logic.
- `PlainCore`: command table, preferences, design tokens, fuzzy filter, slugify, text stats, user data folders and state files, openable file types, emoji table. No AppKit views.
- `MarkdownDocument`: the only Markdown parser. Every feature reads `MarkdownDocument` snapshots; nothing parses Markdown elsewhere.
- `PlainDocument`: one open file, its text storage, saving, autosave, history and backups. No disk access on the typing path.
- `FolderIndex`: the window folder's file tree, file watching, find in folder and file operations.
- `GitStatus`: git marks from `/usr/bin/git`, run on refresh and per commit, never per keystroke.
- `Spellcheck`: spelling through `NSSpellChecker`; takes excluded ranges as plain ranges and does not import `MarkdownDocument`.
- `EditorTextView`: the TextKit 2 editor, styling from snapshots, typing helpers and editor commands.
- `PreviewRenderer`: HTML from snapshots, the preview web view, themes and export.
- `PlainShell`: SwiftUI sidebars, popups, tab bar and labels. Views take data as parameters and report actions through closures.
- `PlainAppKit`: windows, menus, shortcuts and wiring between modules.
- `Plain`: the executable; holds only the `@main` app and its resources.

No global app object: state is passed in, never reached through a shared singleton.

## Build and test

Never run a bare `swift build`, `swift test`, `swift run` or `swift package`. A Claude Code hook (`~/.claude/hooks/prefer-remote-tests.py`) blocks them. Use the wrappers from the repo root:

- `bash scripts/run-tests.sh --filter <Suite>`, for example `bash scripts/run-tests.sh --filter PlainCoreTests`
- `AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh` for the full suite; the hook asks for a filter otherwise
- Performance suites run in release only: `bash scripts/run-tests.sh -c release --filter PerformanceTests`
- `bash scripts/build.sh` for a compile check; extra arguments go to `swift build`
- `bash scripts/run-app.sh` launches the app with `swift run`
- `bash scripts/build-app.sh` assembles and signs `build/Plain.app`
- `bash scripts/fetch-vendor.sh` regenerates `Sources/PlainVendor/Resources/`; never edit or add vendor files by hand

How the wrappers run work, all of it from `~/.claude/scripts/lib/remote.sh`, which AirPlay Controller and `~/.claude/scripts/remote-run` share:

- **Slots.** Every compile and test run takes one slot from a pool shared by every session on this Mac and on the mule (`alechamilton@SUMUP-M9Y197RFVG.local`). `git config audiout.localSlots` and `audiout.remoteSlots` set the sizes. `~/.claude/scripts/capacity status` shows who holds them.
- **Mule first.** With `git config audiout.testPrefer remote`, `run-tests.sh` and `build.sh` rsync the tree to the mule and run there, and come back here when the mule is asleep or full. A mule failure that names no failing test is re-run here. `build-app.sh` and `run-app.sh` always run here, since they need the products. `AUDIOUT_TEST_LOCAL=1` and `AUDIOUT_BUILD_LOCAL=1` skip the mule.
- **Pass cache.** A green run stamps a hash of `Sources`, `Tests`, `Package.swift` and `Package.resolved` in `/tmp/plain-suite-cache`. A later run on the same files that an earlier pass covered is skipped: a full pass covers any filter, and a passed `--filter A` lets `--filter A|B` run only `B`. `AUDIOUT_TEST_NO_CACHE=1` turns it off.
- **Shards.** A full run on the mule builds once, then runs up to three `swift test` processes at once, split by `scripts/lib/suite-shards.sh`: `EditorTextViewTests`; `MarkdownDocumentTests` and `PreviewRendererTests`; everything else. `--shard N` runs one of them. The GitHub `tests` workflow (`.github/workflows/tests.yml`) runs the same three shards on every pull request, with the SwiftPM `.build` cached by `Package.resolved`. A new test target lands in shard 3 with no edit. `AUDIOUT_TEST_SHARDS=1` keeps a full run in one process.
- The last run's output is in `/tmp/plain-suite-last.log`. `AUDIOUT_TEST_MODE=serial` passes `--no-parallel`, for flake hunting only.

## Rules

- Never copy Caret's code, CSS, themes, icons, font data or welcome text. `docs/caret-behaviour-spec.md` describes behaviour and looks only.
- Placeholder files (`Placeholder.swift`, `Sources/Plain/main.swift`, `Sources/Plain/Resources/.keep`) are deleted by the track that owns that folder, and nobody else touches them.
- Prose (docs, comments, commit messages) follows Alec's writing rules: concrete names and numbers, plain words, active voice, no invented terms, no filler, no em dashes in short text.
