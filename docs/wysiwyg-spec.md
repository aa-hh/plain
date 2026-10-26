# WYSIWYG spec: a page that looks and edits like Notion

Agreed by Alec, 26 October 2026; nothing is built yet. Replaces the earlier draft, where Markdown came back at the caret. Alec rejected that: "this isnt hiding markdown, the markdown is there. it should look like, and edit like notion/anytype".

The editor becomes a page. Markdown never shows while you write: `## ` turns a line into a heading, `**` makes bold, `- [ ] ` makes a checkbox, and the characters vanish for good. Blocks are added from a `/` menu, moved and changed with a handle, formatted from a toolbar, and tables edit as a grid. Files on disk stay plain Markdown, byte for byte. View > Show Markdown Source switches a window to today's editor.

Decided by Alec on 26 October 2026:

- The page looks and edits like Notion or Anytype; Markdown never shows, not even at the caret.
- Editing tools: the `/` menu, the block handle, the selection toolbar and the table grid.
- Notion/Anytype's look inside the page only. Plain's tab strip, sidebar, popups and notification bar stay as the design library draws them.
- A Source toggle stays.
- Copy gives plain text; Plain keeps the Markdown on the clipboard for its own pastes.
- Task lines show the checkbox only. Table cells use the body text colour.

The design is in `Plain - Screens.pen`, DISCOVERY, exploration "2026-10-26 Block editing like Notion and Anytype" (status liked): page tokens, every block, every editing tool and full windows. Where this spec and the mockups differ, Alec decides.

## 1. Blocks

Because files are Markdown, the page offers only blocks Markdown can store: no toggles, callouts, colours or columns.

