import AppKit
import MarkdownDocument
import PlainCore

/// Markdown the page does not show, and where a caret in it moves to.
struct HiddenRange: Equatable {
    enum Snap {
        /// Positions in [s, e) move to e.
        case forward
        /// Positions in (s, e] move to s.
        case backward
        /// Positions in (s, e) move to e.
        case inner
    }

    enum Kind {
        case blockPrefix, continuationIndent, inlineMarker, tableGap, fenceLine, divider, tableDividerRow, setextUnderline,
             separator, footnoteReference

        /// Kinds that cover a whole line and a line break.
        var isWholeLine: Bool {
            switch self {
            case .fenceLine, .divider, .tableDividerRow, .setextUnderline, .separator: return true
            default: return false
            }
        }
    }

    var range: NSRange
    var snap: Snap
    var kind: Kind
    /// What Copy writes in place of the range.
    var copyAs: String

    /// Where this range's rule moves a caret at `p`; nil when the rule leaves it alone.
    func target(of p: Int) -> Int? {
        let s = range.location, e = NSMaxRange(range)
        switch snap {
        case .forward: return p >= s && p < e ? e : nil
        case .backward: return p > s && p <= e ? s : nil
        case .inner: return p > s && p < e ? e : nil
        }
    }

    /// True when `p` lies strictly inside the range.
    func strictlyContains(_ p: Int) -> Bool { range.location < p && p < NSMaxRange(range) }
}

/// The hidden ranges of a snapshot, and the caret rules built on them (docs/wysiwyg-spec.md).
@MainActor
enum HiddenRanges {
    /// Hidden ranges, sorted, for the blocks meeting `range` and the separator lines in it. A setext underline is not
    /// hidden while `caret` lies on it.
    static func list(in range: NSRange, snapshot: Snapshot, text: NSString, columnWidth: CGFloat, caret: Int?) -> [HiddenRange] {
        var builder = Builder(snapshot: snapshot, text: text, columnWidth: columnWidth, caret: caret, window: range)
        var index = MarkdownStyler.firstBlockIndex(at: range.location, in: snapshot.blocks)
        while index < snapshot.blocks.count, snapshot.blocks[index].range.location <= NSMaxRange(range) {
            builder.visit(snapshot.blocks[index], listDepth: 0)
            index += 1
        }
        builder.addSeparators()
        return tidy(builder.result)
    }

    /// Sorted by location; empty ranges and ranges lying inside another range are dropped.
    private static func tidy(_ ranges: [HiddenRange]) -> [HiddenRange] {
        let sorted = ranges.filter { $0.range.length > 0 }.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
        var result: [HiddenRange] = []
        var coveredTo = -1
        for hidden in sorted {
            if NSMaxRange(hidden.range) <= coveredTo, let last = result.last, last.range.location <= hidden.range.location { continue }
            result.append(hidden)
            coveredTo = max(coveredTo, NSMaxRange(hidden.range))
        }
        return result
    }

    @MainActor
    private struct Builder {
        let snapshot: Snapshot
        let text: NSString
        let columnWidth: CGFloat
        let caret: Int?
        let window: NSRange
        var result: [HiddenRange] = []

        init(snapshot: Snapshot, text: NSString, columnWidth: CGFloat, caret: Int?, window: NSRange) {
            self.snapshot = snapshot
            self.text = text
            self.columnWidth = columnWidth
            self.caret = caret
            self.window = window
        }

        mutating func add(_ range: NSRange, _ snap: HiddenRange.Snap, _ kind: HiddenRange.Kind, _ copyAs: String = "") {
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= text.length else { return }
            result.append(HiddenRange(range: range, snap: snap, kind: kind, copyAs: copyAs))
        }

        func lineContents(at offset: Int) -> NSRange { HiddenRanges.lineContents(at: offset, in: text) }

        /// The offset after the spaces and tabs starting at `offset`.
        func skipSpaces(_ offset: Int) -> Int {
            var index = offset
            while index < text.length, text.character(at: index) == 32 || text.character(at: index) == 9 { index += 1 }
            return index
        }

