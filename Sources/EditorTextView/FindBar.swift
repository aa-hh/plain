import AppKit
import MarkdownDocument
import PlainCore

/// What Find remembers while it is open.
struct FindState {
    var query = ""
    var matches: [NSRange] = []
    var current: Int?
    /// Scroll position and selection when Find opened, restored by Esc when nothing matched (spec 306).
    var savedOrigin: NSPoint
    var savedSelections: [NSRange]
    /// On the page: the visible text Find searches and each unit's source offset, built once per snapshot and
    /// column width rather than once per query.
    var visible: (version: TextVersion, columnWidth: CGFloat, string: NSString, offsets: [Int])?
}

/// Find in file (spec 298–313). No Replace.
extension EditorTextView {
    public func openFind() {
        let selection = allSelections.first ?? NSRange(location: 0, length: 0)
        let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        find = FindState(savedOrigin: origin, savedSelections: allSelections)
        findBarVisible = true
        let bar = findBar ?? FindBar(editor: self)
        findBar = bar
        bar.show()
        let selected = selection.length > 0 ? nsText.substring(with: selection) : ""
        if !selected.isEmpty, !selected.contains("\n") {
            bar.field.stringValue = selected
            findQueryChanged(selected, fromSelection: true)
        } else {
            bar.field.stringValue = ""
            findQueryChanged("")
        }
    }

    public func closeFind() {
        guard let state = find else { return }
        if state.matches.isEmpty, !state.query.isEmpty {
            setAllSelections(state.savedSelections)
            if let clip = enclosingScrollView?.contentView {
                clip.scroll(to: state.savedOrigin)
                enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        find = nil
        clearFindHighlights()
        findBar?.hide()
        findBarVisible = false
        window?.makeFirstResponder(self)
    }

    /// Case-insensitive matches; the first pass keeps those that start a space-separated chunk, the second all of them
    /// (spec 303).
    static func findMatches(_ query: String, in text: NSString) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var all: [NSRange] = []
        var location = 0
        while location < text.length {
            let range = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound else { break }
            all.append(range)
            location = range.location + max(range.length, 1)
        }
        let starts = all.filter {
            guard $0.location > 0 else { return true }
            let previous = text.character(at: $0.location - 1)
            return previous == 32 || previous == 10 || previous == 9
        }
        return starts.isEmpty ? all : starts
    }

    func findQueryChanged(_ query: String, fromSelection: Bool = false) {
        guard var state = find else { return }
        state.query = query
        if isPage, snapshot == nil {
            // A parse is pending: keep the previous matches; `received` finds the new query once the snapshot arrives.
            find = state
            return
        }
        state.matches = pageFindMatches(query, state: &state) ?? Self.findMatches(query, in: nsText)
        state.current = nil
        if !state.matches.isEmpty {
            if fromSelection, let selection = allSelections.first {
                state.current = state.matches.firstIndex { $0.location >= NSMaxRange(selection) } ?? 0
            } else {
                // The first match below the top of the visible area.
                let top = visibleCharacterRange().location
                state.current = state.matches.firstIndex { $0.location >= top } ?? 0
            }
        }
        find = state
        showFindResults()
    }

    /// Enter / F3 / Cmd+G: next match; with Shift, the previous one; both wrap (spec 304).
    public func findNext(backwards: Bool) {
        guard var state = find, !state.matches.isEmpty else { return }
        let count = state.matches.count
        if let current = state.current {
            state.current = (current + (backwards ? -1 : 1) + count) % count
        } else {
            state.current = 0
        }
        find = state
        showFindResults()
    }

    /// Re-finds after the text changed, keeping the current match near where it was (spec 307).
    /// On the page, matches in the visible text mapped back to the Markdown, so "bold text" finds `**bold** text`.
    /// Nil in the source view or while a parse is pending.
    private func pageFindMatches(_ query: String, state: inout FindState) -> [NSRange]? {
        guard isPage, let snapshot else { return nil }
        let width = styler.pageColumnWidth
        if state.visible?.version != snapshot.version || state.visible?.columnWidth != width {
            let whole = NSRange(location: 0, length: nsText.length)
            let map = VisibleText.map(text: nsText, snapshot: snapshot, range: whole, columnWidth: width)
            // Only characters shown on the page are searched: the stand-ins Copy writes for hidden Markdown (bullets,
            // boxes, footnote numbers, tabs, separator breaks) each map to an offset inside a hidden range, where no
            // shown character is, so they are dropped.
            let hidden = HiddenRanges.list(in: whole, snapshot: snapshot, text: nsText, columnWidth: width, caret: nil)
            let mapped = Array(map.string.utf16)
            var units: [unichar] = []
            var offsets: [Int] = []
            units.reserveCapacity(mapped.count)
            offsets.reserveCapacity(map.offsets.count)
            var next = 0
            for (unit, offset) in zip(mapped, map.offsets) {
                while next < hidden.count, NSMaxRange(hidden[next].range) <= offset { next += 1 }
                if next < hidden.count, NSLocationInRange(offset, hidden[next].range) { continue }
                units.append(unit)
                offsets.append(offset)
            }
            offsets.append(map.offsets.last ?? whole.length)
            state.visible = (snapshot.version, width, NSString(characters: units, length: units.count), offsets)
        }
        guard let visible = state.visible else { return nil }
        return Self.findMatches(query, in: visible.string).map { match in
            let start = visible.offsets[match.location]
            let end = match.length > 0 ? visible.offsets[NSMaxRange(match) - 1] + 1 : start
            return NSRange(location: start, length: end - start)
        }
    }

    func findTextChanged() {
        guard var state = find else { return }
        if isPage, snapshot == nil { return }
        let previous = state.current.map { state.matches[$0].location }
        state.matches = pageFindMatches(state.query, state: &state) ?? Self.findMatches(state.query, in: nsText)
        state.current = state.matches.isEmpty ? nil : (previous.flatMap { p in state.matches.firstIndex { $0.location >= p } } ?? 0)
        find = state
        highlightMatches()
    }

    private func showFindResults() {
        guard let state = find else { return }
        highlightMatches()
        findBar?.showsError = !state.query.isEmpty && state.matches.isEmpty
        if let current = state.current {
            let match = state.matches[current]
            settingSelections = true
            setSelectedRange(match)
            settingSelections = false
            extraSelections = []
            scrollRangeToVisible(match)
        }
    }

    /// Other matches in `--selection-yellow`, the current one in `--selection-orange`, their text in `--color-em`.
    private func highlightMatches() {
        clearFindHighlights()
        guard let state = find, let layoutManager = textLayoutManager else { return }
        for (index, match) in state.matches.enumerated() {
            guard let range = textRange(for: match) else { continue }
            layoutManager.addRenderingAttribute(.backgroundColor, value: index == state.current ? Tokens.selectionOrange : Tokens.selectionYellow, for: range)
            layoutManager.addRenderingAttribute(.foregroundColor, value: Tokens.colorEm, for: range)
        }
    }

    private func clearFindHighlights() {
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        layoutManager.removeRenderingAttribute(.foregroundColor, for: layoutManager.documentRange)
    }

    func textRange(for range: NSRange) -> NSTextRange? {
        guard let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func performFindCommand(_ id: String) -> Bool {
        guard id == "editor:find" else { return false }
        openFind()
        return true
    }

    /// Cmd+G / Cmd+Shift+G from the editor; F3 / Shift+F3 too.
    func handleFindKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isF3 = event.keyCode == 99
        guard (key == "g" && (flags == .command || flags == [.command, .shift])) || (isF3 && (flags.isEmpty || flags == .shift)) else { return false }
        guard find != nil else { return false }
        findNext(backwards: flags.contains(.shift))
        return true
    }
}

/// The find box: 210 × 48, 30 pt from the right and bottom edges, inverse colours, radius 6 (spec 1586–1591).
@MainActor
final class FindBar: NSView, NSTextFieldDelegate {
    weak var editor: EditorTextView?
    let field = NSTextField()
    var showsError = false { didSet { needsDisplay = true } }

