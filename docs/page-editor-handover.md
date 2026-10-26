# Page editor handover

State on 26 October 2026, branch `claude/wysiwyg-spec` (PR 8), which sits on top of `claude/impeccable-navigation-spec-a35d23` (PR 7, not merged yet). Read `AGENTS.md` first; its rules bind you. The spec is `docs/wysiwyg-spec.md`.

## What is built

The editor shows a Markdown file as a page that looks and edits like Notion or Anytype, and View > Show Markdown Source (⇧⌘M) switches a window back to the Markdown view. Everything in the spec is built:

- Page styling with every marker hidden (drawn at 0.01 pt in a clear colour, not the spec's negative kern: the kern left the caret 3 pt off at every block start).
- Hidden ranges and caret snapping, typing conversions, Backspace rules, copy as plain text with Plain's own Markdown clipboard type, and the per-window Source toggle.
- `PageBlocks` (turn into, move, duplicate, delete, insert, add row and column) as single undo steps.
- The `/` menu and code language list (`SlashMenu.swift`), the block handle and block menu (`BlockHandle.swift`), the selection toolbar and link editor (`SelectionToolbar.swift`), and the table grid (`TableGrid.swift`).
- Root `DESIGN.md` has a Page section; `docs/DESIGN.md` records the state file and the deviation from Caret's visible markers.

Decisions Alec made while it was built, beyond the spec:

- A single blank line between two blocks draws 2 pt tall and the caret skips it; extra blank lines stay full height.
- Typing a list marker on the line under a paragraph adds a blank line above it in the file. Backspace at the start of a heading, list item or quote under another line makes the text its own paragraph.
- Turn into applies only to text blocks (headings 1 to 6, paragraphs, lists, tasks, quotes), in the toolbar and the block menu.
- Page typing rules do not run in non-Markdown files. Paste prefers Plain's Markdown clipboard type in both views.
- `LucideIcon` is public and `EditorTextView` depends on `PlainShell`.

The design is in `Plain - Screens.pen` (FINAL, "Page editing like Notion and Anytype") and its components and `page-*` variables are in `Plain - Design Library.lib.pen`, both in `~/Projects/Plain Design/`.

## Verified on 26 October

Run through `~/.claude/scripts/remote-run`, on the mule, exit 0:

- `swift test`: all 10 test modules pass (EditorTextViewTests 210 tests, 7 skipped release-only).
- `swift test -c release --filter PerformanceTests`: editor-keystroke-p95-ms 2.6 (limit 8), editor-caret-move-p95-ms 0.34 (8), editor-block-move-ms 10.7 (50), editor-find-page-ms 24.8 (50), editor-select-all-page-ms 31.1 (50), editor-load-visible-styled-ms 19.9 and editor-load-visible-styled-source-ms 18.5 (300), tab-switch-1mb-ms 17.4 (50).

Not checked: nothing was looked at in the running app. The drawn parts (bullets, boxes, panels, grids, captions), dragging a block with the mouse, hover fills, menu clicks, the link hover tooltip and the ⇧⌘M menu item need a look in `build/Plain.app`.

## Open problems

A second code review did not approve the build. These ten remain, most serious first. Fix each at its root with a test that fails before the fix.

1. **Cmd+G can select text that no longer exists.** `FindBar.swift:148` returns early on the page while `snapshot == nil`, but `findNext` (`FindBar.swift:98`) and `handleFindKey` still select the old matches. Find open on `aaa foo`, query `foo`, match (4,3); click into the text, press Backspace three times, then Cmd+G before the snapshot arrives: `setSelectedRange((4,3))` on 4 characters throws an out-of-range exception.
2. **Find matches text the page draws clear.** `FindBar.swift:121-133` drops only units inside hidden ranges. With Find open, maths source stays hidden (`MathPreviews.swift:118`), so `frac` matches TeX under the formula picture. The front matter colon and spaces after each key are drawn clear (`MarkdownStyler.swift:807-818`), so `:` matches. A picture-only line maps its alt text to the line's first offset (`HiddenRanges.swift:500-504`), so `cat` in `![cat](p.png)` selects the clear `!`.
3. **Find matches across table cells and footnote references.** The tab copy puts between cells (`HiddenRanges.swift:236`) maps inside the gap's hidden range, so `FindBar.swift:126` drops it: `foobar` matches `| foo | bar |` at (2,10), and `ab` matches `a[^1]b`. Keep a boundary there.
4. **A query typed while a parse is pending is never shown.** `findQueryChanged` returns before `showFindResults` (`FindBar.swift:77-81`); when the snapshot arrives, `findTextChanged` only repaints highlights (`FindBar.swift:153`). The match is not selected or scrolled to, the no-match colour stays from the old query, and the `fromSelection` start is lost.
5. **Toggling Show Markdown Source with Find open keeps the old matches.** `apply(_:)` (`EditorTextView.swift:300-307`) closes the page tools but does not re-run Find. Source to page with query `**` on `**b**` leaves matches on hidden markers that Cmd+G selects.
6. **Find rebuilds the whole searched text on every snapshot.** `FindBar.swift:116-131` builds the full hidden-range list twice (once inside `VisibleText.map` at `HiddenRanges.swift:479`, again at `FindBar.swift:121`): 15 to 25 ms on the 1 MB file after every keystroke while Find is open. No test measures typing with Find open.
7. **Clicking a divider can leave the caret on the next divider's hidden line.** `snapped()` in `pageAdjusted` (`HiddenRanges.swift:579-582`) lists ranges two lines either side of one point, but a snap can carry past that window. `a\n\n---\n\n---\n\nb`, click at offset 3: the snap goes 3 → 7 → 8 and stops on the second divider.
8. **Shift+arrow on a large selection lists every hidden range in the file.** The arrow path builds the list over the old and new selection together (`HiddenRanges.swift:591-592`), about 30 ms per key press after selecting most of a 1 MB file. The caret-move speed test covers only a bare caret.
9. **Page typing turns off source typing helpers.** In `TypingHelpers.swift`, typing over a selection always calls `pageReplace` (`:119-121`), whose plain-file branch (`:220`) skips `wrapSelection` and `pair`: selecting `word` and typing `(` gives `(` on the page and `(word)` in the source view. A backtick never pairs on the page (`:416`), and `completeOpener` never runs there (`:115`). Decide with Alec whether the page should wrap and pair like the source view.
10. **Turning a multi-line setext heading into a heading splits it.** `PageBlocks.swift:266-292` removes the underline but prefixes only the first line: `Line one\nLine two\n---` to Heading 1 gives `# Line one\nLine two`. Join the lines or prefix each.

Smaller known gaps:

- Inside a list item, a code block's language label and its click area sit at column left + 32 (`EditorLayoutFragment.drawPageForeground`, `EditorTextView.clickedCodeLabel`), left of the indented panel.
- Some new code reads heading, list and quote prefixes and front matter with its own patterns (`PageBlocks.prefixRegex` and `linePrefix`, `listMarkerUnderParagraph`, `pageFrontMatter`) instead of the snapshot's marker ranges. `AGENTS.md` says `MarkdownDocument` is the only Markdown parser.
- `.impeccable/design.json` was not regenerated after root `DESIGN.md` changed; run the impeccable skill's document step.
- The design library check (`~/.claude/scripts/pen-library-changes "Plain - Screens.pen" --dry-run`) lists 15 rows in FINAL, all example content and window sizes in the mock windows, which Alec accepted.
