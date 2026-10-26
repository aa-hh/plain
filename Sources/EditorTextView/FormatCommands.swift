import AppKit
import MarkdownDocument
import PlainCore

/// Format menu commands, copy and paste (spec 93, 135, 157–176), and the `editor:` command dispatcher.
extension EditorTextView {
    // MARK: Dispatcher

    /// Runs an `editor:` command from the command table. Returns false for an id the editor does not know.
    @discardableResult
    public func perform(commandID: String) -> Bool {
        switch commandID {
        case "editor:undo": undoManager?.undo()
        case "editor:redo": undoManager?.redo()
        case "editor:cut": cut(nil)
        case "editor:copy": copy(nil)
        case "editor:paste": paste(nil)
        case "editor:copy-as-rich-text": copyAsRichText()
        case "editor:copy-as-html": copyAsHTML()
        case "editor:paste-formatted": pasteFormatted()
        case "editor:select-all": selectAll(nil)
        case "editor:toggle-menu": if autocomplete != nil { moveAutocompleteSelection(by: 1) } else { askForSuggestions() }
        case "editor:bold": if !pendInline(.strong, marker: "**") { toggleInline(.strong, marker: "**") }
        case "editor:italic": if !pendInline(.emphasis, marker: "_") { toggleInline(.emphasis, marker: "_") }
        case "editor:strikethrough": toggleInline(.strike, marker: "~~")
        case "editor:mark": toggleInline(.highlight, marker: "::")
        case "editor:code": toggleInline(.code, marker: "`")
        case "editor:math": toggleInline(.math, marker: "$$")
        case "editor:link":
            if isPage, let offset = allSelections.first?.location, !inlines(at: offset).contains(where: { Self.isLinkKind($0.kind) }) {
                openLinkEditor()
            } else {
                toggleLink(image: false)
            }
        case "editor:image": toggleLink(image: true)
        case "editor:list": toggleList(.bullet)
        case "editor:ordered-list": toggleList(.ordered)
        case "editor:task-list": toggleList(.task)
        case "editor:quote": toggleList(.quote)
        case "editor:comment": toggleComment()
        case "editor:code-block": toggleFencedBlock(fence: "```")
        case "editor:math-block": toggleFencedBlock(fence: "$$$")
        case "editor:table-of-contents": perform(NSRange(location: 0, length: 0), "[[toc]]\n\n", caret: 7)
        case "editor:thematic-break": insertAfterBlock("---")
        case "editor:page-break": insertAfterBlock("+++")
        case "editor:clear-syntax": clearSyntax()
        default:
            if commandID.hasPrefix("editor:heading"), let level = Int(commandID.dropFirst("editor:heading".count)) {
                toggleHeading(level)
            } else {
                return performOtherCommand(commandID)
            }
        }
        return true
    }

    /// On the page, Bold or Italic at one empty caret outside that kind waits for the next character typed there.
    private func pendInline(_ kind: InlineKind, marker: String) -> Bool {
        guard isPage, let offset = caret, !inlines(at: offset).contains(where: { $0.kind == kind }) else { return false }
        pendingInline = (kind, marker, offset)
        return true
    }

    static func isLinkKind(_ kind: InlineKind) -> Bool {
        switch kind {
        case .link, .referenceLink, .autolink: return true
        default: return false
        }
    }

    private func performOtherCommand(_ id: String) -> Bool {
        performSelectionCommand(id) || performLineCommand(id) || performFindCommand(id) || performSpellingCommand(id)
    }

    // MARK: Words

