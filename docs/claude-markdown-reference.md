# Claude's markdown renderer, measured

What the Claude desktop app actually does when it renders markdown, taken from the shipped
build rather than from memory. Every number below was read out of the app's own files on
26 October 2026.

Where the evidence came from:

- `/Applications/Claude.app` version 3.6556.2, Electron shell. The shell's stylesheet is
  `.vite/renderer/main_window/assets/MainWindowPage-BjVtjJFx.css` inside `app.asar`.
- The chat UI itself is the claude.ai web app loaded inside that shell
  (`main_window/index.html` says so in a comment: "everything else gets loaded from
  claude.ai"). Its bundles came from the app's HTTP cache under
  `~/Library/Application Support/Claude/Cache/Cache_Data`, plus two chunks fetched
  straight from `assets-proxy.anthropic.com`.
- The chunks that matter: `shared-12-CJ-QYjQa.js` (the `StandardMarkDown` component),
  `shared-10-DBMtvSAn.js` (the streaming renderer and the block scanner),
  `vendor-markdown-FZZNrO14.js` (the unified/remark/rehype stack),
  `shared-styles-DHY0-m4Z.css` (the web app's stylesheet).

Two things could not be recovered and are listed under Gaps at the end.

## 1. The pipeline

Markdown goes through `unified` with remark and rehype plugins, assembled per render by
one function that takes nine flags:

```
Ti({ gfm, artifacts, latex, breaks, stripHtmlComments, citations,
     proseBlocks, smartQuotes, hangingQuotes })
```

- `gfm` is either `true` (GitHub tables, strikethrough with `singleTilde: false`) or the
  string `"tables"`, which swaps in two custom table plugins.
- `latex` adds KaTeX with `{ errorColor: "inherit", output: "htmlAndMathml", strict: false }`.
- `breaks` turns single newlines into `<br>`.
- `stripHtmlComments` drops HTML comments. It is on only in `markdown-document` mode.
- `citations` and `proseBlocks` add citation pills and prose block wrappers.
- `smartQuotes` plus `hangingQuotes` add typographic quotes and hanging punctuation.

Four modes select the flags and the components:

| Mode | Values | Effect |
|---|---|---|
| typography | `prose`, `response`, `chat` | `prose` drops every utility class and styles from CSS instead |
| proseContainer | `response`, `chat` | `response` enables hanging quotes |
| dialect | `chat`, `commonmark-tables` | `commonmark-tables` skips the table fix-ups |
| normalizationMode | `code-in-markdown` | how inline code is normalised |

Assistant messages use typography `prose`, container `response`, and a
`headingLevelOffset` of 1, so an `h1` in the source lands in the DOM as an element with
`aria-level` 2. Links open with `target="_blank"`.

## 2. Type

The design system is "cds", a set of CSS custom properties on `.cds-root`, with Tailwind
v4 utilities on top. At the comfortable density used on desktop:

| Token | Size | Line height |
|---|---|---|
| prose | 1rem (16px) | 1.5rem (24px) |
| body | 0.875rem (14px) | 1.25rem (20px) |
| code | 0.8125rem (13px) | 1.1875rem (19px) |
| heading | 0.9375rem (15px) | 1.25rem (20px) |
| title | 1.375rem (22px) | 1.75rem (28px) |
| caption | 0.75rem (12px) | 1.0625rem (17px) |
| footnote | 0.8125rem (13px) | 1.0625rem (17px) |

The assistant message body overrides that with its own class:

```css
.font-claude-response-body {
  font-size: var(--msg-font-size, .9375rem);          /* 15px */
  line-height: calc(var(--msg-font-size, .875rem) * 1.5);
}
```

`--msg-font-size` is the user's text-size setting: 0.8125rem small, 0.875rem medium,
0.9375rem large.

Fonts are two variable families, Anthropic Sans and Anthropic Serif, weight range 300 to
800, with `font-feature-settings: "dlig" 0`. The weights are named by axis value, not by
CSS keyword: regular 360, medium 460, semibold 540, bold 560. Both have long fallback
stacks that end in the system CJK faces.

Spacing tokens at comfortable density: radius 8px, control height 32px, icon 20px,
padding 6/8/12/16/24px, gaps 8/12/16/28/40px.

## 3. Blocks, element by element

These are the classes the renderer puts on each element. In `prose` mode the classes are
dropped and the CSS scoped under `[data-cds-reply-type] [data-cds=Prose]` takes over, so
both columns matter.

### Headings

Chat classes:

| Element | Classes |
|---|---|
| h1 | `mt-3 -mb-1 text-[1.375rem] font-bold break-words` |
| h2 | `mt-3 -mb-1 text-[1.125rem] font-bold break-words` |
| h3 | `mt-2 -mb-1 text-base font-bold break-words` |
| h4 | `mt-2 -mb-1 text-base font-bold break-words` |
| h5 | `mt-2 -mb-1 text-sm font-bold break-words` |
| h6 | `mt-2 -mb-1 text-sm font-semibold break-words` |

Prose-mode CSS variables, where `1em` is the prose size:

```
--_prose-h1-size: calc(1em + .125rem);   --_prose-h1-leading: calc(var(--_prose-leading) + .1875rem);
--_prose-h2-size: var(--_prose-h1-size); --_prose-h2-leading: var(--_prose-h1-leading);
--_prose-h3-size: 1em;                   --_prose-h3-leading: var(--_prose-leading);
--_prose-h4..h6: same as h3
```

So in an assistant message h1 and h2 are 2px larger than body text with 3px more leading,
and h3 to h6 are body size. Heading weight is semibold (580, axis 540).

### Paragraph, strong, links

- `p`: base typography plus `break-words whitespace-normal`.
- `strong`, `b`: `calc(medium(500) + 1)` = 501, weight axis medium.
- `a`: in prose mode no underline at all, colour only. In other modes
  `underline underline-offset-2 decoration-1 decoration-current/40 hover:decoration-current`.

### Lists

- `ul`: `list-disc flex flex-col gap-1 ps-8 mb-3`, plus
  `[li_&]:mb-0 [li_&]:mt-1 [li_&]:gap-1 [&:not(:last-child)_ul]:pb-1 [&:not(:last-child)_ol]:pb-1`.
- `ol`: same with `list-decimal`.
- `li`: base plus `whitespace-normal break-words ps-2`.
- Markers shrink to 0.7em in the `inherit` typography.

### Blockquote

`ms-2 border-s-4 border-[hsl(var(--border-300)/0.1)] ps-4 text-text-300`: 8px inline start
margin, 4px inline-start border at 10% of the border colour, 16px inline-start padding,
muted text.

### Tables

- Wrapper: `md-table-scroll` in prose mode, `overflow-x-auto w-full mb-6` otherwise.
- `table`: `min-w-full border-collapse text-sm leading-[1.7] whitespace-normal`.
- `thead`: `text-left`. `tr`: nothing.
- `td`: `border-b-0.5 border-[hsl(var(--border-300)/0.3)] py-2 pr-4 align-top`.
- `th`: `text-text-100 border-b-0.5 border-[hsl(var(--border-300)/0.6)] py-2 pr-4 align-top font-bold text-start`.

Prose mode overrides the cells to `padding-block: calc(.4375em + 1px)` (about 8px),
`padding-inline: 0`, no background, no radius, and puts `padding-inline-start: 1.5em`
(24px) on every cell after the first in a row. Header cells get semibold.

### Rule

`hr`: `border-border-200 border-t-0.5 my-3 mx-1.5`. Half-pixel top border, 12px vertical
margin, 6px horizontal.

### Inline code

`background: var(--cds-fill-ghost-hover)`, `color: var(--cds-prose-code-color, var(--cds-text-primary))`,
`border: 0`, `border-radius: 4px`, `padding: 1px 4px`. No font-family or size override, so
it inherits the body face. The non-prose variant is a chip:
`bg-text-200/5 border border-0.5 border-border-300`.

### Code blocks

The wrapper is `bg-bg-000/50 border-0.5 border-border-400 rounded-[var(--msg-block-radius,0.5rem)]`:
page background at 50%, a half-pixel border, 8px radius. The `code` inside is
`p-3.5 !text-sm !leading-relaxed`, so 14px padding and 14px/1.625 text.

A header sits above the code:

- The language name in `text-secondary font-small p-3.5 pb-0`.
- A copy button, and a download button when one is available. The wrapper takes
  `pe-20` with a download button and `pe-14` without, so the code never runs under them.
- The button layer is `sticky top-2`, `opacity-0` until `group-hover` or
  `group-focus-within`, and always visible on touch (`pointer-coarse`, `@media (hover:none)`).
  It is pulled out of flow with `w-0 float-end`, and a `before` pseudo-element 24px wide
  with `mask-image: linear-gradient(to_right, transparent, black)` fades the code out
  behind it.
- The whole block is `role="group"` with `aria-label` "{language} code" or "Code", and
  `focus-visible:ring-2 focus-visible:ring-accent-100`.
- Highlighting is Shiki. Lines wrap when the block has no language. Mermaid blocks render
  as a diagram. Blocks over a size limit render a notice instead of the code.
- Content is normalised before highlighting: `\r\n` and `\r` become `\n`, trailing
  whitespace is trimmed.

## 4. Streaming

This is the part that makes Claude's markdown feel alive, and it is a separate renderer
from the settled one. While text streams, a custom renderer (`streaming_md`) draws it;
once the message settles, React Markdown (`react_md`) redraws the whole thing. There is
also a `react_md_fallback` when the streaming renderer cannot be used.

### Splitting into blocks

A scanner walks the text line by line and keeps this state:

```
codeFence {char, len}   inMathBlock   inList   listPendingBlank
inTable   inBlockquote   inIndentedCode   indentedCodePendingBlank
hadBlankLine   hadContent   offset
```

- A fence opens on `/^(\`{3,}|~{3,})/` and closes on a line that is only the same
  character, at least as long, and nothing else.
- Indented code opens on `/^( {4}| {0,3}\t)/` only after a blank line or before any
  content. A further blank line sets `indentedCodePendingBlank` and keeps it open; a
  non-indented line closes it.
- A list opens on `/^[-*+]\s/` or `/^\d+[.)]\s/`. A blank line sets `listPendingBlank`.
  An indented line clears the pending flag; a line with no indent closes the list.
- A table opens on any line containing `|` and closes on a blank line.
- A blockquote opens on a line starting with `>` and closes on a blank line.
- `$$` on its own line toggles a math block.

A boundary is pushed at every blank line that is not inside an unclosed construct, and
when a list closes. The scanner returns `{boundaries, nextState}` and the state is kept,
so new text only rescans from the saved offset, and only when the new text extends the
old as a prefix.

The split produces `completedChunks`, the `streamingChunk` still open, and an `openBlock`
whose `kind` is one of `code`, `math`, `table`, `blockquote`, `list`, `paragraph`, `none`.

Each completed chunk is rendered as settled markdown. The open chunk is drawn by one of
four fast paths, chosen by its kind: `openFenceFastPath`, `openListFastPath`,
`openTableFastPath`, `openParagraphFastPath`. `earlySettle` (on by default) settles a
block the moment it closes instead of waiting for the message to end. `holdBack` (on by
default) withholds block markers, so the backticks of an unfinished fence do not flash
on screen.

The streaming path uses its own smaller component set:

| Element | Classes |
|---|---|
| h1 | `mt-2 mb-2 font-bold` |
| p | `whitespace-pre-wrap break-words` |
| li | `whitespace-normal break-words` |
| ul / ol | `list-disc`/`list-decimal` `space-y-2.5 ps-7`, nested lists `pb-1` |
| blockquote | `border-s-2 border-border-100 ps-2` |
| code block | the same component as the settled path |

### Word reveal

Text is not shown the moment it arrives. A timer reveals it in steps:

```js
{ stepChars: 22, targetLagMs: 550, minStepMs: 25, maxStepMs: 150 }
```

22 characters per step, aiming to stay 550ms behind the incoming text, with each step
between 25ms and 150ms apart. A word is `(?:^\s+)?\S+\s*`, so reveals land on word
boundaries. Below `joinAboveChars` of 120 characters there is no wave at all; the text
simply appears. After a catch-up join the renderer holds for
`max(25ms, min(chars * 2.5, 150ms))`. `mountedTextShown` turns the wave off entirely,
and the wave is skipped when the document is hidden.

### Other performance work

- A warmup renders a fixed sample ("Warming **up** the _reply_ path with `inline code`.
  - first item - second item") through the real renderer after 2s idle, so the first
  real message does not pay for it.
- Offscreen blocks get `content-visibility: auto` with
  `contain-intrinsic-block-size: auto 3rem` and `overflow-clip-margin: 2.5rem`, behind a
  `@supports` check, in a `md-deferred-blocks` wrapper.
- The assistant message has a transparent inline-start border of 4px that grows with
  window width: `clamp(0px, (100% - 384px) * .175, 56px)`.
- When streaming ends the renderer calls `performance.mark("md:finalize")` with the
  number of chunk slots and how many settled early.

## 5. Gaps

Not recovered, so not specified here:

- The base `[data-cds=Prose]` rules that set paragraph spacing, list marker colour and
  the prose base font. The shell stylesheet and the web stylesheet both reference
  `--_prose-leading` but neither defines it; it is set by a stylesheet that was not in
  the app's cache and could not be fetched (claude.ai returns 403 to a plain request).
- Hanging punctuation works through `span[data-hang-next]` with per-character
  `--hq-kern-*` values. The mechanism is visible; the kerning table is not.
- The raw palette. Claude's colours are CSS custom properties (`--cds-gray-50` to
  `--cds-gray-900`, `--cds-text-primary`, `--cds-fill-ghost-hover`, `--cds-border-300`)
  and only the semantic mapping between them was recovered, not the hex values. Every
  colour in a port is therefore Plain's own choice filling a measured role, not a copied
  value. The structure that is measured: body text on a page background, muted secondary
  text at a lower contrast, a half-pixel border at 10 to 30% opacity for table rules, and
  a ghost fill at 5% for inline code.

## 6. Porting to Plain

Plain's preview is a WKWebView with a shadow root, a theme stylesheet of CSS custom
properties, and per-block patching. That maps onto the above directly.

What to take:

1. The type scale and the two-weight heading scheme (h1/h2 slightly larger than body,
   h3 to h6 at body size) rather than Plain's current 32/24/16px ladder.
2. Inline code that inherits the body face, with a 4px radius and 1px 4px padding.
3. Code blocks with an 8px radius, a half-pixel border, 14px padding, 14px/1.625 text,
   and a header carrying the language and a copy button.
4. Tables with only cell bottom borders at half-pixel, 8px vertical padding, no inline
   padding except 24px between cells, and bold left-aligned headers.
5. Blockquotes with a 4px border at 10% opacity, 16px padding, 8px margin, muted text.
6. Lists as a flex column with a 4px gap, 32px inline-start padding, 2px item padding.
7. `hr` at half a pixel, 12px vertical and 6px horizontal margin.
8. Links with no underline in prose, colour only.

What cannot be taken: the Anthropic Sans and Serif font files are licensed assets, and
Shiki's grammars and theme are a large dependency. Plain keeps its own fonts and Prism.

For the streaming feel, Plain's preview has no stream, but the block scanner is still
the right model for how a preview should treat a document being typed into: blocks that
are closed render settled, and the open block renders provisionally. That is a larger
change than the theme and is not in this pass.
