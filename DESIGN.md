---
name: Plain
description: A quiet, grey Markdown editor for macOS where only the text stands out.
colors:
  material: "#FAFAFA"
  material-secondary: "#F0F0F0"
  material-transparent: "rgba(250,250,250,0.95)"
  material-line: "rgba(0,0,0,0.1)"
  material-thumb: "rgba(82,82,82,0.8)"
  window-background: "#F9F9F9"
  color: "#4C4C4C"
  color-secondary: "#7F7F7F"
  color-tertiary: "#B3B3B3"
  color-blue: "#8599AE"
  color-red: "#D98C8C"
  color-gold: "#C18B8B"
  selection-blue: "rgba(71,153,235,0.25)"
  selection-neutral: "rgba(204,204,204,0.25)"
  selection-yellow: "#FEEBB5"
  selection-orange: "#FEC7B5"
  highlight: "rgba(0,0,0,0.04)"
  highlight-info: "rgba(140,217,179,0.5)"
  highlight-error: "rgba(255,77,77,0.5)"
  dark-material: "#282828"
  dark-material-secondary: "#232323"
  dark-material-line: "#4D4D4D"
  dark-window-background: "#1D1D1D"
  dark-color: "#BFBFBF"
  dark-color-secondary: "#999999"
  dark-color-tertiary: "#666666"
  dark-color-blue: "#8799AC"
  dark-color-red: "rgba(232,125,125,0.7)"
  dark-color-gold: "#A8998A"
typography:
  editor-body:
    fontFamily: "system-ui"
    fontSize: "15px"
    lineHeight: 1.6
  editor-h1:
    fontFamily: "system-ui"
    fontSize: "21px"
    lineHeight: "33.6px"
  editor-h2:
    fontFamily: "system-ui"
    fontSize: "18px"
    lineHeight: "28.8px"
  editor-code:
    fontFamily: "Roboto Mono, monospace"
    fontSize: "13px"
  ui:
    fontFamily: "system-ui"
    fontSize: "13px"
    lineHeight: "24px"
  menu-row:
    fontFamily: "system-ui"
    fontSize: "14px"
    lineHeight: "26px"
  popup-filter:
    fontFamily: "system-ui"
    fontSize: "26px"
    fontWeight: 300
    lineHeight: "72px"
  empty-glyph:
    fontFamily: "system-ui"
    fontSize: "52px"
rounded:
  small: "3px"
  card: "6px"
spacing:
  line: "24px"
  level-indent: "16px"
  row-padding: "20px"
  editor-top: "48px"
  editor-sides: "80px"
  editor-bottom: "96px"
  tab-strip: "48px"
  sidebar: "200px"
  popup: "360px"
components:
  popup-card:
    backgroundColor: "{colors.material}"
    rounded: "{rounded.card}"
    width: "{spacing.popup}"
  popup-filter:
    textColor: "{colors.color}"
    typography: "{typography.popup-filter}"
    height: "72px"
    padding: "0 20px"
  popup-row:
    textColor: "{colors.color-secondary}"
    typography: "{typography.ui}"
    height: "{spacing.line}"
    padding: "0 20px"
  popup-row-selected:
    backgroundColor: "{colors.selection-blue}"
  popup-row-selected-inactive:
    backgroundColor: "{colors.selection-neutral}"
  tab:
    textColor: "{colors.color-tertiary}"
    typography: "{typography.ui}"
    height: "30px"
    padding: "3px 10px"
  tab-current:
    textColor: "{colors.color-secondary}"
  notification-bar:
    backgroundColor: "{colors.material}"
    textColor: "{colors.color-blue}"
    typography: "{typography.ui}"
    padding: "13px"
  notification-bar-error:
    textColor: "{colors.color-red}"
---

# Design System: Plain

Values come from `Sources/PlainCore/DesignTokens.swift` (`Tokens`) and the editor defaults in `Sources/PlainCore/Preferences.swift`. That code is the source of truth; this file explains how to use it. `docs/DESIGN.md` covers how the code is built.

## Overview

