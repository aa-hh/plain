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

- `swift build`
- `swift test --filter <Suite>`, for example `swift test --filter PlainCoreTests`
- Performance suites run in release only: `swift test -c release --filter <Name>PerformanceTests`
- `bash scripts/build-app.sh` assembles and signs `build/Plain.app`
- `bash scripts/fetch-vendor.sh` regenerates `Sources/PlainVendor/Resources/`; never edit or add vendor files by hand

## Rules

- Never copy Caret's code, CSS, themes, icons, font data or welcome text. `docs/caret-behaviour-spec.md` describes behaviour and looks only.
- Placeholder files (`Placeholder.swift`, `Sources/Plain/main.swift`, `Sources/Plain/Resources/.keep`) are deleted by the track that owns that folder, and nobody else touches them.
- Prose (docs, comments, commit messages) follows Alec's writing rules: concrete names and numbers, plain words, active voice, no invented terms, no filler, no em dashes in short text.
