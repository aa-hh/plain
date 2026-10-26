import AppKit
import MarkdownDocument
import PlainCore

/// Typing helpers from spec 86–121: heading markers, auto-pairing, stepping over closers, wrapping, fence completion,
/// smart Enter, Tab and Home.
extension EditorTextView {
    // MARK: Text access

    var nsText: NSString { document.textStorage.string as NSString }

    func character(at offset: Int) -> unichar? {
        offset >= 0 && offset < nsText.length ? nsText.character(at: offset) : nil
    }

    /// The line holding `offset`, without its line break.
    func lineContents(at offset: Int) -> NSRange {
        var start = 0, contentsEnd = 0
        nsText.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(offset, nsText.length), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    func lineString(at offset: Int) -> String { nsText.substring(with: lineContents(at: offset)) }

    var caret: Int? {
        guard extraSelections.isEmpty else { return nil }
        let ranges = allSelections
        guard ranges.count == 1, ranges[0].length == 0 else { return nil }
        return ranges[0].location
    }

    var singleSelection: NSRange? {
        guard extraSelections.isEmpty else { return nil }
        let ranges = allSelections
        return ranges.count == 1 ? ranges[0] : nil
    }

    /// Inline kinds at `offset`, outermost first, from the current snapshot.
    func inlines(at offset: Int) -> [Inline] { snapshot?.inline(at: offset) ?? [] }

    func isInCodeOrMath(_ offset: Int) -> Bool {
        if inlines(at: offset).contains(where: { $0.kind == .code || $0.kind == .math }) { return true }
        switch snapshot?.deepestBlock(at: offset)?.kind {
        case .fencedCode?, .indentedCode?, .mathBlock?, .frontMatter?: return true
        default: return false
        }
    }

    var isMarkdownFile: Bool {
        guard let url = document.url else { return true }
        return OpenableFiles.isMarkdown(url)
    }

    // MARK: Editing primitive

    /// Applies replacements as one undo step and selects `selection` afterwards. Ranges are in the current text.
    func perform(_ edits: [(range: NSRange, text: String)], select selection: [NSRange]?) {
        let sorted = edits.sorted { $0.range.location > $1.range.location }
        let ranges = sorted.map { NSValue(range: $0.range) }
        guard shouldChangeText(inRanges: ranges, replacementStrings: sorted.map(\.text)) else { return }
        helperDepth += 1
        defer { helperDepth -= 1 }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        let storage = document.textStorage
        storage.beginEditing()
        for edit in sorted { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        didChangeText()
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        if let selection, !selection.isEmpty { setAllSelections(selection) }
    }

    func perform(_ range: NSRange, _ text: String, caret: Int) {
        perform([(range, text)], select: [NSRange(location: caret, length: 0)])
    }

    // MARK: insertText

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let signpost = editorSignposter.beginInterval("keystroke")
        defer { editorSignposter.endInterval("keystroke", signpost) }
        if Date().timeIntervalSince(lastEditTime) > 1 { breakUndoCoalescing() }
        lastEditTime = Date()
        lastTypedCharacter = typed.count == 1 ? typed.first : nil
        if allSelections.count > 1, replacementRange.location == NSNotFound, !hasMarkedText(), helperDepth == 0 {
            return typeAtAllCarets(typed)
        }
        guard typed.count == 1, let character = typed.first, replacementRange.location == NSNotFound, !hasMarkedText(),
              let selection = singleSelection, helperDepth == 0 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if handleTyped(character, selection: selection) { return }
        super.insertText(string, replacementRange: replacementRange)
        afterTyping(character)
    }

    /// Returns true when a helper handled the keystroke.
    private func handleTyped(_ character: Character, selection: NSRange) -> Bool {
        let c = String(character)
        if selection.length == 0 {
            let offset = selection.location
            if isPage {
                if pendingInlineTyped(c, at: offset) { return true }
                if listMarkerUnderParagraph(c, at: offset) { return true }
            }
            if c == " ", imageLineSpace(at: offset) { return true }
            if typedInHeadingMarker(c, at: offset) { return true }
            if listTyped(c, at: offset) { return true }
            if tableTyped(c, at: offset) { return true }
            if stepOver(c, at: offset) { return true }
            if !isPage, completeOpener(c, at: offset) { return true }
            if pair(c, selection: selection) { return true }
            return false
        }
        if isPage {
            pageReplace(selection, with: c)
            return true
        }
        if retypeMarker(c, selection: selection) { return true }
        if wrapSelection(c, selection: selection) { return true }
        if pair(c, selection: selection) { return true }
        return false
    }

    /// After a plain insertion: fence completion (spec 110), table padding, autocomplete.
    private func afterTyping(_ character: Character) {
        if character == " ", let offset = caret, offset > 0 { autocorrectAfterSpace(at: offset - 1) }
        if let offset = caret { completeFence(at: offset) }
        tableAfterTyping()
        autocompleteAfterTyping()
        if isPage { slashMenuTextChanged() }
    }

    // MARK: Page typing (docs/wysiwyg-spec.md)

    /// The snapshot the page's typing rules read and the offset its ranges are trusted up to: the current snapshot, or
    /// while a parse is pending the last applied one, whose ranges hold only before the lowest edit made since.
    var pageRuleSnapshot: (snapshot: Snapshot, limit: Int)? {
        guard isPage else { return nil }
        if let snapshot { return (snapshot, Int.max) }
        guard let last = lastAppliedSnapshot else { return nil }
        return (last, lowestEditSinceApplied ?? Int.max)
    }

    /// Hidden ranges near `offset` that the typing rules may trust.
    func pageRuleRanges(around offset: Int) -> [HiddenRange]? {
        guard let rule = pageRuleSnapshot else { return nil }
        if snapshot != nil { return pageHiddenRanges(around: NSRange(location: offset, length: 0)) }
        let text = rule.snapshot.text as NSString
        let at = min(offset, text.length)
        var start = HiddenRanges.lineContents(at: at, in: text).location
        if start > 0 { start = HiddenRanges.lineContents(at: start - 1, in: text).location }
        var end = NSMaxRange(HiddenRanges.lineContents(at: at, in: text))
        if end < text.length { end = NSMaxRange(HiddenRanges.lineContents(at: end + 1, in: text)) }
        return HiddenRanges.list(in: NSRange(location: start, length: end - start), snapshot: rule.snapshot, text: text,
                                 columnWidth: styler.pageColumnWidth, caret: styler.pageCaret)
            .filter { NSMaxRange($0.range) <= rule.limit }
    }

    /// The innermost block at `offset` from the rule snapshot, when its range is trusted.
    func pageRuleBlock(at offset: Int) -> Block? {
        guard let rule = pageRuleSnapshot, let block = rule.snapshot.deepestBlock(at: offset), NSMaxRange(block.range) <= rule.limit else { return nil }
        return block
    }

    /// Bold or italic chosen at an empty caret: the first character typed there is wrapped in the marker, and typing
    /// goes on inside it.
    private func pendingInlineTyped(_ c: String, at offset: Int) -> Bool {
        if let allowed = allowedCaret, offset == allowed {
            allowedCaret = allowed + (c as NSString).length
            return false
        }
        guard let pending = pendingInline, pending.at == offset else { return false }
        pendingInline = nil
        let marker = pending.marker
        let inside = offset + (marker as NSString).length + (c as NSString).length
        allowedCaret = inside
        perform(NSRange(location: offset, length: 0), marker + c + marker, caret: inside)
        return true
    }

    /// True when the line above `lineStart` is a paragraph line (not a list, quote or heading line), so a marker
    /// typed under it would not start a list (CommonMark).
    private func isParagraphAbove(_ lineStart: Int) -> Bool {
        guard lineStart > 0 else { return false }
        let above = lineContents(at: lineStart - 1)
        let text = nsText.substring(with: above)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
              Self.listRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == nil,
              headingMarker(at: above.location) == nil,
              let block = pageRuleBlock(at: above.location) else { return false }
        switch block.kind {
        case .paragraph: return true
        case .setextHeading:
            guard let underline = block.markerRanges.last else { return false }
            return lineContents(at: underline.location).location == lineStart
        default: return false
        }
    }

    /// `- `, `* `, `+ ` or `1. ` typed on the line under a paragraph: a blank line goes above, so it is a list at once.
    private func listMarkerUnderParagraph(_ c: String, at offset: Int) -> Bool {
        guard c == " ", isMarkdownFile else { return false }
        let line = lineContents(at: offset)
        guard offset == NSMaxRange(line) else { return false }
        let text = nsText.substring(with: line)
        guard (try? /^[ \t]*([-*+]|[0-9]{1,9}[.)])$/.wholeMatch(in: text)) != nil, isParagraphAbove(line.location) else { return false }
        perform([(NSRange(location: line.location, length: 0), "\n"), (NSRange(location: offset, length: 0), " ")],
                select: [NSRange(location: offset + 2, length: 0)])
        return true
    }

