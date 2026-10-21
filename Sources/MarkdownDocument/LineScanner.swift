import Foundation

/// The document text as UTF-16 units plus the offset where every line starts. Lines end at `\n`.
struct Source {
    var units: [UInt16]
    var lineStarts: [Int]

    init(units: [UInt16]) {
        self.units = units
        lineStarts = Source.lineStarts(in: units, from: 0, to: units.count)
    }

    var lineCount: Int { lineStarts.count }

    func lineStart(_ line: Int) -> Int { lineStarts[line] }

    /// Offset of the line's `\n`, or the text end for the last line.
    func lineEnd(_ line: Int) -> Int { line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : units.count }

    /// Start offsets of the lines beginning in `start..<end`, where `start` begins a line; always holds `start`.
    static func lineStarts(in units: [UInt16], from start: Int, to end: Int) -> [Int] {
        var result = [start]
        var index = start
        while index < end {
            if units[index] == 10 { result.append(index + 1) }
            index += 1
        }
        return result
    }

    /// The line containing the offset.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    /// Converts a 1-based UTF-8 column on a line into a UTF-16 offset, clamped to the line.
    func offset(line: Int, utf8Column: Int) -> Int {
        let end = lineEnd(line)
        var index = lineStart(line)
        var bytes = utf8Column - 1
        while bytes > 0 && index < end {
            let unit = units[index]
            if unit < 0x80 {
                bytes -= 1
                index += 1
            } else if unit < 0x800 {
                bytes -= 2
                index += 1
            } else if unit >= 0xD800 && unit < 0xDC00 {
                bytes -= 4
                index += 2
            } else {
                bytes -= 3
                index += 1
            }
        }
        return min(index, end)
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    func string(_ range: NSRange) -> String {
        string(range.location..<NSMaxRange(range))
    }

    func isBlank(_ line: Int) -> Bool {
        firstNonSpace(line) == lineEnd(line)
    }

    /// Offset of the first character that is not a space or tab, or the line end.
    func firstNonSpace(_ line: Int) -> Int {
        var index = lineStart(line)
        let end = lineEnd(line)
        while index < end && (units[index] == 32 || units[index] == 9) { index += 1 }
        return index
    }

    /// Offset just after the last character that is not a space or tab.
    func trimmedEnd(_ line: Int) -> Int {
        let start = lineStart(line)
        var index = lineEnd(line)
        while index > start && (units[index - 1] == 32 || units[index - 1] == 9) { index -= 1 }
        return index
    }

    /// Leading spaces before the first other character; a tab counts as four.
    func indent(_ line: Int) -> Int {
        var count = 0
        var index = lineStart(line)
        let end = lineEnd(line)
        while index < end {
            if units[index] == 32 { count += 1 } else if units[index] == 9 { count += 4 } else { break }
            index += 1
        }
        return count
    }

    /// Whether the line, without surrounding spaces, equals the ASCII text.
    func trimmedLine(_ line: Int, equals text: String) -> Bool {
        let start = firstNonSpace(line)
        let end = trimmedEnd(line)
        let target = Array(text.utf16)
        return end - start == target.count && units[start..<end].elementsEqual(target)
    }

    /// First offset in `from..<to` where the ASCII needle starts, comparing letters case-insensitively.
    func find(_ needle: [UInt16], from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, to - from >= needle.count else { return nil }
        var index = from
        while index + needle.count <= to {
            var matched = true
            for (offset, unit) in needle.enumerated() where lowercased(units[index + offset]) != unit {
                matched = false
                break
            }
            if matched { return index }
            index += 1
        }
        return nil
    }
}

func lowercased(_ unit: UInt16) -> UInt16 {
    unit >= 65 && unit <= 90 ? unit + 32 : unit
}

/// Line-level pass that finds fenced code, `$$`/`$$$` math fences, front matter and HTML blocks that run to an end
/// marker, so the pre-pass knows which lines are prose and the incremental parser knows where an open fence closes.
struct LineScanner {
    enum Fence: Equatable {
        case code(character: UInt16, length: Int, indent: Int)
        case math(dollars: Int)
        case frontMatter
        /// An HTML block (CommonMark types 1 to 5) that ends on the line containing `end`.
        case html(end: [UInt16])
    }

    enum LineKind: Equatable {
        case normal
        case blank
        case open(Fence)
        case body(Fence)
        case close(Fence)

        var isOutsideFences: Bool {
            switch self {
            case .normal, .blank: true
            default: false
            }
        }
    }

    let source: Source

