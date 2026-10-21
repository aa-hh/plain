# Caret Beta behaviour spec

What Caret Beta 4.0.0-rc23 (caret.io, February 2019) does, written so a new app can be built to behave the same way. It describes behaviour only. Caret's code is marked "All Rights Reserved", so nothing here is copied from it; only command names, preference keys, addresses and short interface strings are quoted.

## How this was produced

- Source: `caret-beta.dmg`, SHA-256 `87d6468f1e7c7ab17332c2d3bc91dd6d070572b9240cc4429e9ddf0f30e2a9de`.
- Caret is an Electron app (Intel-only). Its JavaScript is in `app.asar`. About half of its own files are empty there; their source was recovered as UTF-16 text from Electron's startup memory image, `snapshot_blob.bin`.
- Parts 1 to 3 were read from the code, not run. Part 4 was measured from the running app (screens at 1680 × 1020, plus 800 × 600). Each section says whether a statement was seen in the code (observed-in-code) or worked out from names, menus and styles (inferred-from-names).

## Sections

1. Editor: typing, Markdown helpers, selection, find, spellcheck
2. Preview, Markdown rendering, themes and export
3. App shell: windows, tabs, sidebars, files, Git, preferences, licensing, updates, network use
4. Visual design: colours, fonts, sizes and layout, measured from the running app

Each section ends with its own list of unknowns.


# Part 1: Editor

## Caret Beta 4.0.0-rc23: editor behaviour spec

Scope: the Markdown editing surface (typing, rendering inside the editor, editing helpers, find, spelling, editor-side shortcuts). Preview pane, sidebars, tabs and file handling belong to other specs.

Paths below are relative to `SRC` (`scratchpad/caret/src`). Most editor modules are empty files in `SRC`; their source was read from the snapshot text dump `scratchpad/snap-src.txt` (split into `scratchpad/edmods/`). "observed-in-code" covers both readable files and that dump. "inferred" means only names, CSS, strings or callers support it.

