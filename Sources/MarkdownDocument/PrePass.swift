import Foundation

/// Rewrites a run of lines into the text swift-markdown parses, keeping the line count, so the post-pass can map
/// every parsed position back by line. Handles the syntax swift-markdown does not know: front matter, math fences,
/// page breaks, inline math and footnote definitions.
struct PrePass {
    struct Footnote {
        var label: String
        /// Absolute lines, the `[^label]:` line first.
        var lines: Range<Int>
    }

    struct Result {
        var text: String
        var kinds: [LineScanner.LineKind]
        var frontMatter: Range<Int>?
        var footnotes: [Footnote]
        var pageBreakLines: Set<Int>
    }

    static let mathLanguage = "plain-math"
    static let pageBreakComment = "<!--plain-page-break-->"

    static func run(_ source: Source, lines: Range<Int>, kinds: [LineScanner.LineKind]) -> Result {
        var output: [UInt16] = []
        output.reserveCapacity(source.lineStart(lines.upperBound - 1) - source.lineStart(lines.lowerBound) + 64)
        var frontMatter: Range<Int>?
        var footnotes: [Footnote] = []
        var pageBreaks: Set<Int> = []
        var blanked: Set<Int> = []

        if lines.lowerBound == 0, case .open(.frontMatter)? = kinds.first,
           let close = kinds.firstIndex(of: .close(.frontMatter)) {
            frontMatter = 0..<(close + 1)
        }
        for (index, kind) in kinds.enumerated() where kind == .normal {
            let line = lines.lowerBound + index
            guard !blanked.contains(line), let label = footnoteLabel(source, line: line) else { continue }
            let end = footnoteEnd(source, start: line, limit: lines.upperBound, kinds: kinds, firstLine: lines.lowerBound)
            footnotes.append(Footnote(label: label, lines: line..<end))
            for covered in line..<end { blanked.insert(covered) }
        }

        let fenceOpen = Array("```\(mathLanguage)".utf16)
        let fenceClose = Array("```".utf16)
        let pageBreak = Array(pageBreakComment.utf16)
        for (index, kind) in kinds.enumerated() {
            let line = lines.lowerBound + index
            if index > 0 { output.append(10) }
            if frontMatter?.contains(line) == true || blanked.contains(line) { continue }
            let range = source.lineStart(line)..<source.lineEnd(line)
            switch kind {
            case .open(.math):
                output.append(contentsOf: fenceOpen)
            case .close(.math):
                output.append(contentsOf: fenceClose)
            case .normal where isPageBreak(source, line: line):
                pageBreaks.insert(line)
                output.append(contentsOf: pageBreak)
            case .normal:
                var copy = Array(source.units[range])
                replaceInlineMath(&copy)
                output.append(contentsOf: copy)
            default:
                output.append(contentsOf: source.units[range])
            }
        }
        return Result(text: String(decoding: output, as: UTF16.self), kinds: kinds, frontMatter: frontMatter,
                      footnotes: footnotes, pageBreakLines: pageBreaks)
    }

    /// The label of a `[^label]:` line starting at column 0.
    static func footnoteLabel(_ source: Source, line: Int) -> String? {
        let units = source.units
        let start = source.lineStart(line)
        let end = source.lineEnd(line)
        guard end - start >= 5, units[start] == 91, units[start + 1] == 94 else { return nil }
        var index = start + 2
        while index < end && units[index] != 93 { index += 1 }
        guard index > start + 2, index + 1 < end, units[index + 1] == 58 else { return nil }
        return source.string((start + 2)..<index)
    }

    /// One past the definition's last line: following non-blank lines, and blank lines followed by an indented line.
    private static func footnoteEnd(_ source: Source, start: Int, limit: Int, kinds: [LineScanner.LineKind], firstLine: Int) -> Int {
        var end = start + 1
        var line = start + 1
        while line < limit && kinds[line - firstLine].isOutsideFences {
            if source.isBlank(line) {
                var next = line
                while next < limit && source.isBlank(next) { next += 1 }
                guard next < limit, source.indent(next) >= 4 else { break }
                line = next
                continue
            }
            if footnoteLabel(source, line: line) != nil { break }
            line += 1
            end = line
        }
        return end
    }

    /// A line of three or more `+`, spaces allowed between them.
    static func isPageBreak(_ source: Source, line: Int) -> Bool {
        var count = 0
        for index in source.lineStart(line)..<source.lineEnd(line) {
            switch source.units[index] {
            case 43: count += 1
            case 32, 9: continue
            default: return false
            }
        }
        return count >= 3
    }

    /// Turns `$$x$$` into ``` ``x`` ``` and `$x$` into `` `x` `` (same length) outside code spans and escapes,
    /// so swift-markdown parses math as inline code and keeps Markdown inside it literal.
    static func replaceInlineMath(_ line: inout [UInt16]) {
        let count = line.count
        var index = 0
        func isEscaped(_ position: Int) -> Bool {
            var backslashes = 0
            var cursor = position - 1
            while cursor >= 0 && line[cursor] == 92 {
                backslashes += 1
                cursor -= 1
            }
            return backslashes % 2 == 1
        }
        while index < count {
            let unit = line[index]
            if unit == 92 {
                index += 2
                continue
            }
            if unit == 96 {
                var run = 0
                while index + run < count && line[index + run] == 96 { run += 1 }
                var search = index + run
                var closed = false
                while search < count {
                    if line[search] == 96 {
                        var other = 0
                        while search + other < count && line[search + other] == 96 { other += 1 }
                        if other == run {
                            index = search + other
                            closed = true
                            break
                        }
                        search += other
                    } else {
                        search += 1
                    }
                }
                if !closed { index += run }
                continue
            }
            guard unit == 36 else {
                index += 1
                continue
            }
            if index + 1 < count && line[index + 1] == 36 {
                var close = index + 2
                while close + 1 < count && !(line[close] == 36 && line[close + 1] == 36 && !isEscaped(close)) { close += 1 }
                if close + 1 < count && close > index + 2 && !line[(index + 2)..<close].contains(96) {
                    line[index] = 96; line[index + 1] = 96; line[close] = 96; line[close + 1] = 96
                    index = close + 2
                } else {
                    index += 2
                }
                continue
            }
            var close = index + 1
            while close < count && !(line[close] == 36 && !isEscaped(close)) { close += 1 }
            if close < count, close > index + 1, line[index + 1] != 32, line[close - 1] != 32,
               !line[(index + 1)..<close].contains(96) {
                line[index] = 96
                line[close] = 96
                index = close + 1
            } else {
                index += 1
            }
        }
    }
}