**Creative North Star: "The Quiet Page"**

Plain's chrome fades back so the writing is the one thing on screen. Every surface is a near-white or near-black grey, text sits in three steps of grey, and the tab strip, sidebars and popups use the same small 13 pt type on a 24 pt line. Nothing is bold, nothing is saturated, and the only icons are small 16 pt pixel-drawn glyphs in the Files sidebar, in tertiary grey. Tabs are plain text, sidebar Git marks are `+ ~ D R`, and notification buttons are bracketed text such as `[ × ]`.

Colour appears only when it means something. Faded blue marks links and information, faded red marks errors and maths commands, and a muted gold marks inline code. Selection, find matches and spelling use soft tints behind the text, never coloured text. The editor itself is a single column, 72 letter "a" widths wide, with 80 pt margins and generous space above and below.

Light and dark modes are the same system with the greys inverted. Dark mode keeps each accent's hue and drops its brightness.

**Key Characteristics:**
- Grey surfaces and grey text in three steps; no pure black or pure white in the chrome.
- One small UI type size (13 pt on 24 pt) everywhere outside the editor and the popup filter.
- Colour carries meaning only: links, information, errors, code.
- Flat surfaces; popups lift with thin outline rings, not blurred shadows.
- Text-first controls; no icon set beyond the sidebar's pixel glyphs.

## Colors

All neutrals, with three faded accents that never reach full saturation.

### Primary
- **Blue** (`color-blue`): link text and bare URLs in the editor, table-of-contents markers, and the text and top rule of information notifications.

### Secondary
- **Red** (`color-red`): error notifications, `\command` names in maths source, page-break markers, and the changed letters in spelling suggestions in the context menu.

### Tertiary
- **Gold** (`color-gold`): inline code and inline maths in the editor, and attribute names in code.

### Neutral
- **Material** (`material`): popup cards, the notification bar and sidebars. `material-secondary` is the one step darker surface.
- **Window background** (`window-background`): the window before content paints.
- **Line** (`material-line`): dividers inside popups and 1 pt separators.
- **Text** (`color`): editor body text and popup filter text.
- **Secondary text** (`color-secondary`): popup rows, the current tab, strikethrough, code blocks, footnotes, Markdown markers.
- **Tertiary text** (`color-tertiary`): other tabs, placeholders, file extensions, Git marks, link brackets, thematic breaks, comments in code.

### Tints behind text
- **Selection blue** / **selection neutral**: the selected popup row while the window is active / inactive.
- **Selection yellow** / **selection orange**: all find matches / the current find match.
- **Highlight info**: `::mark::` highlighted text. **Highlight error**: misspelt words. **Highlight**: the full-width band behind fenced code, maths, front matter and HTML block lines.

Dark mode values sit beside each light value in `Tokens.dark`; the frontmatter lists the dark surfaces, text and accents with a `dark-` prefix.

## Typography

**Body Font:** the system font (`system-ui`, San Francisco), 15 pt with 1.6 line height in the editor.
**Mono Font:** Roboto Mono, 13 pt, for code in the editor; heading labels in the margin use the system monospaced font at 11 pt.

**Character:** one system sans for everything, kept small and light so the chrome never competes with the writing; a single monospace for code.

### Hierarchy
- **Popup filter** (light 300, 26 pt, 72 pt row): the typed query at the top of every popup.
- **Editor h1** (regular, 21 pt, 33.6 pt line): 1.4 × body size when "large font in headings" is on.
- **Editor h2** (regular, 18 pt, 28.8 pt line): 1.2 × body size. h3 to h6 stay at body size.
- **Editor body** (regular, 15 pt, 24 pt line): writing, at most 72 letter "a" widths per line.
- **Menu row** (14 pt, 26 pt line): menu-style rows.
- **UI** (13 pt, 24 pt line): tabs, sidebars, popup rows, notifications, stats.

The editor font, sizes, line height and line width are user preferences (`font`, `fontSize`, `codeFont`, `codeFontSize`, `lineHeight`, `lineWidth`); the values above are the defaults.

