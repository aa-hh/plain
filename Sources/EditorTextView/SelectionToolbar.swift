import AppKit
import MarkdownDocument
import PlainCore
import PlainShell
import SwiftUI

extension PageBlockKind {
    /// Whether Turn into applies to a block of this kind: only blocks that hold text (paragraphs, headings 1 to 6,
    /// list items, tasks and quotes; spec section 3). The toolbar picker and the block menu both use it.
    var canTurnInto: Bool {
        switch self {
        case .text, .heading, .bulleted, .numbered, .task, .quote: return true
        case .code, .table, .divider, .image, .maths: return false
        }
    }
}

/// A style button on the selection toolbar: the inline kind it shows as active and the marker it wraps text in.
enum ToolbarStyle: CaseIterable, Hashable {
    case bold, italic, strike, code, link, highlight

    var icon: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strike: return "strikethrough"
        case .code: return "code"
        case .link: return "link"
        case .highlight: return "highlighter"
        }
    }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strike: return "Strikethrough"
        case .code: return "Code"
        case .link: return "Link"
        case .highlight: return "Highlight"
        }
    }

    /// The marker the Format menu wraps with (`FormatCommands.swift`); the link button opens the link editor instead.
    var marker: String {
        switch self {
        case .bold: return "**"
        case .italic: return "_"
        case .strike: return "~~"
        case .code: return "`"
        case .link: return ""
        case .highlight: return "::"
        }
    }

    func matches(_ kind: InlineKind) -> Bool {
        switch (self, kind) {
        case (.bold, .strong), (.italic, .emphasis), (.strike, .strike), (.code, .code), (.highlight, .highlight),
             (.link, .link), (.link, .referenceLink), (.link, .autolink):
            return true
        default:
            return false
        }
    }
}

/// What the toolbar and the link editor show.
@MainActor @Observable
final class SelectionToolbarModel {
    var title = PageBlockKind.text.title
    var active: Set<ToolbarStyle> = []
    /// The link editor lists folder files instead of taking a typed link.
    var fileMode = false
    var files: [URL] = []
    var highlighted = 0
}

/// The selection toolbar, the "Turn into" picker it opens and the link editor.
@MainActor
final class SelectionToolbarController: NSObject, NSTextFieldDelegate {
    weak var editor: EditorTextView?
    /// The selection the open tools act on.
    var shown: NSRange?
    var toolbar: NSView?
    var picker: NSView?
    var linkEditor: NSView?
    let model = SelectionToolbarModel()
    let linkField = NSTextField()
    /// True while a toolbar edit sets the selection, so the toolbar stays open for the edited text.
    var applying = false
    var observingSnapshots = false

    override init() {
        super.init()
        let page = Tokens.page
        linkField.isBordered = false
        linkField.isBezeled = false
        linkField.drawsBackground = false
        linkField.focusRingType = .none
        linkField.font = .systemFont(ofSize: page.menuLabel)
        linkField.textColor = page.text
        linkField.placeholderAttributedString = NSAttributedString(string: "Paste or type a link", attributes: [
            .font: NSFont.systemFont(ofSize: page.menuLabel), .foregroundColor: page.textTertiary,
        ])
        linkField.cell?.usesSingleLineMode = true
        linkField.cell?.isScrollable = true
        linkField.setAccessibilityLabel("Link")
        linkField.delegate = self
    }

    func controlTextDidChange(_ notification: Notification) {
        editor?.linkEditorQueryChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let editor else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            editor.linkEditorCommit()
        case #selector(NSResponder.cancelOperation(_:)):
            editor.linkEditorCancelled()
        case #selector(NSResponder.moveDown(_:)) where model.fileMode:
            model.highlighted = min(model.highlighted + 1, max(model.files.count - 1, 0))
        case #selector(NSResponder.moveUp(_:)) where model.fileMode:
            model.highlighted = max(model.highlighted - 1, 0)
        default:
            return false
        }
        return true
    }
}

/// The toolbar card: the block kind picker, a divider and the six style buttons.
struct SelectionToolbarView: View {
    let model: SelectionToolbarModel
    let onPicker: () -> Void
    let onStyle: (ToolbarStyle) -> Void