        mutating func visit(_ block: Block, listDepth: Int) {
            switch block.kind {
            case .paragraph:
                inlines(block.inlines, imageOnly: HiddenRanges.isImageOnly(block, text: text))
            case .atxHeading:
                let markers = block.markerRanges
                if let open = markers.first {
                    add(NSRange(location: open.location, length: skipSpaces(NSMaxRange(open)) - open.location), .forward, .blockPrefix)
                }
                for marker in markers.dropFirst() where marker.length > 0 && text.character(at: marker.location) == 35 {
                    var start = marker.location
                    while start > 0, text.character(at: start - 1) == 32 || text.character(at: start - 1) == 9 { start -= 1 }
                    add(NSRange(location: start, length: NSMaxRange(marker) - start), .backward, .inlineMarker)
                }
                inlines(block.inlines, imageOnly: false)
            case .setextHeading:
                guard let underline = block.markerRanges.first else { return }
                let line = lineContents(at: underline.location)
                if let caret, caret >= line.location, caret <= NSMaxRange(line) { return }
                add(NSRange(location: line.location - 1, length: NSMaxRange(line) - line.location + 1), .backward, .setextUnderline)
                inlines(block.inlines, imageOnly: false)
            case .blockQuote:
                for marker in block.markerRanges {
                    let line = lineContents(at: marker.location)
                    var start = marker.location
                    let before = text.substring(with: NSRange(location: line.location, length: marker.location - line.location))
                    if before.allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) { start = line.location }
                    var end = NSMaxRange(marker)
                    if end < NSMaxRange(line), text.character(at: end) == 32 { end += 1 }
                    add(NSRange(location: start, length: end - start), .forward, .blockPrefix)
                }
                for child in block.children { visit(child, listDepth: listDepth) }
            case .bulletList, .orderedList:
                var ordered = false
                if case .orderedList = block.kind { ordered = true }
                for child in block.children { visitItem(child, listDepth: listDepth, ordered: ordered) }
            case .listItem:
                visitItem(block, listDepth: listDepth, ordered: false)
            case .table:
                table(block)
            case .fencedCode:
                fencedCode(block)
            case .thematicBreak:
                let line = lineContents(at: block.range.location)
                if NSMaxRange(line) < text.length {
                    add(NSRange(location: line.location, length: line.length + 1), .forward, .divider)
                } else {
                    let start = max(line.location - 1, 0)
                    add(NSRange(location: start, length: NSMaxRange(line) - start), .backward, .divider)
                }
            case .footnoteDefinition(let label):
                if let number = snapshot.footnotes.order.firstIndex(of: label).map({ $0 + 1 }), let marker = block.markerRanges.first {
                    add(NSRange(location: marker.location, length: skipSpaces(NSMaxRange(marker)) - marker.location), .forward, .blockPrefix,
                        "\(number). ")
                }
                for child in block.children { visit(child, listDepth: 0) }
            default:
                break
            }
        }

        mutating func visitItem(_ item: Block, listDepth: Int, ordered: Bool) {
            guard case .listItem(let task, let checked) = item.kind else { return visit(item, listDepth: listDepth) }
            listItem(item, depth: listDepth, task: task == true, checked: checked, ordered: ordered)
            for child in item.children {
                switch child.kind {
                case .bulletList, .orderedList: visit(child, listDepth: listDepth + 1)
                default: visit(child, listDepth: listDepth)
                }
            }
        }

        mutating func listItem(_ item: Block, depth: Int, task: Bool, checked: Bool, ordered: Bool) {
            let markers = item.markerRanges
            guard let marker = markers.first else { return }
            let line = lineContents(at: marker.location)
            var end = skipSpaces(NSMaxRange(marker))
            if task, markers.count > 1 { end = skipSpaces(NSMaxRange(markers[1])) }
            end = min(end, NSMaxRange(line))
            let symbol: String
            if task {
                symbol = checked ? "☑ " : "☐ "
            } else if ordered {
                symbol = text.substring(with: marker).trimmingCharacters(in: .whitespaces) + " "
            } else {
                symbol = "• "
            }
            add(NSRange(location: line.location, length: end - line.location), .forward, .blockPrefix,
                String(repeating: "\t", count: depth) + symbol)
            // Leading spaces of the item's other lines, outside its nested lists.
            let nested = item.children.filter {
                switch $0.kind {
                case .bulletList, .orderedList: return true
                default: return false
                }
            }.map(\.range)
            var location = NSMaxRange(line) + 1
            while location <= NSMaxRange(item.range), location < text.length {
                let other = lineContents(at: location)
                let inNested = nested.contains { NSLocationInRange(other.location, $0) || (other.location <= $0.location && $0.location <= NSMaxRange(other)) }
                if !inNested {
                    add(NSRange(location: other.location, length: skipSpaces(other.location) - other.location), .forward, .continuationIndent)
                }
                location = NSMaxRange(other) + 1
            }
        }