    /// Classifies each line, starting with no fence open. `open` is the fence still open after the last line.
    func scan(_ lines: Range<Int>) -> (kinds: [LineKind], open: Fence?) {
        var kinds: [LineKind] = []
        kinds.reserveCapacity(lines.count)
        var open: Fence?
        for line in lines {
            if let fence = open {
                if closes(fence, line: line) {
                    kinds.append(.close(fence))
                    open = nil
                } else {
                    kinds.append(.body(fence))
                }
                continue
            }
            if source.isBlank(line) {
                kinds.append(.blank)
                continue
            }
            if line == 0 && frontMatterEnd() != nil {
                open = .frontMatter
                kinds.append(.open(.frontMatter))
                continue
            }
            if let (fence, after) = opener(line) {
                if case .html(let end) = fence, source.find(end, from: after, to: source.lineEnd(line)) != nil {
                    kinds.append(.normal)
                } else {
                    open = fence
                    kinds.append(.open(fence))
                }
                continue
            }
            kinds.append(.normal)
        }
        return (kinds, open)
    }

    /// The first line at or after `line` that closes the fence, or nil when the text ends first.
    func closingLine(of fence: Fence, from line: Int) -> Int? {
        var current = line
        while current < source.lineCount {
            if closes(fence, line: current) { return current }
            current += 1
        }
        return nil
    }

    /// The closing line of front matter: line 0 is exactly `---` and a later `---` line comes before any blank line.
    func frontMatterEnd() -> Int? {
        guard source.lineCount > 1, lineIsExactly(0, "---") else { return nil }
        for line in 1..<source.lineCount {
            if source.isBlank(line) { return nil }
            if lineIsExactly(line, "---") { return line }
        }
        return nil
    }

    private func lineIsExactly(_ line: Int, _ text: String) -> Bool {
        let target = Array(text.utf16)
        let start = source.lineStart(line)
        let end = source.lineEnd(line)
        return end - start == target.count && source.units[start..<end].elementsEqual(target)
    }

    func closes(_ fence: Fence, line: Int) -> Bool {
        switch fence {
        case .code(let character, let length, _):
            guard source.indent(line) <= 3 else { return false }
            var index = source.firstNonSpace(line)
            let end = source.trimmedEnd(line)
            var run = 0
            while index < end && source.units[index] == character {
                run += 1
                index += 1
            }
            return run >= length && index == end
        case .math(let dollars):
            return source.indent(line) <= 3 && source.trimmedLine(line, equals: String(repeating: "$", count: dollars))
        case .frontMatter:
            return lineIsExactly(line, "---")
        case .html(let end):
            return source.find(end, from: source.lineStart(line), to: source.lineEnd(line)) != nil
        }
    }

    /// The fence a line opens, with the offset just after the opening marker.
    func opener(_ line: Int) -> (Fence, Int)? {
        let indent = source.indent(line)
        guard indent <= 3 else { return nil }
        let units = source.units
        let start = source.firstNonSpace(line)
        let end = source.lineEnd(line)
        guard start < end else { return nil }
        let first = units[start]
        if first == 96 || first == 126 {
            var index = start
            while index < end && units[index] == first { index += 1 }
            let run = index - start
            guard run >= 3 else { return nil }
            if first == 96 && units[index..<end].contains(96) { return nil }
            return (.code(character: first, length: run, indent: indent), index)
        }
        if first == 36 {
            if source.trimmedLine(line, equals: "$$") { return (.math(dollars: 2), end) }
            if source.trimmedLine(line, equals: "$$$") { return (.math(dollars: 3), end) }
            return nil
        }
        guard first == 60 else { return nil }
        func starts(_ text: String) -> Bool {
            let needle = Array(text.utf16)
            return start + needle.count <= end && source.find(needle, from: start, to: start + needle.count) == start
        }
        for tag in ["script", "pre", "style", "textarea"] where starts("<" + tag) {
            let after = start + tag.utf16.count + 1
            if after == end || [32, 9, 62].contains(units[after]) {
                return (.html(end: Array("</\(tag)>".utf16)), after)
            }
        }
        if starts("<!--") { return (.html(end: Array("-->".utf16)), start + 4) }
        if starts("<?") { return (.html(end: Array("?>".utf16)), start + 2) }
        if starts("<![cdata[") { return (.html(end: Array("]]>".utf16)), start + 9) }
        if starts("<!"), start + 2 < end, isASCIILetter(units[start + 2]) {
            return (.html(end: Array(">".utf16)), start + 2)
        }
        return nil
    }
}

func isASCIILetter(_ unit: UInt16) -> Bool {
    (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
}

func isASCIIDigit(_ unit: UInt16) -> Bool {
    unit >= 48 && unit <= 57
}

func isASCIIAlphanumeric(_ unit: UInt16) -> Bool {
    isASCIILetter(unit) || isASCIIDigit(unit)
}

func isASCIIPunctuation(_ unit: UInt16) -> Bool {
    (unit >= 33 && unit <= 47) || (unit >= 58 && unit <= 64) || (unit >= 91 && unit <= 96) || (unit >= 123 && unit <= 126)
}

func isWhitespace(_ unit: UInt16) -> Bool {
    unit == 32 || unit == 9 || unit == 10 || unit == 13
}