    /// The word around `offset` (letters, digits, `_`, `'`), or an empty range at `offset`.
    func wordRange(at offset: Int) -> NSRange {
        func isWord(_ c: unichar) -> Bool {
            guard let scalar = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || c == 95 || c == 39
        }
        var start = offset, end = offset
        while start > 0, let c = character(at: start - 1), isWord(c) { start -= 1 }
        while let c = character(at: end), isWord(c) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Inline toggles (spec 160)

    func toggleInline(_ kind: InlineKind, marker: String) {
        var edits: [(range: NSRange, text: String)] = []
        var selections: [NSRange] = []
        let markerLength = (marker as NSString).length
        // Edits made earlier in the text move later selections; track the running shift.
        var shift = 0
        for value in allSelections.sorted(by: { $0.location < $1.location }) {
            let range = value
            if let inline = inlines(at: range.location).last(where: { $0.kind == kind && NSMaxRange(range) <= NSMaxRange($0.range) }) {
                let markers = inline.markerRanges.sorted { $0.location < $1.location }
                for m in markers { edits.append((m, "")) }
                let before = markers.filter { NSMaxRange($0) <= range.location }.reduce(0) { $0 + $1.length }
                selections.append(NSRange(location: range.location - before + shift, length: range.length))
                shift -= markers.reduce(0) { $0 + $1.length }
                continue
            }
            let target = range.length > 0 ? range : wordRange(at: range.location)
            edits.append((target, marker + nsText.substring(with: target) + marker))
            selections.append(range.length > 0
                ? NSRange(location: target.location + markerLength + shift, length: target.length)
                : NSRange(location: range.location + markerLength + shift, length: 0))
            shift += 2 * markerLength
        }
        perform(edits, select: selections)
    }

    // MARK: Links and images (spec 161–162)

    static let imageExtensions = ["png", "gif", "jpg", "jpeg", "bmp"]

    static func isURL(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace), let url = URL(string: string), let scheme = url.scheme else { return false }
        return ["http", "https", "mailto", "ftp", "file"].contains(scheme.lowercased())
    }