        mutating func table(_ block: Block) {
            let columns = HiddenRanges.tableColumns(table: block, text: text, columnWidth: columnWidth)
            guard !columns.wide else { return }
            var location = block.range.location
            for index in 0..<block.lineRange.count {
                guard location <= text.length else { break }
                let line = lineContents(at: location)
                defer { location = NSMaxRange(line) + 1 }
                let full = NSRange(location: line.location, length: min(line.length + 1, text.length - line.location))
                guard full.location <= NSMaxRange(window), NSMaxRange(full) >= window.location else { continue }
                if index == 1 {
                    add(full, .forward, .tableDividerRow)
                    continue
                }
                let cells = HiddenRanges.cells(of: line, in: text)
                guard let first = cells.first, let last = cells.last else { continue }
                add(NSRange(location: line.location, length: first.location - line.location), .forward, .tableGap)
                for (previous, cell) in zip(cells, cells.dropFirst()) {
                    add(NSRange(location: NSMaxRange(previous), length: cell.location - NSMaxRange(previous)), .inner, .tableGap, "\t")
                }
                add(NSRange(location: NSMaxRange(last), length: NSMaxRange(line) - NSMaxRange(last)), .backward, .tableGap)
            }
        }

        mutating func fencedCode(_ block: Block) {
            let markers = block.markerRanges
            guard let open = markers.first else { return }
            let closed = markers.count >= 2
            guard block.lineRange.count - 1 - (closed ? 1 : 0) >= 1 else { return }
            add(text.lineRange(for: NSRange(location: open.location, length: 0)), .forward, .fenceLine)
            if closed {
                let close = lineContents(at: markers[1].location)
                add(NSRange(location: close.location - 1, length: close.length + 1), .backward, .fenceLine)
            }
        }

        mutating func inlines(_ list: [Inline], imageOnly: Bool) {
            for inline in list {
                switch inline.kind {
                case .emphasis, .strong, .strike, .highlight, .code, .link, .referenceLink, .autolink, .escape, .lineBreak:
                    hideMarkers(of: inline)
                case .image, .referenceImage:
                    if !imageOnly { hideMarkers(of: inline) }
                case .footnoteReference:
                    if let number = snapshot.footnotes.references[inline.range.location]?.number {
                        add(inline.range, .inner, .footnoteReference, "\(number)")
                    }
                    continue
                default:
                    break
                }
                inlines(inline.children, imageOnly: imageOnly)
            }
        }

        mutating func hideMarkers(of inline: Inline) {
            for marker in inline.markerRanges where marker.length > 0 {
                add(marker, marker.location == inline.range.location ? .backward : .forward, .inlineMarker)
            }
        }