    /// Replaces a page selection in one step: markers of inlines reaching outside it stay, an inline whose content is
    /// all deleted goes whole, and `text` goes in at the selection's start. Outside Markdown files it is a plain replacement.
    func pageReplace(_ selection: NSRange, with text: String) {
        guard isMarkdownFile else { return perform(selection, text, caret: selection.location + (text as NSString).length) }
        var deleted = [selection]
        var kept: [NSRange] = []
        if let snapshot {
            func visit(_ inlines: [Inline]) {
                for inline in inlines where NSIntersectionRange(inline.range, selection).length > 0 || NSLocationInRange(selection.location, inline.range) {
                    let inside = inline.range.location >= selection.location && NSMaxRange(inline.range) <= NSMaxRange(selection)
                    if !inside {
                        if inline.contentRange.length > 0, inline.contentRange.location >= selection.location,
                           NSMaxRange(inline.contentRange) <= NSMaxRange(selection), !inline.markerRanges.isEmpty {
                            deleted.append(inline.range)
                        } else {
                            kept.append(contentsOf: inline.markerRanges.filter { NSIntersectionRange($0, selection).length > 0 })
                        }
                    }
                    visit(inline.children)
                }
            }
            for block in VisibleText.blocksMeeting(selection, in: snapshot) { visit(block.inlines) }
        }
        // Merge the deleted ranges, then cut the kept markers out of them.
        var merged: [NSRange] = []
        for range in deleted.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, range) } else { merged.append(range) }
        }
        var pieces: [NSRange] = []
        for range in merged {
            var start = range.location
            for marker in kept.sorted(by: { $0.location < $1.location }) where NSIntersectionRange(marker, range).length > 0 {
                if marker.location > start { pieces.append(NSRange(location: start, length: marker.location - start)) }
                start = max(start, NSMaxRange(marker))
            }
            if NSMaxRange(range) > start { pieces.append(NSRange(location: start, length: NSMaxRange(range) - start)) }
        }
        let insertAt = merged.first?.location ?? selection.location
        var edits: [(range: NSRange, text: String)] = pieces.map { ($0, "") }
        if let index = edits.firstIndex(where: { $0.range.location == insertAt }) {
            edits[index].text = text
        } else {
            edits.append((NSRange(location: insertAt, length: 0), text))
        }
        let removedBefore = pieces.filter { $0.location < insertAt }.reduce(0) { $0 + $1.length }
        perform(edits, select: [NSRange(location: insertAt - removedBefore + (text as NSString).length, length: 0)])
    }

    /// Backspace on the page at a caret just after hidden Markdown (docs/wysiwyg-spec.md). Returns false to fall
    /// through to the source view's rules.
    private func pageBackspace(at offset: Int) -> Bool {
        guard isMarkdownFile, let ranges = pageRuleRanges(around: offset) else { return false }
        let ending = ranges.filter { NSMaxRange($0.range) == offset }
        if let prefix = ending.first(where: { $0.kind == .blockPrefix }) {
            let line = lineContents(at: prefix.range.location)
            let aboveBlank = line.location == 0 || nsText.substring(with: lineContents(at: line.location - 1)).trimmingCharacters(in: .whitespaces).isEmpty
            let replacement = aboveBlank ? "" : "\n"
            perform(prefix.range, replacement, caret: prefix.range.location + (replacement as NSString).length)
            return true
        }
        if let indent = ending.first(where: { $0.kind == .continuationIndent }), indent.range.location > 0 {
            perform(NSRange(location: indent.range.location - 1, length: NSMaxRange(indent.range) - indent.range.location + 1), "",
                    caret: indent.range.location - 1)
            return true
        }
        if let separator = ending.first(where: { $0.kind == .separator }) {
            guard separator.range.location > 0 else { return true }
            let before = lineContents(at: separator.range.location - 1)
            if ranges.contains(where: { $0.kind == .divider && NSLocationInRange(before.location, $0.range) }) || pageRuleBlock(at: before.location)?.kind == .thematicBreak {
                perform(NSRange(location: before.location, length: offset - before.location), "", caret: before.location)
                return true
            }
            switch pageRuleBlock(at: before.location)?.kind {
            case .paragraph?, .atxHeading?, .setextHeading?, .listItem?, .blockQuote?:
                perform(NSRange(location: NSMaxRange(before), length: offset - NSMaxRange(before)), "", caret: NSMaxRange(before))
            default:
                setSelectedRange(NSRange(location: HiddenRanges.step(from: offset, to: offset - 1, direction: -1, ranges: ranges, isEnd: false, text: nsText), length: 0))
            }
            return true
        }
        if let divider = ending.first(where: { $0.kind == .divider }) {
            perform(divider.range, "", caret: divider.range.location)
            return true
        }
        if ending.contains(where: { [.fenceLine, .tableDividerRow, .setextUnderline, .tableGap].contains($0.kind) }) { return true }
        if let reference = ending.first(where: { $0.kind == .footnoteReference }) {
            perform(reference.range, "", caret: reference.range.location)
            return true
        }
        if !ending.isEmpty {
            var index = offset
            while index > 0, ranges.contains(where: { NSLocationInRange(index - 1, $0.range) }) { index -= 1 }
            guard index > 0 else { return true }
            let character = nsText.rangeOfComposedCharacterSequence(at: index - 1)
            let target = pageWholeInline(around: character) ?? character
            perform(target, "", caret: target.location)
            return true
        }
        return false
    }

    /// The inline whose only content character is `character`, when there is one.
    private func pageWholeInline(around character: NSRange) -> NSRange? {
        guard let rule = pageRuleSnapshot else { return nil }
        return rule.snapshot.inline(at: character.location).last {
            $0.contentRange == character && !$0.markerRanges.isEmpty && NSMaxRange($0.range) <= rule.limit
        }?.range
    }

    /// Delete on the page at a caret just before hidden Markdown.
    private func pageDeleteForward(at offset: Int) -> Bool {
        guard isMarkdownFile, let ranges = pageRuleRanges(around: offset) else { return false }
        let starting = ranges.filter { $0.range.location == offset }
        if let divider = starting.first(where: { $0.kind == .divider }) {
            perform(divider.range, "", caret: offset)
            return true
        }
        if starting.contains(where: { [.fenceLine, .tableDividerRow, .setextUnderline, .tableGap].contains($0.kind) }) { return true }
        if let reference = starting.first(where: { $0.kind == .footnoteReference }) {
            perform(reference.range, "", caret: offset)
            return true
        }
        if !starting.isEmpty {
            var index = offset
            while index < nsText.length, ranges.contains(where: { NSLocationInRange(index, $0.range) }) { index += 1 }
            guard index < nsText.length else { return true }
            let character = nsText.rangeOfComposedCharacterSequence(at: index)
            let target = pageWholeInline(around: character) ?? character
            perform(target, "", caret: min(offset, target.location))
            return true
        }
        return false
    }

    public override func deleteForward(_ sender: Any?) {
        if isPage, helperDepth == 0, extraSelections.isEmpty, let selection = singleSelection {
            if selection.length > 0 {
                pageReplace(selection, with: "")
                slashMenuTextChanged()
                return
            }
            if pageDeleteForward(at: selection.location) {
                slashMenuTextChanged()
                return
            }
        }
        super.deleteForward(sender)
    }

    // MARK: Headings (spec 89–91)

    /// The `#` run of an ATX heading line and the marker end (after one following space), when the line is not indented.
    func headingMarker(at offset: Int) -> (start: Int, hashes: Int, end: Int)? {
        let line = lineContents(at: offset)
        var index = line.location
        while index < NSMaxRange(line), character(at: index) == 35 { index += 1 }
        let hashes = index - line.location
        guard (1...6).contains(hashes) else { return nil }
        if index < NSMaxRange(line) {
            guard character(at: index) == 32 else { return nil }
            index += 1
        }
        return (line.location, hashes, index)
    }

    private func typedInHeadingMarker(_ c: String, at offset: Int) -> Bool {
        guard let marker = headingMarker(at: offset), offset > marker.start, offset < marker.end else { return false }
        if c == "#" {
            guard marker.hashes < 6 else { return true }
            perform(NSRange(location: marker.start, length: 0), "#", caret: offset + 1)
            return true
        }
        setSelectedRange(NSRange(location: marker.end, length: 0))
        if marker.end == NSMaxRange(lineContents(at: offset)) && character(at: marker.end - 1) != 32 {
            perform(NSRange(location: marker.end, length: 0), " " + c, caret: marker.end + 2)
            return true
        }
        return false
    }

    private func deleteInHeadingMarker(at offset: Int) -> Bool {
        guard let marker = headingMarker(at: offset), offset > marker.start, offset <= marker.end else { return false }
        if marker.hashes >= 2 {
            perform(NSRange(location: marker.start, length: 1), "", caret: marker.end - 1)
        } else {
            perform(NSRange(location: marker.start, length: marker.end - marker.start), "", caret: marker.start)
        }
        return true
    }

    // MARK: Pairs (spec 102–107)

    static let pairs: [String: String] = ["`": "`", "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "*": "*", "_": "_"]
    static let closers: Set<String> = [")", "]", "}", "\"", "'", "`"]

    private func isSpaceOrNil(_ c: unichar?) -> Bool { c == nil || c == 32 || c == 9 || c == 10 }

    private func pair(_ c: String, selection: NSRange) -> Bool {
        guard isMarkdownFile || !["*", "_"].contains(c), let closer = Self.pairs[c] else { return false }
        if isPage, c == "`" { return false }
        if selection.length > 0 {
            if (c == "*" || c == "_") && isInCodeOrMath(selection.location) { return false }
            let inner = nsText.substring(with: selection)
            perform([(selection, c + inner + closer)], select: [NSRange(location: selection.location + 1, length: selection.length)])
            return true
        }
        if c == "*" || c == "_" { return false }
        let offset = selection.location
        let next = character(at: offset)
        let previous = offset > 0 ? character(at: offset - 1) : nil
        let nextIsClosing = next.map { Self.closers.contains(String(utf16CodeUnits: [$0], count: 1)) } ?? false
        guard isSpaceOrNil(next) || nextIsClosing else { return false }
        if c == closer {
            guard isSpaceOrNil(previous) || previous == 61 else { return false }
        }
        if c == "(", let previous, [58, 61, 59, 45].contains(previous), !isInCodeOrMath(offset) { return false }
        perform(NSRange(location: offset, length: 0), c + closer, caret: offset + 1)
        return true
    }

    private func stepOver(_ c: String, at offset: Int) -> Bool {
        guard let next = character(at: offset), String(utf16CodeUnits: [next], count: 1) == c else { return false }
        let previous = offset > 0 ? character(at: offset - 1) : nil
        if Self.closers.contains(c) && previous != 92 {
            setSelectedRange(NSRange(location: offset + 1, length: 0))
            return true
        }
        if !isPage, isMarkdownFile && ["*", "_", ":", "$"].contains(c) {
            let kinds = inlines(at: offset).map(\.kind)
            let inside = kinds.contains { [.emphasis, .strong, .highlight, .code, .math].contains($0) }
            if inside {
                setSelectedRange(NSRange(location: offset + 1, length: 0))
                return true
            }
        }
        return false
    }

    private func deletePair(at offset: Int) -> Bool {
        guard offset > 0, let previous = character(at: offset - 1), let next = character(at: offset) else { return false }
        let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125, 39: 39, 34: 34, 96: 96]
        guard pairs[previous] == next, offset < 2 || character(at: offset - 2) != 92 else { return false }
        perform(NSRange(location: offset - 1, length: 2), "", caret: offset - 1)
        return true
    }

    // MARK: Wrapping a selection (spec 108)

    private func wrapSelection(_ c: String, selection: NSRange) -> Bool {
        guard c == "~" || c == ":" else { return false }
        let marker = c + c
        var range = selection
        while range.length > 0, character(at: range.location) == 32 { range.location += 1; range.length -= 1 }
        while range.length > 0, character(at: NSMaxRange(range) - 1) == 32 { range.length -= 1 }
        let inner = nsText.substring(with: range)
        guard inner.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return false }
        let before = range.location >= 2 ? nsText.substring(with: NSRange(location: range.location - 2, length: 2)) : ""
        let after = NSMaxRange(range) + 2 <= nsText.length ? nsText.substring(with: NSRange(location: NSMaxRange(range), length: 2)) : ""
        if (before == marker && after == marker) || (inner.hasPrefix(marker) && inner.hasSuffix(marker)) { return true }
        perform([(range, marker + inner + marker)], select: [NSRange(location: range.location + 2, length: range.length)])
        return true
    }

    // MARK: Retyping a selected marker (spec 116)

    static let markerCharacters: Set<String> = ["*", "_", "~", "`", "$", ":", "+", "-", "#"]

    private func retypeMarker(_ c: String, selection: NSRange) -> Bool {
        guard Self.markerCharacters.contains(c) else { return false }
        let selected = nsText.substring(with: selection)
        guard let first = selected.first, selected.allSatisfy({ $0 == first }), String(first) != c,
              Self.markerCharacters.contains(String(first)) else { return false }
        let replacement = String(repeating: c, count: selection.length)
        var edits: [(range: NSRange, text: String)] = [(selection, replacement)]
        // The other marker of the same inline element.
        for inline in inlines(at: selection.location).reversed() {
            guard inline.markerRanges.contains(where: { NSIntersectionRange($0, selection).length == selection.length }) else { continue }
            if let other = inline.markerRanges.first(where: { NSIntersectionRange($0, selection).length == 0 }),
               let run = sameRun(of: first, in: other, length: selection.length) {
                edits.append((run, replacement))
            }
            break
        }
        // The closing fence of a fenced code block.
        if edits.count == 1, let block = snapshot?.deepestBlock(at: selection.location), case .fencedCode = block.kind,
           block.markerRanges.count == 2, NSIntersectionRange(block.markerRanges[0], selection).length == selection.length,
           let run = sameRun(of: first, in: block.markerRanges[1], length: block.markerRanges[1].length) {
            edits.append((run, String(repeating: c, count: run.length)))
        }
        perform(edits, select: [NSRange(location: selection.location, length: selection.length)])
        return true
    }

    private func sameRun(of character: Character, in range: NSRange, length: Int) -> NSRange? {
        let unit = String(character).utf16.first
        var start = range.location
        while start < NSMaxRange(range), self.character(at: start) != unit { start += 1 }
        var end = start
        while end < NSMaxRange(range), self.character(at: end) == unit, end - start < length { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: Completing an opener (spec 109)

    private func completeOpener(_ c: String, at offset: Int) -> Bool {
        guard isMarkdownFile, c.count == 1, c.first!.isLetter else { return false }
        if let next = character(at: offset), let scalar = UnicodeScalar(next), CharacterSet.letters.contains(scalar) { return false }
        let line = lineContents(at: offset)
        var start = offset
        while start > line.location, let p = character(at: start - 1), p != 32, p != 9 { start -= 1 }
        var word = nsText.substring(with: NSRange(location: start, length: offset - start))
        if let first = word.first, "([{".contains(first) { word.removeFirst() }
        guard ["*", "**", "_", "__", "$$", "~~", "::"].contains(word) else { return false }
        if isInCodeOrMath(offset) { return false }
        let kinds = inlines(at: offset).map(\.kind)
        if kinds.contains(where: { [.emphasis, .strong, .strike, .highlight].contains($0) }) { return false }
        perform(NSRange(location: offset, length: 0), c + word, caret: offset + 1)
        return true
    }

    // MARK: Fences (spec 110–111)

    private func completeFence(at offset: Int) {
        let line = lineContents(at: offset)
        guard offset == NSMaxRange(line) else { return }
        let trimmed = nsText.substring(with: line).trimmingCharacters(in: .whitespaces)
        guard ["```", "~~~", "$$$"].contains(trimmed) else { return }
        let nextLineStart = NSMaxRange(line) + 1
        if nextLineStart <= nsText.length {
            guard nextLineStart == nsText.length || lineContents(at: nextLineStart).length == 0 else { return }
        }
        // Not when this fence already closes a block above.
        if let block = snapshot?.deepestBlock(at: line.location), block.range.location < line.location {
            switch block.kind {
            case .fencedCode, .mathBlock: return
            default: break
            }
        }
        let indent = nsText.substring(with: line).prefix { $0 == " " }
        perform(NSRange(location: offset, length: 0), "\n" + indent + trimmed, caret: offset)
    }

    /// Enter on the opening line of a block that has only its opening fence adds the closing fence below.
    private func closeOpenFence(at offset: Int) -> Bool {
        guard let block = snapshot?.deepestBlock(at: offset) else { return false }
        let line = lineContents(at: offset)
        guard offset == NSMaxRange(line) else { return false }
        let fence: String
        switch block.kind {
        case .fencedCode, .mathBlock:
            guard block.markerRanges.count == 1 || (block.kind == .mathBlock && !nsText.substring(with: block.range).hasSuffix("$$")),
                  block.range.location == line.location || lineContents(at: block.range.location).location == line.location,
                  NSMaxRange(lineContents(at: NSMaxRange(block.range))) == NSMaxRange(line) else { return false }
            let text = nsText.substring(with: line)
            let indent = text.prefix { $0 == " " }
            let body = text.dropFirst(indent.count)
            guard let first = body.first else { return false }
            fence = String(indent) + String(body.prefix { $0 == first })
        default:
            guard line.location == 0, nsText.substring(with: line) == "---",
                  !nsText.substring(from: NSMaxRange(line)).components(separatedBy: "\n").contains("---") else { return false }
            fence = "---"
        }
        perform(NSRange(location: offset, length: 0), "\n\n" + fence, caret: offset + 1)
        return true
    }

    // MARK: Enter

    public override func insertNewline(_ sender: Any?) {
        lastEditTime = Date()
        if autocompleteAccept() { return }
        if allSelections.count > 1, helperDepth == 0 { return newlineAtAllCarets() }
        guard let selection = singleSelection, helperDepth == 0 else { return super.insertNewline(sender) }
        if selection.length == 0 {
            let offset = selection.location
            if imageLineNewline(at: offset) { return }
            if tableNewline(at: offset) { return }
            if isPage, dividerUnderParagraph(at: offset) { return }
            if setextNewline(at: offset) { return }
            if closeOpenFence(at: offset) { return }
            if listNewline(at: offset) { return }
            if bracketNewline(at: offset) { return }
            if !isMarkdownFile, keepIndentNewline(at: offset) { return }
        }
        super.insertNewline(sender)
        listRenumberAround(selectedRange().location)
    }

    /// Shift+Enter: a plain line break with no list continuation (spec 288).
    public override func insertLineBreak(_ sender: Any?) {
        super.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Return after `---` typed under a paragraph: a blank line goes above, so it is a divider, not a setext underline.
    private func dividerUnderParagraph(at offset: Int) -> Bool {
        let line = lineContents(at: offset)
        guard isMarkdownFile, offset == NSMaxRange(line), nsText.substring(with: line) == "---", isParagraphAbove(line.location) else { return false }
        perform([(NSRange(location: line.location, length: 0), "\n"), (NSRange(location: offset, length: 0), "\n")],
                select: [NSRange(location: offset + 2, length: 0)])
        return true
    }

    private func setextNewline(at offset: Int) -> Bool {
        guard let block = snapshot?.block(at: offset), case .setextHeading = block.kind,
              let underline = block.markerRanges.last, offset == NSMaxRange(underline) else { return false }
        let headingLine = lineContents(at: block.range.location)
        let length = (nsText.substring(with: headingLine).trimmingCharacters(in: .whitespaces) as NSString).length
        guard let marker = nsText.substring(with: underline).first else { return false }
        let rewritten = String(repeating: marker, count: max(length, 1))
        perform(underline, rewritten + "\n", caret: underline.location + (rewritten as NSString).length + 1)
        return true
    }

    private func bracketNewline(at offset: Int) -> Bool {
        guard offset > 0, let previous = character(at: offset - 1), let next = character(at: offset) else { return false }
        let pairs: [unichar: unichar] = [123: 125, 40: 41, 91: 93]
        guard pairs[previous] == next else { return false }
        let indent = lineString(at: offset).prefix { $0 == " " }
        let inner = "\n" + indent + "  "
        perform(NSRange(location: offset, length: 0), inner + "\n" + indent, caret: offset + (inner as NSString).length)
        return true
    }

    private func keepIndentNewline(at offset: Int) -> Bool {
        let indent = lineString(at: offset).prefix { $0 == " " || $0 == "\t" }
        guard !indent.isEmpty else { return false }
        perform(NSRange(location: offset, length: 0), "\n" + indent, caret: offset + 1 + (String(indent) as NSString).length)
        return true
    }

    // MARK: Backspace

    public override func deleteBackward(_ sender: Any?) {
        if Date().timeIntervalSince(lastEditTime) > 1 { breakUndoCoalescing() }
        lastEditTime = Date()
        if allSelections.count > 1, helperDepth == 0 {
            lastTypedCharacter = nil
            return deleteBackwardAtAllCarets()
        }
        if isPage, helperDepth == 0, let selection = singleSelection, selection.length > 0 {
            lastTypedCharacter = nil
            pageReplace(selection, with: "")
            slashMenuTextChanged()
            return
        }
        if let offset = caret, offset > 0 {
            let deleted = nsText.substring(with: NSRange(location: offset - 1, length: 1))
            lastTypedCharacter = deleted.first
            if imageLineBackspace(at: offset) { return }
            if isPage, helperDepth == 0, pageBackspace(at: offset) {
                slashMenuTextChanged()
                return
            }
            if deleteInHeadingMarker(at: offset) { return }
            if deletePair(at: offset) { return }
            if deleteIndent(at: offset) { return }
            super.deleteBackward(sender)
            if deleted == "\n" { listRenumberAround(selectedRange().location) } else { tableAfterTyping(); autocompleteAfterTyping() }
            if isPage { slashMenuTextChanged() }
            return
        }
        lastTypedCharacter = nil
        super.deleteBackward(sender)
    }

    public override func deleteWordBackward(_ sender: Any?) {
        if isPage, helperDepth == 0, let selection = singleSelection {
            if selection.length == 0 { moveWordBackwardAndModifySelection(nil) }
            if let range = singleSelection, range.length > 0 {
                pageReplace(range, with: "")
                slashMenuTextChanged()
                return
            }
        }
        if let offset = caret, deletePair(at: offset) { return }
        super.deleteWordBackward(sender)
    }

    private func deleteIndent(at offset: Int) -> Bool {
        let line = lineContents(at: offset)
        let before = nsText.substring(with: NSRange(location: line.location, length: offset - line.location))
        guard before.count >= 2, before.allSatisfy({ $0 == " " }) else { return false }
        perform(NSRange(location: offset - 2, length: 2), "", caret: offset - 2)
        return true
    }

    // MARK: Tab (spec 113–114)

    public override func insertTab(_ sender: Any?) {
        if autocompleteAccept() { return }
        guard let selection = singleSelection else { return shiftLines(by: 1) }
        if isPage, tableGridTab(forward: true) { return }
        if tableTab(forward: true, selection: selection) { return }
        if selection.length == 0, jumpInline(forward: true, at: selection.location) { return }
        if listTab(outdent: false) { return }
        shiftLines(by: 1)
    }

    public override func insertBacktab(_ sender: Any?) {
        guard let selection = singleSelection else { return shiftLines(by: -1) }
        if isPage, tableGridTab(forward: false) { return }
        if tableTab(forward: false, selection: selection) { return }
        if selection.length == 0, jumpInline(forward: false, at: selection.location) { return }
        if listTab(outdent: true) { return }
        shiftLines(by: -1)
    }

    static let jumpKinds: (InlineKind) -> Bool = { kind in
        switch kind {
        case .emphasis, .strong, .strike, .highlight, .code, .math, .link, .image, .referenceLink, .referenceImage: return true
        default: return false
        }
    }

    private func jumpInline(forward: Bool, at offset: Int) -> Bool {
        let candidates = inlines(at: offset).filter {
            Self.jumpKinds($0.kind) && $0.range.location < offset && offset < NSMaxRange($0.range)
        }
        guard let inline = candidates.last else { return false }
        if forward, case .link = inline.kind, offset <= NSMaxRange(inline.contentRange),
           let url = inline.markerRanges.first(where: { $0.location >= NSMaxRange(inline.contentRange) }) {
            // From the link text to the URL, just after `](`.
            let start = min(url.location + 2, NSMaxRange(inline.range) - 1)
            setSelectedRange(NSRange(location: start, length: 0))
            return true
        }
        setSelectedRange(NSRange(location: forward ? NSMaxRange(inline.range) : inline.range.location, length: 0))
        return true
    }

    /// Indents (`by` 1) or outdents (`by` -1) every selected line to the next 2-space stop; one undo step.
    func shiftLines(by direction: Int) {
        let size = configuration.tabSize
        var edits: [(range: NSRange, text: String)] = []
        var seen = Set<Int>()
        for range in allSelections {
            let lines = nsText.lineRange(for: range)
            var location = lines.location
            repeat {
                let line = lineContents(at: location)
                if seen.insert(line.location).inserted {
                    let indent = nsText.substring(with: line).prefix { $0 == " " }.count
                    if direction > 0 {
                        let add = size - indent % size
                        edits.append((NSRange(location: line.location, length: 0), String(repeating: " ", count: add)))
                    } else if indent > 0 {
                        let remove = indent % size == 0 ? size : indent % size
                        edits.append((NSRange(location: line.location, length: remove), ""))
                    }
                }
                location = NSMaxRange(line) + 1
            } while location < NSMaxRange(lines)
        }
        guard !edits.isEmpty else { return }
        let before = allSelections
        var after: [NSRange] = []
        for range in before {
            var start = range.location, end = NSMaxRange(range)
            for edit in edits {
                let delta = (edit.text as NSString).length - edit.range.length
                if edit.range.location < start || (edit.range.location == start && delta > 0) { start = max(start + delta, edit.range.location) }
                if edit.range.location < end || (edit.range.location == end && delta > 0) { end = max(end + delta, edit.range.location) }
            }
            after.append(NSRange(location: start, length: max(end - start, 0)))
        }
        perform(edits, select: after)
        listRenumberAround(after.first?.location ?? 0)
    }

    // MARK: Home (spec 115)

    public override func moveToBeginningOfLine(_ sender: Any?) {
        guard let offset = caret else { return super.moveToBeginningOfLine(sender) }
        let line = lineContents(at: offset)
        let indent = nsText.substring(with: line).prefix { $0 == " " || $0 == "\t" }.utf16.count
        let target = offset == line.location + indent ? line.location : line.location + indent
        setSelectedRange(NSRange(location: target, length: 0))
    }

    public override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
}