    var body: some View {
        let page = Tokens.page
        PageMenuCard {
            HStack(spacing: 2) {
                Button(action: onPicker) {
                    HStack(spacing: 4) {
                        Text(model.title)
                            .font(.system(size: page.menuLabel))
                            .foregroundStyle(Color(nsColor: page.text))
                        LucideIcon(name: "chevron-down", size: page.menuSmall, colour: Color(nsColor: page.textSecondary))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: page.toolbarButton)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn into")
                Rectangle()
                    .fill(Color(nsColor: page.border))
                    .frame(width: 1, height: page.toolbarButton - 8)
                    .padding(.horizontal, 4)
                ForEach(ToolbarStyle.allCases, id: \.self) { style in
                    let on = model.active.contains(style)
                    Button { onStyle(style) } label: {
                        LucideIcon(name: style.icon, size: page.menuIcon, colour: Color(nsColor: on ? page.text : page.textSecondary))
                            .frame(width: page.toolbarButton, height: page.toolbarButton)
                            .background(on ? Color(nsColor: page.hover) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: page.chipRadius))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(style.title)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .frame(height: page.toolbarHeight)
        }
    }
}

/// The link editor card: the URL field, then "Link to file…" or the matching folder files.
struct LinkEditorView: View {
    let model: SelectionToolbarModel
    let field: NSTextField
    let onFileMode: () -> Void
    let onPick: (Int) -> Void

    /// The card height for `rows` rows under the field.
    static func height(rows: Int) -> CGFloat {
        let page = Tokens.page
        return page.menuRow + 1 + 8 + CGFloat(rows) * page.menuRow
    }

    var body: some View {
        let page = Tokens.page
        PageMenuCard {
            VStack(spacing: 0) {
                LinkFieldView(field: field)
                    .padding(.horizontal, 12)
                    .frame(height: page.menuRow)
                Rectangle()
                    .fill(Color(nsColor: page.border))
                    .frame(height: 1)
                VStack(spacing: 0) {
                    if model.fileMode {
                        ForEach(Array(model.files.enumerated()), id: \.offset) { index, url in
                            PageMenuRow(icon: "file-text", title: url.lastPathComponent, highlighted: index == model.highlighted)
                                .onTapGesture { onPick(index) }
                        }
                    } else {
                        PageMenuRow(icon: "file-search", title: "Link to file…")
                            .onTapGesture(perform: onFileMode)
                    }
                }
                .padding(4)
            }
            .frame(height: Self.height(rows: model.fileMode ? model.files.count : 1), alignment: .top)
        }
        .frame(width: page.linkEditorWidth)
    }
}

/// The controller's own text field inside the SwiftUI card, so the editor can focus it and read it.
private struct LinkFieldView: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ nsView: NSTextField, context: Context) {}
}

extension EditorTextView {
    // MARK: Toolbar