        /// The line break of each blank line that ends a run of blank lines between two non-blank lines, outside
        /// fenced code, maths, front matter and HTML blocks.
        mutating func addSeparators() {
            let length = text.length
            guard length > 0 else { return }
            // One pass over the lines in order. The window's characters, through the line after its last one, are
            // read once; one moving index over the ranges sorted by start, with the furthest end seen so far, tells
            // whether a line meets any of them.
            let existing = result.sorted { $0.range.location < $1.range.location }
            var next = 0
            var furthestEnd = -1
            let start = lineContents(at: min(window.location, length)).location
            let end = min(NSMaxRange(window), length)
            let lastLine = text.lineRange(for: NSRange(location: end, length: 0))
            let bufferEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(NSMaxRange(lastLine), length), length: 0)))
            var chars = [unichar](repeating: 0, count: bufferEnd - start)
            text.getCharacters(&chars, range: NSRange(location: start, length: bufferEnd - start))
            func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x85 || c == 0x2028 || c == 0x2029 }
            /// The end of the line contents starting at `from`, and whether they hold only spaces and tabs.
            func scanLine(_ from: Int) -> (contentsEnd: Int, blank: Bool) {
                var index = from, blank = true
                while index < bufferEnd, !isBreak(chars[index - start]) {
                    if chars[index - start] != 32 && chars[index - start] != 9 { blank = false }
                    index += 1
                }
                return (index, blank)
            }
            // Whether a line that is not blank lies above the first line.
            var textAbove = false
            var back = start - 1
            while back >= 0 {
                let c = text.character(at: back)
                if c != 32 && c != 9 && !isBreak(c) { textAbove = true; break }
                back -= 1
            }
            var location = start
            while location <= end {
                let line = scanLine(location)
                guard line.contentsEnd < length else { break }
                var lineEnd = line.contentsEnd + 1
                if chars[line.contentsEnd - start] == 13, lineEnd < bufferEnd, chars[lineEnd - start] == 10 { lineEnd += 1 }
                defer {
                    if !line.blank { textAbove = true }
                    location = lineEnd
                }
                guard line.blank, textAbove, !scanLine(lineEnd).blank else { continue }
                switch snapshot.deepestBlock(at: location)?.kind {
                case .fencedCode?, .mathBlock?, .frontMatter?, .htmlBlock?, .htmlComment?: continue
                default: break
                }
                let range = NSRange(location: location, length: line.contentsEnd - location + 1)
                while next < existing.count, existing[next].range.location < NSMaxRange(range) {
                    furthestEnd = max(furthestEnd, NSMaxRange(existing[next].range))
                    next += 1
                }
                if furthestEnd > range.location { continue }
                add(range, .forward, .separator, "\n")
            }
        }
    }

    // MARK: Helpers

    static func lineContents(at offset: Int, in text: NSString) -> NSRange {
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(max(offset, 0), text.length), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// A paragraph holding nothing but one image on one line.
    static func isImageOnly(_ block: Block, text: NSString) -> Bool {
        guard block.kind == .paragraph, block.lineRange.count == 1, block.inlines.count == 1 else { return false }
        let inline = block.inlines[0]
        switch inline.kind {
        case .image, .referenceImage: break
        default: return false
        }
        let line = lineContents(at: block.range.location, in: text)
        return text.substring(with: line).trimmingCharacters(in: .whitespaces) == text.substring(with: inline.range)
    }

    /// Cell text ranges of a table row, padding spaces left out; an empty cell is an empty range one space into its slot.
    static func cells(of line: NSRange, in text: NSString) -> [NSRange] {
        var slots: [NSRange] = []
        var start = line.location
        var index = line.location
        let end = NSMaxRange(line)
        while index < end {
            let c = text.character(at: index)
            if c == 92 { index += 2; continue }
            if c == 124 {
                slots.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        slots.append(NSRange(location: start, length: max(end - start, 0)))
        let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !slots.isEmpty { slots.removeFirst() }
        if trimmed.hasSuffix("|"), trimmed.count > 1, !slots.isEmpty { slots.removeLast() }
        return slots.map { slot in
            var s = slot.location, e = NSMaxRange(slot)
            while s < e, text.character(at: s) == 32 { s += 1 }
            while e > s, text.character(at: e - 1) == 32 { e -= 1 }
            if s == e { return NSRange(location: slot.location + min(1, slot.length), length: 0) }
            return NSRange(location: s, length: e - s)
        }
    }

    /// Column edges by table text and column width.
    private static var columnCache: [String: (edges: [CGFloat], wide: Bool)] = [:]

    /// Column edges of a table on the page, from 0 at the column's left. Each column is as wide as its widest cell
    /// text (14 pt, header bold) plus 10 pt padding each side; when they fit, the last column takes what is left.
    static func tableColumns(table: Block, text: NSString, columnWidth: CGFloat) -> (edges: [CGFloat], wide: Bool) {
        let key = "\(columnWidth)|" + text.substring(with: NSRange(location: table.range.location, length: min(table.range.length, max(text.length - table.range.location, 0))))
        if let cached = columnCache[key] { return cached }
        let page = Tokens.page
        let regular = NSFont.systemFont(ofSize: page.cellTextSize)
        let bold = NSFont.boldSystemFont(ofSize: page.cellTextSize)
        var widths: [CGFloat] = []
        var location = table.range.location
        for index in 0..<table.lineRange.count {
            guard location <= text.length else { break }
            let line = lineContents(at: location, in: text)
            location = NSMaxRange(line) + 1
            if index == 1 { continue }
            for (column, cell) in cells(of: line, in: text).enumerated() {
                let width = NSAttributedString(string: text.substring(with: cell), attributes: [.font: index == 0 ? bold : regular]).size().width
                    + 2 * page.cellPadH
                if column < widths.count { widths[column] = max(widths[column], ceil(width)) } else { widths.append(ceil(width)) }
            }
        }
        var edges: [CGFloat] = [0]
        for width in widths { edges.append(edges.last! + width) }
        let wide = edges.last! > columnWidth
        if !wide, edges.count > 1 { edges[edges.count - 1] = columnWidth }
        if columnCache.count > 200 { columnCache.removeAll() }
        columnCache[key] = (edges, wide)
        return (edges, wide)
    }

    // MARK: Caret rules

    static func isValidCaret(_ p: Int, ranges: [HiddenRange]) -> Bool { !ranges.contains { $0.target(of: p) != nil } }

    static func isValidEnd(_ p: Int, ranges: [HiddenRange]) -> Bool { !ranges.contains { $0.strictlyContains(p) } }

    /// The position a caret (`isEnd` false) or a selection end (`isEnd` true) at `p` moves to.
    static func snap(_ p: Int, ranges: [HiddenRange], isEnd: Bool) -> Int {
        var q = p
        for _ in 0..<64 {
            if isEnd {
                guard let hidden = ranges.first(where: { $0.strictlyContains(q) }) else { return q }
                q = hidden.snap == .backward ? hidden.range.location : NSMaxRange(hidden.range)
            } else {
                guard let target = ranges.lazy.compactMap({ $0.target(of: q) }).first else { return q }
                q = target
            }
        }
        return q
    }

    /// True when a character between `a` and `b` is shown; a table gap between two cells counts as one.
    static func hasVisible(between a: Int, and b: Int, ranges: [HiddenRange]) -> Bool {
        let low = min(a, b), high = max(a, b)
        guard low < high else { return false }
        for index in low..<high where !ranges.contains(where: { NSLocationInRange(index, $0.range) }) { return true }
        return ranges.contains { $0.kind == .tableGap && $0.snap == .inner && $0.range.location >= low && NSMaxRange($0.range) <= high }
    }

    /// From `p`, where NSTextView's own move from `start` landed, moves on one composed character at a time in
    /// `direction` until a shown character lies between `start` and the position and the position is valid. Returns
    /// `start` when the text ends first.
    static func step(from start: Int, to p: Int, direction: Int, ranges: [HiddenRange], isEnd: Bool, text: NSString) -> Int {
        var q = min(max(p, 0), text.length)
        while true {
            let valid = isEnd ? isValidEnd(q, ranges: ranges) : isValidCaret(q, ranges: ranges)
            if valid, hasVisible(between: start, and: q, ranges: ranges) { return q }
            if direction > 0 {
                guard q < text.length else { return start }
                q = NSMaxRange(text.rangeOfComposedCharacterSequence(at: q))
            } else {
                guard q > 0 else { return start }
                q = text.rangeOfComposedCharacterSequence(at: q - 1).location
            }
        }
    }
}

// MARK: - Snapping the page's carets and selections

extension EditorTextView {
    /// Hidden ranges for the lines around `range` on the page; nil in the source view or while a parse is pending.
    func pageHiddenRanges(around range: NSRange) -> [HiddenRange]? {
        guard isPage, let snapshot, document.textStorage.editedMask.isEmpty, snapshot.text.utf16.count == nsText.length else { return nil }
        let text = nsText
        var start = min(range.location, text.length), end = min(NSMaxRange(range), text.length)
        for _ in 0..<2 {
            if start > 0 { start = HiddenRanges.lineContents(at: start - 1, in: text).location }
            if end < text.length { end = NSMaxRange(HiddenRanges.lineContents(at: end + 1, in: text)) }
        }
        start = HiddenRanges.lineContents(at: start, in: text).location
        end = NSMaxRange(HiddenRanges.lineContents(at: end, in: text))
        return HiddenRanges.list(in: NSRange(location: start, length: end - start), snapshot: snapshot, text: text,
                                 columnWidth: styler.pageColumnWidth, caret: styler.pageCaret)
    }

    /// The page's version of a selection NSTextView is about to set, from the main selection before the change.
    func pageAdjusted(_ new: NSRange, previous: NSRange) -> NSRange {
        // Only the ends move, so each is snapped with the hidden ranges around it alone; listing the whole span
        // would read every hidden range in the file for a Select All.
        func snapped(_ p: Int, isEnd: Bool) -> Int {
            var point = p
            for _ in 0..<8 {
                guard let ranges = pageHiddenRanges(around: NSRange(location: point, length: 0)) else { return point }
                let next = HiddenRanges.snap(point, ranges: ranges, isEnd: isEnd)
                if next == point { return point }
                point = next
            }
            return point
        }
        guard let move = pageMove else {
            if new.length == 0 {
                if new.location == allowedCaret { return new }
                return NSRange(location: snapped(new.location, isEnd: false), length: 0)
            }
            let start = snapped(new.location, isEnd: true)
            let end = snapped(NSMaxRange(new), isEnd: true)
            return NSRange(location: min(start, end), length: abs(end - start))
        }
        let text = nsText
        // Which end moved, where it was, and the end that stayed.
        let moved: (from: Int, to: Int, anchor: Int?)
        if new.length == 0 {
            let from = previous.length == 0 ? previous.location : (new.location == previous.location ? NSMaxRange(previous) : previous.location)
            moved = (from, new.location, nil)
        } else if new.location == previous.location, NSMaxRange(new) != NSMaxRange(previous) {
            moved = (NSMaxRange(previous), NSMaxRange(new), new.location)
        } else if NSMaxRange(new) == NSMaxRange(previous), new.location != previous.location {
            moved = (previous.location, new.location, NSMaxRange(new))
        } else {
            let start = snapped(new.location, isEnd: true)
            let end = snapped(NSMaxRange(new), isEnd: true)
            return NSRange(location: min(start, end), length: abs(end - start))
        }
        let span = NSUnionRange(NSRange(location: moved.from, length: 0), NSRange(location: moved.to, length: 0))
        guard let ranges = pageHiddenRanges(around: span) else { return new }
        let isEnd = moved.anchor != nil
        var position: Int
        if move.vertical {
            position = pageVertical(from: moved.from, to: moved.to, direction: move.direction)
            position = HiddenRanges.snap(position, ranges: pageHiddenRanges(around: NSRange(location: position, length: 0)) ?? ranges, isEnd: isEnd)
        } else {
            position = HiddenRanges.step(from: moved.from, to: moved.to, direction: move.direction, ranges: ranges, isEnd: isEnd, text: text)
        }
        guard let start = moved.anchor else { return NSRange(location: position, length: 0) }
        let anchorRanges = pageHiddenRanges(around: NSRange(location: start, length: 0)) ?? ranges
        let anchor = HiddenRanges.snap(start, ranges: anchorRanges, isEnd: true)
        let result = NSRange(location: min(anchor, position), length: abs(position - anchor))
        // A selection holding nothing shown collapses to its anchor. The check is exact only within the lines listed
        // around the moved end and the anchor; a selection reaching beyond them counts as holding shown text.
        if result.length > 0, !HiddenRanges.hasVisible(between: result.location, and: NSMaxRange(result), ranges: ranges + anchorRanges) {
            return NSRange(location: anchor, length: 0)
        }
        return result
    }

    /// Up or Down on the page: while `moved` lies in a hidden whole line, takes the position at the previous caret's x
    /// on the line above (Up) or below (Down) that hidden line; keeps `previous` when there is no such line.
    func pageVertical(from previous: Int, to moved: Int, direction: Int) -> Int {
        let text = nsText
        let x = rect(forCharacterRange: NSRange(location: previous, length: 0)).minX
        var position = moved
        for _ in 0..<32 {
            guard let ranges = pageHiddenRanges(around: NSRange(location: position, length: 0)),
                  let hidden = ranges.first(where: { $0.kind.isWholeLine && $0.target(of: position) != nil }) else { return position }
            let line = HiddenRanges.lineContents(at: hidden.snap == .backward ? NSMaxRange(hidden.range) : hidden.range.location, in: text)
            let y: CGFloat
            if direction < 0 {
                guard line.location > 0 else { return previous }
                let above = HiddenRanges.lineContents(at: line.location - 1, in: text)
                y = rect(forCharacterRange: NSRange(location: NSMaxRange(above), length: 0)).midY
            } else {
                guard NSMaxRange(line) < text.length else { return previous }
                let below = HiddenRanges.lineContents(at: NSMaxRange(line) + 1, in: text)
                y = rect(forCharacterRange: NSRange(location: below.location, length: 0)).midY
            }
            position = characterIndexForInsertion(at: NSPoint(x: x, y: y))
        }
        return position
    }

    /// Typing attributes from the first shown character at or after the caret on its line, else the page's base ones.
    func pageTypingAttributes() {
        guard isPage, let offset = caret, let ranges = pageHiddenRanges(around: NSRange(location: offset, length: 0)) else { return }
        let line = lineContents(at: offset)
        var index = offset
        while index < NSMaxRange(line) {
            if !ranges.contains(where: { NSLocationInRange(index, $0.range) }) {
                var attributes = document.textStorage.attributes(at: index, effectiveRange: nil)
                for key in [NSAttributedString.Key.plainPageMarker, .plainPageFootnote, .plainPageChip, .kern, .toolTip] { attributes.removeValue(forKey: key) }
                typingAttributes = attributes
                return
            }
            index += 1
        }
        typingAttributes = styler.baseAttributes
    }

    private func pageMoving(_ direction: Int, vertical: Bool, _ body: () -> Void) {
        let saved = pageMove
        pageMove = (direction, vertical)
        defer { pageMove = saved }
        body()
    }

    public override func moveWordLeft(_ sender: Any?) { pageMoving(-1, vertical: false) { super.moveWordLeft(sender) } }
    public override func moveWordRight(_ sender: Any?) { pageMoving(1, vertical: false) { super.moveWordRight(sender) } }
    public override func moveWordBackward(_ sender: Any?) { pageMoving(-1, vertical: false) { super.moveWordBackward(sender) } }
    public override func moveWordForward(_ sender: Any?) { pageMoving(1, vertical: false) { super.moveWordForward(sender) } }
    public override func moveLeftAndModifySelection(_ sender: Any?) {
        pageMoving(-1, vertical: false) { super.moveLeftAndModifySelection(sender) }
    }
    public override func moveRightAndModifySelection(_ sender: Any?) {
        pageMoving(1, vertical: false) { super.moveRightAndModifySelection(sender) }
    }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) {
        pageMoving(-1, vertical: false) { super.moveWordLeftAndModifySelection(sender) }
    }
    public override func moveWordRightAndModifySelection(_ sender: Any?) {
        pageMoving(1, vertical: false) { super.moveWordRightAndModifySelection(sender) }
    }
    public override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        pageMoving(-1, vertical: false) { super.moveWordBackwardAndModifySelection(sender) }
    }
    public override func moveWordForwardAndModifySelection(_ sender: Any?) {
        pageMoving(1, vertical: false) { super.moveWordForwardAndModifySelection(sender) }
    }
    public override func moveUpAndModifySelection(_ sender: Any?) { pageMoving(-1, vertical: true) { super.moveUpAndModifySelection(sender) } }
    public override func moveDownAndModifySelection(_ sender: Any?) { pageMoving(1, vertical: true) { super.moveDownAndModifySelection(sender) } }
}
