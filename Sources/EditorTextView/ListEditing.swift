import AppKit
import MarkdownDocument

/// One line's list prefix, split into its parts.
struct LinePattern: Equatable {
    var indent: String
    /// `-`, `*`, `+`, `1.`, `1)`, `>` or empty for plain indentation or a generic shared prefix.
    var marker: String
    /// `[ ]` or `[x]` for task items.
    var box: String?
    var spacing: String
    /// The shared prefix when the pattern came from neighbouring lines (`// `, `| `).
    var generic: String?

    var text: String {
        if let generic { return generic }
        var result = indent + marker
        if !marker.isEmpty { result += spacing.isEmpty ? " " : spacing }
        if let box { result += box + " " }
        return result
    }

    var isNumbered: Bool { marker.first?.isNumber ?? false }
    var number: Int? { isNumbered ? Int(marker.dropLast()) : nil }
    var isBullet: Bool { ["-", "*", "+"].contains(marker) }

    /// The pattern for the next line: unchecked box, next number.
    func next(keepNumber: Bool) -> LinePattern {
        var copy = self
        if box != nil { copy.box = "[ ]" }
        if let number, !keepNumber, let suffix = marker.last { copy.marker = "\(number + 1)\(suffix)" }
        if generic != nil { copy.generic = generic }
        return copy
    }

    /// The form used to compare and learn levels: numbers become 1, boxes unchecked.
    var normalized: String {
        var copy = self
        if let suffix = marker.last, isNumbered { copy.marker = "1\(suffix)" }
        if box != nil { copy.box = "[ ]" }
        return copy.text
    }
}