## Layout

Everything snaps to a 24 pt line (`line`). Popup rows, sidebar rows and editor lines at default size all use it.

- **Window:** a 48 pt tab strip on top, then the editor. The strip has 80 pt side padding to match the editor, and the window drags by its empty area.
- **Editor:** 48 pt above the text, 96 pt below, 80 pt at the sides, one centred column.
- **Sidebars:** 200 pt wide, rows padded 20 pt at the sides, 16 pt indent per folder or heading level.
- **Popups:** 360 pt wide cards: a 72 pt filter row, up to 16 rows of 24 pt, then 12 pt of space under the last row.
- **Preview:** a web page with its own theme (Default, GitHub, Dark in `Tokens.previewThemes`); Default keeps a 626 px column with 80 px side padding.

## Elevation & Depth

Flat. Surfaces do not cast blurred shadows. A popup separates from the window with two outline rings drawn around its card at 0 offset and 0 blur: a 1 pt ring of `material-line` and a 7 pt, almost transparent ring. In dark mode the inner ring is `#4D4D4D` and the outer ring is the surface colour at half opacity.

### Shadow Vocabulary
- **Card rings** (1 pt `rgba(0,0,0,0.1)` + 7 pt `rgba(0,0,0,0.025)`): popup cards.

## Shapes

Gentle corners only where something floats. Popup cards round at 6 pt (`card`); the editor's scrollbar slider rounds at 3 pt (`small`). The tab strip, sidebars, editor and notification bar are square-edged and borderless, separated by a single 1 pt line where needed.

## Components

### Popup card
Barely-there list with a large filter.
- **Shape:** 360 pt card, 6 pt corners, card rings.
- **Filter:** 26 pt light text, 72 pt tall, 20 pt side padding; placeholder in tertiary text.
- **Rows:** 13 pt secondary text, 24 pt tall, 20 pt side padding, one line, typed letters underlined.
- **Selected row:** selection blue fill; selection neutral when the window is inactive. Arrows and Ctrl+N / Ctrl+P move, Return or Right picks, Escape closes.
- **Empty:** a single "not found" row in tertiary text.

### Tabs
Plain text, no backgrounds.
- **Style:** 13 pt, 30 pt tall, 3 pt / 10 pt padding, at most 200 pt wide, middle truncation.
- **States:** current tab in secondary text, others in tertiary; the extension always tertiary; `•` after the name when edited, `⇾` before it when the file is outside the folder.

### Notification bar
- **Style:** material background, 1 pt top rule in the message colour, 13 pt centred text, 13 pt padding.
- **Colour:** blue for information, red for errors.
- **Buttons:** bracketed text, `[ Label ]` and `[ × ]`, no button chrome.

### Files sidebar
- **Rows:** 13 pt on 24 pt, 16 pt indent per level, 16 pt pixel-drawn icons in tertiary text.
- **Git marks:** `+` added, `~` changed, `D` deleted, `R` renamed, all in tertiary text.

### Editor
Markdown stays visible and styled in place. Markers fade to secondary or tertiary text, links turn blue inside faded brackets, inline code turns gold in Roboto Mono, and find, spelling and highlights paint tints behind the text.

## Do's and Don'ts

### Do:
- **Do** take every colour, size and spacing from `Tokens`; add a token there before using a new value.
- **Do** keep chrome text at 13 pt on the 24 pt line.
- **Do** use `color-blue`, `color-red` or `color-gold` only for their meanings above.
- **Do** show state with text colour steps (secondary versus tertiary) or tints behind text.
- **Do** give every new colour a dark-mode value in `Tokens.dark`.

### Don't:
- **Don't** add bold, saturated colour or new icons to the chrome.
- **Don't** use blurred drop shadows; floating elements use the outline rings.
- **Don't** add button chrome to text actions; bracketed text is the pattern.
- **Don't** colour text to show selection or matches; tint behind it.
- **Don't** copy Caret's CSS, themes, icons or fonts; these values are Plain's own, measured from its behaviour spec.
