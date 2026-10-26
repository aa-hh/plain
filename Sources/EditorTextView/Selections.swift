import AppKit
import MarkdownDocument
import NaturalLanguage
import PlainCore

/// Selections (spec 264–279).
extension EditorTextView {
    // MARK: Extend and shrink (spec 273)

    /// Grows the selection to the smallest larger unit: word, sentence, line, bracket pair, paragraph, indented block,
    /// list item and list, Markdown node, heading section, document.
    func extendSelection() {
        guard let current = selectedRanges.first?.rangeValue else { return }
        let candidates = selectionUnits(around: current).filter {
            $0.location <= current.location && NSMaxRange($0) >= NSMaxRange(current) && $0.length > current.length
        }
        guard let next = candidates.min(by: { $0.length < $1.length }) else { return }
        extendStack.append(current)
        adjustingExtend = true
        setSelectedRange(next)
        adjustingExtend = false
    }

    func shrinkSelection() {
        guard let previous = extendStack.popLast() else { return }
        adjustingExtend = true
        setSelectedRange(previous)
        adjustingExtend = false
    }

    func selectionUnits(around range: NSRange) -> [NSRange] {
        var units: [NSRange] = []
        let word = wordRange(at: range.location)
        if word.length > 0 { units.append(word) }
        let line = lineContents(at: range.location)
        units.append(line)
        let lineText = nsText.substring(with: line)
        // Sentence on this line (spec: single line).
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = lineText
        tokenizer.enumerateTokens(in: lineText.startIndex..<lineText.endIndex) { tokenRange, _ in
            var sentence = NSRange(tokenRange, in: lineText)
            let trimmed = (lineText as NSString).substring(with: sentence)
            sentence.length -= trimmed.count - trimmed.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression).count
            units.append(NSRange(location: line.location + sentence.location, length: sentence.length))
            return true
        }
        units += bracketPairs(around: range)
        // Paragraph: the run of non-blank lines.
        let paragraph = surroundingLines(range.location)
        if let first = paragraph.first, let last = paragraph.last {
            units.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
        }
        units.append(indentedBlock(at: range.location))
        // Markdown blocks and inlines holding the selection.
        if let snapshot {
            var level = snapshot.block(at: range.location).map { [$0] } ?? []
            while let block = level.first(where: { NSLocationInRange(range.location, $0.range) || NSMaxRange($0.range) == range.location }) {
                units.append(block.range)
                func addInlines(_ inlines: [Inline]) {
                    for inline in inlines where inline.range.location <= range.location && NSMaxRange(inline.range) >= NSMaxRange(range) {
                        units.append(inline.contentRange)
                        units.append(inline.range)
                        addInlines(inline.children)
                    }
                }
                addInlines(block.inlines)
                level = block.children
            }
            if let section = headingSection(at: range.location, snapshot: snapshot) { units.append(section) }
        }
        units.append(NSRange(location: 0, length: nsText.length))
        return units
    }

    private func bracketPairs(around range: NSRange) -> [NSRange] {
        let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        var result: [NSRange] = []
        var depth: [unichar: Int] = [:]
        var index = range.location - 1
        while index >= 0, range.location - index < 10_000 {
            let c = nsText.character(at: index)
            if let close = opens[c] {
                if depth[close, default: 0] > 0 {
                    depth[close]! -= 1
                } else if let end = matchingClose(from: index + 1, open: c, close: close), end >= NSMaxRange(range) {
                    result.append(NSRange(location: index + 1, length: end - index - 1))
                    result.append(NSRange(location: index, length: end - index + 1))
                    break
                }
            } else if opens.values.contains(c) {
                depth[c, default: 0] += 1
            }
            index -= 1
        }
        return result
    }

    private func matchingClose(from start: Int, open: unichar, close: unichar) -> Int? {
        var depth = 0
        var index = start
        while index < nsText.length, index - start < 10_000 {
            let c = nsText.character(at: index)
            if c == open { depth += 1 } else if c == close {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    /// The run of non-blank lines indented at least as far as the line at `offset`.
    private func indentedBlock(at offset: Int) -> NSRange {
        let line = lineContents(at: offset)
        let indent = nsText.substring(with: line).prefix { $0 == " " }.count
        var first = line, last = line
        func qualifies(_ other: NSRange) -> Bool {
            let text = nsText.substring(with: other)
            return !text.trimmingCharacters(in: .whitespaces).isEmpty && text.prefix { $0 == " " }.count >= indent
        }
        while first.location > 0 {
            let above = lineContents(at: first.location - 1)
            guard qualifies(above) else { break }
            first = above
        }
        while NSMaxRange(last) < nsText.length {
            let below = lineContents(at: NSMaxRange(last) + 1)
            guard qualifies(below) else { break }
            last = below
        }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// From the heading above `offset` to just before the next heading of the same or a higher level.
    private func headingSection(at offset: Int, snapshot: Snapshot) -> NSRange? {
        guard let index = snapshot.headings.lastIndex(where: { $0.range.location <= offset }) else { return nil }
        let heading = snapshot.headings[index]
        let next = snapshot.headings[(index + 1)...].first { $0.level <= heading.level }
        var end = next?.range.location ?? nsText.length
        while end > heading.range.location, let c = character(at: end - 1), c == 10 { end -= 1 }
        return NSRange(location: heading.range.location, length: end - heading.range.location)
    }
}

/// Extra carets and selections. `NSTextView` keeps only one empty selection and types into only the first of several
/// ranges, so the editor keeps the others itself, draws them, and applies every edit at each of them in one undo step.
extension EditorTextView {
    /// The main selection and the extra ones, in text order, overlaps merged.
    var allSelections: [NSRange] {
        let native = selectedRanges.map(\.rangeValue)
        return Self.merged(native + extraSelections)
    }

    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length }) {
            if let last = result.last, range.location < NSMaxRange(last) || (range.location == last.location && range.length == last.length) || (range.length == 0 && range.location == NSMaxRange(last) && last.length > 0) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Selects `ranges`; `primary` (default the first) is the main selection, the rest become extra carets.
    func setAllSelections(_ ranges: [NSRange], primary: NSRange? = nil) {
        let length = nsText.length
        let clamped = Self.merged(ranges.map {
            let location = min(max($0.location, 0), length)
            return NSRange(location: location, length: min($0.length, length - location))
        })
        guard let main = primary.map({ p in clamped.first { NSLocationInRange(p.location, $0) || $0.location == p.location } ?? p }) ?? clamped.first else { return }
        settingSelections = true
        setSelectedRange(main)
        settingSelections = false
        let extras = clamped.filter { $0 != main }.map { range in
            guard let hidden = pageHiddenRanges(around: range) else { return range }
            if range.length == 0 { return NSRange(location: HiddenRanges.snap(range.location, ranges: hidden, isEnd: false), length: 0) }
            let start = HiddenRanges.snap(range.location, ranges: hidden, isEnd: true)
            let end = HiddenRanges.snap(NSMaxRange(range), ranges: hidden, isEnd: true)
            return NSRange(location: min(start, end), length: abs(end - start))
        }
        // Carets merge only after snapping, since two can snap to one place; the main selection (snapped by
        // `setSelectedRanges` on the page) wins over any extra it merges with.
        let snappedMain = isPage ? selectedRange() : main
        extraSelections = Self.merged([snappedMain] + extras).filter {
            !($0.location <= snappedMain.location && NSMaxRange(snappedMain) <= NSMaxRange($0))
        }
        if isPage { styler.pageSelections = allSelections }
        extraSelectionsChanged()
    }

    func clearExtraSelections() {
        guard !extraSelections.isEmpty else { return }
        extraSelections = []
        occurrenceStack = []
        extraSelectionsChanged()
    }

    private func extraSelectionsChanged() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        extraCaretsOn = true
        if extraSelections.contains(where: { $0.length == 0 }) {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.extraCaretsOn.toggle()
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    /// Extra selections in selection blue, extra carets as 1 pt bars in the secondary colour (spec 1503–1504).
    func drawExtraSelections(in rect: NSRect) {
        guard !extraSelections.isEmpty else { return }
        for range in extraSelections {
            if range.length > 0 {
                (window?.firstResponder === self ? Tokens.selectionBlue : Tokens.selectionNeutral).setFill()
                var location = range.location
                while location < NSMaxRange(range) {
                    let line = lineContents(at: location)
                    let piece = NSIntersectionRange(range, NSRange(location: line.location, length: line.length + 1))
                    let pieceRect = self.rect(forCharacterRange: NSRange(location: piece.location, length: min(piece.length, NSMaxRange(line) - piece.location)))
                    var fill = pieceRect
                    if NSMaxRange(range) > NSMaxRange(line) { fill.size.width = columnRight - fill.minX }
                    if fill.width == 0 { fill.size.width = 4 }
                    fill.fill(using: .sourceOver)
                    location = NSMaxRange(line) + 1
                }
            } else if extraCaretsOn {
                let caretRect = self.rect(forCharacterRange: range)
                Tokens.colorSecondary.setFill()
                NSRect(x: caretRect.minX, y: caretRect.minY + 3, width: 1, height: max(caretRect.height - 6, 1)).fill()
            }
        }
    }

    // MARK: Editing at every caret

    /// Replaces each selection with the text `make` returns for it, in one undo step; carets land after each insertion.
    func replaceAtAllSelections(_ make: (NSRange) -> (range: NSRange, text: String)?) {
        let selections = allSelections
        var edits: [(range: NSRange, text: String)] = []
        for selection in selections { if let edit = make(selection) { edits.append(edit) } }
        guard !edits.isEmpty else { return }
        edits.sort { $0.range.location < $1.range.location }
        var carets: [NSRange] = []
        var shift = 0
        for edit in edits {
            let length = (edit.text as NSString).length
            carets.append(NSRange(location: edit.range.location + shift + length, length: 0))
            shift += length - edit.range.length
        }
        perform(edits, select: carets)
    }

    func typeAtAllCarets(_ text: String) {
        replaceAtAllSelections { ($0, text) }
    }

    func deleteBackwardAtAllCarets() {
        replaceAtAllSelections { range in
            if range.length > 0 { return (range, "") }
            guard range.location > 0 else { return nil }
            return (nsText.rangeOfComposedCharacterSequence(at: range.location - 1), "")
        }
    }

    func newlineAtAllCarets() {
        replaceAtAllSelections { range in (range, "\n" + (listContinuation(at: range.location) ?? "")) }
        listRenumberAround(allSelections.first?.location ?? 0)
    }

    /// Arrow keys with extra carets: every caret moves (spec 264). Returns false without extra carets.
    func moveAllCarets(by step: Int, vertical: Bool) -> Bool {
        guard !extraSelections.isEmpty else { return false }
        let moved = allSelections.map { range -> NSRange in
            if !vertical {
                if range.length > 0 { return NSRange(location: step < 0 ? range.location : NSMaxRange(range), length: 0) }
                let location = step < 0 ? max(range.location - 1, 0) : min(range.location + 1, nsText.length)
                if let hidden = pageHiddenRanges(around: NSRange(location: min(location, range.location), length: 1)) {
                    return NSRange(location: HiddenRanges.step(from: range.location, to: location, direction: step, ranges: hidden, isEnd: false, text: nsText), length: 0)
                }
                return NSRange(location: location, length: 0)
            }
            let line = lineContents(at: range.location)
            let column = range.location - line.location
            var moved: Int
            if step < 0 {
                guard line.location > 0 else { return NSRange(location: 0, length: 0) }
                let above = lineContents(at: line.location - 1)
                moved = above.location + min(column, above.length)
            } else {
                guard NSMaxRange(line) < nsText.length else { return NSRange(location: nsText.length, length: 0) }
                let below = lineContents(at: NSMaxRange(line) + 1)
                moved = below.location + min(column, below.length)
            }
            if isPage, snapshot != nil { moved = pageVertical(from: range.location, to: moved, direction: step) }
            return NSRange(location: moved, length: 0)
        }
        setAllSelections(moved)
        return true
    }

    // MARK: Mouse (spec 267)

    /// Alt+click adds a caret (Alt+double-click a word, Alt+triple-click a line); Cmd+Alt+drag makes a column selection.
    func handleSelectionClick(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        if flags == [.command, .option] {
            var current = event
            columnSelection(from: point, to: point)
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                current = next
                columnSelection(from: point, to: convert(current.locationInWindow, from: nil))
                if current.type == .leftMouseUp { break }
            }
            return true
        }
        guard flags == .option else {
            clearExtraSelections()
            return false
        }
        let offset = characterIndexForInsertion(at: point)
        let added: NSRange
        switch event.clickCount {
        case 2: added = wordRange(at: offset)
        case 3: added = nsText.lineRange(for: NSRange(location: offset, length: 0))
        default: added = NSRange(location: offset, length: 0)
        }
        setAllSelections(allSelections + [added], primary: added)
        return true
    }

    /// One selection per line between the two points, from the left x to the right x (view coordinates).
    func columnSelection(from start: NSPoint, to end: NSPoint) {
        let top = min(start.y, end.y), bottom = max(start.y, end.y)
        let left = min(start.x, end.x), right = max(start.x, end.x)
        var line = lineContents(at: characterIndexForInsertion(at: NSPoint(x: left, y: top)))
        var ranges: [NSRange] = []
        while true {
            let lineRect = rect(forCharacterRange: NSRange(location: line.location, length: 0))
            let y = lineRect.midY
            let a = min(max(characterIndexForInsertion(at: NSPoint(x: left, y: y)), line.location), NSMaxRange(line))
            let b = min(max(characterIndexForInsertion(at: NSPoint(x: right, y: y)), line.location), NSMaxRange(line))
            ranges.append(NSRange(location: a, length: b - a))
            guard NSMaxRange(line) < nsText.length else { break }
            let next = lineContents(at: NSMaxRange(line) + 1)
            if rect(forCharacterRange: NSRange(location: next.location, length: 0)).minY > bottom { break }
            line = next
        }
        setAllSelections(ranges, primary: ranges.first)
    }

    // MARK: Commands (spec 268–272)

    func performSelectionCommand(_ id: String) -> Bool {
        switch id {
        case "editor:extend-selection": extendSelection()
        case "editor:shrink-selection": shrinkSelection()
        case "editor:add-next-occurrence": addNextOccurrence()
        case "editor:add-each-occurrence": addEachOccurrence()
        case "editor:remove-last-occurrence": removeLastOccurrence()
        case "editor:add-selection-above": addSelection(below: false)
        case "editor:add-selection-below": addSelection(below: true)
        case "editor:split-selection-into-lines": splitSelectionIntoLines()
        default: return false
        }
        return true
    }

    /// With no selection, selects the word at the caret; then adds the next occurrence of the selected text, wrapping.
    func addNextOccurrence() {
        let selections = allSelections
        guard let main = selections.first else { return }
        if selections.count == 1, main.length == 0 {
            let word = wordRange(at: main.location)
            if word.length > 0 { setAllSelections([word]) }
            occurrenceStack = []
            return
        }
        let needle = nsText.substring(with: main)
        guard !needle.isEmpty else { return }
        let from = NSMaxRange(occurrenceStack.last ?? selections.last!)
        var found = nsText.range(of: needle, options: [.literal], range: NSRange(location: from, length: nsText.length - from))
        if found.location == NSNotFound { found = nsText.range(of: needle, options: [.literal], range: NSRange(location: 0, length: nsText.length)) }
        guard found.location != NSNotFound, !selections.contains(found) else { return }
        occurrenceStack.append(found)
        setAllSelections(selections + [found], primary: found)
        scrollRangeToVisible(found)
    }

    func addEachOccurrence() {
        var selections = allSelections
        guard let main = selections.first else { return }
        if main.length == 0 {
            let word = wordRange(at: main.location)
            guard word.length > 0 else { return }
            selections = [word]
        }
        let needle = nsText.substring(with: selections[0])
        var location = 0
        var found: [NSRange] = []
        while location < nsText.length {
            let range = nsText.range(of: needle, options: [.literal], range: NSRange(location: location, length: nsText.length - location))
            guard range.location != NSNotFound else { break }
            found.append(range)
            location = NSMaxRange(range)
        }
        occurrenceStack = found.filter { !selections.contains($0) }
        setAllSelections(found, primary: selections[0])
    }

    func removeLastOccurrence() {
        var selections = allSelections
        guard selections.count > 1 else { return }
        let last = occurrenceStack.popLast() ?? selections.last!
        selections.removeAll { $0 == last }
        setAllSelections(selections)
    }

    /// Adds a caret or selection at the same column on the next line above or below, skipping lines that are too short
    /// for a range selection (spec 271).
    func addSelection(below: Bool) {
        let selections = allSelections
        guard let edge = below ? selections.last : selections.first else { return }
        let line = lineContents(at: edge.location)
        let column = edge.location - line.location
        var probe = line
        while true {
            if below {
                guard NSMaxRange(probe) < nsText.length else { return }
                probe = lineContents(at: NSMaxRange(probe) + 1)
            } else {
                guard probe.location > 0 else { return }
                probe = lineContents(at: probe.location - 1)
            }
            if edge.length == 0 {
                let added = NSRange(location: probe.location + min(column, probe.length), length: 0)
                setAllSelections(selections + [added], primary: added)
                return
            }
            if probe.length >= column + edge.length {
                let added = NSRange(location: probe.location + column, length: edge.length)
                setAllSelections(selections + [added], primary: added)
                return
            }
        }
    }

    func splitSelectionIntoLines() {
        var result: [NSRange] = []
        for range in allSelections {
            guard range.length > 0 else { result.append(range); continue }
            var location = range.location
            while location <= NSMaxRange(range) {
                let line = lineContents(at: location)
                let piece = NSIntersectionRange(range, line)
                if piece.length > 0 || (line.length == 0 && location < NSMaxRange(range)) {
                    result.append(piece.length > 0 ? piece : NSRange(location: line.location, length: 0))
                }
                guard NSMaxRange(line) < NSMaxRange(range) else { break }
                location = NSMaxRange(line) + 1
            }
        }
        setAllSelections(result)
    }
}