/// List continuation, empty items, task boxes, levels, renumbering and the list format commands (spec 122–140).
extension EditorTextView {
    static let listRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|[0-9]{1,9}[.)]|>)( +)(\[[ xX]\] )?"#)

    /// The list prefix of the line at `offset`, if any (spec 125).
    func pattern(ofLineAt offset: Int) -> LinePattern? {
        let line = lineContents(at: offset)
        let text = nsText.substring(with: line)
        if let match = Self.listRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let s = text as NSString
            let box = match.range(at: 4).location == NSNotFound ? nil : s.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
            return LinePattern(indent: s.substring(with: match.range(at: 1)), marker: s.substring(with: match.range(at: 2)),
                               box: box, spacing: s.substring(with: match.range(at: 3)))
        }
        // `- ` alone on a line (an empty item) does not match the regex when nothing follows the space.
        let trimmedEnd = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        if let match = Self.listRegex.firstMatch(in: trimmedEnd + " ", range: NSRange(location: 0, length: (trimmedEnd as NSString).length + 1)),
           match.range.length == (trimmedEnd as NSString).length + 1 {
            let s = (trimmedEnd + " ") as NSString
            return LinePattern(indent: s.substring(with: match.range(at: 1)), marker: s.substring(with: match.range(at: 2)),
                               box: nil, spacing: " ")
        }
        if let generic = genericPattern(at: line, text: text) { return generic }
        let indent = String(text.prefix { $0 == " " || $0 == "\t" })
        return indent.isEmpty ? nil : LinePattern(indent: indent, marker: "", box: nil, spacing: "")
    }

    /// A prefix ending in a space that the line shares with the nearest line above or below at the same indent.
    private func genericPattern(at line: NSRange, text: String) -> LinePattern? {
        let indent = text.prefix { $0 == " " }
        for direction in [-1, 1] {
            var location = direction < 0 ? line.location - 1 : NSMaxRange(line) + 1
            while location >= 0 && location < nsText.length {
                let other = lineContents(at: location)
                let otherText = nsText.substring(with: other)
                if otherText.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if otherText.prefix(while: { $0 == " " }) == indent {
                    let common = zip(text, otherText).prefix { $0 == $1 }.map(\.0)
                    if let lastSpace = common.lastIndex(of: " "), lastSpace >= indent.count,
                       !String(common[indent.count...lastSpace]).trimmingCharacters(in: .whitespaces).isEmpty {
                        let prefix = String(common[...lastSpace])
                        if prefix.contains(where: { $0.isLetter }) { return nil }
                        return LinePattern(indent: String(indent), marker: "", box: nil, spacing: "", generic: prefix)
                    }
                    break
                }
                location = direction < 0 ? other.location - 1 : NSMaxRange(other) + 1
            }
        }
        return nil
    }

    private func isInTable(_ offset: Int) -> Bool {
        if let block = snapshot?.block(at: offset), block.kind == .table { return true }
        return false
    }

    /// Every line of the run of non-blank lines around `offset`.
    func surroundingLines(_ offset: Int) -> [NSRange] {
        var lines: [NSRange] = []
        var location = lineContents(at: offset).location
        while location > 0 {
            let above = lineContents(at: location - 1)
            if nsText.substring(with: above).trimmingCharacters(in: .whitespaces).isEmpty { break }
            location = above.location
        }
        while location <= nsText.length {
            let line = lineContents(at: location)
            if nsText.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty && !lines.isEmpty { break }
            lines.append(line)
            if NSMaxRange(line) >= nsText.length { break }
            location = NSMaxRange(line) + 1
        }
        return lines
    }

    /// True when every numbered item at this indent in the list is `1.` or `1)`.
    private func isAllOnes(_ item: LinePattern, near offset: Int) -> Bool {
        let siblings = surroundingLines(offset).compactMap { self.pattern(ofLineAt: $0.location) }
            .filter { $0.isNumbered && $0.indent == item.indent }
        return siblings.count > 1 && siblings.allSatisfy { $0.number == 1 }
    }

    // MARK: Enter (spec 126–127)

    func listNewline(at offset: Int) -> Bool {
        guard isMarkdownFile, !isInTable(offset), let pattern = pattern(ofLineAt: offset) else { return false }
        let line = lineContents(at: offset)
        let lineText = nsText.substring(with: line)
        if lineText.trimmingCharacters(in: .whitespaces) == pattern.text.trimmingCharacters(in: .whitespaces) {
            guard !pattern.marker.isEmpty || pattern.generic != nil else { return false }
            // An empty item: outdent to the parent's pattern, or clear the line.
            let replacement = parentPattern(of: pattern, above: line.location)?.next(keepNumber: false).text ?? ""
            perform(line, replacement, caret: line.location + (replacement as NSString).length)
            listRenumberAround(line.location)
            return true
        }
        guard let next = listContinuation(at: offset) else { return false }
        perform(NSRange(location: offset, length: 0), "\n" + next, caret: offset + 1 + (next as NSString).length)
        listRenumberAround(offset + 1)
        return true
    }

    /// The pattern a new line after `offset` starts with, when the line has one and holds text (spec 126).
    func listContinuation(at offset: Int) -> String? {
        guard isMarkdownFile, !isInTable(offset), let pattern = pattern(ofLineAt: offset) else { return nil }
        let line = lineContents(at: offset)
        let lineText = nsText.substring(with: line)
        guard lineText.contains(where: { $0.isLetter || $0.isNumber }),
              offset >= line.location + min((pattern.text as NSString).length, line.length) else { return nil }
        return pattern.next(keepNumber: isAllOnes(pattern, near: offset)).text
    }

    /// The nearest list line above with a smaller indent.
    private func parentPattern(of pattern: LinePattern, above location: Int) -> LinePattern? {
        var position = location - 1
        while position >= 0 {
            let line = lineContents(at: position)
            let text = nsText.substring(with: line)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            if let other = self.pattern(ofLineAt: line.location), !other.marker.isEmpty, other.indent.count < pattern.indent.count {
                return other
            }
            position = line.location - 1
        }
        return nil
    }

    // MARK: Typing (spec 129–130)

    func listTyped(_ c: String, at offset: Int) -> Bool {
        guard isMarkdownFile else { return false }
        let line = lineContents(at: offset)
        let text = nsText.substring(with: line)
        if c == " ", text == "[]", offset == NSMaxRange(line) {
            perform(line, "- [ ] ", caret: line.location + 6)
            return true
        }
        if c == " " || c.lowercased() == "x", let box = taskBox(at: offset), offset > box.location, offset < NSMaxRange(box) {
            let mark = c == " " ? " " : "x"
            perform(NSRange(location: box.location + 1, length: 1), mark, caret: box.location + 2)
            return true
        }
        return false
    }

    /// The `[ ]` or `[x]` of the task line at `offset`.
    func taskBox(at offset: Int) -> NSRange? {
        let line = lineContents(at: offset)
        guard let pattern = pattern(ofLineAt: offset), pattern.box != nil else { return nil }
        let start = line.location + ((pattern.indent + pattern.marker + pattern.spacing) as NSString).length
        return NSRange(location: start, length: 3)
    }

    // MARK: Esc (spec 128)

    func listEscape() -> Bool {
        guard let offset = caret, let pattern = pattern(ofLineAt: offset), !pattern.marker.isEmpty else { return false }
        let line = lineContents(at: offset)
        guard nsText.substring(with: line).trimmingCharacters(in: .whitespaces) == pattern.text.trimmingCharacters(in: .whitespaces) else { return false }
        perform(line, "", caret: line.location)
        return true
    }

    // MARK: Levels (spec 131)

    func listTab(outdent: Bool) -> Bool {
        guard isMarkdownFile, let selection = singleSelection else { return false }
        let lines = linesTouched(by: selection)
        guard let first = lines.first, let current = pattern(ofLineAt: first.location), !current.marker.isEmpty else { return false }
        // The most common pattern at each indent among the list's lines.
        var counts: [Int: [String: Int]] = [:]
        var samples: [String: LinePattern] = [:]
        for line in surroundingLines(first.location) {
            guard let p = pattern(ofLineAt: line.location), !p.marker.isEmpty else { continue }
            counts[p.indent.count, default: [:]][p.normalized, default: 0] += 1
            samples[p.normalized] = p
        }
        let indents = counts.keys.sorted()
        let target = outdent ? indents.last { $0 < current.indent.count } : indents.first { $0 > current.indent.count }
        guard let target, let best = counts[target]?.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key,
              var replacement = samples[best] else { return false }
        if current.box != nil { replacement.box = current.box }
        var edits: [(range: NSRange, text: String)] = []
        for line in lines {
            guard let p = pattern(ofLineAt: line.location), !p.marker.isEmpty else { continue }
            edits.append((NSRange(location: line.location, length: (p.text as NSString).length), replacement.text))
        }
        let delta = (replacement.text as NSString).length - (current.text as NSString).length
        perform(edits, select: [NSRange(location: max(selection.location + delta, first.location), length: selection.length)])
        listRenumberAround(first.location)
        return true
    }

    func linesTouched(by range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var location = lineContents(at: range.location).location
        while true {
            let line = lineContents(at: location)
            result.append(line)
            let next = NSMaxRange(line) + 1
            if range.length == 0 || next >= NSMaxRange(range) || next > nsText.length { break }
            location = next
        }
        return result
    }

    // MARK: Renumbering (spec 132)

    /// Renumbers ordered items 1, 2, 3 per indent in the list around `offset`; lists of all `1.` stay that way.
    func listRenumberAround(_ offset: Int) {
        guard isMarkdownFile, nsText.length > 0 else { return }
        let lines = surroundingLines(min(offset, nsText.length))
        var groups: [[(line: NSRange, pattern: LinePattern)]] = []
        var open: [Int: Int] = [:]  // indent → index into groups
        for line in lines {
            guard let p = pattern(ofLineAt: line.location), !p.marker.isEmpty, p.generic == nil else { continue }
            let indent = p.indent.count
            guard p.isNumbered else {
                // A bullet or quote ends numbered runs at its indent and deeper.
                open = open.filter { $0.key < indent }
                continue
            }
            open = open.filter { $0.key <= indent }
            if let index = open[indent] {
                groups[index].append((line, p))
            } else {
                open[indent] = groups.count
                groups.append([(line, p)])
            }
        }
        var edits: [(range: NSRange, text: String)] = []
        for group in groups where group.count > 0 {
            if group.count > 1 && group.allSatisfy({ $0.pattern.number == 1 }) { continue }
            let start = 1
            for (index, item) in group.enumerated() {
                guard let suffix = item.pattern.marker.last else { continue }
                let wanted = "\(start + index)\(suffix)"
                if wanted != item.pattern.marker {
                    let location = item.line.location + (item.pattern.indent as NSString).length
                    edits.append((NSRange(location: location, length: (item.pattern.marker as NSString).length), wanted))
                }
            }
        }
        guard !edits.isEmpty else { return }
        let selection = allSelections
        var adjusted: [NSRange] = []
        for range in selection {
            var location = range.location
            for edit in edits where edit.range.location < location {
                location += (edit.text as NSString).length - edit.range.length
            }
            adjusted.append(NSRange(location: location, length: range.length))
        }
        perform(edits, select: adjusted)
    }

    // MARK: Format › List, Ordered List, Task List, Quote (spec 135)

    enum ListStyle { case bullet, ordered, task, quote }

    func toggleList(_ style: ListStyle) {
        guard let selection = singleSelection ?? allSelections.first else { return }
        var lines = linesTouched(by: selection)
        // Extend to the contiguous list of that type at the same indent.
        if let first = lines.first, let p = pattern(ofLineAt: first.location), matches(p, style) {
            for line in surroundingLines(first.location) where !lines.contains(line) {
                if let other = pattern(ofLineAt: line.location), matches(other, style), other.indent == p.indent { lines.append(line) }
            }
            lines.sort { $0.location < $1.location }
        }
        let all = lines.allSatisfy { pattern(ofLineAt: $0.location).map { matches($0, style) } ?? false }
        var edits: [(range: NSRange, text: String)] = []
        for (index, line) in lines.enumerated() {
            let existing = blockMarkerRange(at: line)
            let indent = String(nsText.substring(with: line).prefix { $0 == " " || $0 == "\t" })
            let marker: String
            if all {
                marker = ""
            } else {
                switch style {
                case .bullet: marker = "- "
                case .ordered: marker = "\(index + 1). "
                case .task: marker = "- [ ] "
                case .quote: marker = "> "
                }
            }
            let markerRange = NSRange(location: line.location + (indent as NSString).length,
                                      length: existing.map { NSMaxRange($0) - line.location - (indent as NSString).length } ?? 0)
            edits.append((markerRange, marker))
        }
        let firstLine = lines.first?.location ?? 0
        perform(edits, select: nil)
        setSelectedRange(spanOfLines(from: firstLine, count: lines.count))
        listRenumberAround(firstLine)
    }

    private func matches(_ pattern: LinePattern, _ style: ListStyle) -> Bool {
        switch style {
        case .bullet: return pattern.isBullet && pattern.box == nil
        case .ordered: return pattern.isNumbered
        case .task: return pattern.box != nil
        case .quote: return pattern.marker == ">"
        }
    }

    /// The block marker after the indentation of a line: list, task, quote or heading marker and its space.
    func blockMarkerRange(at line: NSRange) -> NSRange? {
        let text = nsText.substring(with: line)
        let indent = (String(text.prefix { $0 == " " || $0 == "\t" }) as NSString).length
        if let p = pattern(ofLineAt: line.location), !p.marker.isEmpty {
            return NSRange(location: line.location + indent, length: (p.text as NSString).length - indent)
        }
        let rest = (text as NSString).substring(from: indent)
        if let match = try? /^#{1,6}( |$)/.firstMatch(in: rest) {
            return NSRange(location: line.location + indent, length: match.output.0.utf16.count)
        }
        return nil
    }

    // MARK: Context menu list items (spec 136)

    func toggleTask(at offset: Int) {
        guard let box = taskBox(at: offset) else { return }
        let checked = nsText.substring(with: NSRange(location: box.location + 1, length: 1)).lowercased() == "x"
        let keep = allSelections
        perform([(NSRange(location: box.location + 1, length: 1), checked ? " " : "x")], select: keep)
    }

    /// Converts the whole list around `offset` to `style`.
    func convertList(at offset: Int, to style: ListStyle) {
        let lines = surroundingLines(offset).filter { pattern(ofLineAt: $0.location).map { !$0.marker.isEmpty && $0.marker != ">" } ?? false }
        var edits: [(range: NSRange, text: String)] = []
        var counters: [Int: Int] = [:]
        for line in lines {
            guard let p = pattern(ofLineAt: line.location) else { continue }
            let indent = p.indent.count
            counters = counters.filter { $0.key <= indent }
            let number = (counters[indent] ?? 0) + 1
            counters[indent] = number
            let marker: String
            switch style {
            case .bullet: marker = "- "
            case .ordered: marker = "\(number). "
            case .task: marker = "- " + (p.box ?? "[ ]") + " "
            case .quote: marker = "> "
            }
            let start = line.location + (p.indent as NSString).length
            edits.append((NSRange(location: start, length: (p.text as NSString).length - (p.indent as NSString).length), marker))
        }
        perform(edits, select: nil)
    }
}
