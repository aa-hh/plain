import AppKit
import MarkdownDocument

/// The page's text as a reader sees it: what Copy writes as plain text and what Find searches.
@MainActor
enum VisibleText {
    static func plain(text: NSString, snapshot: Snapshot, range: NSRange, columnWidth: CGFloat) -> String {
        map(text: text, snapshot: snapshot, range: range, columnWidth: columnWidth).string
    }

    /// The visible text of `range` and, per UTF-16 unit of it, the source offset it came from (a replacement maps to
    /// the location of what it replaced), plus one entry for the end.
    static func map(text: NSString, snapshot: Snapshot, range: NSRange, columnWidth: CGFloat) -> (string: String, offsets: [Int]) {
        let list = edits(text: text, snapshot: snapshot, range: range, columnWidth: columnWidth, forFind: false)
        let (units, offsets) = render(text: text, range: range, edits: list, replacementsAsBreaks: false)
        return (String(utf16CodeUnits: units, count: units.count), offsets)
    }

    /// What page Find searches: the text of `map`, except that every replacement is one line break, so no match runs
    /// across a table gap, a footnote reference or a list prefix, and maths source and front matter colons and list
    /// brackets, which the page draws clear, are line breaks too.
    static func searchable(text: NSString, snapshot: Snapshot, range: NSRange, columnWidth: CGFloat) -> (string: NSString, offsets: [Int]) {
        let list = edits(text: text, snapshot: snapshot, range: range, columnWidth: columnWidth, forFind: true)
        let (units, offsets) = render(text: text, range: range, edits: list, replacementsAsBreaks: true)
        return (NSString(characters: units, length: units.count), offsets)
    }

    /// The replacements over `range`, sorted by location. With `forFind`, a maths block is one replacement over its
    /// whole range instead of losing its fence lines, and each front matter marker after the two fence lines is one
    /// replacement too.
    private static func edits(text: NSString, snapshot: Snapshot, range: NSRange, columnWidth: CGFloat,
                              forFind: Bool) -> [(range: NSRange, text: String)] {
        let hiddenRanges = HiddenRanges.list(in: range, snapshot: snapshot, text: text, columnWidth: columnWidth, caret: nil)
        var edits: [(range: NSRange, text: String)] = []
        edits.reserveCapacity(hiddenRanges.count)
        for hidden in hiddenRanges {
            let part = NSIntersectionRange(hidden.range, range)
            guard part.length > 0 else { continue }
            edits.append((part, part.length == hidden.range.length ? hidden.copyAs : ""))
        }
        // Edits for front matter, maths and image lines, clipped to `range`; the hidden ones above already are.
        var blockEdits: [(range: NSRange, text: String)] = []
        for block in blocksMeeting(range, in: snapshot) {
            if forFind, block.kind == .mathBlock {
                blockEdits.append((block.range, "\n"))
                continue
            }
            if forFind, block.kind == .frontMatter {
                blockEdits += block.markerRanges.dropFirst(2).map { ($0, "\n") }
            }
            switch block.kind {
            case .frontMatter, .mathBlock:
                let first = HiddenRanges.lineContents(at: block.range.location, in: text)
                let last = HiddenRanges.lineContents(at: NSMaxRange(block.range), in: text)
                guard last.location > first.location else { continue }
                if NSMaxRange(first) < text.length { blockEdits.append((NSRange(location: first.location, length: first.length + 1), "")) }
                let closing = text.substring(with: last).trimmingCharacters(in: .whitespaces)
                if block.kind == .frontMatter ? closing == "---" || closing == "..." : closing.allSatisfy({ $0 == "$" }) && closing.count >= 2 {
                    blockEdits.append((NSRange(location: last.location - 1, length: last.length + 1), ""))
                }
            case .paragraph where HiddenRanges.isImageOnly(block, text: text):
                let inline = block.inlines[0]
                let alt: String
                if case .image(_, let text) = inline.kind { alt = text } else { alt = text.substring(with: inline.contentRange) }
                blockEdits.append((inline.range, alt))
            default:
                break
            }
        }
        edits += blockEdits.map { (NSIntersectionRange($0.range, range), $0.text) }.filter { $0.range.length > 0 || !$0.text.isEmpty }
        edits.sort { $0.range.location < $1.range.location }
        return edits
    }

    /// Shown runs of `range` with their offsets, and each edit's text at the edit's location; with
    /// `replacementsAsBreaks`, an edit with any text gives one line break instead.
    private static func render(text: NSString, range: NSRange, edits: [(range: NSRange, text: String)],
                               replacementsAsBreaks: Bool) -> (units: [unichar], offsets: [Int]) {
        // The range's characters are read once; shown runs are copied from them in one go.
        var source = [unichar](repeating: 0, count: range.length)
        text.getCharacters(&source, range: range)
        var units: [unichar] = []
        var offsets: [Int] = []
        units.reserveCapacity(range.length + 1)
        offsets.reserveCapacity(range.length + 1)
        var cursor = range.location
        func copy(upTo end: Int) {
            guard cursor < end else { return }
            units.append(contentsOf: source[(cursor - range.location)..<(end - range.location)])
            offsets.append(contentsOf: cursor..<end)
            cursor = end
        }
        for edit in edits where edit.range.location >= cursor {
            copy(upTo: edit.range.location)
            if replacementsAsBreaks {
                if !edit.text.isEmpty {
                    units.append(10)
                    offsets.append(edit.range.location)
                }
            } else {
                for unit in edit.text.utf16 {
                    units.append(unit)
                    offsets.append(edit.range.location)
                }
            }
            cursor = NSMaxRange(edit.range)
        }
        copy(upTo: NSMaxRange(range))
        offsets.append(NSMaxRange(range))
        return (units, offsets)
    }

    /// Every block, nested ones included, that meets `range`.
    static func blocksMeeting(_ range: NSRange, in snapshot: Snapshot) -> [Block] {
        var result: [Block] = []
        func visit(_ block: Block) {
            guard block.range.location <= NSMaxRange(range), NSMaxRange(block.range) >= range.location else { return }
            result.append(block)
            block.children.forEach(visit)
        }
        var index = MarkdownStyler.firstBlockIndex(at: range.location, in: snapshot.blocks)
        while index < snapshot.blocks.count, snapshot.blocks[index].range.location <= NSMaxRange(range) {
            visit(snapshot.blocks[index])
            index += 1
        }
        return result
    }
}