| Block | Markdown | On the page |
|---|---|---|
| Text | a paragraph | 16 pt on 24 in `page-text` |
| Heading 1 to 6 | `#` … `######` | bold, 30 / 24 / 20 / 16 / 16 / 16 pt, with space above; no `#`, no level labels |
| Bold, italic, strikethrough | `**` `*` `~~` | the style; struck text in `page-text-secondary` with a line through it |
| Inline code | `` ` `` | Roboto Mono 14 on `page-code-background`, rounded, in `color-red` |
| Highlight | `::text::` | the text on `selection-yellow` |
| Link | `[text](url)`, `<url>`, reference links | the text with a thin underline; hovering shows the destination |
| Bulleted list | `-` `*` `+` | `•` at 1.5× size, 24 pt per level |
| Numbered list | `1.` | the number |
| Task list | `- [ ]` `- [x]` | a checkbox only; ticked fills `page-accent` with a white check and strikes the text through in `page-text-tertiary`; a click ticks or unticks it |
| Quote | `>` | a 3 pt bar in `page-text` at the left |
| Divider | `---` | a 1 pt `page-border` line with space above and below |
| Code block | a fenced block | a rounded `page-code-background` panel, code in Roboto Mono 14 with the `code-*` colours, the language at top left (a click opens a language list), Copy at top right on hover |
| Table | pipes and a delimiter row | a grid with a line around every cell, the header row bold on `page-code-background` |
| Image | an image-only line | the picture, rounded, with its alt text as a caption below |
| Maths block | `$$` | the rendered formula; a click shows its source in place while you edit it |
| Footnotes | `[^1]`, `[^1]: …` | a superscript number in `page-accent`; definitions show where they are in the file, in 14 pt `page-text-secondary`, with their number |
| Front matter | `---` YAML at the top | rows of key and value in 14 pt; a click shows the YAML in place while you edit it |
| Inline HTML, Liquid tags, `{…}` attributes, emoji shortcodes | as written | shown as written, in `page-text-secondary`: they have no page form |

Maths and front matter are the only places where source shows, and only while you are editing that one block.

## 2. Typing

- Typing a block's Markdown at the start of a line turns the line into that block at once: `# ` to `###### `, `- `, `* `, `1. `, `[] ` or `- [ ] `, `> `, ` ``` ` then Return, `---` then Return. The characters stay in the file and vanish from the page.
- Inline Markdown turns into its style the moment it closes: `**bold**`, `*italic*`, `~~struck~~`, `` `code` ``, `::highlight::`. Until it closes, what you typed shows as typed.
- ⌘B, ⌘I and ⌘K (the existing Bold, Italic and Link commands) wrap or unwrap the selection, or start the style at the caret.
- The caret never stands inside hidden characters. Arrow keys move one visible character and skip hidden ones with it. A click lands on the visible text. At the edge of a styled run the caret sits outside the markers, so typing there is plain text.
- Return in a list, task list or quote continues it; Return on an empty item ends it (today's typing helpers).
- Backspace at the very start of a heading, list item, task or quote turns it back into plain text in one press, removing its whole hidden prefix.
- Typing `/` at the start of an empty line opens the `/` menu.
- An empty line under the caret shows "Type / for blocks" in `page-text-tertiary`.

## 3. Editing tools

All four are drawn on the page in the page's look, from the mockups.

- **`/` menu:** opens below the line and shows up to 10 rows, scrolling for the rest. It always fits the window: with too little room below it opens above the line, and with too little room either way it shows fewer rows; filters as you type after the `/`, Up and Down move, Return inserts, Esc closes and leaves what you typed. Blocks: Text, Heading 1 to 3, Bulleted list, Numbered list, Task list, Quote, Code, Table, Divider, Image (opens a file picker and links the file), Maths. Inserting writes that block's Markdown in place of the `/` and what follows it.
- **Block handle:** hovering a block shows a `+` and a grip in the left margin at its first line. `+` adds an empty line below with the `/` menu open. Dragging the grip moves the block; a line in `page-accent` shows where it will land. A click on the grip opens the block menu: Turn into › (the blocks that hold text: Text, Heading 1 to 3, Bulleted list, Numbered list, Task list, Quote, Code; the current one ticked), Duplicate (no shortcut: ⌘D is Add Next Occurrence), Copy as Markdown, Delete. A block is a paragraph, heading, list item with its nested items, task, quote, code block, table, divider, image or maths block.
- **Selection toolbar:** selecting text with the mouse shows it above the selection: a "Text" picker (Turn into), then bold, italic, strikethrough, code, link and highlight. A button lights up when the whole selection has that style; clicking it adds or removes the style. The link button opens a small editor with a URL field and a "Link to file…" row that searches the folder.
- **Table grid:** clicking a cell puts the caret in it; Tab and Shift+Tab move between cells and Tab in the last cell adds a row (today's table typing helpers); a selected cell shows a 2 pt `page-accent` outline. Hovering the table shows `+` bars along its right and bottom edges to add a column or a row.

Every action is one undo step and edits only the Markdown: Turn into rewrites the block's prefix, a move cuts and pastes the block's lines, Delete removes them.

## 4. Copy and paste

- Copy and Cut put the visible text on the clipboard as plain text: `bold` not `**bold**`, a link's text, `•` for bullets, `☐` and `☑` for tasks, code without fences, headings without `#`, table cells separated by tabs and rows by line breaks.
- They also put the Markdown under a private type named after Plain's bundle ID, and Paste in Plain prefers it, so cut and paste inside Plain keeps every style.
- Copy as Markdown (block menu) puts the block's Markdown as plain text. Copy as Rich Text is unchanged.
- Pasting plain text from elsewhere inserts it as typed; pasted Markdown turns into blocks like typed Markdown.

## 5. The Source toggle

View > Show Markdown Source: a checkbox, ⇧⌘M (free in `CommandTable` today), id `window:toggle-markdown-source`. Off by default. Saved per window in a new state file, `markdown-source-wN`. On gives today's editor exactly: today's fonts, faded markers, heading labels, no page tools.

## States and limits

- A table wider than the page column stays as Markdown source, because a text line cannot scroll sideways. A known limit, shown with a caption-sized note under it: "Too wide to show as a table".
- Multiple carets still work; the block handle and the selection toolbar hide while there is more than one.
- Find matches the visible text; a match never falls on hidden characters. While the Find bar is open the page stays a page.
- VoiceOver reads the stored text, so it reads Markdown markers aloud. Out of scope here; worth fixing next, because the page promises no Markdown.
- Dark mode: every page token has a dark value.

## Architecture

The page stays one `EditorTextView` over the Markdown text, the same storage that is saved. No second document model.

- **Page styling:** `MarkdownStyler` gets a page mode, used whenever Show Markdown Source is off. It hides every marker with the method headings use today (`collapse`: a negative kern of each character's measured width and a clear colour), styles text with the page tokens, and sets paragraph spacing for the block gaps. Page colours and sizes join `Tokens` as `Tokens.page`, light and dark.
- **Drawn parts:** `EditorLayoutFragment` already draws heading labels, images and the hard-break arrow over the text. In page mode it also draws bullets, checkboxes, quote bars, dividers, code panels, table grids, footnote numbers, front matter rows and image captions, from attribute keys the styler sets.
- **Hidden ranges and the caret:** a pure function lists the hidden ranges from the snapshot's `markerRanges`. The `setSelectedRanges` override snaps every caret and selection end out of them. The move and delete overrides step over them.
- **Blocks:** a pure `PageBlocks` module maps the snapshot to blocks, with range, type, and first-line rectangle from the layout. It provides `turnInto`, `move`, `duplicate`, `delete`, `insert(kind:)`, `addRow` and `addColumn` as `TextEdit` values the editor applies as one undo group.
- **Tools:** the `/` menu, the block handle, the block menu, the selection toolbar, the link editor and the language list are views over the text view, positioned from layout fragment rectangles. They live in `EditorTextView` and use SwiftUI the way `EditorView` already does. The `/` menu filters with PlainCore's fuzzy filter.
- **Copy and paste:** a pure `VisibleText.plain(text:snapshot:range:)` turns a range into the plain text of section 4. The existing `copy:`, `cut:` and `paste:` overrides in `FormatCommands.swift` write and read both clipboard types.
- **Toggle:** `EditorConfiguration.showMarkdownSource`, filled from a per-window value on `WindowModel`, saved in `markdown-source-wN`. Then a `CommandTable` entry in the View group, `WindowModel.perform`, and its check mark in `isOn`.

## Speed

- New release test `editor-caret-move-p95-ms`: 200 caret moves across styled lines in the 1 MB fixture, p95 at most 8 ms.
- New release test `editor-block-move-ms`: moving a 200-line block in the 1 MB fixture, at most 50 ms to `layoutViewport()`.
- `editor-keystroke-p95-ms` (8 ms) and `tab-switch-1mb-ms` (50 ms) still hold, measured in page mode.
- `editor-load-visible-styled-ms` (300 ms) already sits near its limit, and page styling adds work. Measure it in both modes, and report both.
- Hovering must never restyle: the handle and toolbar only move views.

## Tests

- Styler, page mode: every block in section 1 hidden and drawn as described; with Show Markdown Source on, the existing `StylerTests` pass unchanged.
- Hidden ranges and the caret: clicks, arrows, word moves, Backspace at a block start, multiple carets.
- `PageBlocks`: every operation in section 3 as a `TextEdit`, and each one as a single undo step.
- Typing conversions in section 2, the `/` menu filter and insertions, the toolbar's style toggling over mixed selections.
- `VisibleText.plain` for every block; copy then paste inside Plain keeps the Markdown.
- Then `~/.claude/scripts/remote-run swift test` and the release speed suites, with their output shown.

## Order of work

After PR 7 merges, because it changes `Links.swift` and `EditorTextView.swift`, which this work touches too.

1. Page styling, hidden ranges and the caret, copy and paste, the Source toggle. Everything else stands on this.
2. Then four tracks at once, each with its own files: the `/` menu; the block handle with the block menu and dragging; the selection toolbar with the link editor; the table grid.

## Docs and the design file

- Root `DESIGN.md`: a new Page section with the page tokens and blocks. The current Editor section becomes the Source view.
- `docs/DESIGN.md`: the new state file, and a Deviations entry: the page hides all Markdown, against Caret's visible markers.
- The library gains the page tokens and the `Page/*` and `Page Tool/*` components when this design is built.

## Where Plain departs from Notion and Anytype

- Only blocks Markdown can store, because files stay Markdown.
- A table wider than the column shows as Markdown, because text cannot scroll sideways.
- Maths and front matter show their source while you edit them.
- A plain click on a link places the caret; ⌘-click opens it, as in the rest of Plain (docs/navigation-spec.md).
- Plain's chrome keeps Plain's look; only the page takes the Notion/Anytype style.

## Not in scope

Toggles, callouts, colours, columns, databases, comments, backlinks, page icons and covers, inline maths editing, and VoiceOver reading without markers.