    init(editor: EditorTextView) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 210, height: 48))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Tokens.uiFont
        field.textColor = Tokens.material
        field.delegate = self
        field.frame = NSRect(x: 15, y: 12, width: 180, height: 24)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        addSubview(field)
        autoresizingMask = [.minXMargin, .maxYMargin]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        (showsError ? Tokens.highlightError : Tokens.color).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.cornerRadius, yRadius: Tokens.cornerRadius).fill()
    }

    func show() {
        guard let editor, let host = editor.enclosingScrollView?.superview ?? editor.enclosingScrollView else { return }
        if superview !== host { host.addSubview(self, positioned: .above, relativeTo: nil) }
        let bottom: CGFloat = host.isFlipped ? host.bounds.height - 30 - 48 : 30
        frame = NSRect(x: host.bounds.width - 30 - 210, y: bottom, width: 210, height: 48)
        autoresizingMask = host.isFlipped ? [.minXMargin, .minYMargin] : [.minXMargin, .maxYMargin]
        isHidden = false
        window?.makeFirstResponder(field)
    }

    func hide() {
        removeFromSuperview()
    }

    func controlTextDidChange(_ notification: Notification) {
        editor?.findQueryChanged(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            editor?.findNext(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.cancelOperation(_:)):
            editor?.closeFind()
        default:
            return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor, window?.firstResponder === field.currentEditor(), editor.handleFindKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