Libraries the editor uses (from `SRC/package.json`, present in `SRC/node_modules`): `markdown` (the app's own incremental Markdown parser that builds the editor tree), `prism-electron` (Prism syntax highlighter, about 150 languages loaded on demand), `katex` (math), `emojilib` + `emoji-regex` (emoji), `spellchecker` (OS spelling engine) with the app's `spelling` wrapper, `franc-min` (language detection), `parse-english` (sentence detection), `jaro-winkler` (similarity ranking), `list-pattern`, `brackets-match`, `word` (word boundaries), `is-paired-character`, `chars`, `html-to-markdown`, `html-tags`, `is-image`, `@sindresorhus/slugify`, `multi-click`, `filter` (fuzzy matching). `SRC/local_modules` is empty; the "file:local_modules/..." packages were copied into `node_modules` and are readable there (except `line-range`, `multi-click`, `middle-click`, `markdown/index.js`, which are snapshot-only).

### Editor engine and layout

Behaviour
- The editor is a custom text engine, not a browser text field and not CodeMirror. A hidden, transparent input element receives keystrokes; the text is drawn as absolutely positioned line elements (`editor__line`, `white-space: pre`) grouped in tiles. The browser's own selection is made invisible; the app draws its own cursor and selection as overlay elements (`editor__highlight--cursor`, `editor__highlight--selection`).
- Cursor: 1px wide, inset 3px from the top and bottom of the line. Extra cursors (multi-cursor) use the secondary text colour.
- Selection uses the blue selection colour; when the editor loses focus it switches to a neutral grey (`editor--blurred`).
- Two fonts. Prose font (`--editor-font`) for paragraphs, list/quote/task text, ATX headings, emphasis. Code font (`--editor-code-font`, bundled Roboto Mono, with Merriweather also supported by the measuring code) for markers, code, math, tables, setext headings, front matter. Line height = line-height multiplier × prose font size. The app ships per-character width tables (`fonts-data/*.js` + kerning files) so it can measure text without the DOM.
- Soft wrap. Preference `lineWidth` (default 72, minimum 20) sets the maximum text column width as that many widths of the letter "a" in the paragraph font; the page centres at that width. Wrapping prefers: after a space, after `-` or `/`, after any CJK character, before `(` `[` `{` `<` `#`. Wrapped continuation lines of list items and indented lines are indented to align with the text after the list marker (hanging indent).
- Tabs in the text are drawn as spaces.
- Emoji characters are wrapped in their own span so they can use an emoji font.
- Custom scrollbar: 16px wide track on the right, 7px rounded slider, minimum slider height 20px. The slider appears while scrolling or when the mouse moves over the track and fades out (0.3s) 750ms later, unless the mouse is over it. Slider can be dragged.
- Clicking in the window outside any text field returns focus to the editor.

Source: `extensions/Editor/editor.css`, `editor--app.css`, `editor--highlights.css`; dump modules `Editor.Markdown.Lines.js`, `Editor.Scrollbar.js`, `extensions/Editor/Editor.js`, `Editor.Fonts.js` (names only), `fonts-data/`.

Confidence: observed-in-code.

### How Markdown looks inside the editor

Behaviour
- The editor is a styled-source editor. Every Markdown character stays in the text and stays visible; syntax markers are drawn in a faded colour (tertiary), content in the normal colour. There is no syntax hiding except for ATX heading markers, rendered math blocks and rendered images (sections below). A CSS comment mentions "syntax auto-hide" as an idea; no code implements it.
- Each parsed node becomes a span whose class is the node type (`block-*`, `inline-*`, plus `__marker`, `__text` children), so styling is pure CSS on those classes.
- Inline styles:
  - Emphasis: italic; the `*`/`_` markers faded, the text normal colour.
  - Strong: bold; markers faded.
  - Strikethrough `~~x~~`: text secondary colour with a line through it; markers faded.
  - Highlight `::x::` (this app's syntax, not `==`): text gets a tinted background; markers secondary colour.
  - Links (inline, reference, footnote, autolink `<...>`, bare URL): link text blue, no underline; brackets, parentheses and URL faded.
  - Images: alt text secondary colour, rest faded (see Images for the inline picture).
  - Inline code and inline math: code font at the smaller "inline code" size, content gold, delimiters faded.
  - Inline HTML tags and Liquid tags: code font, secondary colour, punctuation faded.
  - Emoji shortcode `:name:`: name secondary, colons faded.
  - Hard line break (two trailing spaces): a small "↓" glyph is drawn after the line.
  - Backslash escapes: the backslash is faded.
- Block styles:
  - Paragraphs: prose font.
  - List, quote and task markers: secondary colour in the code font, so markers line up regardless of the prose font.
  - Indented code, reference definitions, footnotes, HTML blocks and HTML comments: secondary colour.
  - Thematic break: faded. Page break (a line of three or more `+`, spaces allowed): red. `[[toc]]` line: blue.
  - Tables: once a table is complete (has header + divider), its text turns secondary and pipes/dividers faded; all table text uses one font so columns line up.
  - YAML front matter, math blocks, fenced code: code font; fences faded, body secondary.
  - Fenced code, math, front matter and HTML block lines get a full-width tinted background band (`editor__highlight--md-background`).
  - Fenced code body is syntax-highlighted with Prism when the language after the fence is known; token colours come from theme variables (`--code-keyword`, `--code-string`, `--code-comment`, `--code-number`, `--code-function`, `--code-tag`, `--code-attr-name`, `--code-attr-value`, `--code-property`, `--code-punctuation`, `--code-boolean`, `--code-variable`, `--code-shell-comment`). The fence language is matched against the editor's file-type syntaxes first (JavaScript, CSS, HTML get their own), otherwise the generic Prism one.
- Headings:
  - ATX headings (`#`..`######`): bold, emphasis colour, prose font, same size as body by default.
  - The `#` marker characters are drawn at zero width and replaced by a small faded label "h1".."h6" in a monospace font. The first line of the heading is shifted left by the label's width so the heading text starts at the same left edge as paragraphs and the label sits in the left margin.
  - Setext headings (`===` / `---` underline): bold, code font.
  - Class `editor--large-headings` (an option; how it is switched on is unknown) makes h1 1.4× and h2 1.2× the body size; h3–h6 stay body size. Line heights for such headings are measured so wrapping stays correct.
- Supported Markdown in the editor parser (node types seen): paragraph, ATX and setext heading, quote, bullet list, ordered list, task list, table (header, divider with alignment, rows), fenced code, indented code, YAML front matter, math block, HTML block, HTML comment, reference definition, footnote definition, `[[toc]]`, thematic break, page break; inline emphasis, strong, strike, highlight, code, math, link, reference link, reference image, footnote link, "no-link" (shortcut reference), autolink, bare URL, image, emoji, HTML tag, Liquid tag, line break, escape.
- Math delimiters: inline `$..$`; block `$$` (and `$$$` per the bundled sample document).

Source: `extensions/Editor/editor--blocks.css`, `editor--inlines.css`, `editor--highlights.css`; dump `Editor.Markdown.Lines.js`, `Editor.Markdown.Headings.js`, `Editor.Markdown.js`, `extensions/Editor/Editor.js` (`_parseCode`); `node_modules/markdown/Sliceup.js`; `extensions/Markdown/markdown-it-page-break.js`; `extensions/Project/welcome-project/Markdown Support.md`.

Confidence: observed-in-code. The trigger for large headings is unknown.

### Heading editing

Behaviour
- Caret inside the `#` marker run (not at its very start, line not indented): typing any character first moves the caret to just after the marker, so text cannot be typed into the marker.
- Typing `#` while the caret is in the marker adds one `#` at the start of the line (raises the level number, e.g. h2 → h3).
- Backspace with the caret in or right after the marker: if the marker has two or more `#`, remove one `#` (h3 → h2) and keep the caret after the marker; if it has one, remove the whole marker and its space. One undo step.
- Pressing Enter at the end of a setext heading rewrites the underline to exactly match the heading text length.
- Format › Heading 1–6 (`editor:heading1`..`heading6`, no default shortcuts) toggles the heading marker on every line in the selection: if all lines already have that marker it is removed, otherwise lines get it (replacing a different block marker).

Source: dump `Editor.Markdown.Headings.js`, `Editor.Markdown.Assist.js`, `Editor.Markdown.Format.js`; `menu.js`.

Confidence: observed-in-code.

### Auto-pairing and typing helpers

Behaviour
- Pairs inserted when typing an opening character in Markdown files: `` ` `` `(` `[` `{` `"` `'` `*` `_`. The closing character is inserted and the caret placed between.
- A pair is only inserted when: there is a selection (then the selection is wrapped, selection kept inside), or the next character is whitespace / end of line / a closing character and either the opener differs from the closer or the previous character is whitespace or `=` and the run is symmetric. For `*` and `_` there must be a selection, and the caret must not be in code or math. `(` right after `:`, `=`, `;` or `-` with no selection does not pair outside code (avoids smileys like `:(`).
- No pairing inside a selected marker (see "Retyping a selected marker").
- Typing a closing character `)` `]` `}` `'` `"` `` ` `` when the same character is next, and the previous character is not a backslash, steps over it instead of inserting.
- In Markdown, typing `*`, `_`, `:` or `$` when the same character is next and the caret is inside emphasis/strong/highlight/code/math steps over it.
- Backspace between an empty pair (`()`, `[]`, `{}`, `''`, `""`, ``` `` ```) deletes both, unless preceded by a backslash. Same for delete-word-backward.
- Selection + `~` wraps the selection in `~~`; selection + `:` wraps it in `::`. Wrapping trims leading/trailing spaces off the selection first and refuses if the selection has no letters or digits, or is already wrapped.
- Auto-completing bold/italic: if the current word so far is only an opener (`*`, `**`, `_`, `__`, `$$`, `~~`, `::`, optionally after `(`, `[`, `{`) and you type a letter with no letter after the caret, the matching closer is inserted after the caret. Not in code/math or inside existing emphasis.
- Typing ```` ``` ````, `~~~` or `$$$` as a whole line, with an empty line (or end of document) after it, inserts the closing fence on the next line and leaves the caret after the opening fence (ready for a language name).
- Pressing Enter inside an unclosed fenced code / math / YAML block that has only its opening fence adds the closing fence below with the same length and indent.
- Enter keeps the indent of the previous line (code files); in Markdown this is handled by list continuation instead. Enter between a just-typed `{`/`(`/`[` and its match indents the new line by the tab size (2 spaces) and puts the closer on its own line.
- Tab / Shift+Tab with the caret inside an inline element (emphasis, strong, strike, highlight, code, math, link, image, reference link) jumps to the end / start of that element. Inside a link, Tab from the text jumps to the URL; Tab from the URL jumps past the link.
- Tab otherwise indents the selected lines to the next 2-space stop; Shift+Tab outdents. Also Cmd/Ctrl+] and Cmd/Ctrl+[. Backspace in leading whitespace that ends in 2 spaces deletes 2 spaces.
- Home / Cmd+Left first goes to the first non-space character, then to the line start.
- Retyping a selected marker: if the selection exactly covers a run of the same marker character (e.g. `**`, a fence ```` ``` ````) and you type a different special character, the run is replaced by that character repeated, and the matching closing marker of the same element is changed too (e.g. select `**` and type `_` to turn `**a**` into `__a__`).

Source: dump `Editor.Code.js`, `Editor.Markdown.Assist.js`, `Editor.Markdown.js`; `extensions/Project/welcome-project/Tips and Tricks.md`.

Confidence: observed-in-code.

### List continuation and list editing

Behaviour
- The "pattern" of a line is its leading prefix: bullet (`*`, `+`, `-`), task bullet (`- [ ]`, `- [x]`), number (`1.` or `1)`, up to 9 digits), quote (`>`), or plain indentation, and only if the line contains a letter. It is also detected generically: if the current line and the nearest line above (or below) at the same indent share a prefix ending in a space, that shared prefix is the pattern (so prefixes such as `// ` or `| ` repeat too). A checked box in a pattern is always copied as unchecked.
- Enter at the end of (or inside the text of) a line with a pattern starts the next line with the same pattern. Ordered numbers increment, unless the list at that indent is a "all 1." list (every item is `1.`), which keeps `1.`.
- Enter on a line that holds only the pattern (an empty item) removes it; if a parent level exists above, the line becomes that parent's pattern (outdent one level), otherwise the line becomes empty. Not when inside an unclosed bracket.
- Esc on a line that holds only the pattern deletes the pattern.
- Typing `[] ` at the start of an empty line turns it into `- [ ] `.
- With the caret inside a task's `[ ]`/`[x]`, typing space unchecks and typing `x`/`X` checks it (caret moves inside the box).
- Tab / Shift+Tab on list lines change the line's prefix to the pattern of the next deeper / shallower level, learned from nearby lines in the same list (the most common pattern at each indent wins). If no deeper level exists yet, normal indent applies.
- Ordered numbers are renumbered automatically (1, 2, 3 per indent level, restarting when indent changes) after: Enter, deleting a line break, Backspace over a line break, Move Line Up/Down, indent/outdent, pasting, Format › Ordered List. "All 1." lists stay all 1.
- Pasting text that already starts with the current line's pattern, when the caret sits in or right after the pattern, drops the duplicate prefix. The same for block markers in general.
- List continuation is suppressed inside tables.
- Format › List / Ordered List / Task List / Quote toggle `-`, `1.`, `- [ ]`, `>` on all selected lines, extended to the whole contiguous list of that type at the same indent. If every line already has that marker, it is removed; otherwise any existing block marker is replaced.
- Context menu on a list item: "Check Item"/"Uncheck Item" (tasks), "Convert to OL", "Convert to UL", "Convert to Task List".

Source: dump `Editor.List.js`, `Editor.Markdown.Format.js`; `node_modules/list-pattern/*.js`; `extensions/Editor/Editor/Editor.Markdown.Menu.js`.

Confidence: observed-in-code.

### Table editing

Behaviour
- The table helper loads the first time the caret is in a table or on a line containing `|`.
- Enter at the end of a paragraph line that starts and ends with `|` (a header row) creates the divider row (dashes under each cell, pipes kept) and an empty row of blanks, caret in the first cell.
- Enter inside a table body row (not header) adds a new empty row below the current line, cells sized like the divider; caret in its first cell.
- Enter on the last row when every cell is empty deletes that row (leaves the table).
- Typing `|` directly after the end of a table starts a new empty row.
- Tab / Shift+Tab select the next / previous cell's text (without the padding spaces), moving across rows and wrapping; only in complete tables and only when the selection is inside a single cell.
- While typing in a cell, the whole column is re-padded after each edit so all pipes line up: every cell padded to the widest cell, divider rebuilt with the same alignment colons (`:--`, `:-:`, `--:`), at least one dash. Skipped with multiple cursors.

Source: `extensions/Editor/Editor/Editor.Markdown.Table.js`; dump `extensions/Editor/Editor.js` (lazy load).

Confidence: observed-in-code.

### Format menu and inline formatting commands

Behaviour
- Bold (Cmd/Ctrl+B) toggles `**`; Italic (Cmd/Ctrl+I) toggles `_`; Strikethrough `~~`; Mark `::`; Code `` ` ``; Math `$$` (inline). With no selection the word under the caret is wrapped. If the caret/selection is already inside that element, its markers are removed. Works per cursor with multiple cursors.
- Link (Cmd/Ctrl+K): if inside a link/image, removes the link syntax leaving the text. Otherwise wraps the selection (or word under caret) as `[text](url)`. If the selected text is a URL it becomes the URL with empty text; else if the clipboard holds a URL without spaces it is used as the URL. URLs ending in .png/.gif/.jpg/.jpeg/.bmp produce an image `![..](..)` instead. Caret lands where input is still needed (in the text, the URL, or after the link).
- Image: same, always `![..](..)`.
- Code Block / Math Block: wrap the selected lines in ```` ``` ```` / `$$$` fences; if the selection is inside one fenced block, the fences are removed; overlapping fenced blocks are merged.
- Add Table of Contents inserts `[[toc]]` and a blank line at the very top of the document.
- Add Thematic Break / Add Page Break insert `---` / `+++` after the current block, separated by a blank line.
- Comment (Cmd/Ctrl+/) wraps the selected lines in `<!-- ... -->` with inner spaces, or unwraps them.
- Clear Syntax (Cmd/Ctrl+Alt+Backspace) deletes all inline marker characters of the inline element at the caret (outermost one), or of every inline element touched by the selection.
- Pasting a URL over a plain-text selection (not already a link) makes `[selection](url)`. Pasting plain text over a selected URL makes `[text](url)` with the caret in the text.
- Copy as Rich Text (Cmd/Ctrl+Shift+C) puts both plain Markdown and rendered HTML on the clipboard; Copy as HTML (Cmd/Ctrl+Alt+C) puts the HTML as text. Uses the selection or, if none, the whole document.
- Paste Formatted converts clipboard HTML to Markdown (headings, lists, quotes, pre/code, em/strong/strike, links, images, tables) and pastes it.
- Pasting an image from the clipboard saves it as `<timestamp>.png` in a `.pastes` folder (in the project root, or next to the file), reusing an identical existing file, and inserts `![](relative/path)`.
- With no selection, Cut and Copy act on the whole current line including its line break.

Source: dump `Editor.Markdown.Format.js`, `Editor.Markdown.Assist.js`, `Editor.Markdown.js`, `Editor.Code.js`, `extensions/Editor/Editor.js`; `node_modules/html-to-markdown/`; `menu.js`.

Confidence: observed-in-code.

### Autocomplete

Behaviour
- After every typed character or backspace the editor asks all helpers for suggestions (not after deleting a line break). Ctrl+Space or Alt+Enter also asks, then opens the context menu if nothing appeared.
- The popup (`list--autocomplete`) appears under the caret (above it if there is no room, in reverse order), shows at most 6 items with the typed part underlined, and an optional icon (the emoji). It does not appear if the only suggestion equals what is already typed.
- Keys while open: Down, Ctrl+Space, Alt+Enter (and Ctrl+N on Mac) next item; Up (Ctrl+P on Mac) previous; Enter or Tab accept; Esc close. It closes on blur, any selection change, window resize.
- Accepting replaces the typed fragment at every cursor.
- Suggestion sources in Markdown:
  - Emoji: typing `:` then letters (no space) lists emoji whose names fuzzy-match, recently used emoji first, then keyword matches. Accepting inserts the Unicode emoji character (not the `:name:` code) plus a space unless a space follows. Typing or pasting a single emoji records it as recent (browser local storage key `caret.editor.markdown.autocomplete.emojis`).
  - File paths: inside a link/image URL, or an HTML `src="..."`/`href="..."`, when the text starts with `./`, `../`, `/` (project root), `~/` (home) or a drive letter: lists matching files and folders (hidden files only if a `.` is typed; case-insensitive unless the typed part has capitals; junk files like `.DS_Store` skipped). Picking a folder adds `/` and asks again. Paths are URL-encoded.
  - Heading anchors: in a link URL starting with `#` (or `href="#`), lists slugs of the document's headings.
  - Fence language: on the opening line of a fenced block, after the backticks, lists language names (about 56: aspnet, bash, batch, basic, c, cpp, csharp, css, coffeescript, dart, docker, elixir, erlang, fortran, fsharp, git, go, groovy, handlebars, haskell, html, http, java, javascript, js, json, latex, less, lua, makefile, markdown, matlab, mathml, mermaid, nginx, objectivec, ocaml, oz, pascal, perl, php, powershell, prolog, python, ruby, rust, scala, scss, smalltalk, sql, svg, swift, typescript, xml, yaml).
  - HTML: typing `>` to close an opening tag of a known non-void HTML tag inserts the closing tag after the caret. Inside an opening tag after a space, attribute names valid for that tag (plus global ones) are suggested; accepting inserts `name=""` with the caret between the quotes. (The HTML helper is active in Markdown, minus its code-editing part.)
- In other file types: CSS/SCSS/LESS suggest property names on indented lines (accept inserts `name: ` and asks again) and values after `name:` (accept appends `;`); JavaScript suggests keywords longer than 4 letters that start with the typed text and are at least 0.85 similar.

Source: dump `Editor.Autocomplete.js`, `Editor.Markdown.Autocomplete.js`, `Editor.Menu.js`, `Editor.HTML.js`, `extensions/Editor/Editor.js`; `extensions/Editor/Editor/Editor.CSS.js`, `Editor.JavaScript.js`, `modules/html-autocomplete.js`, `modules/css-properties.js`; `editor--app.css`.

Confidence: observed-in-code.

### Context menu (quick actions)

Behaviour
- Opened by right-click (native menu) or Ctrl+Space / Alt+Enter (`editor:toggle-menu`, in-editor list `list--menu` at the caret, keyboard-driven like autocomplete). Right-click outside the current selection first selects the word under the pointer.
- Items depend on the caret position; the native menu always ends with Cut, Copy, Paste.
  - Misspelled word: up to 4 corrections, with differing letters shown red; then "Add to Dictionary".
  - Link or image at caret: target is a local file → "Open File" (or "Open <name>" for reference links) if openable, "Show in Finder" / "Reveal in Explorer" / "Show in File Manager", "Show in Sidebar" if inside the project. Target is a URL → "Visit Link" (or "Visit <url>", truncated to 40 chars + "..."). Target starts with `#` → "Go to Heading". Target missing → "Create File" (creates it empty and opens it in a tab).
  - Reference link/image or footnote ref: "Go to Definition" (selects the definition); reference link/image also "Convert to Inline".
  - List item: see List section.
  - `[[toc]]`: "Convert to List" replaces it with a nested bullet list of links to every heading (two spaces of indent per heading level actually used, anchors are slugs).
  - Emoji character next to the caret: "Convert to Text" (→ `:name:`). Emoji shortcode at caret: "Convert to Unicode".
  - Single-line text selection that is not a URL: "Search for "…"" (quoted, cut to about 47 characters at a word boundary) opens a Google search.

Source: `extensions/Editor/Editor.Links.js`, `Editor.Spellcheck/Editor.Spellcheck.Menu.js`, `Editor/Editor.Markdown.Menu.js`, `Editor/Editor.SearchMenu.js`; dump `extensions/Editor/Editor.js`, `Editor.Mouse.js`.

Confidence: observed-in-code.

### Links: clicking

Behaviour
- Holding Cmd (Mac) / Ctrl turns every link in the document into a clickable area with a pointer cursor; releasing the key or the window losing focus turns it off.
- Cmd/Ctrl+click on a link opens its target: URLs in the browser, local paths (resolved relative to the file) in Caret or the system.
- Plain click places the caret; links do not open.
- Anchor links (`#slug`) navigate to the heading whose slug matches and scroll it to about 3 lines from the top, selecting the heading text.

Source: dump `Editor.InteractiveMode.js`, `Editor.Markdown.js`; `editor--highlights.css`.

Confidence: observed-in-code.

### Images inline

Behaviour
- A line that contains nothing but an image `![alt](url)` (and the image loads) is shown as the picture instead of its text: the source line is hidden and a preview line is inserted. Height is the image height scaled to fit the text width, capped at 200px, plus half a line of spacing; it respects the line's indent. URLs resolve relative to the current file. Broken images fall back to showing the text.
- Moving the caret onto the image line selects past it: the caret skips to the start or end; with a selection, the selection is extended to the end of the line. When the caret is at the start of the image line a blue overlay marks the image as selected.
- With the caret at the image line start: Enter expands the line to show its Markdown text for editing (stays expanded until the caret leaves); Space opens a zoomed view of the image. Backspace deletes the whole image line. Arrow Up/Left at document start or Down/Right at document end inserts an empty line before/after the image so you can type.
- Clicking the image when the caret is already on it zooms; zoom animates the image to the centre of the window (max window minus 120px, never above natural size) over a dimmed background; click, Esc or Space closes. Hover shows a zoom-in cursor when the image line is selected.
- Dropping image files on the window inserts `![<file name without extension>](<path relative to the current file>)` at the caret; other openable files open in tabs. Dropped links become `[title](url)`, dropped linked images `[![alt](src)](url)`, dropped HTML or text is pasted.

Source: dump `Editor.Markdown.Images.js`, `Editor.DragDrop.js`, `Editor.Markdown.js`, `extensions/Editor/Editor.js`; `editor--app.css`.

Confidence: observed-in-code.

### Math

Behaviour
- Each complete math block (opening fence, non-empty body, closing fence) is rendered with KaTeX (display mode, left-aligned, 1.5× size) and drawn over its source lines, which are blanked out with the background colour.
- When any cursor or selection touches the block or the line just before/after it, the rendering hides and the source shows for editing.
- Renderings are created lazily for blocks in view and redrawn on edits and resize.
- Rendering is hidden while Find is open and while the live (split) preview is showing.
- Inline math is not rendered in the editor; it is styled as gold code.

Source: dump `Editor.Markdown.Math.js`; `editor--app.css`, `editor--highlights.css`; `extensions/Preview/Preview.Modes.js`.

Confidence: observed-in-code.

### Code highlighting in fenced blocks and code files

Behaviour
- Fenced code with a language tag is tokenised with Prism (via `prism-electron`, languages loaded on first use, about 150 available). Unknown languages show unhighlighted.
- Caret next to a bracket highlights it and its match. Selecting a whole word highlights its other whole-word occurrences. (Code files and code syntaxes; options `matchBrackets`/`matchWords` are off for Markdown text.)
- Spelling mistakes inside code blocks are ignored.
- Markdown file extensions recognised: .md .markdown .mmd .multimarkdown .mdown .mkdn .mkd .mdwn .mdtxt .mdtext .mdml. Other text files are edited with code helpers: JavaScript (.js .jsx .es6 .javascript), CSS (.css .scss .less), HTML (.html .xml .markup) and a long list of Prism languages by extension.

Source: dump `extensions/Editor/Editor.js`, `Editor.Markdown.js`, `Editor.Code.js`; `extensions/Editor/Editor/Editor.CodeSyntaxes.js`, `Editor.CSS.js`, `Editor.JavaScript.js`; `node_modules/prism-electron/`.

Confidence: observed-in-code.

### Selections and multiple cursors

Behaviour
- Mouse: click places caret; Shift+click extends from the last caret; Alt+click adds a cursor; double-click selects a word (sub-word aware), triple-click a line, with Alt to add them as extra selections; dragging after double/triple-click extends by words/lines; Cmd/Ctrl+Alt+drag makes a column (box) selection, one selection per line.
- Add Next Occurrence (Cmd/Ctrl+D; Mac also Ctrl+G; others Alt+J): with no selection selects the word under the caret; then adds the next occurrence of the selected text, wrapping to the top.
- Add Each Occurrence (Mac Cmd+Ctrl+G, others Alt+F3): selects all occurrences.
- Remove Last Occurrence (Cmd/Ctrl+U; Mac Ctrl+Shift+G; others Alt+Shift+J).
- Add Selection Above / Below (Shift+Ctrl+Up/Down): adds a cursor/selection at the same column on the adjacent line, skipping lines too short for a range selection.
- Split Selection Into Lines (Cmd/Ctrl+Shift+L).
- Extend Selection (Alt+Up; also Cmd+Ctrl+Shift+Right): grows to the smallest larger unit among word, sentence (English sentence parser, single line), line, enclosing bracket pair, paragraph (blank-line separated), indented block, list/pattern block and nested levels, Markdown tree node, heading section, whole document. Shrink Selection (Alt+Down; also Cmd+Ctrl+Shift+Left) steps back.
- When pasting text whose line count equals the number of cursors, each cursor gets one line.
- Select All Cmd/Ctrl+A.

Source: dump `Editor.Mouse.js`, `Editor.Code.js`, `Editor.ExtendSelection.js`, `Editor.Input.js`; `menu.js`.

Confidence: observed-in-code.

### Line commands and other edit commands

Behaviour
- Move Line Up/Down (Mac: Cmd+Ctrl+Up/Down, Alt+Shift+Up/Down, Cmd+Alt+Up/Down; others Alt+Shift+Up/Down, Cmd+Alt+Up/Down, Ctrl+Up/Down): moves all lines touched by each selection; renumbers ordered lists.
- Duplicate Line Cmd/Ctrl+Shift+D: copies touched lines below, selection follows the copy.
- Delete Line Cmd+Shift+K / Ctrl+Shift+K.
- Toggle Case Cmd/Ctrl+Shift+U: on the selection or the word at the caret; if any capital is present the text goes lower case, otherwise upper case.
- New line above Cmd/Ctrl+Shift+Enter, new line below Cmd/Ctrl+Enter. Shift+Enter inserts a plain line break (no list continuation).
- Deleting: Alt+Backspace / Alt+Del delete by word; Cmd+Backspace / Cmd+Del to line start/end. Ctrl+T transposes characters (Mac).
- Cursor movement: arrows, Home/End, PageUp/PageDown, Alt+Left/Right by word, Cmd+Left/Right line start/end, Cmd+Up/Down document start/end, Ctrl+Home/End, Ctrl+Left/Right; Mac Emacs keys Ctrl+A/E/B/F/N/P, Alt+B/F. Up/Down keep the desired horizontal pixel position. Commands also exist to move/select to the start/end of the current Markdown block (no default keys).
- Undo Cmd/Ctrl+Z, Redo Cmd/Ctrl+Shift+Z or Cmd/Ctrl+Y. Undo steps are cut when typing switches between inserting and deleting, after 1 second without edits, and around every command; undo restores the selections too. Undo history is kept per open file.
- Go › To Last Edit (Cmd/Ctrl+Shift+Backspace, Ctrl+Q, Mac Ctrl+-, others Alt+-) and To Next Edit (hidden; Mac Ctrl+Shift+- / Ctrl+=): jump between the last 10 edit locations, across files (reopens the file).

Source: dump `Editor.Code.js`, `Editor.Navigation.js`, `Editor.History.js`, `Editor.EditPositions.js`, `Editor.Input.js`, `extensions/Editor/Editor.js`; `menu.js`.

Confidence: observed-in-code (exact key-to-command mapping for every navigation key not fully traced).

### Find in file

Behaviour
- Edit › Find (Cmd/Ctrl+F) shows a small dark box (210px wide) at the bottom right of the window with one text field.
- If text is selected (single line), it is pre-filled and the next match selected; otherwise the field is empty.
- Typing highlights all matches in yellow and selects the first match below the top of the visible area (orange). Matching ignores case. First pass keeps matches that start the space-separated chunk they are in (as judged by the app's fuzzy filter); if that finds none, all substring matches count. No regex, whole-word or case options.
- Enter / F3: next match; Shift+Enter / Shift+F3: previous; both wrap. Cmd/Ctrl+G and Cmd/Ctrl+Shift+G do the same from anywhere.
- No matches with non-empty text: the box turns the error colour.
- Esc closes. If there were no matches, scroll position and selection return to where they were before Find opened.
- Matches are redrawn with Markdown styling inside the highlight; highlights update as the document changes.
- Edit › Replace… does not show a replace field; it shows a dialog telling the user to use Selection › Select Each and type. (A replace field and replace function exist in code but are not reachable.)
- Find in Folder (Cmd/Ctrl+Shift+F) is a separate feature (other spec).

Source: `extensions/Find/Find.js`, `Editor.Find.js`, `find.css`; `editor--highlights.css`; `menu.js`.

Confidence: observed-in-code.

### Spellcheck and autocorrect

Behaviour
- Edit › Check Spelling (preference `spellcheck`, default on) underlines misspelled words with a 3px error-coloured line.
- Uses the operating system's spelling engine. Language is detected per line (franc), with US vs British English told apart by spelling; on macOS the system setting "automatically identify languages" or the preferred spelling language is followed, re-read when the window gains focus.
- Rechecks the changed lines immediately after a typed space or deleted space, otherwise 1 second after the last change.
- Not flagged: one-character words, words with special characters, words in the app's own word list, anything inside code blocks (fenced, indented, math, front matter, HTML). For English, a list of two-letter transpositions is always flagged.
- Corrections in the context menu are ranked by the app's score, then similarity; picking one replaces the word in one undo step. "Add to Dictionary" adds to the system dictionary and rechecks.
- Edit › Autocorrect Spelling (preference `autoCorrectSpelling`, default off): when you type a space right after a misspelled word that was typed character by character, the word is replaced with the best automatic correction in its own undo step, and the corrected word flashes a grey background that fades over 1 second. The same word at the same position is never corrected twice, so undo followed by space keeps your spelling.
- A LanguageTool grammar checker (languagetool.org web API, 700ms after typing) exists in the code but is not loaded by the editor in this build.

Source: dump `Editor.Spellcheck.js`, `extensions/Editor/Editor.js`; `extensions/Editor/Editor.Spellcheck/*.js`; `node_modules/spelling/`; `extensions/Editor/Editor/Editor.LanguageTool*.js`; `menu.js`.

Confidence: observed-in-code. LanguageTool being inactive is inferred from it not being loaded anywhere.

### Typewriter mode

Behaviour
- View › Mode Typewriter (`window:typewriter-mode`, preference `typewriter`, default off).
- Adds top and bottom padding of about half the editor height so the first and last lines can reach the middle.
- After every edit or caret move, scrolls so the caret's line sits at the vertical middle. Jumps more than 1.5 lines scroll smoothly; smaller ones snap. Nothing happens while the mouse button is held; it recentres on release.
- Other code's scroll-into-view requests are ignored while active.

Source: `extensions/Editor/Editor/Editor.Typewriter.js`; dump `extensions/Editor/Editor.js`; `menu.js`.

Confidence: observed-in-code.

### Block focus

Behaviour
- When active, everything outside the Markdown block(s) containing the selection is covered by a semi-transparent layer, dimming it; updates on every caret move or edit.
- The code for a `focusMode` preference and `window:focus-mode` command exists but is never called in this build and there is no menu item; CSS labels the style "deprecated". Treat as not shipped.

Source: `extensions/Editor/Editor/Editor.BlockFocus.js`; dump `extensions/Editor/Editor.js`; `editor--highlights.css`.

Confidence: observed-in-code (unused).

### Vertical align

Behaviour
- When active, short documents are centred vertically: top padding = half the visible height minus half the text height, never less than the normal padding. Padding changes animate (0.2s) after a 200ms pause, except tiny or large (>100px) changes, which apply at once.
- Nothing in the readable code or the dump turns it on in this build.

Source: `extensions/Editor/Editor/Editor.VerticalAlign.js`.

Confidence: observed-in-code; whether any setting enables it is unknown.

### Placeholder, read-only and embedded text fields

Behaviour
- Placeholder: an element shown at the top of the editor only while the document is empty; its text is set by the caller (unknown for the main editor; for an editor that replaces a `<textarea>` it is the textarea's placeholder).
- Read-only: while the full-screen preview is open the editor ignores input. Separately, a "writable ranges" mode lets only given ranges be edited: deletions are clipped to the range, input outside is blocked, Tab/Shift+Tab move between ranges, clicking a range selects it. No caller found.
- A textarea mode replaces a `<textarea>` with an editor of the same height, optional auto-grow, and a small diagonal resize grip at the bottom right. Probably used in other windows (e.g. preferences); no caller found in this scope.

Source: `extensions/Editor/Editor/Editor.Placeholder.js`, `Editor.ReadOnly.js`, `Editor.TextArea.js`; `extensions/Preview/Preview.Modes.js`.

Confidence: observed-in-code; callers for writable ranges and placeholder text unknown.

### Git change marks

Behaviour
- When the open file is inside a Git repository, the editor compares it with the committed version 50ms after each change (and on focus) and marks changed lines with a faded character just outside the right edge of the text column (30px out): `+` added, `~` changed, `D` deleted. Wrapped lines of a changed line are all marked; a deletion marks one row.
- Marks clear when switching tabs or when the file is not in a repository.

Source: `extensions/Editor/Editor/Editor.GitDiff.js`, `extensions/Git/Git.File.js`, `editor--app.css`.

Confidence: observed-in-code (the side is from CSS `right: -30px`; exact visual placement needs the running app).

### Text stats

Behaviour
- View › Show Stats (`window:toggle-text-stats`, preference `text-stats.visible`, default off) shows a counter at the bottom right.
- Counts the selection if there is one, otherwise the whole document; background turns selection-blue while counting a selection.
- Modes (preference `text-stats.type`, default `word-count`): words ("N W"; punctuation stripped, then whitespace-separated chunks), characters ("N C"), reading time at 200 words per minute ("mm:ss RT"). Clicking the counter opens a menu with all three values to pick from.
- Hidden when the document is empty or no tab is open. Updates when idle after selection changes.

Source: `extensions/TextStats/TextStats.js`; `css/all.css`.

Confidence: observed-in-code.

### Keyboard shortcuts (editor-related menu items)

Edit: Undo Cmd/Ctrl+Z; Redo Shift+Cmd/Ctrl+Z; Cut; Copy; Copy as Rich Text Cmd/Ctrl+Shift+C; Copy as HTML Cmd/Ctrl+Alt+C; Paste Cmd/Ctrl+V (+ Shift+Ins off Mac); Paste Formatted (none); Move Line Up/Down, Duplicate Line, Delete Line, Toggle Case (see Line commands); Show Context Menu Ctrl+Space, Alt+Enter; Find… Cmd/Ctrl+F; Find in Folder… Cmd/Ctrl+Shift+F; Replace… (none); Check Spelling, Autocorrect Spelling (checkboxes).

Selection: Select All Cmd/Ctrl+A; Extend Selection Alt+Up / Cmd+Ctrl+Shift+Right; Shrink Selection Alt+Down / Cmd+Ctrl+Shift+Left; Add Next Occurrence, Add Each Occurrence, Remove Last Occurrence, Add Selection Above/Below, Split Selection Into Lines (see Selections).

Format: Heading 1–6 (none); Bold Cmd/Ctrl+B; Italic Cmd/Ctrl+I; Strikethrough, Mark (none); Link Cmd/Ctrl+K; Image, List, Ordered List, Task List, Quote (none); Comment Cmd/Ctrl+/; Code, Code Block, Math, Math Block, Add Table of Contents, Add Thematic Break, Add Page Break (none); Clear Syntax Cmd/Ctrl+Alt+Backspace.

Go: To File… Cmd/Ctrl+P, Cmd/Ctrl+T, Cmd/Ctrl+Shift+O; To Heading… Cmd/Ctrl+R; To Command… Cmd/Ctrl+Shift+P, Cmd/Ctrl+Shift+A; To Next/Prev Tab Cmd/Ctrl+Alt+Right/Left, Cmd/Ctrl+Shift+]/[; To Last Edit / To Next Edit (see Line commands).

View (editor-related): Mode Typewriter; Show Stats; Font Size Up/Down/Default.

Editor-internal keys not in the menu: Tab/Shift+Tab (indent, jump out of inline element, next table cell, next writable range, accept autocomplete), Cmd/Ctrl+] and [ (indent/outdent), Cmd/Ctrl+Enter and Cmd/Ctrl+Shift+Enter (new line below/above), Shift+Enter (plain new line), Esc (close menu, clear empty list item), Cmd/Ctrl+G and Cmd/Ctrl+Shift+G (next/previous find match), Cmd/Ctrl+Alt+drag (column selection).

Source: `SRC/menu.js`; dump modules listed above.

Confidence: observed-in-code. Shortcuts are user-configurable (Preferences › Keyboard Shortcuts); menu values are the defaults.

### Unknowns

- How `editor--large-headings` is switched on (preference name and default).
- Default fonts and sizes for prose (`--editor-font`, size, line-height multiplier); the values are set in snapshot code outside this scope (`Caret.js`), and Merriweather support suggests a serif option.
- Main editor placeholder text, and which feature uses writable ranges.
- Whether vertical align is reachable from any setting.
- Exact look of Git marks, heading labels in the margin, image previews and math overlays, at real sizes and in dark mode.
- Exact behaviour of the find filter's first pass on real text (which matches it keeps).
- Precise mapping of every navigation key (e.g. what Ctrl+Left/Right do on Mac versus Windows).
- Scroll behaviour when the caret moves off screen (padding, centring) outside typewriter mode.
- Performance limits (large files, many images or math blocks).

# Part 2: Preview, rendering and export

## Caret Beta 4.0.0-rc23: rendering, preview, themes, export

Paths are relative to `SRC` (the unpacked app `src` folder). "Snapshot-only" means the file is empty on disk; its code was read from the text dump of the V8 startup snapshot (`scratchpad/snap-src.txt`).

### Libraries

| Name | Bundled version | Role |
|---|---|---|
| markdown-it | 8.4.2 | Core Markdown parser and HTML renderer (CommonMark plus GitHub-style tables and strikethrough) |
| linkify-it | 2.1.0 | Auto-links bare URLs (pulled in by markdown-it) |
| markdown-it-mark | 2.0.0 (git fork astoilkov/markdown-it-mark) | `::text::` to `<mark>` (the fork changes the marker from `=` to `:`) |
| markdown-it-emoji | 1.4.0 | `:name:` shortcodes and text shortcuts such as `:)` |
| markdown-it-attrs | 1.2.1 | `{.class #id key=value}` attribute blocks |
| markdown-it-footnote | 3.0.1 | `[^1]` footnotes and `^[inline]` footnotes |
| markdown-it-front-matter | 0.1.2 | Recognises a leading `---` YAML block so it is not rendered |
| markdown-it-task-lists | 1.4.1 | `- [ ]` / `- [x]` checkboxes |
| markdown-it-anchor | 2.7.1 | Adds `id` to every heading |
| markdown-it-table-of-contents | 0.3.6 | `[[toc]]` marker |
| markdown-it-math | 4.0.1 (git fork astoilkov/markdown-it-math) | `$...$` / `$$...$$` / `$$$...$$$` math |
| markdown-it-page-break (app's own) | n/a | `+++` page breaks, `extensions/Markdown/markdown-it-page-break.js` |
| katex | 0.8.3 | Renders math to HTML |
| dompurify | 1.0.10 | Sanitises rendered HTML |
| prism-electron | 1.15.0 (git fork astoilkov/prism-electron, wraps Prism) | Code-block syntax highlighting, 151 language files loaded on first use |
| @sindresorhus/slugify | 0.2.0 | Heading ids and table-of-contents link targets |
| html-to-markdown (app's local module) | 0.1.0 | HTML to Markdown, used by Paste Formatted |
| wrap-emoji (app's local module) | 0.1.0 | Wraps emoji characters in `<span class="emoji">` (caller unknown) |
| emojilib / emoji-regex | 2.2.12 / 6.5.1 | Emoji data and matching (callers snapshot-only) |
| mermaid | not bundled | Referenced in code but the package is absent; diagrams do not render |

### Markdown flavour

#### Behaviour
- Parser: markdown-it with raw HTML allowed in the source, auto-linking on, and its default typographer off (straight quotes stay straight, `--` stays two hyphens).
- Single newlines inside a paragraph do not become `<br>` (markdown-it default `breaks: false`).
- GitHub-style pipe tables and `~~strikethrough~~` work (markdown-it default rules).
- Auto-linking requires a scheme: `https://example.com` becomes a link; `example.com` and `www.example.com` stay plain text (fuzzy links off). Bare email addresses still link (linkify default).
- `::text::` renders as `<mark>` (Caret ships an altered copy of markdown-it-mark that uses `:` instead of `=`; `==text==` stays plain text). No preview theme styles `mark`, so it shows with the browser's default yellow.
- Emoji: `:smile:` style shortcodes and text shortcuts render as `<span class="emoji emoji-NAME">CHAR</span>`, where NAME is the shortcode name and CHAR the Unicode emoji.
- Attribute blocks `{.cls #id attr=val}` after a heading, paragraph, inline element etc. add those attributes to the element. Delimiters are `{` and `}`.
- Footnotes: `[^label]` references with `[^label]: text` definitions, and `^[inline text]`. Output follows markdown-it-footnote 3: superscript links, then a separator rule and a numbered footnote section at the end.
- Front matter: a `---` YAML block at the very start of the document is consumed and produces no output. Its contents are ignored by the renderer.
- Task lists: `- [ ]` and `- [x]` items render as real, clickable checkboxes (not disabled), each wrapped in a `<label>`; list items get class `task-list-item`, checkboxes `task-list-item-checkbox`.
- Heading ids: every heading (levels 1 to 6) gets an `id` made by slugify 0.2.0 (lower case, words joined by `-`, accented letters transliterated). A repeated slug gets `-1`, `-2` ... appended. No visible permalink symbol is added.
- Table of contents: a paragraph starting with `[[toc]]` (any letter case) is replaced by a `<div class="table-of-contents">` holding a nested `<ul>` of links to all headings, levels 1 to 6, using the same slugs.
- Math (two rule sets are registered, the first wins on overlap):
  - Inline `$$x$$` and inline `$x$` render as inline KaTeX.
  - A block fenced by `$$$` lines, or by `$$` lines, renders as display KaTeX.
  - A `$$` block whose whole content is itself wrapped in single `$` has those outer `$` removed first.
  - KaTeX runs with errors suppressed (bad input shows KaTeX's red error text). If KaTeX still throws, the raw source is shown in a span with class `katex katex--error` (inline) or `katex-display katex--error` (block).
  - Results are cached per source text and inline/block mode for the life of the window.
- Page break: inside a paragraph, a line of three or more `+` characters, optionally with spaces between them (`+++`, `+ + +`), becomes `<div class="page-break"></div>`. Text before and after the line is parsed as separate blocks. Format > Add Page Break (`editor:page-break`) inserts one (insert text inferred).
- Fenced code: if the info-string language is one Prism knows, the code is highlighted with Prism `token` spans; otherwise it is HTML-escaped and shown plain. Output is markdown-it's standard `<pre><code class="language-X">`.
- Mermaid code blocks are not rendered as diagrams; they show as ordinary code blocks.

#### Source
`extensions/Markdown/Markdown.js`, `extensions/Markdown/markdown-it-page-break.js`, `node_modules/markdown-it-table-of-contents/index.js`, `node_modules/markdown-it-anchor/index.js`, `node_modules/prism-electron/index.js`

#### Confidence
observed-in-code (plugin options and renderers). Exact footnote and emoji output markup follows each plugin's documented behaviour at the bundled version.

### Sanitisation and link rewriting

#### Behaviour
- Every render passes the full markdown-it HTML through DOMPurify 1.0.10 with its default settings before it reaches the page. Scripts, inline event handlers and `javascript:` URLs are removed; `<iframe>` and `<object>` are dropped (DOMPurify defaults, inferred).
- Raw HTML that survives DOMPurify (for example `<details>`, `<kbd>`, `<img>`, inline `style` attributes) renders.
- For the on-screen preview only (not HTML export), after sanitising:
  - `img src`, `a href` and `object data` values go through `caret.resolve`: a leading `file://` is stripped; full URLs and `#anchors` are left alone; the path is URL-decoded; `~/` becomes the home folder; a path starting with `/` is joined to the project root folder when there is one; anything else is joined to the current file's folder (overlapping leading path segments are merged rather than repeated). With no project root and no open tab the path is left as is.
  - The element directly before and directly after the table of contents is deleted. This removes the empty paragraphs the browser creates when the plugin wraps a `div` inside a `p`.

#### Source
`extensions/Markdown/Markdown.js`

#### Confidence
observed-in-code (pipeline, `caret.resolve` in snapshot-only `Caret.js` and `extensions/Project/Project.js`), inferred (exact DOMPurify allow-list)

### Preview rendering

#### Behaviour
- The preview is a `div.preview` holding a shadow root (isolated style scope). Inside: the KaTeX stylesheet, `extensions/Preview/css/base.css`, the active theme stylesheet, and a `section.content` that holds the rendered document.
- Rendering is incremental. If the new document has the same number of top-level nodes as the current one, each node is compared in order: a different node type or tag forces a full replace; otherwise a node whose inner HTML differs gets only its inner HTML replaced. For top-level elements other than headings, `p`, `ul`, `ol`, `pre`, `hr`, `br`, attributes are copied across too. A different node count forces a full replace.
- After each render, task checkboxes are wired up: ticking or unticking the Nth checkbox in the preview toggles the Nth task item in the editor's source text.
- Clicking a link whose `href` starts with `#` scrolls the preview to the element with that id (works for table-of-contents links and footnotes). Any other link click becomes a navigation that the window intercepts (`will-navigate` / `new-window`): the target is passed through `caret.resolve` and then `caret.open`, so it opens outside the preview rather than replacing it.
- Right-clicking the preview shows the app's copy/paste context menu.
- The preview element is keyboard-focusable and its text is selectable.
- base.css removes the top margin of the first block and the bottom margin of the last block, gives page breaks a forced page break before them, and in print wraps long lines in code blocks instead of cutting them off.

#### Source
`extensions/Preview/Preview.js`, `extensions/Preview/css/base.css`, `Caret.js` (snapshot-only)

#### Confidence
observed-in-code

### Preview modes

#### Behaviour
- Two modes, each a checkbox in the View menu. Turning one on turns the other off.
- Split preview: View > Show Preview, command `window:toggle-live-preview`, shortcut Cmd/Ctrl+Shift+I.
  - Preview fills the right half of the window; the editor and title bar shrink to the left half. When the file sidebar is open, the preview width is half the window minus half the sidebar width (sidebar is 200px).
  - The editor re-wraps its lines to the new width. Inline math previews inside the editor are hidden while split preview is on, and restored when it is turned off.
  - The preview re-renders after every edit. In practice each re-render is deferred to the next event-loop turn, so several quick edits in the same turn produce one render (the throttle code reads a timing value that is never set on that object, which collapses its delay to zero).
  - Scroll sync runs one way, editor to preview. The first editor scroll event after opening is ignored. After that, 100 ms after the editor stops scrolling, the preview scrolls to the matching spot: smoothly, or instantly if the jump is over 5000px.
  - Matching spot: editor at top gives preview top; editor at bottom gives preview bottom. Otherwise the app takes the text from the start of the document up to the character at the middle of the first visible line, appends every reference-link definition in the document, renders that into a hidden copy of the preview, and uses its height plus the table of contents height plus the line's offset inside the editor viewport.
- Full preview: View > Preview, command `window:toggle-preview`, no default shortcut.
  - Preview covers the whole window, above the sidebar and popups. The editor is made read-only and the preview takes focus.
  - Escape leaves it. So does showing another view, or running the Show Files (`window:sidebar`) or Show Outline (`window:headings-bar`) command.
  - Opening or switching tabs scrolls the preview to the top. Edits re-render it.
  - On entry the preview jumps to the spot matching the editor's scroll position; there is no ongoing sync.
  - On exit the editor gets focus back.
- The current mode (full, split or none) is saved per window and restored when that window reopens.

#### Source
`extensions/Preview/Preview.Modes.js`, `extensions/Preview/preview.css`, `css/all.css`, `menu.js`

#### Confidence
observed-in-code

### Preview themes

#### Behaviour
- Three built-in themes ship in `extensions/Preview/themes`: `default.css`, `github.css`, `dark.css`.
- On every launch they are copied into `<user data folder>/Themes` as `Default.css`, `GitHub.css`, `Dark.css`, overwriting files of those names. Edits a user makes to those three files are lost on the next launch.
- Every `.css` file in that folder becomes a checkbox item in View > Preview Theme, named after the file without extension, added above the fixed "Add Theme..." item. Items are only added to the main window's menu.
- Each theme gets a command id `windows:<name>-preview-theme`, where `<name>` is the file name lower-cased with every non-letter removed (`GitHub.css` gives `windows:github-preview-theme`).
- Choosing a theme loads it into the preview, removes the previous theme once the new one has loaded, checks only that menu item, and saves the theme's file path app-wide (cache `preview`, key `themePath`).
- Startup theme: the saved path; if that file is missing, `Themes/Default.css`; if that is missing, the bundled `default.css`.
- Add Theme... (`application:add-custom-theme`): opens the Themes folder in the system file manager and shows a notification "Restart the app so your custom theme gets added to the menu" with a restart button. New files are not picked up without a restart.
- Theme files are written for the shadow root: they target `:host` and `.content`, and style headings, tables, block quotes, images, task-list items, KaTeX display and error classes, and Prism `.token` classes.
- Built-in theme character (described, not copied):
  - Default: light, white background, system-ui text at 16px, Roboto Mono code, content max width 626px, line height 1.8em.
  - Dark: same layout as Default on a near-black background, 15px text, Fira Mono / Roboto Mono code.
  - GitHub: a copy of GitHub's 2019-era Markdown style, Helvetica Neue stack, 16px text, max width 890px.
- A theme can set a print font size inside `@media print` on `:root`, `html`, `body`, `:host` or `.content`. The app reads the first one found (in that order) and applies it to the whole page when printing. Default and Dark set 14px.

#### Source
`extensions/Preview/preview--preload.js`, `extensions/Preview/Preview.js`, `extensions/Preview/themes/*.css`, `menu.js`

#### Confidence
observed-in-code

### Export to PDF

#### Behaviour
- File > Export to PDF... (`window:export-to-pdf`, no shortcut) opens a save dialog with a PDF filter and `.pdf` extension. Cancel does nothing.
- The PDF is Electron's `printToPDF` of the current window with default options (A4 portrait, default margins, backgrounds not printed by default; Electron defaults of that era).
- Print CSS hides everything except the preview and lays it out full width, auto height, with 48px top/bottom and 32px left/right padding, and asks for exact colour printing.
- If the preview is hidden, it is rendered and shown invisibly for the print, then hidden again.
- Content is the rendered preview with the active theme, so links and images are already resolved. `+++` page breaks start a new page. Long code lines wrap. Print font size comes from the theme as described above.
- Errors from `printToPDF` are thrown, not shown to the user.

#### Source
`extensions/Preview/Preview.js`, `extensions/Preview/css/base.css`, `css/all.css`

#### Confidence
observed-in-code (Electron default page settings inferred)

### Export to HTML

#### Behaviour
- File > Export to HTML... (`window:export-to-html`, no shortcut) opens a save dialog with an HTML filter and `.html` extension, then writes one self-contained HTML file.
- Output, in order: HTML5 doctype; UTF-8 charset; viewport meta; `<title>` set to the current file's name including extension, or `untitled`; a style rule giving `.content` the preview's current computed padding; the full text of `base.css`; the full text of the active theme file.
- In the inlined CSS every `:host` becomes `:root`, and every `var(--x)` is replaced with that variable's current computed value in the preview (recursively).
- The `<body>` holds the sanitised rendered HTML directly. It is not wrapped in `section.content`, so theme and padding rules that target `.content` do not apply in the exported file.
- Unlike the preview, relative image and link paths are left as written, and the empty paragraphs around the table of contents are kept.
- Math is exported as KaTeX HTML but no KaTeX stylesheet is included. The code meant to add a KaTeX 0.7.1 CDN stylesheet and script when the document contains math has a logic error and never adds them, so math looks broken in the exported file.
- No JavaScript, no images embedded, no fonts embedded.

#### Source
`extensions/Preview/Preview.js`

#### Confidence
observed-in-code

### Copy as Rich Text and Copy as HTML

#### Behaviour
- Edit > Copy > Copy as Rich Text: command `editor:copy-as-rich-text`, Cmd/Ctrl+Shift+C.
- Edit > Copy > Copy as HTML: command `editor:copy-as-html`, Cmd/Ctrl+Alt+C.
- Source text: the selected text when there is a non-empty selection, otherwise the whole document.
- Both render it with the same pipeline as export (markdown-it plus DOMPurify; relative paths not resolved; no theme CSS, no KaTeX CSS).
- Rich Text writes two clipboard formats at once: the rendered HTML as HTML, and the original Markdown as plain text. Pasting into a rich editor gives formatting; pasting into a plain-text field gives the Markdown.
- Copy as HTML writes the rendered HTML source as plain text only.

#### Source
`menu.js`, `extensions/Editor/Editor.js` (snapshot-only)

#### Confidence
observed-in-code

### Paste Formatted

#### Behaviour
- Edit > Paste > Paste Formatted: command `editor:paste-formatted`, no default shortcut. Plain Paste is Cmd/Ctrl+V (also Shift+Insert off macOS).
- Reads the clipboard's HTML; if there is none, reads its plain text instead. Either is run through the bundled `html-to-markdown` module and inserted with the editor's normal paste. Plain text therefore has its line breaks and surrounding whitespace collapsed by the text-node trimming below. Conversion rules:
  - h1 to h6 become `#` to `######` headings with a blank line around them.
  - Every `li` becomes `- item` (ordered lists also become bullets; nesting is lost).
  - `blockquote` gets a single leading `> `.
  - `pre` becomes a fenced block with three backticks and no language; `code` inside `pre` is left bare, other `code` gets single backticks.
  - `em` becomes `*x*`, `strong` becomes `**x**`, `strike` becomes `~~x~~` (`b`, `i`, `s`, `del` have no rule and lose their formatting).
  - Links become `[text](href)`; a link with no text is dropped; with no href, only text remains; when text equals href (ignoring a trailing `/`), only the URL is output.
  - Images become `![alt](src)`.
  - Tables become padded pipe tables. When the first row is not a header row, an empty header row is added.
  - `br` gives a newline, `hr` gives `***`.
  - `head`, `style`, `script`, elements with inline `display:none` or `opacity:0`, and Apple clipboard helper spans are skipped.
  - Text nodes are trimmed; a space is inserted between adjacent pieces when neither side has whitespace; block elements are followed by a newline. The final string is trimmed.

#### Source
`menu.js`, `extensions/Editor/Editor.js` (snapshot-only), `node_modules/html-to-markdown/index.ts`, `node_modules/html-to-markdown/table.ts`

#### Confidence
observed-in-code

### Dark mode (app theme)

#### Behaviour
- View > Mode Dark: checkbox, command `window:dark-mode`, shortcuts Cmd/Ctrl+Alt+L and Cmd+Ctrl+N.
- Stored app-wide as `nightMode` (cache `app`, default off).
- At window load, exactly one of two stylesheets is enabled: `css/themes/default.css` (light) or `css/themes/default-dark.css` (dark). New windows are created with background `#F9F9F9` (light) or `#1d1d1d` (dark) to avoid a flash.
- The body gets class `--night` in dark mode (used for the macOS text cursor image).
- `window:dark-mode` flips the `nightMode` preference. On change, the app disables both stylesheets, enables the matching one, writes `nightMode` to the app cache, toggles `--night` on the app element and updates the menu checkbox. It is a silent preference (not shown in the Preferences file).
- Dark mode does not touch the preview theme; the two are independent settings.
- App palette (CSS custom properties on `:root`):

| Variable | Light | Dark |
|---|---|---|
| `--material` (background) | rgb(250,250,250) | rgb(40,40,40) |
| `--material-secondary` | rgb(240,240,240) | rgb(35,35,35) |
| `--material-transparent` (overlays) | hsla(0,0%,98%,.95) | rgba(40,40,40,.97) |
| `--material-line` | rgba(0,0,0,.1) | hsla(0,0%,30%,1) |
| `--color` (main text) | hsl(0,0%,30%) | hsl(0,0%,75%) |
| `--color-secondary` | hsl(0,0%,50%) | hsl(0,0%,60%) |
| `--color-tertiary` (Markdown markers) | hsl(0,0%,70%) | hsl(0,0%,40%) |
| `--color-em` (headings) | not set | hsl(0,0%,80%) |
| `--color-blue` (links) | hsl(210,20%,60%) | hsl(210,18%,60%) |
| `--color-red` | hsl(0,50%,70%) | hsla(0,70%,70%,.7) |
| `--color-gold` (inline code) | hsl(0,30%,65%) | hsl(30,15%,60%) |
| `--selection-blue` | hsla(210,80%,60%,.25) | hsla(210,25%,50%,.25) |
| `--selection-yellow` (find match) | hsl(45,95%,85%) | hsl(45,20%,45%) |
| `--selection-orange` (current match) | hsl(15,95%,85%) | hsl(15,25%,45%) |
| `--code-string` / `--code-property` | #c88 | #a77 |
| `--code-keyword` / `--code-tag` / `--code-function` | #979 | #979 |
| `--code-number` | #68a | #68a |

#### Source
`index.js`, `index.html`, `Caret.js` (snapshot-only), `css/themes/default.css`, `css/themes/default-dark.css`, `css/all.css`, `main/Application.js`, `menu.js`

#### Confidence
observed-in-code

### Font size

#### Behaviour
- View > Font Size > Up (`window:font-size-increase`, Cmd/Ctrl+= and Cmd/Ctrl+Shift+=), Down (`window:font-size-decrease`, Cmd/Ctrl+-), Default (`window:font-size-default`, Cmd/Ctrl+0).
- Two preferences: `fontSize` (prose, default 15, range 10 to 30) and `codeFontSize` (code and Markdown markers, default 13, range 10 to 30), both in px.
- Up adds 1 to both; Down subtracts 1 from both; Default restores both defaults. Changes are saved as preferences (app-wide) and the editor re-wraps.
- They set `--editor-font-size` and `--editor-code-font-size`; `--editor-inline-code-font-size` is set to `codeFontSize / fontSize` in em.
- Related preferences: `lineHeight` (default 1.6, range 1.5 to 2, multiplied by `fontSize`), `font` (default `system-ui`), `codeFont` (default `"Roboto Mono"`).
- Font size commands do not change the preview, whose themes use fixed pixel sizes.
- App fonts bundled: Merriweather (regular, bold, italic) and Roboto Mono (regular, bold).

#### Source
`menu.js`, `css/all.css`, `Caret.js` (snapshot-only)

#### Confidence
observed-in-code (range enforcement by the preferences system inferred from the `min`/`max` fields)

### Unknowns
- What `caret.open` does with a resolved local path from a preview link (open in a Caret tab or hand to the system).
- markdown-it-mark and markdown-it-math are forks by the app's author; differences from upstream are not checked.
- Electron version, and therefore the exact `printToPDF` defaults (page size, margins, background printing).
- `wrap-emoji` and `emojilib` callers (likely editor emoji display and autocomplete).
- `index.html` contains a KaTeX stylesheet link placed after the closing `</html>` tag; whether the browser applies it to the main window is untested.

# Part 3: App shell

## Caret Beta 4.0.0-rc23: app shell behaviour spec

Scope: everything outside the editor and the preview. Written from the shipped code, in my own words.

Sources and how to read "Source" lines:
- `SRC/...` is the unpacked app folder (`scratchpad/caret/src`).
- `snapshot: X` means the module X whose file in SRC is empty. Its full original source is stored as UTF-16 text inside `Electron Framework.framework/.../snapshot_blob.bin`. I dumped it to `scratchpad/snap-src.txt` and split it per module into `scratchpad/snapmods/`. So most "snapshot-only" extensions are observed in code, not inferred.
- Confidence: **observed-in-code**, **inferred-from-names**, or **unknown**.

User data folder (Electron `userData`, on macOS `~/Library/Application Support/Caret Beta`) is called "user data" below.

---

### App start, single instance, window restore

**Behaviour**
- Only one app process runs. A second launch passes its non-option arguments (file paths) to the running app as file-open requests and then quits.
- On first ever launch a random 32-character id is generated and stored (cache `uuid`). It is used as the analytics client id and in error reports.
- macOS: files opened from Finder before the app is ready are queued and opened once the first window loads; after that they go to the focused window (or to window 1, shown if hidden).
- At start the app looks for saved window-size files (`window-bounds__w<N>`) and reopens one window per file with the same numeric id N. If none exist it opens one window. The window that was focused at quit gets focus again.
- If a window's saved display no longer exists, the window is moved to the primary display and shrunk to fit.
- A window with no saved size and no explicit size starts maximised.
- Window size, position, maximised state and display are saved 200 ms after each move or resize.
- New windows open 40 px right and down from the focused window (same position if that one is maximised), using the focused window's size, or the last-closed window's size if none is focused.
- Minimum window size 400×400. The minimum width grows: ×2 while the preview is visible, +260 px while a sidebar is visible. If the window is narrower it is widened.
- macOS: hidden-inset title bar (traffic lights over the content). Linux: normal OS frame. Windows: frameless with custom buttons (see Windows title buttons).
- Window background colour before load: light `#F9F9F9`, dark `#1d1d1d`, chosen from the saved night-mode flag. The matching theme stylesheet is enabled before any other code runs, to avoid a flash.
- Startup data is passed to each window in its URL: window id, queued errors, folder to open, whether it is the first ("main") window, the file paths to open, the user data path.
- Only the main (first) window installs the full application menu and sends the analytics launch event.
- Launch placeholder: on close, each window takes a screenshot of itself and saves it as `launch__w<N>.png` in user data. On next start this image is shown full-window on top until the real UI and fonts are ready, then deleted.
- Links clicked inside the window never navigate the window; they go through the app's open logic (see Opening files).
- Pinch-zoom is disabled.
- Electron flag "enable-experimental-web-platform-features" is on.
- "Not responding" dialog with Close / Keep Waiting exists in code but nothing hooks it up.

**Source** SRC/main/main.js, SRC/main/Application.js, SRC/main/AppWindow.js, SRC/index.js, snapshot: Caret.js

**Confidence** observed-in-code

### Closing windows and quitting

**Behaviour**
- Command `window:close` (no menu item; reached from the Windows close button): macOS full screen → close the window. macOS, or more than one visible window → close the current tab (stop if the user cancels the save prompt), then delete this window's saved size and hide the window (it is hidden, not destroyed). Last visible window on Windows/Linux → quit.
- `window:close-tab` (Cmd/Ctrl+W) closes the current tab only.
- Windows/Linux: closing all windows quits. macOS: app stays running; clicking the Dock icon re-shows window 1 if no window is visible.
- On quit: remember the focused window id, then each window fires its "will-close" work (autosave, analytics minutes, launch screenshot), hides, then the app quits.
- Unsaved changes: closing a tab with changes asks `"<name>" has changes, do you want to save them?` with Save / Cancel / Don't save. Untitled tabs are named "Untitled".

**Source** snapshot: Caret.js, Tabs/Tab.js; SRC/main/Application.js

**Confidence** observed-in-code

### Opening files and folders

**Behaviour**
- Openable in a tab: files ending `.md`, `.markdown`, `.txt`, `.text` (exact list in code).
- Opening a path (from links, sidebar, palettes):
  1. Path with `#anchor`, `?query`, or trailing `/` that does not exist, but exists without that suffix → open the file in a tab and scroll to the heading named by the suffix.
  2. Openable file that exists → open in a new tab (or switch to it if already open).
  3. macOS: existing `.png .gif .jpg .jpeg .bmp .pdf` → macOS Quick Look preview over the window; closed when the window regains focus.
  4. Any other existing file → open with the OS default app.
  5. Otherwise treat as a URL and open in the browser.
- File-open requests from the OS or command line go straight to "new tab"; a path that is not a regular file (for example a folder) is ignored.
- File > Open (Cmd/Ctrl+O): system dialog "Open File". macOS allows picking files or folders; others files only. Picking a folder makes it the window's folder. Default location: the current file's folder, else the current folder (unless it is inside user data).
- File > Open Folder (Windows/Linux only in menu): dialog "Open Folder"; opens the folder and shows the files sidebar.
- Dropping a folder onto the window opens it as the window's folder.
- macOS: each opened or switched-to real file is added to the OS "recent documents" list. Windows: a jump list section "Recent" lists files from tab history.
- Relative link resolution: `~/` expands to home; a path starting with `/` resolves against the git repository root (or the window folder); other paths resolve against the current file's folder. `file://` prefixes are stripped; URLs and `#anchors` pass through.

**Source** snapshot: Caret.js (open, resolve), File/File.js, Project/Project.js

**Confidence** observed-in-code

### File types and associations

**Behaviour**
- macOS Info.plist declares the app as **owner** (default handler) of Markdown: `md markdown mmd multimarkdown mdown mkdn mkd mdwn mdtxt mdtext mdml`, exported type `io.caret.markdown`, also claims `net.daringfireball.markdown`.
- macOS also registers as an editor (not owner) for plain text `txt text` (type `io.caret.plain-text`) and content types public.plain-text, public.source-code, public.html, public.xml, public.data.
- Bundle id `io.caret`, category productivity, minimum macOS 10.8, document icon `file.icns`.
- Note: the macOS association list is wider than what opens in a tab. `.mdown`, `.mkd` etc. are not in the openable list, so they fall to "open with default app" when opened from inside the app.
- Windows installer (Squirrel): on install registers `.md .markdown .mdown .mkdwn` and creates a shortcut; on update re-registers and refreshes the desktop shortcut if one exists; on uninstall removes both.

**Source** caret-mnt/Caret Beta.app/Contents/Info.plist, SRC/main/main.win32.js, snapshot: Caret.js

**Confidence** observed-in-code

### `caret` command-line tool

**Behaviour**
- Platform wrappers run the app's own Electron binary in Node mode on `bin/cli.js`.
- `cli.js` supports `--version` (prints the app version) and the default help from the "commander" library; otherwise it starts the app detached with all arguments and exits immediately.
- The app treats bare arguments as file paths to open (see Opening files). Folders are not opened.
- Linux wrapper refuses to run as root unless `--user-data-dir=` is given, printing a message.
- Install step exists in code (`_installTerminalCommand`): macOS symlinks `/usr/local/bin/caret` to the macOS wrapper and makes it executable. Windows writes `caret.sh` and `caret.cmd` into `<install>/bin` and adds that folder to the user PATH with `setx`.
- No menu item or command calls the install step in this build.
- macOS wrapper calls `/usr/bin/python` with Python 2 syntax to resolve the symlink (breaks on current macOS).

**Source** app.asar.unpacked/bin/*, snapshot: Caret.js

**Confidence** observed-in-code (install trigger: unknown)

### Window folder (project) and welcome folder

**Behaviour**
- Each window has one current folder, remembered per window (cache `project__w<N>`).
- First launch with no remembered folder: copies the bundled welcome folder (`Welcome.md`, `Tips and Tricks.md`, `Markdown Support.md`, `Images/md-logo.png`) into user data `Introduction/` (once), makes it the folder and opens `Welcome.md`.
- Changing folder: if any tab has unsaved changes, asks "Project has changes, do you want to save them?" with Save / Cancel / Don't save. Cancel aborts the change.
- On folder change: the window title is set to the folder name (see Unknowns: the channel names do not match), the tabs for that folder are restored, the save dialog default folder becomes this folder.
- Folder index: read in the background, up to 4 folders at a time, 6 levels deep. Skips names starting with `.`, OS junk files (`.DS_Store`, `Thumbs.db`, etc.), `node_modules`, `bower_components`.
- Per-folder recent files: last 40 files opened in this folder, with last-used time.

**Source** snapshot: Project/Project.js; SRC/extensions/Project/welcome-project/

**Confidence** observed-in-code

### Recent folders

**Behaviour**
- Every folder made current is moved to the top of a global history (cache `folders`).
- File > Open Recent Folder… (`window:recent-folders`, Ctrl+R): popup titled "Folders", lists history except the current folder, each with folder icon, name and its parent path. Type to filter (sorted by match). Enter/Right opens it in this window.

**Source** SRC/extensions/Folders/Folders.js

**Confidence** observed-in-code

### Tabs

**Behaviour**
- Tab bar across the top, centred, each tab max 200 px. It is the window drag area (tabs themselves are not).
- Tabs are remembered per window per folder: list of files, current index, recently closed files (max 20). Switching folders swaps the whole tab set.
- New tabs open right after the current tab. Opening a file already open switches to it.
- Tab label: file name without extension, extension shown dimmer; untitled files show "Untitled". Dates in names are shown in a friendlier format.
- Marks: modified tab shows a dot `•`; file outside the folder shows `⇾` and a path tooltip; separate classes for preferences files, untitled files and backup tabs.
- No tabs: a large "×" placeholder in the editor area.
- Mouse: click switches; double-click on the bar toggles maximise; middle-click closes; drag to reorder.
- Right-click menu: Close Tab (Cmd/Ctrl+W), Close Other Tabs (Cmd/Ctrl+Alt+W), Close All Tabs, Move to the Left / Right (macOS Ctrl+Shift+Left/Right), Show in Finder / Reveal in Explorer / Show in File Manager; on a backup tab also "Revert to This".
- Keys: Cmd/Ctrl+1…9 go to tab N; next/previous tab (Cmd/Ctrl+Alt+Right/Left, Cmd/Ctrl+Shift+] / [) wrap around; reopen last closed tab Cmd/Ctrl+Shift+T.
- New file (Cmd/Ctrl+N): creates an empty `untitled-files/<10 random chars>.md` in user data and opens it.
- Save on an untitled file runs Save As.
- Save As: dialog "Save as...", filters Markdown (md) and All Files; default name is today's date (YYYY-MM-DD) for untitled, else the current name; default folder is the last Save As folder, else the window folder, else home. Adds `.md` if no extension given.
- When the window regains focus, the open file is re-read. If it changed on disk and the tab has unsaved edits: "<name> has changed, do you want to reload it?" with Cancel / Reload; Cancel is remembered for that disk version. With no unsaved edits it reloads silently, keeping selection.
- Read- or write-protected files/folders prompt "This file is write-protected." (or read-protected / folder) with Overwrite / Cancel; Overwrite changes the file permissions.
- Files renamed, cut or trashed from the sidebar update or close their tabs.
- Line endings are normalised to `\n` when read.

**Source** snapshot: Tabs/Tabs.js, Tabs/Tab.js, File/File.js; SRC/extensions/Tabs/tabs--main.js; SRC/css/all.css

**Confidence** observed-in-code

### Tab state memory (unsaved edits, scroll, undo)

**Behaviour**
- Per file the app stores: scroll position, undo history, selection, whether it has unsaved edits, last-used time (cache `file.history`).
- Saved on tab switch, save, window blur, page unload, and every 30 s while the editor has focus.
- Unsaved file contents are copied to user data `unsaved-files/` and restored when the file is reopened, even after restart.
- Scroll/undo/selection are restored only if last used under 6 hours ago; otherwise the file opens at the top with empty undo.
- Keeps 50 entries; entries with unsaved edits are never dropped.
- "Don't save" on close discards the stored entry.

**Source** snapshot: Tabs/Tabs.History.js

**Confidence** observed-in-code

### Autosave

**Behaviour**
- File > Autosave (`window:toggle-autosave`) is a checkbox, default **on**, stored in silent preference `file.autosave`.
- When on: saves the current file 500 ms after edits settle, on window blur, and synchronously before tab switch/open, before close (if the answer was Save), and on window close.
- Never autosaves untitled files.
- Never autosaves the Preferences or Keyboard Shortcuts files (they count as "modified" until saved by hand, which triggers parsing).
- With autosave on, normal files never show the modified dot and closing never prompts.
- Autosave writes without a dialog and fires the normal "save" event (which can trigger the purchase prompt, git refresh, etc.).

**Source** snapshot: Tabs/Tabs.Autosave.js, Tabs/Tab.js, File/File.js

**Confidence** observed-in-code

### Backups

**Behaviour**
- Always on (the preference hook `_initBackupsPreference` is empty).
- Stored in user data `file-revisions/<file path with separators replaced by "__--__", drive colon dropped, extension dropped>/`. Each backup file is named by its timestamp. A `metadata` JSON file records the original path. If the path cannot be turned into a folder name, a random 16-character folder is used and remembered (cache `file.revisions`).
- When a backup is due: on tab open/switch, before tab switch/close, and every 10 minutes. A backup is taken only if there is none, or the newest is older than 1 hour and the length differs from the current text. It is written at the next moment the user inserts or deletes a line break.
- Thinning before each save: keep at most one backup per hour today, one per day for the last 8 days, one per week for 4 weeks, one per month for 23 months; others are deleted.
- Renaming a file in the app renames its backup folder.
- File > Backups… (`window:backups`): popup titled "Backups" listing this file's backups newest first with friendly dates. Picking one opens a tab named `<file> | <backup>` that shows the merged diff, read-only, with added and removed text highlighted.
- In that tab, the tab context menu adds "Revert to This": writes the backup content over the original, opens the original, closes the backup tab.
- Go to File hides backup tabs.

**Source** snapshot: Backups/Backups.js, Backups/Backups.Popup.js, Tabs/Tabs.js

**Confidence** observed-in-code

### Files sidebar

**Behaviour**
- View > Show Files (`window:sidebar`, Cmd/Ctrl+Shift+E). Pressing it while the sidebar is visible and focused hides it; otherwise shows and focuses it and reveals the current file.
- Visible by default per window (cache `sidebar__w<N>`, default visible).
- Header is a filter field whose placeholder is the folder name and tooltip its path. Typing filters items. Esc or Tab clears the filter; if already empty, returns focus to the editor.
- Tree: folders first, then files, natural case-insensitive name order. Hidden (dot) and junk files skipped. Folders load on demand; expanded state remembered.
- Icons: folder (closed/open), text file (`md mdown markdown txt`), image (`png jpg gif`), other file. Non-openable files get a dimmer class. Current file highlighted.
- Git marks per item: added / changed / deleted / renamed; a folder takes "changed" if any child is changed, else any child change.
- Keys: Up/Down (macOS also Ctrl+N/Ctrl+P) move, Shift+Up/Down extend selection, Home/End, Right expands folder or opens file, Left or Cmd+Up collapses, Enter or Cmd+Down opens, Cmd/Ctrl+Enter opens selected files in new tabs, Cmd/Ctrl+N new file, Del or Cmd/Ctrl+Shift+Backspace trash, Cmd+Backspace in empty filter trash, Cmd/Ctrl+C/X/V copy/cut/paste, Cmd/Ctrl+R or F2 rename. Multi-select supported.
- Alt+click on a file opens it in a new tab.
- Right-click menu changes with selection: New File, New Folder, Cut, Copy, Paste, Rename, Delete, Show in Finder / Reveal in Explorer / Show in File Manager. Right-click on empty area: New File, New Folder, Paste, Show in….
- New File/Folder: an inline name field appears in the tree. Empty or Esc cancels. A name ending in `/` or `\` makes a folder. A file without an extension gets `.md`. New files open in a tab.
- Rename: inline field, initially selects the name without extension; Enter confirms, Esc or click-away cancels. Name clash shows error "Error renaming file / File with the provided name already exists".
- Delete moves to Trash after "Are you sure you want to delete <name>?" (or "the selected items") with Move to Trash / Cancel; closes tabs of trashed files.
- Paste copies; cut-paste copies then trashes the source. Name clashes get `-1`, `-2`… after the first part of the name.
- Drag a sidebar item into the editor: a line marker shows the drop line; drop inserts a Markdown link `[file name](relative path)` (prefixed `!` for images) on its own line.
- Refreshes on window focus and when files in the folder are written.
- Only one sidebar shows at a time (Files or Outline). View > Show None (`window:toggle-sidebar`, Cmd/Ctrl+\) hides the visible one or re-shows the last one. The three menu items act as a radio group.

**Source** snapshot: FilesSidebar/*.js, node_modules/desktop/SidebarView.js, List.Files.js, List.Tree.js, List.js; SRC/extensions/FilesSidebar/rename.js

**Confidence** observed-in-code

### Outline (headings) sidebar and Go to Heading popup

**Behaviour**
- View > Show Outline (`window:headings-bar`, Cmd/Ctrl+Shift+B): sidebar listing all ATX and Setext headings, indented by rank among the heading levels actually used, with an h1–h6 icon. Hidden by default; visibility remembered per window.
- Current heading (the last one above the cursor) is highlighted; the list updates on edits and cursor moves.
- Each heading shows a git mark if the git diff has a change inside its section.
- Enter jumps to the heading and focuses the editor; Space jumps but keeps focus in the list. Typing filters.
- Go > To Heading… (`window:titles`, Cmd/Ctrl+R): popup "Outline". Filtering keeps each match plus its parent headings for context. Pick scrolls to the heading.

**Source** SRC/extensions/Headings/*.js

**Confidence** observed-in-code

### Popups: shared behaviour

**Behaviour**
- Popups (Go to File, Go to Command, Outline, Folders, Backups, Tabs switcher, Find in Folder) appear centred near the top, 360 px wide, up to 16 rows, with a filter field.
- Opening clears the filter and selects the first row. Pressing the popup's own shortcut again moves to the next row.
- Up/Down (macOS also Ctrl+N/Ctrl+P), Enter or Right picks, Esc closes. No matches shows a disabled "not found" row.
- Closes when the window loses focus or focus leaves it; then the editor is refocused.

**Source** snapshot: node_modules/desktop/PopupFilterView.js, List.js; SRC/css/all.css

**Confidence** observed-in-code

### Go to File

**Behaviour**
- Go > To File… (`window:files`, Cmd/Ctrl+P, Cmd/Ctrl+T, Cmd/Ctrl+Shift+O): popup "Files".
- Empty filter: up to 8 recent files of this folder, excluding untitled, preferences and backup files.
- With a filter: also every existing file in the folder index; fuzzy-filtered and sorted by match. New files found by the background index appear live.
- Each row: type icon, name, extension, "in <folder path>" (home shown relative, user data as "Caret Beta/…"), git mark.
- Pick opens via the general open logic.
- The welcome "Tips and Tricks" file says Alt+Enter on a non-existent name creates it (ending `/` makes a folder). No such command is in Navigator.js.

**Source** SRC/extensions/Navigator/Navigator.js, snapshot: Path/Path.js

**Confidence** observed-in-code (create-from-palette: unknown)

### Go to Command

**Behaviour**
- Go > To Command… (`window:commands`, Cmd/Ctrl+Shift+P, Cmd/Ctrl+Shift+A): popup "Commands".
- Lists every application-menu item that has a command, shown as "<parent menu> › <item>", with a ✓ for checked checkbox items and the first shortcut on the right (macOS uses ⌘ ⌥ ⇧ ⌃ ⌫ ↑ ↓ ← → ⎋ symbols).
- The 3 most recently run commands appear first, then a divider, then the rest. History is global (cache `commands`).
- Picking focuses the editor and runs the command.

**Source** SRC/extensions/Commands/Commands.js, commands--main.js

**Confidence** observed-in-code

### Ctrl+Tab switcher

**Behaviour**
- Ctrl+Tab shows a popup titled "Tabs" listing open tabs in most-recently-used order (from the folder's recent files), with modified marks.
- The second entry is preselected when the first is the current tab.
- While holding Ctrl: Tab or Down moves next, Shift+Tab or Up moves back. Releasing Ctrl opens the selected tab and closes the popup. Ctrl+Esc cancels.
- With no tabs it shows "no tabs opened".

**Source** snapshot: CtrlTab/CtrlTab.js; SRC/css/all.css

**Confidence** observed-in-code

### Find in Folder

**Behaviour**
- Edit > Find in Folder… (`window:find-in-files`, Cmd/Ctrl+Shift+F): popup with a search field. If a single-line selection exists it is used as the search and run at once.
- Searches live as you type; empty field clears results. A new search stops the previous one.
- Searches only openable files (`.md .markdown .txt .text`) in the folder index. Case-insensitive; no regex.
- A hit counts only where the app's fuzzy-filter library places its first match at that spot within the surrounding space-separated text (exact rule hard to restate; roughly "plain substring, first match per word").
- Results grouped by file (path relative to folder). A file group starts expanded if it has under 15 hits. Each hit shows its line, trimmed from the left to a word boundary about 12 characters before the hit, with the hit highlighted.
- Picking a hit (Enter or Cmd/Ctrl+Enter) opens the file in a new tab, selects the hit and centres it.
- A second component offers "normal search / match case / match whole word / match case & whole word" options, but it calls a sidebar that does not exist and is never loaded.

**Source** SRC/extensions/FindInFiles/FindInFiles.js, SearchInFolder.js, FindInFilesPopup.js

**Confidence** observed-in-code

### Git integration

**Behaviour**
- A folder counts as a git project if `.git` exists in it or up to 5 parents.
- Folder status: runs `git status --porcelain --untracked-files` and `git rev-parse --show-toplevel`. Codes map to add (`A`, `??`), change (`M`), delete (`D`), rename (`R`). Refreshed when the folder changes and on the next save after the open file's diff changes. Drives sidebar and Go to File marks.
- Open-file diff: compares the editor text with the HEAD version (`git show HEAD:<path>`, cached per commit hash in user data `file-diff/`) using `git diff --diff-algorithm=histogram`. Runs 50 ms after edits and on editor focus. Produces per-line add / change / delete marks.
- Editor gutter marks: `+` added, `~` changed, `D` deleted (CSS classes `git--add`, `git--change`, `git--delete`).
- Fails silently (no marks) if git is missing or the file is not committed.
- No commit, stage or branch UI.

**Source** SRC/extensions/Git/*.js, snapshot: Git/Git.js; SRC/css/all.css

**Confidence** observed-in-code

### Text stats

**Behaviour**
- View > Show Stats (`window:toggle-text-stats`): small label at the bottom right. Hidden by default (silent preference `text-stats.visible`).
- Shows one of: words `N W`, characters `N C`, reading time `mm:ss RT`. Choice stored in `text-stats.type` (default `word-count`).
- Counts the selection if there is one (label gets a blue background), else the whole file. Empty when there is no tab or no text.
- Words: punctuation `' " ; : , . ? ¿ - ! ¡` removed, then whitespace-separated pieces counted. Characters: raw length. Reading time: words at 200 per minute.
- Clicking the label opens a menu listing all three values; picking one switches the display.

**Source** SRC/extensions/TextStats/TextStats.js

**Confidence** observed-in-code

### Hide interface

**Behaviour**
- Cmd/Ctrl+. (`window:hide-interface`, not in the menu) hides the tab bar, text stats and both sidebars, remembering which were visible.
- Pressing it again, or showing Files, Outline or Stats, restores what was visible.
- Survives restart (cache `hide-interface`).

**Source** snapshot: Caret.js (_setupHideInterface)

**Confidence** observed-in-code

### Preferences

**Behaviour**
- Caret > Preferences (macOS Cmd+,; others File > Preferences, Ctrl+,) opens `config/Preferences.md` in user data as a normal tab; running it again while that tab is current closes it.
- The file is created from a template: a heading "Preferences", the line "Edit and save to update preferences:", one YAML code block, and a footer pointing to Twitter and email.
- On open (and whenever a value changes) the YAML block is regenerated from current values, ordered by each key's `order`, then by name, and saved.
- On save the YAML is parsed and changed values applied. Numbers are clamped to min/max. Parse errors show a footer notification "Error occurred when parsing settings. Settings not saved."
- Changes are broadcast to every window (IPC `config.change` → `<name>-config.change`).
- Values live in electron-cache files `confg--preferences.md` (visible ones) and `confg--silent-preferences` (menu toggles not shown in the file). The "confg" spelling is in the code.
- View > Font Size Up / Down / Default (Cmd/Ctrl+= or Cmd/Ctrl+Shift+=, Cmd/Ctrl+-, Cmd/Ctrl+0) change `fontSize` and `codeFontSize` together by 1, or reset both.
- Migration on update to 4.0.x: font settings reset (code font "Fira Mono" becomes "Roboto Mono", large headings back on) and a notification "Your font preferences have been reset".

| key | default | effect | confidence |
|---|---|---|---|
| `font` | `system-ui` | prose font family | observed-in-code |
| `fontSize` | 15 (min 10, max 30) | prose font size in px | observed-in-code |
| `codeFont` | `"Roboto Mono"` | code font family | observed-in-code |
| `codeFontSize` | 13 (min 10, max 30) | code font size in px; inline code scales relative to `fontSize` | observed-in-code |
| `lineHeight` | 1.6 (min 1.5, max 2) | editor line height | observed-in-code |
| `lineWidth` | 72 (min 20) | text column width in characters of the paragraph font; also sets the page max width | observed-in-code |
| `tabSize` | 2 | indent width in code | observed-in-code |
| `useLargeFontInHeadings` | true | larger heading text in the editor | observed-in-code |
| `nightMode` (silent) | false | dark theme; View > Mode Dark, Cmd/Ctrl+Alt+L or Cmd+Ctrl+N | observed-in-code |
| `typewriter` (silent) | false | typewriter scrolling; View > Mode Typewriter, Cmd/Ctrl+Alt+T | observed-in-code |
| `focusMode` (silent) | false | dims all but the current block; command `window:focus-mode`, no menu item | observed-in-code |
| `spellcheck` (silent) | true | Edit > Check Spelling | observed-in-code |
| `autoCorrectSpelling` (silent) | false | Edit > Autocorrect Spelling | observed-in-code |
| `file.autosave` (silent) | true | File > Autosave | observed-in-code |
| `text-stats.visible` (silent) | false | View > Show Stats | observed-in-code |
| `text-stats.type` (silent) | `word-count` | `word-count`, `character-count` or `reading-time` | observed-in-code |
| `useProportionalFontInProse` | not registered in 4.0 | only touched by a 3.3 migration | observed-in-code |

- macOS spelling language follows the system setting (auto-detect or the preferred spell-server language), re-read on window focus. Not a preference.
- Window-level remembered state (not preferences): files sidebar visible (default true), outline visible (default false), preview modes, tabs per folder, hide-interface.

**Source** snapshot: Preferences/Preferences.js, Preferences/Config.js, Preferences/baby-yaml.js, Caret.js, Editor/Editor.js, Tabs/Tabs.Autosave.js; SRC/extensions/TextStats/TextStats.js, SRC/extensions/Preferences/Preferences.md

**Confidence** observed-in-code

### Keyboard shortcuts screen

**Behaviour**
- Caret > Keyboard Shortcuts (`application:keyboard-shortcuts`) opens `config/Keyboard Shortcuts.md` in user data, same edit-and-save mechanism as Preferences. Toggle closes it if current.
- Template: sections File, Edit, Selection, Format, Go, View, each with one YAML block.
- Each entry key is the command name without its prefix (for example `file-save`, `bold`); the value is one shortcut or a list, written with spaces instead of `+` (for example `Cmd S`). Defaults come from the menu.
- On save, new shortcuts update both the in-app command and the menu accelerator.
- On Windows/Linux, shortcuts containing `Cmd` are dropped and `CmdOrCtrl` becomes `Ctrl`; on macOS `CmdOrCtrl` becomes `Cmd`.
- Commands registered as not configurable (About, Purchase, Enter License, Check for Updates, Help links, font size) keep their menu shortcut and are not editable.
- Commands outside the menu are assigned to an "app" or "editor" category, which has no block in the template, so they do not appear.
- The full shortcut table is in SRC/menu.js.

**Source** snapshot: Preferences/Preferences.Shortcuts.js; SRC/extensions/Preferences/Shortcuts.md, SRC/menu.js

**Confidence** observed-in-code

### Application menu

**Behaviour**
- The renderer sends the menu template to the main process (`menu.set`); later changes (checked, visible, enabled, shortcut, radio-group check, prepend/append) are batched in idle time and sent as `menu.update`. Context menus use `menu.popup`; Windows uses `menu.popup-app-menu` for its menu button.
- Menus: (macOS) Caret, File, Edit, Selection, Format, Go, View, Window, Help. On Windows/Linux, About and Check for Updates move to the top of Help; Preferences, Keyboard Shortcuts and Exit go to the end of File.
- Hidden item "Licensed" (command id `licencsed`, disabled) becomes visible when a license is active, while Purchase License and Enter License hide.
- Help items: Email Support (`mailto:contact@caret.io?subject=Caret%20Feedback`), Create Issue on GitHub (`https://github.com/careteditor/caret/issues`), Visit Website (`https://caret.io/?ref=app`), Purchase License, Enter License, Third Party Licenses (opens bundled `licenses.md` in a tab).
- Hidden commands with no menu item: `application:newsletter` (opens `http://eepurl.com/dwRi7L`), `application:tweet-us` (opens a Twitter compose page to @careteditor).
- Commands with prefix `application:` or `windows:` are routed through the main process (sent to the focused window, or to all windows for `windows:`); others run in the window.
- Esc: if the editor has focus, hides footer notifications; otherwise focuses the editor.
- Shortcut clash in the menu file: Open Recent Folder is Ctrl+R and Go to Heading is Cmd/Ctrl+R, so on Windows/Linux both claim Ctrl+R.

**Source** SRC/menu.js, SRC/extensions/Menu/menu--main.js, snapshot: Menu/Menu.js, Caret.js

**Confidence** observed-in-code

### Licensing, purchase and nag prompt

**Behaviour**
- Licensed state = a license key is stored locally (cache `license`: `key`, `username`). There is no local validation of the key text.
- Help > Enter License (`application:enter-license`): full-window overlay with message "Paste your license key and hit enter to activate it:", a text field, and "Don't have a license? Purchase here". The field keeps focus while the overlay is open.
- Enter sends the key to the server (see Network endpoints) with the platform and milliseconds since install. Message shows "checking...". HTTP 403 → "activation failed". Any other response → key stored, "licensed to" name stored from the reply, message "activated", field becomes read-only showing the key, menu switches to the licensed state, analytics event `activate` with days since install.
- Help > Purchase License opens `https://caret.io/purchase?ref=app&os=<platform>` in the browser.
- Nag prompt (macOS only): after a save or Save As, if not licensed and at least 30 minutes since the window started or since the last nag, a full-window overlay appears 0.5 s later: title "We hope that you like Caret!", a short request to buy if used a lot, a "Purchase License" button (opens `…/purchase?ref=prompt&prompt=<platform>`) and "Have a license? Enter it here" (opens the license overlay).
- For the first 3 seconds the app is locked: all commands are disabled and key presses are swallowed (Esc too; typing is allowed only in text fields). A bottom line counts down "hit esc to close | 3/2/1", then shows "hit esc to close" and Esc closes it.
- Each nag increments a counter (cache `purchase.showCount`) that nothing reads.
- Because autosave fires "save", unlicensed macOS users see the nag every 30 minutes of editing.
- No trial expiry or feature limits exist in this build.

**Source** SRC/extensions/Purchase/Purchase.js, snapshot: License/License.js, Caret.js

**Confidence** observed-in-code

### Updates

**Behaviour**
- Checks silently at window start and every 4 hours. Caret > Check for Updates… checks with feedback.
- Fetches the feed URL; a JSON reply with `url` means an update exists. Errors or non-200 mean none.
- macOS: hands the macOS feed URL to the Squirrel updater (Electron autoUpdater), which downloads in the background. Windows: hands it the `url` from the reply. Linux: dialog "Update available" with Download / Cancel; Download opens `https://caret.io`.
- Manual check dialogs: "New update is available!" / "It'll download in the background. You'll get notified when it's ready." or "You're up-to-date!" / "<name> <version> is currently the newest version available."
- When downloaded: "Update available" / "Restart to apply it. Cancel will install it on the next app start." with Restart / Cancel. Cancel installs on quit.
- Release channel: beta builds (package name ends `-beta`) use the beta channel. An empty file named `insider` in user data adds `insider=true`.
- After a minor or major version change, a dialog "Welcome to <name> <version>" offers Release Notes / Continue. Release Notes opens `https:/caret.io/releases` (malformed, single slash).

**Source** snapshot: Updates/Updates.js; Squirrel.framework in the bundle

**Confidence** observed-in-code

### Analytics

**Behaviour**
- Google Analytics (Measurement Protocol v1) via POST to `https://ssl.google-analytics.com/collect`.
- Tracking id: `UA-80991424-4` stable, `UA-80991424-6` beta, `UA-80991424-5` debug.
- Every hit carries: IP anonymised flag, app name, app version, client id (the random uuid), primary screen resolution.
- Hits: screenview "Home" per window; event `launch` (action install / update / downgrade / regular, label "licensed" when licensed) from the main window only; value event `exit` with minutes spent in the previous session (saved on window close); value event `activate` with days from install to activation.
- On/off flag in cache `analytics.enabled` (default on). No UI found to turn it off.
- Launch type is decided by comparing the stored version (ignoring `-beta…`/`-rc…` suffixes) with the current one; other code uses it for migrations and release notes.

**Source** snapshot: Analytics/Analytics.js

**Confidence** observed-in-code

### Errors and crash reporting

**Behaviour**
- Uncaught errors in a window, and main-process errors (forwarded as `application:error`, or queued and passed to the first window if they happen before it opens), show a dialog "Oops" / "An error has occurred." with Send Error Data / Cancel.
- The same error (message + file + stack) is shown only once per window session.
- Send posts JSON to `https://caret.io/app/logError` containing: message, app version, OS name, uuid, file path trimmed to inside the app, a short code snippet at the error position, line, column, error count, stack (paths trimmed).
- Electron crash reporter (main and window processes) uploads native crashes to `https://caret.io/app/logCrash` with OS name and app version. Disabled in debug runs.

**Source** snapshot: Errors/Errors.js, Caret.js; SRC/main/Application.js

**Confidence** observed-in-code

### Notifications

**Behaviour**
- Bar at the bottom of the editor column, centred blue text (red for error type), with optional buttons shown as `[ label ]` and a `[ × ]` close button.
- Esc with editor focus hides them.
- Used for the preferences parse error and the font-reset notice.

**Source** snapshot: Notifications/*.js; SRC/css/all.css

**Confidence** observed-in-code

### About

**Behaviour**
- macOS: the native About panel with product name, version and "Copyright (C) 2018 Caret.io LTD. All rights reserved".
- Windows/Linux: Help > About Caret toggles a full-window overlay showing the app name, "Version <version>" and "© 2015 - <current year> Caret.io Ltd". Closes when it loses focus.

**Source** SRC/main/Application.js, SRC/extensions/About/About.js, SRC/menu.js

**Confidence** observed-in-code

### Welcome screen

**Behaviour**
- There is no welcome screen in this build. The first-run experience is the Introduction folder with `Welcome.md` (see Window folder).
- A `Welcome` extension exists only as a source map; it is never loaded. Same for `Clipboard`, `TrafficLights`, `Sidebars` (old sidebar code), `Title`, `TitleBar`.

**Source** SRC/extensions/Welcome/ (map only), snapshot: snapshot.js and Caret.js extension list

**Confidence** observed-in-code

### Windows title buttons

**Behaviour**
- Windows only: custom buttons drawn top-right (minimise, maximise or restore depending on state, close; each 46×32 px, close turns red on hover) and a menu button top-left.
- The menu button, or tapping Alt alone, pops up the application menu.
- Close runs `window:close`. A 1 px border is drawn around the window when not maximised.

**Source** snapshot: WindowsIcons/WindowsIcons.js; SRC/css/all.css

**Confidence** observed-in-code

### Layout

**Behaviour**
- Body classes describe state: platform (`--darwin`, `--win32`, `--linux`), `--night`, `--blurred` (window unfocused), `--maximized`, `--sidebar` (a sidebar is open), `--compact` (not enough room, sidebar pushes the editor), `--resized` (window narrower than the screen), `--live-preview`.
- Top: the tab bar, a strip 48 px tall across the full width, tabs centred with 80 px side padding (leaves room for macOS traffic lights). It is the window drag area.
- Centre: the editor column, centred, max width = line width (from `lineWidth`) + 80 px margin each side. Content starts below a 96 px top padding.
- Left: one sidebar (Files or Outline), 200 px wide, from below the tab strip to the bottom, same background as the window, no visible scrollbar. When shown, the editor column shifts right by an amount based on free screen space; in compact mode it shifts by the full 200 px.
- Right half: live preview, when on, takes 50% of the window (minus half the sidebar if one is open); the editor area takes the other half.
- Bottom of the editor column: notification bar. Bottom right corner: text stats label.
- Popups float centred near the top (360 px wide). Overlays (About, License, Purchase) cover the whole window with a translucent background, content centred.
- Stacking from back to front: footer, sidebar, popups, tabs, overlays, Windows buttons, the purchase lock countdown.
- Windows/Linux use 16 px rounded scrollbars; macOS uses system scrollbars.

**Source** SRC/css/all.css, snapshot: node_modules/desktop/SidebarView.js, Caret.js

**Confidence** observed-in-code (exact pixel results: inferred-from-names)

### Stored files in user data

**Behaviour**
- `electron-cache/` JSON stores: `app` (nightMode, focusedWindowId, defaultBounds), `uuid`, `window-bounds__w<N>`, `analytics`, `in-app-minutes`, `commands`, `folders`, `purchase`, `license`, `updates`, `project`, `project__w<N>`, `tabs__w<N>`, `sidebar__w<N>`, `headings-bar__w<N>`, `file`, `file.history`, `file.revisions`, `hide-interface`, `confg--preferences.md`, `confg--silent-preferences`, `confg--keyboard-shortcuts.md`, `preview`, `preview.modes__w<N>`. App-wide stores re-read when another window changed them.
- `config/Preferences.md`, `config/Keyboard Shortcuts.md`.
- `file-revisions/` backups, `untitled-files/`, `unsaved-files/`, `file-diff/` (git temp), `Introduction/` (welcome folder), `launch__w<N>.png`, optional `insider` flag file.
- Browser localStorage keeps lazy-load flags for views and tree expansion state.

**Source** snapshot: node_modules/electron-cache/*, all modules above

**Confidence** observed-in-code

### Network endpoints

| URL | when | what is sent |
|---|---|---|
| `https://ssl.google-analytics.com/collect` (POST, query string) | window start, close-related, activation | see Analytics |
| `https://caret.io/app/activate` (POST JSON) | license entry | platform, license key, ms since install |
| `https://caret.io/app/logError` (POST JSON) | user clicks Send Error Data | error report (see Errors) |
| `https://caret.io/app/logCrash` | native crash | Electron crash dump, OS name, version |
| `https://caret.io/update/mac?version=<v>&channel=beta\|stable[&insider=true]` | macOS update checks (start, every 4 h, manual) | version, channel |
| `https://caret.io/app/update?version=<v>&platform=<p>&repo=beta\|caret[&insider=true]` | Windows/Linux update checks | version, platform, channel |
| `https://caret.io/purchase?ref=app&os=<p>` / `?ref=prompt&prompt=<p>` / `?ref=lprompt&prompt=<p>` | opened in browser from menu, nag, license overlay | none |
| `https://caret.io/?ref=app`, `https://caret.io`, `https:/caret.io/releases`, `https://github.com/careteditor/caret/issues`, `http://eepurl.com/dwRi7L`, twitter.com compose, `mailto:contact@caret.io` | opened in browser | none |

**Confidence** observed-in-code

### Unknowns

- Window title: Tabs sends IPC `title.setTitle` but the main process listens on `tabs.setTitle`, so the title is probably never set. Not run to confirm.
- No caller found for the terminal-command install step or for `caret.newWindow()` (no "New Window" menu item); how users got the `caret` command or a second window in this build is unclear.
- "Alt+Enter in Go to File creates the file" is documented in the bundled tips but not present in Navigator.js; maybe removed.
- Find in Folder's exact match rule depends on the internal fuzzy-filter library (`filter.indexes`); not traced further.
- No UI to disable analytics was found; it may have lived in an unloaded extension.
- `Electron Helper NP/EH` and Squirrel server responses were not exercised; the update feed reply format beyond `url` is unknown.
- Behaviour of `window:typewriter-mode` and `window:focus-mode` themselves belongs to the editor spec.

# Part 4: Visual design

## Caret Beta 4.0.0-rc23: visual design spec

Goal: a new app built from this section should look the same as Caret on macOS at the default preferences (font `system-ui` 15px, code font Roboto Mono 13px, line height 1.6, line width 72 characters, large headings on).

How to read the sources column:

- `shots/NN-name.png` is a screenshot at 2x. All sizes in this document are CSS pixels (half the screenshot pixels).
- `styles/NN-name.json` is the computed style dump taken at the same moment as the screenshot.
- `live` means measured with the running app over the debugging port while writing this (preview measurements on `testdocs/Everything.md`).
- `px` means a pixel sampled from the screenshot (a blended colour, so it already includes any transparency).
- `all.css`, `default.css`, `default-dark.css` are `caret/src/css/...`; `editor--app.css`, `find.css` and so on are under `caret/src/extensions/`; preview themes are `caret/src/extensions/Preview/themes/*.css`; `snap` is `snap-src.txt` (app script compiled into the startup snapshot).
- "rem" inside the preview resolves against the app root font size of 13px, which is why some preview values are odd numbers (0.2rem = 2.6px, 2.4rem = 31.2px).

Behaviour (what happens when) lives in `docs/caret-behaviour-spec.md`. Section names there are used here: "How Markdown looks inside the editor", "Images inline", "Math", "Find in file", "Text stats", "Preview modes", "Preview themes", "Dark mode (app theme)", "Layout".

### 1. Design tokens

#### Colour palette (app chrome and editor)

The app has two colour sets, swapped by turning on one of two stylesheets (`default.css` or `default-dark.css`) and adding the `--night` class to `body`. Names below are the CSS variable names Caret uses, so they can be searched in the source.

| Token (CSS variable) | Used for | Light | Dark | Source |
|---|---|---|---|---|
| `--material` | window, editor, sidebar, popup background | `#FAFAFA` rgb(250,250,250) | `#282828` rgb(40,40,40) | styles/01, styles/02 (`section.editor` background) |
| `--material-secondary` | defined, not seen on screen in these shots | `#F0F0F0` | `#232323` | default.css, default-dark.css |
| `--material-transparent` | full-window overlays, image zoom backdrop, block-focus fade | rgba(250,250,250,0.95) | rgba(40,40,40,0.97) | same |
| `--material-line` | 1px ring of popups, sidebar right edge in compact mode | rgba(0,0,0,0.1) | `#4D4D4D` (hsl 0 0% 30%) | same |
| `--material-thumb` | editor scrollbar slider | rgba(82,82,82,0.8) | rgba(153,153,153,0.9) | styles/01, styles/02 (`editor__scrollbar__slider`) |
| `--color` | body text, cursor, find box background | `#4C4C4C` rgb(76,76,76) | `#BFBFBF` rgb(191,191,191) | styles/01, styles/02 |
| `--color-secondary` | sidebar and tab text, list markers, code text, front matter text | `#7F7F7F` rgb(127,127,127) | `#999999` rgb(153,153,153) | same |
| `--color-tertiary` | faded Markdown markers, file extensions, placeholders, word count, margin heading labels | `#B3B3B3` rgb(179,179,179) | `#666666` rgb(102,102,102) | same |
| `--color-em` | headings in dark mode | not defined, so headings fall back to `--color` (rgb 76) | `#CCCCCC` rgb(204,204,204) | default-dark.css; styles/01 vs styles/02 `block-header__text` |
| `--color-blue` | link text, bare URLs, `[[toc]]`, footnote ref text, notification text | `#8599AE` rgb(133,153,174) | `#8799AC` rgb(135,153,172) | styles/01, styles/02 (`inline-link__text`) |
| `--color-red` | `+++` page break, math function names, spelling-correction match | `#D98C8C` rgb(217,140,140) | rgba(232,125,125,0.7) | styles/17 (`block-page-break`), styles/02 (`span.function`) |
| `--color-gold` | inline code text, inline math text, code attribute names | `#C18B8B` rgb(193,139,139) | `#A8998A` rgb(168,153,138) | styles/01, styles/02 (`inline-code__text`) |
| `--selection-blue` | editor selection, selected list row (focused) | rgba(71,153,235,0.25), blends to `#D3E1F5` | rgba(95,127,159,0.25) | styles/41; px shots/41 at (600,100) |
| `--selection-neutral` | selected list row in an unfocused window, open file in sidebar, editor selection when the editor is not focused | rgba(204,204,204,0.25), blends to `#EEEEEE` | rgba(70,70,70,0.25), blends to `#303030` | styles/01, styles/02 (`list__item--open`); px shots/01 (100,130) and shots/02 (100,130) |
| `--selection-yellow` | find: other matches | `#FEEBB5` rgb(254,235,181) | hsl(45,20%,45%) = about `#8A7E5C` | styles/21; dark from default-dark.css |
| `--selection-orange` | find: current match | `#FEC7B5` rgb(254,199,181) | hsl(15,25%,45%) = about `#8F6456` | same |
| `--highlight` | band behind front matter, code block and math source lines; bracket and word match | rgba(0,0,0,0.04), blends to `#F0F0F0` | rgba(255,255,255,0.04), blends to `#303030` | styles/01 (`editor__highlight--md-background`); px shots/01 (1000,130), shots/02 (1000,130) |
| `--highlight-info` | background of `::highlighted::` text | rgba(140,217,179,0.5), blends to about `#C3EAD7` | rgba(61,92,92,0.8), blends to about `#395252` | styles/01, styles/02 (`inline-highlight`) |
| `--highlight-error` | spellcheck underline; find box when nothing matches | rgba(255,77,77,0.5) | `#995555` | styles/34 (`editor__highlight--spellcheck`), default-dark.css |
| `--highlight-input` | text selection inside text fields | rgba(0,0,0,0.08) | rgba(255,255,255,0.1) | all.css (`input::selection`) |
| window background while loading | native window colour before the page paints | `#F9F9F9` | `#1D1D1D` | `caret/src/main/Application.js` |

Shadows (popup ring, not a blur shadow):

| Name | Light | Dark | Used by | Source |
|---|---|---|---|---|
| `--shadow` | 1px ring rgba(0,0,0,0.1), then a 7px ring rgba(0,0,0,0.025) | 1px ring `#4D4D4D`, then a 7px ring rgba(40,40,40,0.5) | go to file, go to heading, commands, backups, tabs switcher, find in folder | default.css / default-dark.css; visible in shots/24, shots/26 |
| `--shadow-small` | 1px ring rgba(0,0,0,0.1), then a 5px ring rgba(0,0,0,0.025) | 1px ring `#4D4D4D`, then a 5px ring rgba(40,40,40,0.5) | autocomplete list, right-click menu | styles/34 (`list--autocomplete` box-shadow) |

Both rings are spread-only box shadows (0 offset, 0 blur), so a popup looks like a card with a thin grey border and a very faint 7px halo.

#### Fonts

| Role | Family (as computed) | Size | Source |
|---|---|---|---|
| UI (tabs, sidebar, popups, word count, find box) | `-apple-system, system-ui, "Segoe WPC", "Segoe UI", HelveticaNeue-Light, Ubuntu, "Droid Sans", sans-serif` | 13px, line height 24px | styles/01 (`section.app`); all.css `--font-family` |
| Prose in the editor (paragraphs, headings, list and quote text, link text) | `system-ui` (the `font` preference) | 15px (the `fontSize` preference, range 10 to 30) | live `.editor` inline style; styles/01 (`block-paragraph`); snap preference defaults |
| Code in the editor (fences, front matter, tables, markers, inline code) | `"Roboto Mono"` (the `codeFont` preference) | 13px (the `codeFontSize` preference, range 10 to 30); inline code and inline math use 13/15 = 0.8667em so they also land on 13px | same |
| Heading margin labels (`h1`..`h6`) | `SFMono-Regular, Consolas, "Liberation Mono", Menlo, Courier, monospace` | code size minus 2 = 11px, normal weight | live `::before` of `.block-header__marker` |
| Popup filter field | UI family, weight 300 | 26px, line height 72px | styles/23 (`input.list__filter`) |
| Empty window glyph `×` | UI family | 52px | styles/33 (`div.empty`) |
| Math in editor and preview | KaTeX fonts | see sections 3 and 4 | styles/01 (`span.katex`) |

Font files that ship:

- `caret/src/fonts/Roboto+Mono/Roboto+Mono-400-normal.woff` and `-700-normal.woff` (declared in all.css as `Roboto Mono` 400 and 700).
- KaTeX fonts in `node_modules/katex/dist/fonts`: AMS, Caligraphic, Fraktur, Main (regular, bold, italic), Math (italic, bold italic), SansSerif, Script, Size1 to Size4, Typewriter.
- `extensions/Editor/fonts-data/Roboto+Mono-400/700-normal.bfkm` and `.js`: character width and kerning tables the editor uses for line wrapping (not drawn).
- all.css also declares Merriweather (400/700, normal/italic, `.ttf`), but no `fonts/Merriweather` folder exists in the package. The dark preview theme asks for `Fira Mono`, which is not shipped either.
- `system-ui` on macOS resolves to the system font (San Francisco). Ligatures are turned off app-wide (`font-feature-settings: "liga" 0` on the root), and kerning is turned off in the editor, paragraphs and h1 by an inline stylesheet the app injects (live).

#### Type scale

| Element | Font | Size | Weight | Line height | Colour (light / dark) | Source |
|---|---|---|---|---|---|---|
| Tab / title text | UI | 13px | normal | 24px | open tab `#7F7F7F` / `#999999`; other tabs `#B3B3B3` / `#666666` | styles/39, styles/42 |
| Sidebar row | UI | 13px | normal | 24px (row height 24) | name `#7F7F7F` / `#999999`; extension `#B3B3B3` / `#666666` | styles/01, styles/02 |
| Body paragraph (editor) | system-ui | 15px | normal | 24px (15 × 1.6) | `#4C4C4C` / `#BFBFBF` | styles/01 |
| h1 (editor, large headings on) | system-ui | 21px (15 × 1.4) | bold | 33.6px | `#4C4C4C` / `#CCCCCC` | styles/01, styles/02 |
| h2 (editor) | system-ui | 18px (15 × 1.2) | bold | 28.8px | same | styles/01 |
| h3 to h6 (editor) | system-ui | 15px | bold | 24px | same | styles/01 |
| Headings with large headings off | system-ui | 15px for all levels | bold | 24px | same | all.css (`editor--large-headings` rules only apply when on) |
| Code, front matter, tables, markers | Roboto Mono | 13px | normal | 24px | see section 3 | styles/01 |
| Heading margin label | SFMono stack | 11px | normal | n/a | `#B3B3B3` / `#666666` | live |
| Word count | UI | 13px | normal | 24px | `#B3B3B3` / `#666666` | styles/08 |
| Popup filter text | UI | 26px | 300 | 72px | `#4C4C4C` (typed), `#B3B3B3` (placeholder) | styles/23, shots/26 |
| Popup row | UI | 13px | normal | 24px | `#7F7F7F`; prefix and shortcut `#B3B3B3` | styles/26 |
| Autocomplete / right-click menu row | UI | 14px | normal | 26px | `#4C4C4C` | styles/34 |
| Rendered math block (editor) | KaTeX | container 19.5px (1.5 × 13), KaTeX text 23.6px | normal | n/a | `--color` | styles/01 (`math-preview`, `span.katex`) |

Preview type sizes are in section 4.

#### Spacing, sizes and radii

| Value | Where | Source |
|---|---|---|
| 48px | height of the tab strip (title bar); editor starts 48px down | styles/01 (`section.tabs`, `section.editor` margin) |
| 96px | first text line's top (48 strip + 48 editor top padding) | styles/01 (`editor__line` y = 96) |
| 96px | editor bottom padding | styles/01 |
| 80px | editor side padding (minimum page margin); tab strip side padding | styles/01 |
| 562px | editor text column width = ceil(72 × width of "a" in 15px system-ui) | live `--page-max-width: calc(562px + 160px)`; snap |
| 200px | sidebar width | all.css `--sidebar-width`; styles/01 |
| 20px | horizontal padding of sidebar and popup rows | styles/01, styles/23 |
| 16px | per-level indent in outline and go-to-heading rows; icon box width | styles/06, styles/25 |
| 360px | popup width | styles/23 (row width) |
| 6px | popup and find box corner radius (`--border-radius`) | all.css; styles/21, styles/34 |
| 3px | small radius (license field, purchase button) and scrollbar slider radius | all.css |
| 24px | one line (rhythm unit for UI and body text) | styles/01 |

### 2. Window layout

Reference window: 1680 × 1020, maximised, light, files sidebar open (styles/01, shots/01).

#### Title bar and tabs

- No visible title bar. The window uses macOS `hiddenInset` style, so the native traffic lights sit over the top-left of the page (`main/Application.js`).
- The top 48px is the tab strip and the window drag area. It has the window background colour and no border (styles/01, shots/01).
- Tabs sit in one centred row: row padding 9px top and 80px left and right; each tab is 30px tall (3px top and bottom padding, 10px left and right), maximum 200px wide, text 13px (styles/01, styles/39).
- With one file open the strip shows only its name, centred, which reads like a window title (shots/01: "Everything.md" centred at x 840).
- Open tab: `--color-secondary`. Other tabs: `--color-tertiary`. No background, underline or border on any tab (styles/39, shots/41).
- Unsaved file: a `•` after the name, 5px gap, 13px, same colour as that tab's text (live `::after`; shots/41 "Untitled •").
- A file outside the open folder gets `⇾` before its name, 5px gap (all.css `list__item--outside-file`).
- Untitled files are named "Untitled" (shots/41).

#### Sidebar

- 200px wide, from y 48 to the bottom, same colour as the window, no visible border and no scrollbar (styles/01; all.css).
- List starts 48px below the sidebar top (first row at y 96, the same line as the first editor line) (styles/01).
- Rows: 24px tall, 20px left and right padding, 16px icon box then the name (styles/01).
- In compact or narrow windows (`--compact` or `--resized`), the list gets a 1px right edge in `--material-line` (all.css).
- The 48px at the top and 96px at the bottom of the sidebar fade the list out with a 1px inset edge in window colour (all.css `.sidebar::before/::after`). It reads as blank space.

#### Editor column

- The editor area spans the whole window under the tab strip. Its text column is 562px wide, centred in the editor area (styles/01: column x 559 to 1121, centre 840 = window centre).
- With the sidebar open in a maximised window, the column does not move. The sidebar overlays the empty left margin (styles/01 vs styles/07: column x 559 in both).
- The editor area is shifted right by `left = (screen width − window width) × 200 / (screen width − (722 + 200 + preview width))` pixels, so it slides further right as the window gets narrower (snap `_resizeSidebar`).
- When the window is narrower than 722 + 200 + preview width, or that free space is under 200px, `body` gets `--compact` and the editor area is shifted by the full 200px, so the sidebar sits beside it instead of over it (snap; styles/42: editor area x 200 to 800).
- In a narrow editor area the column shrinks to (area width − 160) and stays centred: 440px in an 800px window with sidebar (styles/42, styles/43).
- Typewriter mode only changes the editor padding to 450px top and 498px bottom in a 1020px window, so the caret line sits at the vertical middle (styles/09).

#### Margin heading labels

- ATX heading markers (`#`, `##`) are not drawn. In their place a label ` h1 ` to ` h6 ` sits in the left margin, ending just before the text column: marker box x 533 to 560, the label inside it is 11px SFMono, `--color-tertiary` (styles/01 `block-header__marker`; live; shots/01 labels at about x 540 to 553).
- The label sits on the heading's baseline area, vertically centred on the heading line by eye (shots/01).

#### Word count

- Bottom-right corner of the window: 12px from the bottom, 20px from the right, 13px UI text, `--color-tertiary`, with a window-coloured background so text scrolling under it is hidden (styles/08: rect x 1623, y 984, 37 × 24, text "173 W").
- Clicking marks it selected: background `--selection-blue` (all.css `text-stats--selected`).

#### Split preview

- Without sidebar: editor half and preview half, each 50% of the window (preview.css).
- With sidebar: the editor side (tab strip included) is 50% + 100px wide, the preview 50% − 100px (styles/04: app 0 to 940, preview 940 to 1680, width 740).
- The tab strip only spans the editor side; tabs stay centred within it (styles/04: open tab at x 416).
- In the reference window, split preview with sidebar makes the layout compact: editor area x 200 to 940, column 562px centred in it at x 289 (styles/04).
- Preview pane: its own background (white in Default and GitHub themes, rgb(20,20,20) in Dark), no divider line between editor and preview (styles/04, shots/04).
- Dark app mode does not change the preview theme. A dark editor beside a white preview is normal (shots/03, styles/03).

#### Full preview

- The preview covers the whole window including the tab strip and sidebar: rect 0,0 to 1680,1020 (live `preview--full-screen`).
- Content column centred; widths per theme in section 4.

#### Window size

- Minimum size 400 × 400. Minimum width doubles to 800 while a preview is visible, and gains 260px while a sidebar is visible. If the window is narrower than the new minimum, the app widens it (snap `_updateMinWindowWidth`).
- So split preview plus sidebar forces at least 1060px: shots/44 shows an 800 × 600 window widened to 1060 × 600 (editor side 630, preview 430).

#### Empty window

- With no tab open the window shows a centred `×` in 52px, `--color-tertiary`, on the window background (styles/33, shots/33).

#### Stacking (back to front)

footer (find box, notifications) → sidebar → popups → tab strip → About / License / Purchase overlays → full preview → Windows buttons → disabled-app notice (all.css z-index 1 to 8).

### 3. Editor rendering per Markdown element

General rule: every Markdown character stays visible. Markers are faded to `--color-tertiary`, content keeps the normal colour. Prose runs use the prose font (15px system-ui); markers of block elements and all code-like content use Roboto Mono 13px. All lines are 24px tall except large headings.

Colours below are light / dark. Sources: styles/01 and styles/02 for the top of `Everything.md`, styles/17 and styles/18 for the bottom, shots/01, shots/02, shots/17.

| Element | What is drawn | Font | Colours |
|---|---|---|---|
| Front matter `---` ... `---` | Fence lines faded. Inner lines in a full-column-width band (562px, 24px per line); the fences have no band. | Mono 13 | fences `#B3B3B3` / `#666666`; text, keys and colons `#7F7F7F` / `#999999`; band `--highlight` (`#F0F0F0` / `#303030` blended) |
| `[[toc]]` | Plain text | Mono 13 | `--color-blue` |
| ATX heading `#`..`######` | Marker hidden, margin label shown (section 2). Text bold. h1 line box about 33px, h2 about 29px | Prose, 21 / 18 / 15 / 15 / 15 / 15 px | light `#4C4C4C`, dark `#CCCCCC` |
| Setext heading (`===`/`---` underline) | Whole heading in code font, bold; large headings make it 1.4× / 1.2× with 1.5em line height | Mono, editor font size | `--color` (all.css) |
| `**bold**` | Markers bold and faded, text bold | Prose 15 bold | markers `#B3B3B3` / `#666666`; text `--color` |
| `_italic_` | Markers italic and faded, text italic | Prose 15 italic | same pattern |
| `~~struck~~` | Markers faded; text in secondary colour with line-through | Prose 15 | text `#7F7F7F` / `#999999` |
| `::highlighted::` | Background over the whole run including markers; markers in secondary colour | Prose 15 | background `--highlight-info`; markers `#7F7F7F` / `#999999`; text `--color` |
| `` `inline code` `` | Backticks faded, text gold. No background box | Mono 13 (0.8667em) | text `#C18B8B` / `#A8998A` |
| `[link](url)` | Brackets, parentheses and URL faded; link text blue | Prose 15 | text `--color-blue`; rest `--color-tertiary` |
| Bare URL `https://...` | Whole URL blue | Prose 15 | `--color-blue` |
| `<autolink>` | Angle brackets faded, URL blue | Prose 15 | all.css |
| `:smile:` emoji | Not converted to a picture. Colons faded, name in secondary colour | Prose 15 | `#7F7F7F` / `#999999` name |
| Footnote ref `[^1]` | Brackets faded, `^1` blue | Prose 15 | `--color-blue` |
| Block quote `> ` | Marker in mono, secondary colour; text in prose. No bar, no indent beyond the marker width (16px) | marker Mono 13, text Prose 15 | marker `#7F7F7F` / `#999999` |
| Bullet `- ` | Marker in mono, secondary colour; nested items keep their leading spaces in the marker (`  - ` is 31px wide) | same | same |
| Ordered `1. ` | Same as bullets (marker 23px wide) | same | same |
| Task `- [ ] ` / `- [x] ` | Whole marker including box text in mono, secondary colour. Checked tasks look the same as open ones (no strike, no fade) | same | same |
| Inline math `$E = mc^2$` | Dollars faded, content gold | Mono 13 | as inline code |
| Math block `$$$` ... `$$$` | Rendered with KaTeX in place of the source lines, left aligned, at 1.5 × 13 = 19.5px (KaTeX glyphs about 23.6px). Source lines hidden behind a window-coloured cover. When the caret is inside, or the find box is open, the source shows instead: mono, secondary colour, `\int`-style commands red, braces faded, source lines on the `--highlight` band | KaTeX / Mono 13 | rendered math in `--color` (styles/01 `math-preview`; shots/21 shows the source state) |
| Code fence | Fence lines (```` ```js ````) faded, no band. Code lines on a full-width `--highlight` band, text secondary colour with token colours below | Mono 13 | shots/17 |
| Table | Whole table in mono (cells too). Pipes and the divider row faded; cell text secondary colour. No grid lines, no band | Mono 13 | pipes `#B3B3B3`, text `#7F7F7F` (styles/17) |
| Image line `![alt](photo.png)` | Source line hidden and the picture shown instead, left edge on the text column, 6px space above and below. Height is the image scaled to fit the column, capped at 200px (480 × 270 file drawn at 356 × 200). No border, no radius | n/a | styles/17 (`img.image-preview`), shots/17 |
| Raw HTML | Tags, attribute names and values in mono 13 secondary; `<`, `>`, `=`, quotes faded; the text between tags stays in prose font and normal colour | Mono 13 + Prose 15 | styles/17 (`inline-tag`), shots/17 |
| Thematic break `---` | Plain faded text, no rule drawn | Mono 13 | `--color-tertiary` |
| Page break `+++` | Red text, no rule drawn | Mono 13 | `--color-red` |
| Footnote definition `[^1]: text` | Label in mono; text in prose; the whole block in secondary colour | Mono 13 + Prose 15 | `#7F7F7F` / `#999999` |
| Indented code, reference definition, HTML comment | Secondary colour | Mono 13 | all.css |
| Hard line break | A `↓` glyph after the line end, 0.15em gap, secondary colour | Mono 13 | all.css `inline-line-break::after` |
| Escape `\*` | Backslash faded | Prose | all.css |

#### Code token colours (editor, fenced blocks)

Token class names are the Prism names, so a rebuild can use Prism or any highlighter with the same names. Tokens without a colour here take the code text colour (`--color-secondary`).

| Token | Light | Dark | Source |
|---|---|---|---|
| keyword, function, tag | `#997799` | `#997799` | styles/17 (`span.keyword`, `span.function`) |
| string | `#CC8888` | `#AA7777` | styles/17, styles/30; default-dark.css |
| number | `#6688AA` | `#6688AA` | styles/17, styles/30 |
| boolean | `#669999` | `#669999` | styles/30 |
| property | `#CC8888` | `#AA7777` | default.css |
| variable | `#668888` | `#668888` | default.css |
| attr-name | `#C18B8B` (gold) | `#A8998A` (gold) | default.css |
| attr-value | `#6688AA` | `#AA7777` | default.css |
| comment, punctuation, shell comment | `--color-tertiary` | `--color-tertiary` | styles/17 (`span.comment`) |
| operator, interpolation, YAML key | `--color-secondary` | `--color-secondary` | styles/17, styles/30 |

#### Cursor, selection and other overlays

| Item | Look | Source |
|---|---|---|
| Caret | 1px wide bar in `--color`, inset 3px from the top and bottom of the line box. Blinks 500ms on, 500ms off; restarts on every move; hidden while the editor is not focused | all.css; snap `_blinkCursor` |
| Extra carets (multi-cursor) | Same bar in `--color-secondary` | all.css |
| Selection | `--selection-blue` behind the text; covers to the column's right edge for lines selected through their end (shots/41) | styles/41 |
| Selection when the editor is not focused | `--selection-neutral` | all.css `editor--blurred` |
| Find matches | other matches `--selection-yellow`, current `--selection-orange`; text in matches drawn in `--color-em` | styles/21, shots/21 |
| Spelling mistake | 3px solid underline in `--highlight-error`, as a bottom border of the word box | styles/34 |
| Matching bracket, other occurrences of the word under the caret (code) | `--highlight` background | all.css |
| Image selected (caret at image line start) | Image covered by `--selection-blue` at 70% opacity | editor--app.css |
| Block focus (focus mode) | Other blocks covered by `--material-transparent` | all.css |
| Git marks | `+`, `~` or `D` in tertiary colour, 30px right of the column's right edge | editor--app.css |
| Backup comparison | added lines rgba hsl(150,100%,75%) at 0.2, deleted lines hsl(0,100%,75%) at 0.2 | backups.css |
| Editor scrollbar | 16px track at the right edge of the editor; slider 7px wide, 2px from the right, radius 3px, `--material-thumb`. Hidden until scrolling, hides 750ms after scrolling stops with a 0.3s fade | editor.css; snap scrollbar code |
| Native text selection | Hidden (the editor draws its own) | editor.css |
| Mouse cursor | I-beam over the editor. In dark mode on macOS the app swaps in its own light I-beam image | all.css |

### 4. Preview themes

The preview is rendered inside its own isolated style scope. Three themes ship: Default, GitHub, Dark. The app's dark mode does not switch the preview theme. All values measured live on `testdocs/Everything.md` in full preview, 1680px window, unless the source column says otherwise; CSS files are `extensions/Preview/themes/*.css` and `extensions/Preview/css/base.css`.

| Item | Default | GitHub | Dark |
|---|---|---|---|
| Background | `#FFFFFF` | `#FFFFFF` | rgb(20,20,20) (hsl 0 0% 8%) |
| Body font | `system-ui, sans-serif` | `"Helvetica Neue", Helvetica, "Segoe UI", Arial, freesans, sans-serif` + emoji fonts | `system-ui, sans-serif` |
| Body size / line height | 16px / 28.8px (1.8em) | 16px / 25.6px (1.6) | 15px / 24.7px (1.9rem) |
| Body colour | `#333333` | `#333333` | `#AAAAAA` |
| Content column max width | 626px | 890px | 626px |
| Pane padding (top/bottom, sides) | 100.8px, 80px (3.5 lines) | 84px, 80px | 86.45px, 80px |
| Paragraph margin | 16px top, 28.8px bottom | 0 top, 16px bottom | 15px top, 24.7px bottom |
| Headings font / weight | system-ui, bold | Helvetica stack, bold | system-ui, normal weight, line height normal |
| h1 | 32px, line height 28.8, margin 86.4 top / 57.6 bottom | 36px, line height 43.2, 1px `#EEEEEE` bottom border, 10.8px bottom padding, margin 36 / 16 | 26px, margin 37.05 / 24.7 |
| h2 | 24px, margin 64.8 / 43.2 | 28px, line height 34.3, 1px `#EEEEEE` bottom border, 8.4px padding, margin 28 / 16 | 22.1px, margin 37.05 / 24.7 |
| h3 | 16px, margin 43.2 / 28.8 | 24px, margin 24 / 16 | 18.2px |
| h4 | 16px | 20px, margin 20 / 16 | 18.2px |
| h5 | 16px | 16px, margin 16 / 16 | 18.2px |
| h6 | 16px | 16px, colour `#777777` | 18.2px |
| Heading colour | body colour | body colour (h6 `#777777`) | body colour |
| Links | `#7799BB`, no underline | `#4078C0`, underline on hover and press | `#88AACC`, no underline |
| Bold / italic / strike | bold / italic / line-through in body colour | same | same |
| `mark` (`::text::`) | browser default: yellow `#FFFF00` background, black text | same | same (unstyled by all three themes) |
| Inline code | Roboto Mono 13.6px (0.85em), `#444444` on `#F3F3F3`, radius 2px, padding 1.36px 6.8px, margin 0 2.72px | Consolas, "Liberation Mono", Menlo, Courier, monospace 13.6px, `#333333` on rgba(0,0,0,0.04), radius 3px, padding 2.72px 0 plus a non-breaking space before and after | Roboto Mono 12.35px (0.95rem), `#AAAAAA` on `#292929`, radius 2px, padding 1.3px 6.5px, margin 0 2.6px |
| Code block | `#F3F3F3` background, no radius, padding 14.4px 15.6px, margin 16 top 28.8 bottom; code Roboto Mono 13.6px, line height 28.8px, `#444444` | `#F7F7F7`, radius 3px, padding 16px, margin 0 0 16; Consolas stack 13.6px, line height 19.72px (1.45) | `#292929`, no radius, padding 12.35px 15.6px; block font `"Fira Mono", monospace` 15px, code inside Roboto Mono 12.35px, line height 24.7px |
| Code tokens | keyword, tag `#AA77AA`; function, attr-value `#6688AA`; string, number, boolean, regex `#66AA88`; comment `#AAAAAA`; punctuation, operator `#888888`; selector, attr-name, url `#998877`; variable, property, key `#AA6666` | same as Default | as Default except comment `#777777`, punctuation and operator `#999999` |
| Block quote | 2.6px (0.2rem) left border `#DDDDDD`, 13px left padding, text `#999999`, margin 16 / 40 right / 16 | 4px left border `#DDDDDD`, padding 0 15px, text `#777777`, margin 0 0 16 | 2.6px left border `#333333`, 13px padding, text `#777777` |
| Lists | left padding 31.2px (2.4rem), disc / decimal; nested lists no bottom margin; ordered inside lists lower-roman | left padding 32px, nested bullets circle, nested ordered lower-roman then lower-alpha | as Default |
| Task list items | no bullet; native checkbox pulled 20.8px left, width 16.9px (1.3rem) | no bullet; checkbox margin 0 0.2em 0.25em −1.6em; 3px between items | as Default |
| Table | full width, collapsed borders; 3.9px (0.3rem) `#DDDDDD` rule above the table, 2.6px rule above the first body row, 3.9px rule below the last row; no vertical lines; th normal weight, left aligned; cell padding 7.2px 7.8px, first cell no left padding, last cell no right padding | block display, width of content; every cell 1px `#DDDDDD` border, padding 6px 13px; th bold; even rows `#F8F8F8`; rows 1px `#CCCCCC` top | as Default with `#333333` rules, cell padding 6.175px 7.8px |
| Image | natural size, max width 100%, no border | white background behind images | as Default |
| Horizontal rule | 2.6px `#DDDDDD` top border, margin 8 top / 28.8 bottom | 4px bar `#E7E7E7` (bottom border `#EEEEEE`), margin 16 | 2.6px `#333333`, margin 7.5 / 24.7 |
| Table of contents (`[[toc]]`) | plain nested bullet list of heading links, same as a normal list | same | same |
| Math block | 19.2px (1.2em), left aligned, padding 11.52px 0, margin 19.2 top / 28 bottom, radius 4px, scrolls sideways if wide | centred, padding 7.8px 0, margin 16 | 26px (2rem), left aligned, padding 7.8px 0, margin 26 / 28 |
| Inline math | KaTeX 19.36px | KaTeX 19.36px | KaTeX 18.15px |
| Footnote ref | superscript `[1]` at 13.33px in link colour | same, link colour | 12.5px, link colour |
| Footnotes block | rule above (same as `hr`), then a numbered list with the text and a `↩︎` back link in link colour | same | same |
| Emoji `:smile:` | rendered as the emoji character 😄 at text size | same | same |
| Page break `+++` | invisible (0px tall); forces a page break in print/PDF | same | same |
| Text selection | browser default | browser default | rgba(255,255,255,0.1) |
| Print | body forced to 14px; page padding 48px top/bottom, 32px sides | 14px | 14px |

Sources for the table: live measurement (`work/prev-default.json`, `work/prev-github.json`, `work/prev-dark.json` written during this session) and the theme CSS files for hover, nesting, print and selection. Screenshots: shots/11 to shots/16.

### 5. Pop-ups and panels

#### Shared popup card (go to file, go to heading, commands, backups, tabs switcher, find in folder)

- 360px wide, centred horizontally on the window, top edge 96px from the window top (styles/23: rows x 660 to 1020; all.css `--top-padding`).
- Background `--material`, radius 6px, `--shadow` ring (section 1). No dimming of the window behind (shots/24).
- Header: 72px tall, 20px side padding. It holds the filter field: 26px, weight 300, `--color` when typed. Empty field shows the popup name as placeholder in `--color-tertiary` ("Commands", "Backups") (styles/23, shots/26, crops of shots/28).
- List under the header: rows 24px, 20px side padding, at most 16 rows visible (384px), then it scrolls; 12px empty space under the last row. When the list is empty it is removed and the card is only the 72px header (shots/22, shots/28).
- Row text `--color-secondary`. Faded parts (file extension, folder, menu group, shortcut) `--color-tertiary`.
- Selected row: `--selection-blue` when the window is focused (shots/39), `--selection-neutral` when it is not (styles/23, shots/24).
- Typed letters that match are underlined in the row, skipping descenders (styles/24 `list__item__match`).
- A macOS overlay scrollbar shows inside the list when it scrolls (shots/26).

Per popup:

| Popup | Row content | Source |
|---|---|---|
| Go to file | file icon, name, faded `.ext`, faded ` in <folder>` | styles/24, shots/24 |
| Go to heading | heading icon (h1..h6 glyph), 16px indent per level below h1, heading text | styles/25 |
| Commands | faded `Group ›` prefix, command name, ` ✓` after checked toggles, shortcut right-aligned in faded text with 10px left gap (for example `⌘ ,`, `⌘ ⇧ S`) | styles/26, shots/26 |
| Backups | same card; placeholder "Backups"; rows not captured (no backups existed) | shots/28 |
| Tabs switcher (Ctrl+Tab) | no filter field; the header shows the word "Tabs" in the placeholder style (26px, weight 300, tertiary); rows: text-file icon and file name | shots/39, all.css `ctrl-tab` |
| Find in folder | filter field with the search text; result rows: file rows in tertiary with a `›` 7px after the name, which turns 90° when the file is expanded (9px gap); match rows under it | shots/22; find-in-files.css (result rows not captured) |

#### Find box

- Small dark box (light mode) in the bottom-right: 210px wide, 48px tall, 30px from the right and bottom edges, padding 12px 15px, radius 6px (styles/21, shots/21).
- Background `--color` (`#4C4C4C` light, `#BFBFBF` dark), so it is the inverse of the window. Text `--material` (`#FAFAFA` light, `#282828` dark), 13px UI font.
- No matches: background turns `--highlight-error` (find.css).
- While it is open, rendered math blocks show their source (shots/21; snap).

#### Autocomplete list (emoji, paths) and right-click menu

- Card under the current line, left edge 15px left of the text being completed: background `--material`, radius 6px, `--shadow-small`, padding 12px top and bottom (styles/34, shots/34).
- Rows 26px tall, 14px UI font, `--color`, 20px side padding. Selected row `--selection-blue`.
- Emoji rows: the emoji, 14px gap, then the name ("smile", "smirk cat") (crop of shots/34).
- Right-click menu uses the same card; a spelling suggestion that matches is drawn in `--color-red` (editor--app.css).

#### Files sidebar

- Row: 16px icon box, then the name in secondary colour, then the extension in tertiary colour (`Everything` + `.md`) (shots/10).
- Open file row: `--selection-neutral` background. Selected row while the sidebar has focus: `--selection-blue`; this stays blue even when the window is unfocused (styles/17; all.css rule order).
- Icons are tiny pixel drawings, 9px wide × 7px tall, at the bottom-left of a 16 × 16 box, filled `--color-tertiary` (live SVG; all.css `.list__item .icon`). Five file icons exist (snap `getIconHtml`):
  - folder closed: a folder outline with a tab and three small vertical slots;
  - folder open: a filled folder shape;
  - text file (`.md`, `.mdown`, `.markdown`, `.txt`): four horizontal lines, alternating long and short, like a paragraph;
  - image (`.png`, `.jpg`, `.gif`): a checkerboard-like dotted pattern;
  - any other file: a grid of dots.
- Files the app cannot open get `list__item--non-openable` but look the same in the shots (styles/01, `photo.png`).
- Drag target line: 2px bottom border in `--color` (files-sidebar.css).

#### Outline sidebar

- Same 200px sidebar. Rows: heading icon (a small box with H1..H6 drawn in pixels), heading text; each level below h1 indents 16px; long text ends with `…` (styles/06, crop of shots/06).
- Current heading row: `--selection-blue` (styles/06).

#### Preferences and Keyboard Shortcuts

- Both open as ordinary editor tabs (`Preferences.md`, `Keyboard Shortcuts.md`) and use the editor's Markdown look; nothing special is drawn (shots/30, shots/31).
- Preferences: h1 "Preferences", one paragraph, a ` ```yaml ` block on the code band (keys secondary, colons tertiary, numbers `#6688AA`, strings `#CC8888`, `true` `#669999`), then a paragraph with two links (styles/30).
- Keyboard Shortcuts: h2 per menu ("File", ...), each followed by a YAML block of `command: shortcut` lines (styles/31).

#### Other panels

- Notification bar (bottom of the editor column): centred text in `--color-blue`, 13px padding, 1px top border in the text colour, buttons written as `[ Label ]` with 13px gap (all.css). Not captured.
- About / License / Purchase overlays: full window, `--material-transparent` background, content centred; title 26px in `--color`; License field and Purchase button are `--color` blocks with `--material` text, radius 3px (all.css). macOS uses the native About panel instead (shots/29 not useful).
- Image zoom: window covered by `--material-transparent`, the image moved to the window centre and scaled up to fit (window minus 120px, never above natural size); cursor zoom-out (snap `_zoom`).

### 6. Focus, dark mode, hover and motion

#### Focused vs unfocused window

`body` gets `--blurred` when the window loses focus. Only these change (all.css; compare shots/23 and shots/39):

- Selected rows in popup lists: `--selection-blue` → `--selection-neutral`.
- The sidebar gets `sidebar--blurred` but its selected row stays blue (rule order in all.css).
- The editor's own focus is separate: when the editor loses focus the caret is hidden and the selection turns `--selection-neutral`.
- Tabs, text colours and backgrounds do not change.

#### Dark mode

Everything in section 1's dark column applies. In addition:

- Headings use `--color-em` `#CCCCCC`, brighter than body text `#BFBFBF`; in light mode headings and body are the same `#4C4C4C` (styles/01 vs styles/02).
- Inline code and inline math text turn from pinkish gold `#C18B8B` to brownish gold `#A8998A`; code strings and properties turn `#AA7777`.
- The find box becomes a light grey `#BFBFBF` box with dark text.
- Popup ring becomes a solid 1px `#4D4D4D` line plus a 7px dark halo.
- Custom light I-beam mouse cursor over text on macOS.
- The preview keeps its own theme (shots/03: dark editor, white preview).
- 800 × 600 dark: shots/42.

#### Hover, press and motion

- No hover styles on tabs, sidebar rows, popup rows or menu rows (none in all.css).
- GitHub preview theme: links underline on hover and press.
- Windows only: window buttons get a `--highlight` background on hover; the close button turns `#DD3333` with white glyph.
- Mouse cursors: text I-beam in the editor; pointer over links (with the modifier, see behaviour spec) and the word count; default over sidebar, popups and tabs; zoom-in / zoom-out over images.
- Motion: caret blink 500ms; scrollbar fade-out 0.3s after 750ms idle; split-preview scroll sync scrolls smoothly unless the jump is over 5000px (behaviour spec "Preview modes"). No other CSS transitions or animations exist in the app stylesheets.

### 7. Unknowns

- Find-in-folder result rows and Backups rows were never on screen with content; their look comes from CSS only.
- Dark-mode find highlight colours are converted from the CSS, not measured.
- The `file` (unknown type) and `folder open` icons were only read from their drawing data, not seen in a screenshot; descriptions are approximate.
- Image zoom: no CSS transition was found, so it likely jumps rather than animates (the behaviour spec says "animates"; not checked on screen).
- Notification bar, About / License / Purchase overlays, right-click menu and the image zoom were not captured.
- `system-ui` and `-apple-system` resolve to whatever macOS ships; exact rendering (and therefore the 562px column) depends on that font's "a" width.
- The dark preview theme's code block font (`Fira Mono`) and the declared Merriweather font are not in the package; what the original authors saw may differ.
- Windows and Linux looks (16px rounded scrollbars, window buttons, 1px window border) were not captured.
- Exact traffic-light position is native macOS (`hiddenInset`) and was not measured.
- Preview and popup scrollbars are macOS native overlay scrollbars; their look was not measured.