    /// After a mouse selection on the page, shows the toolbar 8 pt above the selection's first line (below it when
    /// there is no room above).
    func selectionToolbarAfterMouseUp() {
        let tools = selectionToolbar
        closeSelectionToolbar()
        let ranges = allSelections
        guard isPage, ranges.count == 1, ranges[0].length > 0 else { return }
        let range = ranges[0]
        tools.editor = self
        tools.shown = range
        if !tools.observingSnapshots {
            tools.observingSnapshots = true
            snapshotObservers.append { [weak self] _ in
                guard let self, self.selectionToolbar.toolbar != nil else { return }
                self.refreshSelectionToolbar()
            }
        }
        refreshSelectionToolbar()
        let view = SelectionToolbarView(model: tools.model,
                                        onPicker: { [weak self] in self?.toggleTurnIntoPicker() },
                                        onStyle: { [weak self] in self?.selectionToolbarClicked($0) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let line = selectionLineRect(range)
        let visible = visibleRect
        var y = line.minY - 8 - size.height
        if y < visible.minY { y = line.maxY + 8 }
        let x = min(max(line.minX, visible.minX), max(visible.maxX - size.width, visible.minX))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        addSubview(host)
        tools.toolbar = host
    }

    /// Closes the tools when the selection is no longer the one they were opened for, or there is more than one.
    func selectionToolbarSelectionMoved() {
        let tools = selectionToolbar
        guard !tools.applying, tools.shown != nil else { return }
        let ranges = allSelections
        if ranges.count != 1 || ranges[0] != tools.shown { closeSelectionToolbar() }
    }

    func closeSelectionToolbar() {
        let tools = selectionToolbar
        tools.toolbar?.removeFromSuperview()
        tools.picker?.removeFromSuperview()
        tools.linkEditor?.removeFromSuperview()
        tools.toolbar = nil
        tools.picker = nil
        tools.linkEditor = nil
        tools.shown = nil
        tools.model.fileMode = false
        tools.model.files = []
    }

    /// The selection's part on its first line, in view coordinates.
    private func selectionLineRect(_ range: NSRange) -> NSRect {
        let line = lineContents(at: range.location)
        let length = max(min(range.length, NSMaxRange(line) - range.location), 0)
        return rect(forCharacterRange: NSRange(location: range.location, length: length))
    }

    /// Reads the block kind and the active styles of the shown selection from the current snapshot.
    func refreshSelectionToolbar() {
        let tools = selectionToolbar
        guard let range = tools.shown, let snapshot, let hidden = pageHiddenRanges(around: range) else {
            tools.model.active = []
            return
        }
        tools.model.title = PageBlocks.block(at: range.location, snapshot: snapshot, text: nsText)?.kind.title ?? PageBlockKind.text.title
        tools.model.active = Set(ToolbarStyle.allCases.filter { styleActive($0, in: range, snapshot: snapshot, hidden: hidden) })
    }

    func selectionToolbarClicked(_ style: ToolbarStyle) {
        if style == .link {
            openLinkEditor()
            return
        }
        guard let range = selectionToolbar.shown else { return }
        toggleStyle(style, in: range)
    }

    // MARK: Styles

    /// True when every visible character in `range` other than spaces lies in an inline of `style`.
    func styleActive(_ style: ToolbarStyle, in range: NSRange) -> Bool {
        guard let snapshot, let hidden = pageHiddenRanges(around: range) else { return false }
        return styleActive(style, in: range, snapshot: snapshot, hidden: hidden)
    }

    private func styleActive(_ style: ToolbarStyle, in range: NSRange, snapshot: Snapshot, hidden: [HiddenRange]) -> Bool {
        let covered = styleInlines(style, meeting: range, snapshot: snapshot).map(\.range)
        var h = 0, c = 0, counted = false
        for offset in range.location..<NSMaxRange(range) {
            while h < hidden.count, NSMaxRange(hidden[h].range) <= offset { h += 1 }
            if h < hidden.count, hidden[h].range.location <= offset { continue }
            if isBlank(at: offset) { continue }
            while c < covered.count, NSMaxRange(covered[c]) <= offset { c += 1 }
            guard c < covered.count, covered[c].location <= offset else { return false }
            counted = true
        }
        return counted
    }

    /// The inlines of `style`, nested ones included, that meet `range`, by location.
    private func styleInlines(_ style: ToolbarStyle, meeting range: NSRange, snapshot: Snapshot) -> [Inline] {
        var result: [Inline] = []
        var seen = Set<Inline>()
        func visit(_ inlines: [Inline]) {
            for inline in inlines where inline.range.location <= NSMaxRange(range) && NSMaxRange(inline.range) >= range.location {
                if style.matches(inline.kind), seen.insert(inline).inserted { result.append(inline) }
                visit(inline.children)
            }
        }
        for block in VisibleText.blocksMeeting(range, in: snapshot) { visit(block.inlines) }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private func isBlank(at offset: Int) -> Bool {
        guard let c = character(at: offset) else { return false }
        return c == 32 || c == 9 || c == 10 || c == 13
    }

    /// One edit that turns `style` off over `range` when it is active, else on.
    ///
    /// Off: the markers of each inline of that kind go, and an inline reaching outside the selection keeps markers
    /// around its outside parts (`**ab[cd]ef**` → `**ab**cd**ef**`). On: the markers of that kind's inlines inside the
    /// selection go, and the selection, without spaces at its edges and stretched over any inline of that kind it
    /// starts or ends in, is wrapped.
    func toggleStyle(_ style: ToolbarStyle, in range: NSRange) {
        guard let snapshot, style != .link else { return }
        let text = nsText
        var edits: [(range: NSRange, text: String)] = []
        let selection: NSRange
        if styleActive(style, in: range) {
            for inline in styleInlines(style, meeting: range, snapshot: snapshot) where inline.markerRanges.count >= 2 {
                let content = inline.contentRange
                guard NSIntersectionRange(content, range).length > 0 else { continue }
                let open = inline.markerRanges[0], close = inline.markerRanges[inline.markerRanges.count - 1]
                if content.location < range.location {
                    var at = range.location
                    while at > content.location, isBlank(at: at - 1) { at -= 1 }
                    edits.append((NSRange(location: at, length: 0), text.substring(with: close)))
                } else {
                    edits.append((open, ""))
                }
                if NSMaxRange(content) > NSMaxRange(range) {
                    var at = NSMaxRange(range)
                    while at < NSMaxRange(content), isBlank(at: at) { at += 1 }
                    edits.append((NSRange(location: at, length: 0), text.substring(with: open)))
                } else {
                    edits.append((close, ""))
                }
            }
            // An insertion at the selection's start lands before it; one at its end lands after it.
            let start = range.location + edits.filter { $0.range.location < range.location || ($0.range.location == range.location && $0.range.length == 0) }
                .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
            let endOffset = NSMaxRange(range)
            let end = endOffset + edits.filter { $0.range.location < endOffset && ($0.range.length == 0 || NSMaxRange($0.range) <= endOffset) }
                .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
            selection = NSRange(location: start, length: max(end - start, 0))
        } else {
            var start = range.location, end = NSMaxRange(range)
            while start < end, isBlank(at: start) { start += 1 }
            while end > start, isBlank(at: end - 1) { end -= 1 }
            guard start < end else { return }
            let found = styleInlines(style, meeting: NSRange(location: start, length: end - start), snapshot: snapshot)
            for inline in found {
                if inline.range.location < start, start < NSMaxRange(inline.range) { start = inline.range.location }
                if inline.range.location < end, end < NSMaxRange(inline.range) { end = NSMaxRange(inline.range) }
            }
            let marker = style.marker
            var deleted = 0, replacedStart = false
            for inline in found where inline.range.location >= start && NSMaxRange(inline.range) <= end {
                for m in inline.markerRanges where m.length > 0 {
                    deleted += m.length
                    // A marker at the start becomes the new opening marker, so the two edits never touch.
                    if m.location == start {
                        edits.append((m, marker))
                        replacedStart = true
                    } else {
                        edits.append((m, ""))
                    }
                }
            }
            if !replacedStart { edits.append((NSRange(location: start, length: 0), marker)) }
            edits.append((NSRange(location: end, length: 0), marker))
            selection = NSRange(location: start + (marker as NSString).length, length: end - start - deleted)
        }
        guard !edits.isEmpty else { return }
        let tools = selectionToolbar
        tools.applying = true
        perform(edits, select: [selection])
        tools.applying = false
        if tools.shown != nil { tools.shown = allSelections.first }
    }

    // MARK: Turn into

    private func toggleTurnIntoPicker() {
        let tools = selectionToolbar
        if let picker = tools.picker {
            picker.removeFromSuperview()
            tools.picker = nil
            return
        }
        guard let range = tools.shown, let toolbar = tools.toolbar, let snapshot else { return }
        let current = PageBlocks.block(at: range.location, snapshot: snapshot, text: nsText)?.kind
        let page = Tokens.page
        let height = CGFloat(PageBlockKind.turnIntoKinds.count) * page.menuRow + 8
        let list = TurnIntoList(current: current) { [weak self] kind in self?.selectionToolbarTurnInto(kind) }
        tools.picker = showPageTool(list, size: NSSize(width: page.menuWidth, height: height), below: toolbar.frame, above: toolbar.frame)
    }

    /// Turns every text-holding block the shown selection touches into `kind`, as one undo step; tables, dividers,
    /// pictures, maths and code blocks stay as they are.
    func selectionToolbarTurnInto(_ kind: PageBlockKind) {
        guard let range = selectionToolbar.shown else { return }
        let text = nsText
        let touched = pageBlocks().filter { block in
            block.range.location < NSMaxRange(range) && NSMaxRange(block.range) >= range.location && block.kind.canTurnInto
        }
        closeSelectionToolbar()
        guard let first = touched.first else { return }
        let edits = touched.flatMap { PageBlocks.turnInto($0, to: kind, text: text).edits }
        apply(edits, caret: PageBlocks.turnInto(first, to: kind, text: text).caret)
    }

    // MARK: Link editor

    /// The link the selection lies in.
    private func link(around range: NSRange) -> Inline? {
        inlines(at: range.location).last {
            ToolbarStyle.link.matches($0.kind) && NSMaxRange(range) <= NSMaxRange($0.range) && (range.length == 0 || range.location < NSMaxRange($0.range))
        }
    }

    /// Opens the link editor under the selection's first line, its field holding the link's target when the selection
    /// is in a link, and focuses the field.
    func openLinkEditor() {
        let tools = selectionToolbar
        guard isPage, let range = singleSelection else { return }
        closeSelectionToolbar()
        tools.editor = self
        tools.shown = range
        var destination = ""
        if let link = link(around: range) {
            switch link.kind {
            case .link(let target), .autolink(let target): destination = target
            default: break
            }
        }
        tools.linkField.stringValue = destination
        let view = LinkEditorView(model: tools.model, field: tools.linkField,
                                  onFileMode: { [weak self] in self?.linkEditorFileMode() },
                                  onPick: { [weak self] index in
                                      self?.selectionToolbar.model.highlighted = index
                                      self?.linkEditorCommit()
                                  })
        let line = selectionLineRect(range)
        let host = showPageTool(view, size: NSSize(width: Tokens.page.linkEditorWidth, height: LinkEditorView.height(rows: 1)), below: line, above: line)
        host.layoutSubtreeIfNeeded()
        tools.linkEditor = host
        window?.makeFirstResponder(tools.linkField)
    }

    /// "Link to file…": the field filters the window folder's files by name.
    func linkEditorFileMode() {
        let tools = selectionToolbar
        tools.model.fileMode = true
        tools.linkField.stringValue = ""
        linkEditorQueryChanged()
        window?.makeFirstResponder(tools.linkField)
    }

    func linkEditorQueryChanged() {
        let tools = selectionToolbar
        guard tools.model.fileMode else { return }
        let matches = PlainCore.filter(items: actions.folderFiles(), query: tools.linkField.stringValue) { $0.lastPathComponent }
        tools.model.files = matches.prefix(8).map(\.item)
        tools.model.highlighted = 0
        guard let host = tools.linkEditor else { return }
        let height = LinkEditorView.height(rows: tools.model.files.count)
        let visible = visibleRect
        var frame = host.frame
        frame.size.height = height
        frame.origin.y = max(min(frame.origin.y, visible.maxY - height), visible.minY)
        host.frame = frame
    }

    /// Return in the link editor: the typed link, or the highlighted file as a path from the document's folder.
    func linkEditorCommit() {
        let tools = selectionToolbar
        if tools.model.fileMode {
            guard tools.model.files.indices.contains(tools.model.highlighted) else { return }
            commitLink(relativePath(to: tools.model.files[tools.model.highlighted]))
        } else {
            commitLink(tools.linkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// In a link: replaces its target, or with an empty `url` removes the link. Otherwise wraps the selection as
    /// `[selection](url)`, or at a caret inserts `[url](url)`.
    private func commitLink(_ url: String) {
        guard let range = selectionToolbar.shown else { return }
        window?.makeFirstResponder(self)
        closeSelectionToolbar()
        if let link = link(around: range) {
            if url.isEmpty {
                toggleLink(image: false)
            } else if case .link = link.kind, link.markerRanges.count == 2 {
                let close = link.markerRanges[1]
                let replacement = "](" + url + Self.linkTitle(inClosingMarker: nsText.substring(with: close)) + ")"
                perform(close, replacement, caret: close.location + (replacement as NSString).length)
            } else {
                let result = "[" + nsText.substring(with: link.contentRange) + "](" + url + ")"
                perform(link.range, result, caret: link.range.location + (result as NSString).length)
            }
            return
        }
        guard !url.isEmpty else { return }
        let label = range.length > 0 ? nsText.substring(with: range) : url
        let result = "[" + label + "](" + url + ")"
        perform(range, result, caret: range.location + (result as NSString).length)
    }

    /// The title of a link's closing marker `](destination "title")` with the space before it, or "" when it has none.
    static func linkTitle(inClosingMarker marker: String) -> String {
        guard marker.hasPrefix("]("), marker.hasSuffix(")") else { return "" }
        let inner = marker.dropFirst(2).dropLast().drop { $0 == " " || $0 == "\t" }
        let afterDestination: Substring
        if inner.hasPrefix("<"), let close = inner.firstIndex(of: ">") {
            afterDestination = inner[inner.index(after: close)...]
        } else {
            afterDestination = inner.drop { $0 != " " && $0 != "\t" && $0 != "\n" }
        }
        let title = afterDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "" : " " + title
    }

    /// Esc in the link editor: closes it and gives the editor its focus back.
    func linkEditorCancelled() {
        window?.makeFirstResponder(self)
        closeSelectionToolbar()
    }
}
