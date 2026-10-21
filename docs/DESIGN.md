# Plain design

How the shipped code is put together. Behaviour and looks come from `docs/caret-behaviour-spec.md` (the spec); this file covers the parts the spec leaves to the build, and every place Plain does something other than the spec says.

## Modules

One Swift package, one target per module under `Sources/`. Each module lists the modules it imports.

| Module | Imports | What it holds |
|---|---|---|
| `PlainVendor` | nothing | KaTeX 0.19.0, Prism 1.30.0, the gemoji `emoji.json` and Roboto Mono, written by `scripts/fetch-vendor.sh`. `VendorFiles` gives their URLs. |
| `PlainCore` | `PlainVendor` | `CommandTable` (every menu command, id and shortcut), `Preferences`, `Tokens` (colours, sizes, fonts), fuzzy filter, `slugify`, `TextStats`, `UserData` and `StateStore`, `OpenableFiles`, `EmojiTable`. |
| `MarkdownDocument` | swift-markdown, `PlainCore`, `PlainVendor` | The `MarkdownDocument` actor, the only Markdown parser. Publishes `Snapshot` values: blocks, inlines, headings, reference definitions and Prism code tokens, with UTF-16 ranges. |
| `PlainDocument` | `PlainCore` | `Document` (one open file: text storage, undo manager, saving), `AutosaveController`, `FileHistory`, `Backups`, `UnsavedFiles`. |
| `FolderIndex` | `PlainCore` | The `FolderIndex` actor (the window folder's file tree), find in folder, file operations. |
| `GitStatus` | `PlainCore` | The `GitStatus` actor (file marks from `git status`, committed text from `git show`) and the line diff behind the editor's change marks. |
| `Spellcheck` | `PlainCore` | `SpellingEngine` (`SystemSpellingEngine` wraps `NSSpellChecker`; `WordListSpellingEngine` is for tests) and `SpellcheckController`. Takes excluded ranges as plain `NSRange` values. |
| `EditorTextView` | `MarkdownDocument`, `PlainDocument`, `Spellcheck`, `GitStatus`, `PlainCore`, `PlainVendor` | `EditorTextView`, an `NSTextView` on TextKit 2, with styling from snapshots, typing helpers, multiple cursors, find, autocomplete, inline images and maths, spelling and Git marks. `EditorController` and `EditorView` wrap it for SwiftUI. |
| `PreviewRenderer` | `MarkdownDocument`, `PlainCore`, `PlainVendor` | `HTMLRenderer` (HTML from snapshots), `PreviewController` (keeps a `WKWebView` page in step), `Themes`, `Sanitizer`, `RichText` (copy as rich text, HTML to Markdown), `Export` (PDF and HTML). |
| `PlainShell` | `FolderIndex`, `GitStatus`, `MarkdownDocument`, `PlainDocument`, `PlainCore` | SwiftUI views: tab bar, files and outline sidebars, popups, notification bar, stats label. Views take data as parameters and report actions through closures. |
| `PlainAppKit` | all of the above, Yams | `AppDelegate` and `AppContext`, `WindowController` (one `NSWindow` hosting `WindowView`), `WindowModel` (one per window), `MenuBuilder`, `CommandDispatcher`, `KeyMonitor`, `Shortcuts`. |
| `Plain` | `PlainAppKit` | The `@main` app, the Welcome folder, `Licences.md` and the `bin/plain` launcher. |

State is passed in through initialisers and closures. `AppContext` holds what the windows share (preferences, the command table with its shortcuts, themes, file history, backups, recent folders, the state store) and is handed to each `WindowModel`; nothing reaches it through a global. The two shared objects that do exist, `EmojiTable.shared` and `CodeHighlighter.shared`, hold the emoji list and Prism results.

`WindowModel` wires the modules together. It gives `EditorController` closures such as `completePath` (backed by `FolderIndex`) and `openPath` (backed by `WindowModel.open`), and gives `PreviewController` its `openPath` and `applyEdit` closures, so `EditorTextView` and `PreviewRenderer` never import each other or the shell.

Commands run through one table. `MenuBuilder` builds the menu bar from `CommandTable.all`; menu items, `KeyMonitor` and the Commands popup all call `CommandDispatcher.run(_:)`, which sends `editor:` ids to `EditorController.perform` and the rest to `WindowModel` or the app.

## Markdown parsing

swift-markdown (cmark-gfm with tables, strikethrough and task lists) does the CommonMark work. Plain adds its own syntax around it in three passes, all in `MarkdownDocument`:

1. `LineScanner` marks each line as normal, blank, or the opening, body or closing line of a fence (code, `$$` maths, front matter).
2. `PrePass` rewrites the lines into text swift-markdown can parse while keeping the line count, so every parsed position maps back by line. Front matter lines are blanked, `$$` fences become code fences with the language `plain-math`, `+++` lines become `<!--plain-page-break-->`, inline `$x$` and `$$x$$` become same-length code spans, and footnote definitions are cut out and parsed separately.
3. swift-markdown parses with `.disableSmartOpts`, then `PostPass` turns its tree into `Block` and `Inline` values with UTF-16 ranges and adds what swift-markdown leaves as plain text: `[[toc]]`, reference definitions, footnote references, `<...>` autolinks, bare URLs and emails, `::highlight::`, `:emoji:` shortcodes, Liquid tags, `{...}` attributes, hard breaks and escapes. Fenced code gets Prism tokens from `CodeHighlighter`, which runs Prism in one `JSContext` and caches the 512 most recent results.

Edits reparse a window of lines, not the whole text. The window runs from the block before the first edited block to the second block after the last one. It grows when the edit leaves a fence open or when the last block in the window ends differently than before, up to 8 times; after that, or when footnote labels change, the whole text is parsed again. Blocks whose text did not change keep their `BlockID`, and each snapshot lists the changed and removed ids so the editor and preview only redo those blocks.

The preview colours code from the snapshot's Prism tokens. Maths in the preview is rendered by `KaTeXJSRenderer`, which runs KaTeX in its own `JSContext` and caches 1,024 results.

## Threads

- Main actor: `Document` and its text storage and undo manager, `EditorTextView`, `EditorController`, `WindowModel`, `PreviewController`, `SpellcheckController`, `Preferences`, all views.
- `MarkdownDocument` is an actor. `apply(_:)` is `nonisolated`: it adds the edit to a `Mutex`-guarded queue and returns a `TextVersion` at once, so typing never waits for a parse. The actor takes every edit queued since its last parse, parses once and publishes the snapshot on `AsyncStream`s. The editor restyles only from a snapshot whose version matches its latest edit.
- `PreviewController` merges snapshots that arrive within 16 ms and renders changed blocks on the `RenderQueue` actor, then sends the page one patch message.
- Disk reads and writes in `Document` run in detached tasks; `WriteGate` drops an older save that finishes after a newer one. `FileHistory`, `Backups` and `StateStore` are actors.
- `FolderIndex` and `GitStatus` are actors fed by `FSEventStream`s on private dispatch queues. `GitStatus` runs `/usr/bin/git` on a global queue: `git status --porcelain --untracked-files` on refresh, `git show HEAD:<path>` once per file per commit. The line diff runs in memory.
- Spelling goes through `NSSpellChecker.requestChecking`, one paragraph at a time, 1 second after the last edit or at once after a space.
- Maths in the editor renders in one hidden `WKWebView` (`KaTeXRenderer` in `MathPreviews.swift`), one render at a time, captured with `takeSnapshot`.

## Files on disk

Everything lives in `~/Library/Application Support/Plain/`:

| Path | Holds |
|---|---|
| `config/Preferences.md`, `config/Keyboard Shortcuts.md` | The two settings files, opened as tabs and read with Yams on save. |
| `state/*.json` | `StateStore` files, listed below. |
| `Themes/` | Preview theme stylesheets. |
| `file-revisions/` | Backups. |
| `untitled-files/` | Untitled documents. |
| `unsaved-files/` | Unsaved text kept between launches. |
| `Introduction/` | The Welcome folder, copied from the app on first launch. |

State files: `app` (focused window), `commands` (3 most recent commands), `emoji-recent`, `file-history` (up to 50 files: scroll position, selection, unsaved flag, last use), `file-revisions` (backup names), `folders` (recent folders), `hide-interface`, `keyboard-shortcuts`, `preferences`, `silent-preferences`, `preview` (chosen theme), `sidebar-expansion`, and per window `N`: `window-bounds-wN`, `tabs-wN` (tabs and 40 recent files per folder), `project-wN`, `sidebar-wN`, `preview-modes-wN`.

## Deviations from the spec

- Text encoding: files are read as UTF-8, or as Latin-1 when they are not valid UTF-8, and always written back as UTF-8. A Latin-1 file therefore changes encoding on its first save.
- Line breaking: wrapping uses the system line breaker (`lineBreakStrategy = .standard`, word wrapping). The spec's wrap preferences (spec line 38: after a space, `-`, `/` or a CJK character, before `(` `[` `{` `<` `#`) are not implemented. The hanging indent for list items is.
- Images, rendered maths and the hard-break `↓` are drawn by `EditorLayoutFragment`, a TextKit layout fragment, over the source text. They are not `NSTextAttachment` characters, so a saved file never gains U+FFFC characters.
- The spelling underline uses `NSUnderlineStyle.thick`, the system's thickest underline, in place of the spec's 3 px line (spec line 318).
- Multiple cursors are Plain's own code in `Selections.swift`. `NSTextView` keeps only one empty selection and types into only the first of several ranges, so the editor stores the extra cursors and selections itself, draws them, and applies each edit at every one of them from last to first inside one undo group.
- The code font is Roboto Mono under the SIL Open Font License 1.1, which ships in `Licences.md`. Merriweather and Fira Mono are not bundled.
- Undo history is not saved across launches. `file-history` keeps scroll position, selection and the unsaved flag; the undo stack starts empty each time a file opens.
- `:name:` emoji shortcodes work; markdown-it-emoji's text shortcuts such as `:)` are not converted.
- Replace is removed. Find has no replace field and no Replace menu item.
- File has a New Window item (Cmd+Shift+N, `file:new-window`). Caret had multi-window state but no way to open a second window (spec line 1252).
- The `plain` command-line tool is `exec open -a Plain "$@"`. It has no `--version` and no help text.
- Ordered list renumbering always starts from 1, so a list that begins at `5.` becomes `1.`, `2.`, `3.`. Lists of all `1.` stay that way.
- Each tab gets its own `MarkdownDocument` the first time it becomes the current tab and keeps it until the tab closes, so switching back to a tab does not reparse it.
- Spelling leaves language detection to the system setting and drops Caret's own word list and its English two-letter transposition list (spec line 321).
- HTML export fixes two bugs in Caret's export: the body sits in `<section class="content">`, and a document with maths carries KaTeX's stylesheet with its woff2 fonts inlined as `data:` URLs.
- Business features are left out: licences and purchases, analytics, the updater, error uploads, Caret's web links, and the Twitter and newsletter commands. The Help menu holds Open Welcome Folder and Third-Party Licences.

## Speed

Release build, `swift test -c release --filter PerformanceTests`, run on 22 October 2026 on this Mac (8 cores). The first run shared the machine with other builds (load average 12.9 over 1 minute) and missed two targets; the two rows marked below come from reruns at a load average near 4. The editor load test sits close to its limit and has measured 224 to 302 ms across runs.

| Measure | Result | Target |
|---|---|---|
| `markdown_apply_p95_ms` (caller side, ~1 MB document) | 0.008 ms | 1 ms |
| `markdown_snapshot_p95_ms` | 4.28 ms | 16 ms |
| `markdown_init_ms` (full parse) | 362 to 366 ms (rerun) | 600 ms |
| `editor-keystroke-p95-ms` | 5.127 ms | 8 ms |
| `editor-load-visible-styled-ms` (1 MB file) | 224 to 302 ms (rerun) | 300 ms |
| `tab-switch-1mb-ms` | 32.3 ms | 50 ms |
| `preview-one-block-p95-ms` | 0.81 ms | 20 ms |
| `preview-full-html-ms` (20,838 blocks, 7,098,353 bytes) | 129.2 ms | 500 ms |
| `folder-index-5000-files` | 112.9 ms | 2,000 ms |
| `folder-search-5000-files` | 56.5 ms | 300 ms |
| `git-line-diff-10k-lines` | 13.06 ms | 30 ms |
