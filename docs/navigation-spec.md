# Navigation spec: Anytype's navigation in Plain

Draft, 26 October 2026. Waiting for Alec's confirmation; nothing is built.

Three parts of Anytype's desktop navigation come to Plain: opening files in the current tab, back and forward through the files a tab has shown, and one sidebar made of sections. All three keep Plain's look (root `DESIGN.md`): grey text, 13 pt rows on the 24 pt line, no new icons or colours. The surface is an editor, so the work is judged as a tool: fast to scan, consistent, and behaving like a Mac app.

## Who it is for

Someone writing in a folder of linked Markdown files: notes that point at other notes, docs with an index page. Today every link, sidebar click and Go to File pick opens a new tab, so a short read through five linked notes leaves five tabs and no way back but the tab strip. After this change a tab works like a browser tab: links replace its file, Cmd+[ goes back, and the sidebar shows pinned files, recent files, the folder and the outline at once.

Success: following a link and coming back takes Cmd+click then Cmd+[, with no new tab and no lost text; the Files tree and the outline are both on screen without switching sidebars.

## What Anytype does

Measured from Anytype Desktop's documentation and its source at `github.com/anyproto/anytype-ts`, branch `develop`, 23 October 2026.

| Anytype behaviour | Source |
|---|---|
| Opening an object replaces the current tab's object; Cmd+click, middle-click or "Open in new tab" opens a new tab | doc.anytype.io, Features > Tabs |
| Back and forward arrows sit at the top left of the header, dimmed when there is nowhere to go; Cmd+[ and Cmd+] | `src/ts/component/header/index.tsx`, `src/json/shortcut.ts` |
| A clock button lists the 15 most recently opened objects, newest first | `src/ts/component/header/index.tsx` |
| The sidebar stacks sections (Shared Pins, My Favorites, Unread, Recently Edited, Types, Bin); each can be hidden or dragged into a new order, for your view only | doc.anytype.io, Basics > Sidebar > Sections |
| A section folds from its title, shows 6 objects by default, and is reordered by dragging its title | doc.anytype.io, Basics > Sidebar > Widgets |
| Dragging the sidebar's right edge resizes it between 240 and 480 px (default 336); dragging it below 75% of the minimum closes it | `src/ts/component/sidebar/left.tsx`, `src/json/size.ts` |

Anytype's code is under the Any Source Available License 1.0. As with Caret, Plain takes behaviour and measured sizes only: never its code, CSS, icons, text or name inside the app.

## 1. Open in place

"Open in place" means the current tab shows the new file; no new tab opens.

### Gestures

| Where | Opens in place | Opens a new tab |
|---|---|---|
| Files, Pinned and Recent rows | Click, Return | Option+click, middle-click, Cmd+Return |
| Link in the editor | Cmd+click | Cmd+Option+click |
| Link in the preview | Click | Option+click, middle-click |
| Go to File (Cmd+P) and Find in Folder (Cmd+Shift+F) | Return, click | Cmd+Return, Option+click |
| Open… dialog, drop on the window, Finder, the `plain` command, New, Reopen Last Closed Tab, Open Recent Folder, the two settings files | | Always a new tab, as today |

Option means "new tab" in every place a click already means something else: in the sidebar Cmd+click adds a row to the selection (spec line 903, Finder's rule), and in the editor Cmd+click is what follows a link (spec 217–219). Middle-click matches Anytype everywhere.

Links to images and other files keep their current targets (Quick Look, the system app, the browser; spec 757–762). Only files that open in a tab go through the rules below.

### Which tab the file lands in

For an in-place request, the first rule that fits wins:

1. The file is the current tab's file: no change. A `#heading` in the link still scrolls to the heading.
2. The file is open in another tab: switch to that tab (spec 831 stays).
3. The current tab cannot be left: open a new tab instead, with no message. A tab cannot be left when there is no current tab, when its file is untitled, a settings file or a backup tab, or when it still has unsaved changes after autosave has been flushed (autosave off, or the save failed).
4. Otherwise replace: flush autosave, record scroll and selection in `FileHistory`, request a backup, push the current path onto the tab's back list, empty the forward list, release the old document (its undo history goes, as when a tab closes), load the new one and attach it. The tab keeps its place and id; its name, `⇾` mark and edited dot update.

Rule 3 is how this keeps Plain's "never lose text" rule without a save prompt.

## 2. Back and forward

Each tab keeps a back list and a forward list of file paths, up to 50 each; the oldest entry drops first.

- **Back** (Cmd+[, `window:go-back`, Go menu) takes the newest back entry, puts the current file on the forward list and opens the entry in place. **Forward** (Cmd+], `window:go-forward`) does the reverse.
- The mouse's back and forward buttons (button numbers 3 and 4) do the same.
- The same four rules apply to the target. Rule 2: the other tab is shown and this tab's lists stay as they were. Rule 3: the target opens in a new tab and leaves this tab's list.
- An entry whose file no longer loads is dropped and the next one is tried; with none left, nothing happens.
- Renaming or moving a file in the sidebar rewrites its path in every tab's lists. Trashing it removes it from them.
- Jumps inside one file (headings, footnotes, To Last Edit) do not add entries.
- Lists are saved with the window's tabs and come back on launch. Reopen Last Closed Tab brings back the file without its lists.

### The arrows

`←` and `→` sit at the left of the tab strip, at the 80 pt mark where the first tab starts today; tabs move right to make room.

- 13 pt UI font, each 24 pt wide and 30 pt tall (a tab's height), 10 pt before the first tab.
- Tertiary text, like tabs that are not current. An arrow with an empty list is not drawn, but its space stays, so tabs never shift.
- Tooltip: "Back to notes.md (⌘[)" and "Forward to plan.md (⌘])".
- Right-click an arrow: a menu of that list's files, newest first, up to 15. Picking one moves that many steps.
- Hidden with the tab strip (Hide Interface, Cmd+.) and in an empty window; the shortcuts still work while the strip is hidden.

## 3. The sidebar

One sidebar replaces the Files and Outline sidebars. It holds four sections, in this default order:

| Section | Header text | Rows |
|---|---|---|
| Pinned | "Pinned" | Files you pinned in this folder, in your order. Up to 10 rows show, then the section scrolls. Not drawn while empty or with no folder. |
| Recent | "Recent" | The 6 most recently opened files of this folder (the 40-file list Plain already keeps, spec 810), newest first, without the current tab's file and without files that no longer exist. Not drawn while empty. |
| Files | The folder's name | Today's Files tree, unchanged: filter, keys, rename, drag, Git marks. Not drawn with no folder. |
| Outline | "Outline" | Today's Outline: filter, current heading, Git change marks. With no headings, one row "No headings" in tertiary text. |

Pinned and Recent rows look like files in the tree: 16 pt pixel icon, name with the extension in tertiary text, Git mark, 20 pt side padding, no indent, middle truncation. The current file gets the `selection-neutral` tint the tree already uses.

Pinning: "Pin" on a file's context menu in Files and Recent, and "Pin in Sidebar" on a tab's context menu. Pinned rows offer "Unpin" and "Show in Finder" and reorder by dragging. Folders cannot be pinned. Pins belong to the folder, so every window on that folder shows the same list. Renaming a file keeps its pin; trashing it removes the pin.

### Folding, hiding and order

- Click a header to fold or unfold its section. Unfolded headers use secondary text, folded headers tertiary text, the same two steps tabs use for current and not current. No chevrons, no animation.
- Right-click any header: a menu listing the four sections with checkmarks. Unticking hides a section; nothing is deleted.
- Drag a header to move its section. A 1 pt `material-line` rule shows where it will land.
- Fold state, hidden sections and order are one setting for the whole app.

### Heights

The sidebar does not scroll as one list; a 5,000-file tree would push the outline out of reach.

- Every section shown is one 24 pt header row, with 12 pt of space above every header but the first.
- Pinned and Recent take the height of their rows.
- Files and Outline share what is left equally when both are unfolded, and each scrolls on its own. One folded gives the other all of it. When nothing is left, they show their headers only.

### Width

- Drag the sidebar's right edge (a 4 pt hit area, left-right resize pointer, nothing drawn) between 160 and 400 pt. Default 200 pt, today's width.
- Dragging below 120 pt (75% of the minimum, Anytype's rule) closes the sidebar. Show Sidebar brings it back at the last width.
- Double-click the edge to return to 200 pt.
- The width is saved per window. The window's minimum width becomes the sidebar's width plus 60 pt instead of a fixed 260.

### Commands

| Command | Id (kept) | Shortcut | Does |
|---|---|---|---|
| Show Sidebar (was Show None) | `window:toggle-sidebar` | Cmd+\ | Checkbox: shows or hides the sidebar |
| Show Files | `window:sidebar` | Cmd+Shift+E | Shows the sidebar, un-hides and unfolds Files, expands folders down to the current file and gives the tree keyboard focus. Pressed again while the tree has focus, hides the sidebar and focuses the editor (spec 897). |
| Show Outline | `window:headings-bar` | Cmd+Shift+B | The same for Outline and its filter field (spec 921). |
| Back | `window:go-back` (new) | Cmd+[ | Go menu, after To Previous Tab |
| Forward | `window:go-forward` (new) | Cmd+] | Go menu |

Show Files and Show Outline stop being a radio group. Their ids stay, so shortcuts users set in `Keyboard Shortcuts.md` keep working. Cmd+[ and Cmd+] are free in `CommandTable` today.

## States and ranges

- Folder: none to over 5,000 files (`folder-index-5000-files`). With no folder, only Recent and Outline show.
- Pins: none to any number. History: 0 to 50 entries each way per tab.
- Long file names truncate in the middle in rows; the arrow tooltips show the full name.
- Dark mode needs nothing new: every colour named here already has a value in `Tokens.dark`.

## Accessibility

- The arrows are buttons labelled "Back" and "Forward" with the target file name as their value, and are skipped while their list is empty.
- Section headers are buttons with the header trait and an "expanded" or "collapsed" value.
- Pinned and Recent rows are buttons, reachable with Full Keyboard Access.
- The resize edge is an adjustable element labelled "Sidebar width" that steps 20 pt.
- Fold state is shown by more than colour: a folded section's rows are gone.

## Architecture

### By module

| Module | Change |
|---|---|
| `PlainCore` | `Tokens`: `sidebarMinWidth` 160, `sidebarMaxWidth` 400, `sidebarCloseWidth` 120, `sidebarSectionGap` 12; `sidebarWidth` 200 stays as the default. `CommandTable`: Back and Forward; Show None becomes the Show Sidebar checkbox; Show Files and Show Outline become plain actions. |
| `PlainShell` | `ShellModels.swift`: `TabItem.document` becomes `var`; `TabItem` gains `history: TabHistory`, a value type with `push`, `back(steps:)`, `forward(steps:)`, `rename(from:to:)`, `remove(under:)` and the 50-entry cap. `SidebarState` loses `mode` and `lastVisible`, gains `visible`, `width` and `sections` (kind, folded, hidden, in order), and loads the old `sidebar-wN` value. New `Sidebar.swift` stacks the sections, sized by a pure `SidebarLayout.heights(…)`, with the resize edge. New `FileListSection.swift` draws Pinned and Recent from `FileIcon` and `GitMarkLabel`. `FilesSidebar` and `OutlineSidebar` keep their bodies and become sections. `TabBar` gains the arrows, the two list menus, "Pin in Sidebar", and `goBack(steps:)` and `goForward(steps:)` in `TabBarActions`. `PopupCard.onPick` gains `newTab` (Cmd+Return, Option+click). |
| `EditorTextView` | `EditorActions.openPath` becomes `(URL, _ newTab: Bool)`. `clickedLink` accepts Cmd and Cmd+Option; the link pointer shows for both. |
| `PreviewRenderer` | The page's `link` message carries `newTab` (Option held), and an `auxclick` listener sends middle-clicks the same way. `onLink` and `PreviewController.openPath` become `(String, Bool)`. |
| `PlainAppKit` | `WindowModel`: `open(_:newTab:)` and `openLink(_:newTab:)` replace today's versions; the four rules live in a pure `Placement.decide(…)` beside `OpenTarget` under "Rules kept apart from the window"; the leaving steps `activate` runs today become one `leaveCurrent()` used by both; `goBack(steps:)` and `goForward(steps:)`; `fileMoved` and `closeTabs(under:)` also update histories and pins; `sidebarActions.open` passes `newTab` on (today it drops it); `minimumWidth` takes the sidebar width. `TabMemory` gains `history`, decoded only when present so older `tabs-wN` files still load. `AppContext` holds the pins, shared by every window. `WindowView`: `WindowLayout.compute` takes the sidebar width instead of reading `Tokens.sidebarWidth`; the sidebar view becomes `Sidebar`. A local event monitor maps mouse buttons 3 and 4 to Back and Forward. |
| `FolderIndex`, `GitStatus`, `MarkdownDocument`, `PlainDocument`, `Spellcheck` | No change. |

### State files

| File | Holds |
|---|---|
| `sidebar-wN` | Was the sidebar mode string. Now `{ visible, width }`. The old string loads as `visible = (mode != none)`, width 200, and an old `outline` value unfolds Outline. |
| `sidebar-sections` (new, app-wide) | The four sections in order, each with `folded` and `hidden`. |
| `pins` (new, app-wide) | `{ "<folder path>": ["<file path>", …] }` |
| `tabs-wN` | `TabMemory` per folder gains `history`, one `{ back, forward }` per tab beside `files`. |

### Speed

- Opening in place costs the same as opening a new tab today: `editor-load-visible-styled-ms`, 300 ms for a 1 MB file. Going back reloads the file; no documents stay in memory.
- The outline's Git work (`refreshChangedHeadings`) runs while the Outline section is unfolded and the sidebar shows, which will be more often than today's Outline mode. `editor-keystroke-p95-ms` must stay under 8 ms with Files and Outline both open; check that by hand with a 1 MB file in a folder with Git changes.
- Every existing suite in `docs/DESIGN.md`, Speed, must still pass.

### Tests

New tests check the pure parts:

- `TabHistory`: the 50 cap, push emptying forward, `back(steps: 3)` order, rename, remove, a round trip through JSON, and an old `tabs-wN` file without `history`.
- `Placement.decide`: one case per rule, plus an edited file with autosave on and off, a settings file, a backup tab and no current tab.
- `SidebarLayout.heights`: all unfolded; Files folded; Outline hidden; 14 pins (10 rows shown); 2 recents; a window too short for anything.
- Sidebar width: clamping to 160–400, closing below 120, reset to 200, the old `sidebar-wN` values.
- Pins: rename and trash.
- `testEachViewRendersInHostingView` also renders `Sidebar` and the tab strip with both arrows.

Then `~/.claude/scripts/remote-run swift test` and `~/.claude/scripts/remote-run swift test -c release --filter PerformanceTests`, with their output pasted.

### Order of work

Two parts, built one after the other because both edit `CommandTable.swift`, `ShellModels.swift`, `WindowModel.swift` and `WindowView.swift`:

1. Open in place with back and forward. Part 2's Pinned and Recent rows need its `open(_:newTab:)`.
2. The sidebar.

### Docs to update with the code

- `docs/DESIGN.md`: Deviations (links, rows and popups open in place, against spec 759, 831, 904 and 989; one sidebar of sections against spec 897 and 921) and the new state files.
- Root `DESIGN.md`: the sidebar sections and history arrows under Components, the width range and section gap under Layout. Then regenerate `.impeccable/design.json`.

## Where Plain departs from Anytype

- New tab is Option+click (Cmd+Option+click in the editor), not Cmd+click, because Plain already uses Cmd+click for selection and for links.
- No clock button: Anytype's Recently Opened list becomes the Recent section, because root `DESIGN.md` allows no new icons in the chrome.
- Files and Outline split the sidebar's height and scroll on their own; Anytype scrolls its whole sidebar.
- A tab with changes autosave could not write opens links in a new tab. Anytype saves every change at once, so it never meets this case.
- No Shared Pins, Unread, Types or Bin: Plain has one user, files have no types, and Finder holds the Trash.
- Section rows have one look, like Files rows; Anytype's Compact, Detailed, Same as Object and Hierarchical layouts are not copied.
- Plain's shortcuts stay: Cmd+. is Hide Interface (Anytype uses it to toggle the sidebar, Plain uses Cmd+\), and Cmd+T stays Go to File.

## Not in scope

Anytype's Vault (the column of spaces at the far left), pinned tabs, dragging a tab out into its own window, the graph, the pane of links to and from a page, the header's object path button, and Cmd+K search.