    func toggleLink(image: Bool) {
        guard let range = singleSelection else { return }
        if let inline = inlines(at: range.location).last(where: {
            switch $0.kind {
            case .link, .image, .referenceLink, .referenceImage, .autolink: return true
            default: return false
            }
        }) {
            let content = nsText.substring(with: inline.contentRange)
            perform(inline.range, content, caret: inline.range.location + (content as NSString).length)
            return
        }
        let target = range.length > 0 ? range : wordRange(at: range.location)
        let selected = nsText.substring(with: target)
        var text = selected
        var url = ""
        if Self.isURL(selected) {
            url = selected
            text = ""
        } else if let clip = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), Self.isURL(clip) {
            url = clip
        }
        let isImage = image || Self.imageExtensions.contains((url as NSString).pathExtension.lowercased())
        let opener = isImage ? "![" : "["
        let result = opener + text + "](" + url + ")"
        let base = target.location + (opener as NSString).length
        let caret: Int
        if text.isEmpty {
            caret = base
        } else if url.isEmpty {
            caret = base + (text as NSString).length + 2
        } else {
            caret = target.location + (result as NSString).length
        }
        perform(target, result, caret: caret)
    }

    // MARK: Headings (spec 93)

    func toggleHeading(_ level: Int) {
        guard let range = singleSelection else { return }
        let lines = linesTouched(by: range)
        let marker = String(repeating: "#", count: level) + " "
        let all = lines.allSatisfy { line in
            guard let m = headingMarker(at: line.location) else { return false }
            return m.hashes == level
        }
        var edits: [(range: NSRange, text: String)] = []
        for line in lines {
            if let existing = blockMarkerRange(at: line) {
                edits.append((existing, all ? "" : marker))
            } else if !all {
                let indent = (String(nsText.substring(with: line).prefix { $0 == " " }) as NSString).length
                edits.append((NSRange(location: line.location + indent, length: 0), marker))
            }
        }
        let start = lines.first?.location ?? 0
        perform(edits, select: nil)
        let span = spanOfLines(from: start, count: lines.count)
        setSelectedRange(lines.count == 1 && range.length == 0 ? NSRange(location: NSMaxRange(span), length: 0) : span)
    }

    /// From the start of the line at `start` to the end of the `count`th line.
    func spanOfLines(from start: Int, count: Int) -> NSRange {
        var line = lineContents(at: start)
        for _ in 1..<max(count, 1) where NSMaxRange(line) < nsText.length { line = lineContents(at: NSMaxRange(line) + 1) }
        return NSRange(location: start, length: NSMaxRange(line) - start)
    }

    // MARK: Comment (spec 166)

    func toggleComment() {
        guard let range = singleSelection else { return }
        let lines = linesTouched(by: range)
        guard let first = lines.first, let last = lines.last else { return }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let text = nsText.substring(with: whole)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") {
            var inner = String(trimmed.dropFirst(4).dropLast(3))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            perform([(whole, inner)], select: [NSRange(location: whole.location, length: (inner as NSString).length)])
        } else {
            let wrapped = "<!-- " + text + " -->"
            perform([(whole, wrapped)], select: [NSRange(location: whole.location, length: (wrapped as NSString).length)])
        }
    }

    // MARK: Code and math blocks (spec 163)

    func toggleFencedBlock(fence: String) {
        guard let range = singleSelection else { return }
        let lines = linesTouched(by: range)
        guard let first = lines.first, let last = lines.last else { return }
        var whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let fenced = (snapshot?.blocks(where: {
            switch $0.kind {
            case .fencedCode, .mathBlock: return true
            default: return false
            }
        }) ?? []).filter { NSIntersectionRange($0.range, whole).length > 0 || NSLocationInRange(whole.location, $0.range) }
        if fenced.count == 1, let block = fenced.first, block.range.location <= whole.location, NSMaxRange(whole) <= NSMaxRange(block.range) {
            // Inside one fenced block: remove its fence lines.
            var edits: [(range: NSRange, text: String)] = []
            let open = nsText.lineRange(for: NSRange(location: block.range.location, length: 0))
            edits.append((open, ""))
            if block.markerRanges.count > 1, let close = block.markerRanges.last {
                let closeLine = lineContents(at: close.location)
                edits.append((NSRange(location: closeLine.location - 1, length: closeLine.length + 1), ""))
            }
            perform(edits, select: [NSRange(location: block.range.location, length: 0)])
            return
        }
        // Merge with overlapping fenced blocks: their fences go, one fence pair wraps everything.
        var edits: [(range: NSRange, text: String)] = []
        for block in fenced {
            whole = NSUnionRange(whole, block.range)
            let open = nsText.lineRange(for: NSRange(location: block.range.location, length: 0))
            edits.append((open, ""))
            if block.markerRanges.count > 1, let close = block.markerRanges.last {
                let closeLine = lineContents(at: close.location)
                edits.append((NSRange(location: closeLine.location - 1, length: closeLine.length + 1), ""))
            }
        }
        if edits.isEmpty {
            perform([(NSRange(location: whole.location, length: 0), fence + "\n"), (NSRange(location: NSMaxRange(whole), length: 0), "\n" + fence)],
                    select: [NSRange(location: whole.location + (fence as NSString).length, length: 0)])
            return
        }
        perform(edits, select: nil)
        let start = whole.location
        let end = min(NSMaxRange(whole) - edits.reduce(0) { $0 + $1.range.length }, nsText.length)
        let body = NSRange(location: start, length: max(end - start, 0))
        let inner = nsText.substring(with: body)
        perform([(body, fence + "\n" + inner + "\n" + fence)], select: [NSRange(location: start + (fence as NSString).length, length: 0)])
    }

    // MARK: Breaks (spec 165)

    func insertAfterBlock(_ marker: String) {
        guard let offset = allSelections.first?.location else { return }
        let end = snapshot?.block(at: offset).map { NSMaxRange($0.range) } ?? NSMaxRange(lineContents(at: offset))
        let insertion = "\n\n" + marker
        perform(NSRange(location: end, length: 0), insertion, caret: end + (insertion as NSString).length)
    }

    // MARK: Clear syntax (spec 167)

    func clearSyntax() {
        var markers: [NSRange] = []
        func collect(_ inline: Inline) {
            markers.append(contentsOf: inline.markerRanges)
            inline.children.forEach(collect)
        }
        for range in allSelections {
            if range.length == 0 {
                if let outer = inlines(at: range.location).first(where: { !$0.markerRanges.isEmpty }) { collect(outer) }
            } else if let snapshot {
                for block in snapshot.blocks(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    for inline in block.inlines where NSIntersectionRange(inline.range, range).length > 0 { collect(inline) }
                }
            }
        }
        let unique = Array(Set(markers.map { NSValue(range: $0) })).map(\.rangeValue).filter { $0.length > 0 }
        guard !unique.isEmpty else { return }
        let first = allSelections.first?.location ?? 0
        let before = unique.filter { NSMaxRange($0) <= first }.reduce(0) { $0 + $1.length }
        perform(unique.map { ($0, "") }, select: [NSRange(location: first - before, length: 0)])
    }

    // MARK: Copy and cut (spec 169, 172)

    /// With no selection, Cut and Copy act on the whole line and its line break.
    private func wholeLineIfEmpty() -> Bool {
        guard let offset = caret else { return false }
        let line = nsText.lineRange(for: NSRange(location: offset, length: 0))
        setSelectedRange(line)
        return true
    }

    /// Plain's own pasteboard type for page copies: the selection's Markdown, balanced.
    static let markdownPasteboardType = NSPasteboard.PasteboardType("com.alechenderson.Plain.markdown")

    /// The ranges page Copy and Cut act on: the non-empty selections, or the caret's whole line.
    private var pageCopyRanges: [NSRange] {
        let ranges = allSelections.filter { $0.length > 0 }
        if ranges.isEmpty, let offset = caret { return [nsText.lineRange(for: NSRange(location: offset, length: 0))] }
        return ranges
    }

    /// Writes the visible text as plain text and the balanced Markdown under Plain's own type. False without a snapshot.
    private func pageCopy(_ ranges: [NSRange]) -> Bool {
        guard isPage, let snapshot, !ranges.isEmpty else { return false }
        let plain = ranges.map { VisibleText.plain(text: nsText, snapshot: snapshot, range: $0, columnWidth: styler.pageColumnWidth) }
        let markdown = ranges.map { balancedMarkdown($0, snapshot: snapshot) }
        let board = pasteboard
        board.clearContents()
        board.setString(plain.joined(separator: "\n"), forType: .string)
        board.setString(markdown.joined(separator: "\n"), forType: Self.markdownPasteboardType)
        return true
    }

    /// The Markdown of `range` with the markers added that emphasis, strong, strike, highlight and code inlines only
    /// partly inside it are missing; a partly selected link gives its text without link syntax.
    func balancedMarkdown(_ range: NSRange, snapshot: Snapshot) -> String {
        var prefix = "", suffix = "", dropped: [NSRange] = []
        func visit(_ inlines: [Inline]) {
            for inline in inlines where NSIntersectionRange(inline.range, range).length > 0 {
                let inside = inline.range.location >= range.location && NSMaxRange(inline.range) <= NSMaxRange(range)
                if !inside {
                    switch inline.kind {
                    case .emphasis, .strong, .strike, .highlight, .code:
                        if inline.markerRanges.count == 2 {
                            let open = inline.markerRanges[0], close = inline.markerRanges[1]
                            if open.location < range.location { prefix += nsText.substring(with: open) }
                            if NSMaxRange(close) > NSMaxRange(range) { suffix = nsText.substring(with: close) + suffix }
                        }
                    case .link, .referenceLink, .autolink:
                        dropped += inline.markerRanges
                    default:
                        break
                    }
                }
                visit(inline.children)
            }
        }
        for block in VisibleText.blocksMeeting(range, in: snapshot) { visit(block.inlines) }
        var body = ""
        var location = range.location
        for marker in dropped.sorted(by: { $0.location < $1.location }) {
            let part = NSIntersectionRange(marker, range)
            guard part.length > 0, part.location >= location else { continue }
            body += nsText.substring(with: NSRange(location: location, length: part.location - location))
            location = NSMaxRange(part)
        }
        body += nsText.substring(with: NSRange(location: location, length: NSMaxRange(range) - location))
        return prefix + body + suffix
    }

    public override func copy(_ sender: Any?) {
        if pageCopy(pageCopyRanges) { return }
        let restore = selectedRanges
        let wholeLine = wholeLineIfEmpty()
        _ = writeSelection(to: pasteboard, types: writablePasteboardTypes)
        if wholeLine { selectedRanges = restore }
    }

    public override func cut(_ sender: Any?) {
        let ranges = pageCopyRanges
        if pageCopy(ranges) {
            if ranges.count == 1 { pageReplace(ranges[0], with: "") } else { replaceAtAllSelections { $0.length > 0 ? ($0, "") : nil } }
            return
        }
        _ = wholeLineIfEmpty()
        if writeSelection(to: pasteboard, types: writablePasteboardTypes) { delete(sender) }
    }

    private var copySource: String {
        let ranges = allSelections.filter { $0.length > 0 }
        return ranges.isEmpty ? nsText as String : ranges.map { nsText.substring(with: $0) }.joined(separator: "\n")
    }

    func copyAsRichText() {
        let markdown = copySource
        let render = actions.htmlRenderer
        let board = pasteboard
        Task {
            let html = await render(markdown)
            board.clearContents()
            board.setString(html, forType: .html)
            board.setString(markdown, forType: .string)
        }
    }

    func copyAsHTML() {
        let markdown = copySource
        let render = actions.htmlRenderer
        let board = pasteboard
        Task {
            let html = await render(markdown)
            board.clearContents()
            board.setString(html, forType: .string)
        }
    }

    // MARK: Paste (spec 133, 168, 170, 171, 274)

    public override func paste(_ sender: Any?) {
        let board = pasteboard
        if let markdown = board.string(forType: Self.markdownPasteboardType) { return paste(text: markdown) }
        if board.string(forType: .string) == nil, pasteImage(from: board) { return }
        guard let string = board.string(forType: .string) else { readSelection(from: board); return }
        paste(text: string)
    }

    /// Pastes plain text with the editor's rules applied.
    func paste(text string: String) {
        let ranges = allSelections
        // One line per caret when the line count equals the caret count (spec 274).
        let lines = string.components(separatedBy: "\n")
        if ranges.count > 1, lines.count == ranges.count {
            var edits: [(range: NSRange, text: String)] = []
            var carets: [NSRange] = []
            var shift = 0
            for (range, line) in zip(ranges.sorted { $0.location < $1.location }, lines) {
                edits.append((range, line))
                carets.append(NSRange(location: range.location + shift + (line as NSString).length, length: 0))
                shift += (line as NSString).length - range.length
            }
            perform(edits, select: carets)
            return
        }
        guard let range = singleSelection else { return replaceAtAllSelections { ($0, string) } }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if range.length > 0 && isMarkdownFile {
            let selected = nsText.substring(with: range)
            let inLink = inlines(at: range.location).contains {
                if case .link = $0.kind { return true }
                return false
            }
            if Self.isURL(trimmed), !Self.isURL(selected), !inLink, !selected.contains("\n") {
                let result = "[" + selected + "](" + trimmed + ")"
                perform(range, result, caret: range.location + (result as NSString).length)
                return
            }
            if Self.isURL(selected), !Self.isURL(trimmed), !trimmed.contains("\n") {
                let result = "[" + trimmed + "](" + selected + ")"
                perform(range, result, caret: range.location + 1 + (trimmed as NSString).length)
                return
            }
        }
        var text = string
        // Drop a duplicate list or block prefix when the caret sits in or right after the line's pattern (spec 133).
        if range.length == 0, isMarkdownFile, let pattern = pattern(ofLineAt: range.location), !pattern.marker.isEmpty {
            let line = lineContents(at: range.location)
            let prefixEnd = line.location + (pattern.text as NSString).length
            let marker = pattern.text.trimmingCharacters(in: .whitespaces)
            if range.location <= prefixEnd, text.trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                let leading = text.prefix { $0 == " " }
                text = String(text.dropFirst(leading.count + marker.count)).replacingOccurrences(of: #"^ +"#, with: "", options: .regularExpression)
                let replace = NSRange(location: range.location, length: max(prefixEnd - range.location, 0))
                perform(replace, (pattern.text as NSString).substring(from: range.location - line.location) + text,
                        caret: prefixEnd + (text as NSString).length)
                listRenumberAround(range.location)
                return
            }
        }
        perform(range, text, caret: range.location + (text as NSString).length)
        listRenumberAround(range.location)
    }

    func pasteFormatted() {
        let board = pasteboard
        if let html = board.string(forType: .html) {
            paste(text: actions.htmlToMarkdown(html))
        } else {
            paste(nil)
        }
    }

    /// Saves a pasted image as `<timestamp>.png` in the `.pastes` folder, reusing an identical file, and links it.
    func pasteImage(from board: NSPasteboard) -> Bool {
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let folder = actions.pasteFolder() else { return false }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var target: URL?
        for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "png" {
            if (try? Data(contentsOf: file)) == png { target = file; break }
        }
        if target == nil {
            let name = "\(Int(Date().timeIntervalSince1970 * 1000)).png"
            let url = folder.appendingPathComponent(name)
            guard (try? png.write(to: url)) != nil else { return false }
            target = url
        }
        guard let target else { return false }
        let path = relativePath(to: target)
        insertAtSelection("![](" + path + ")")
        return true
    }

    /// A path from the document's folder to `url`, percent-encoded for a Markdown link.
    func relativePath(to url: URL) -> String {
        let path: String
        if let base = document.url?.deletingLastPathComponent().standardizedFileURL.pathComponents {
            let target = url.standardizedFileURL.pathComponents
            var common = 0
            while common < base.count, common < target.count, base[common] == target[common] { common += 1 }
            path = (Array(repeating: "..", count: base.count - common) + target[common...]).joined(separator: "/")
        } else {
            path = url.path
        }
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    func insertAtSelection(_ text: String) {
        let range = allSelections.first ?? NSRange(location: nsText.length, length: 0)
        perform(range, text, caret: range.location + (text as NSString).length)
    }
}
