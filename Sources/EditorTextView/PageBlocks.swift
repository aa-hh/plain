import AppKit
import MarkdownDocument

/// The kinds of block the page offers: what the `/` menu inserts and what "Turn into" converts between.
enum PageBlockKind: Equatable {
    case text, heading(Int), bulleted, numbered, task(checked: Bool), quote, code, table, divider, image, maths

    var title: String {
        switch self {
        case .text: return "Text"
        case .heading(let level): return "Heading \(level)"
        case .bulleted: return "Bulleted list"
        case .numbered: return "Numbered list"
        case .task: return "Task list"
        case .quote: return "Quote"
        case .code: return "Code"
        case .table: return "Table"
        case .divider: return "Divider"
        case .image: return "Image"
        case .maths: return "Maths"
        }
    }

    /// The Lucide icon name.
    var icon: String {
        switch self {
        case .text: return "type"
        case .heading(let level): return "heading-\(min(max(level, 1), 6))"
        case .bulleted: return "list"
        case .numbered: return "list-ordered"
        case .task: return "list-todo"
        case .quote: return "quote"
        case .code: return "square-code"
        case .table: return "table"
        case .divider: return "minus"
        case .image: return "image"
        case .maths: return "sigma"
        }
    }

    var slashDescription: String {
        switch self {
        case .text: return "A plain paragraph"
        case .heading(1): return "The largest heading"
        case .heading(2): return "A section heading"
        case .heading: return "A subsection heading"
        case .bulleted: return "Points marked with dots"
        case .numbered: return "Steps counted 1, 2, 3"
        case .task: return "Items you can tick off"
        case .quote: return "Text set off with a bar"
        case .code: return "Code with syntax colours"
        case .table: return "Rows and columns"
        case .divider: return "A line between sections"
        case .image: return "A picture from a file"
        case .maths: return "A formula written in TeX"
        }
    }

    static let turnIntoKinds: [PageBlockKind] = [.text, .heading(1), .heading(2), .heading(3), .bulleted, .numbered, .task(checked: false), .quote, .code]
    static let slashKinds: [PageBlockKind] = turnIntoKinds + [.table, .divider, .image, .maths]

    var isItem: Bool {
        switch self {
        case .bulleted, .numbered, .task: return true
        default: return false
        }
    }
}

/// One block on the page. `range` is the block's own whole lines without the trailing line break (for a list item,
/// up to the line before its first nested list); `fullRange` includes nested items.
struct PageBlock: Equatable {
    var range: NSRange
    var fullRange: NSRange
    var kind: PageBlockKind
    var depth: Int
    /// The snapshot block's markers: a heading's `#` run or setext underline, an item's marker then its task box,
    /// a quote's `>` per line.
    var markerRanges: [NSRange]

    var isItem: Bool { kind.isItem }
}

/// The page's blocks and the edits the editing tools make to them, as pure functions of the text and a snapshot.
@MainActor
enum PageBlocks {
    // MARK: Reading

    /// Top-level paragraphs, headings, quotes, fenced code, tables, dividers and maths, and every list item at every
    /// depth, in text order.
    static func blocks(in snapshot: Snapshot, text: NSString) -> [PageBlock] {
        snapshot.blocks.flatMap { pageBlocks(of: $0, text: text) }
    }

    /// The block whose `range` holds `offset`; the deepest item wins.
    static func block(at offset: Int, snapshot: Snapshot, text: NSString) -> PageBlock? {
        guard let top = snapshot.block(at: offset) else { return nil }
        return pageBlocks(of: top, text: text).last { $0.range.location <= offset && offset <= NSMaxRange($0.range) }
    }

    /// Whole lines from the line holding `start` to the end of the line holding `end`, without the last line break.
    static func wholeLines(_ start: Int, _ end: Int, text: NSString) -> NSRange {
        let first = HiddenRanges.lineContents(at: start, in: text)
        let last = HiddenRanges.lineContents(at: end, in: text)
        return NSRange(location: first.location, length: max(NSMaxRange(last) - first.location, 0))
    }

    private static func pageBlocks(of block: Block, text: NSString) -> [PageBlock] {
        let lines = wholeLines(block.range.location, NSMaxRange(block.range), text: text)
        func single(_ kind: PageBlockKind) -> [PageBlock] { [PageBlock(range: lines, fullRange: lines, kind: kind, depth: 0, markerRanges: block.markerRanges)] }
        switch block.kind {
        case .paragraph: return single(HiddenRanges.isImageOnly(block, text: text) ? .image : .text)
        case .atxHeading(let level), .setextHeading(let level): return single(.heading(level))
        case .blockQuote: return single(.quote)
        case .fencedCode: return single(.code)
        case .table: return single(.table)
        case .thematicBreak: return single(.divider)
        case .mathBlock: return single(.maths)
        case .bulletList, .orderedList: return items(of: block, depth: 0, text: text)
        default: return []
        }
    }

    private static func items(of list: Block, depth: Int, text: NSString) -> [PageBlock] {
        var ordered = false
        if case .orderedList = list.kind { ordered = true }
        var result: [PageBlock] = []
        for item in list.children {
            guard case .listItem(let task, let checked) = item.kind else { continue }
            let kind: PageBlockKind = task == true ? .task(checked: checked) : ordered ? .numbered : .bulleted
            let full = wholeLines(item.range.location, NSMaxRange(item.range), text: text)
            let nested = item.children.filter {
                switch $0.kind {
                case .bulletList, .orderedList: return true
                default: return false
                }
            }
            var own = full
            if let first = nested.first {
                let nestedStart = HiddenRanges.lineContents(at: first.range.location, in: text).location
                own = NSRange(location: full.location, length: max(nestedStart - 1 - full.location, 0))
            }
            result.append(PageBlock(range: own, fullRange: full, kind: kind, depth: depth, markerRanges: item.markerRanges))
            for child in nested { result += items(of: child, depth: depth + 1, text: text) }
        }
        return result
    }

    /// The language label of a code block.
    static func languageName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Plain text" }
        let names = ["cpp": "C++", "csharp": "C#", "css": "CSS", "html": "HTML", "json": "JSON", "js": "JavaScript", "javascript": "JavaScript",
                     "typescript": "TypeScript", "objectivec": "Objective-C", "php": "PHP", "sql": "SQL", "svg": "SVG", "xml": "XML",
                     "yaml": "YAML", "http": "HTTP", "fsharp": "F#", "latex": "LaTeX", "mathml": "MathML", "scss": "SCSS",
                     "aspnet": "ASP.NET", "powershell": "PowerShell", "coffeescript": "CoffeeScript"]
        if let name = names[id.lowercased()] { return name }
        return id.prefix(1).uppercased() + id.dropFirst()
    }

    // MARK: Edits

    static func blockText(_ block: PageBlock, text: NSString) -> String { text.substring(with: block.fullRange) }

    private static func isBlankLine(at offset: Int, text: NSString) -> Bool {
        text.substring(with: HiddenRanges.lineContents(at: offset, in: text)).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What `move` and `delete` take out of the text for `block`.
    static func removalRange(_ block: PageBlock, text: NSString) -> NSRange {
        let full = block.fullRange
        let after = NSMaxRange(full)
        if block.isItem {
            if after < text.length { return NSRange(location: full.location, length: after + 1 - full.location) }
            let start = max(full.location - 1, 0)
            return NSRange(location: start, length: after - start)
        }
        if after < text.length {
            var end = after + 1
            if end <= text.length, isBlankLine(at: end, text: text) {
                let blank = HiddenRanges.lineContents(at: end, in: text)
                end = min(NSMaxRange(blank) + 1, text.length)
            }
            return NSRange(location: full.location, length: end - full.location)
        }
        guard full.location > 0 else { return full }
        var start = full.location - 1
        if start > 0, isBlankLine(at: start, text: text) {
            start = max(HiddenRanges.lineContents(at: start, in: text).location - 1, 0)
        }
        return NSRange(location: start, length: after - start)
    }

    static func delete(_ block: PageBlock, text: NSString) -> (edits: [TextEdit], caret: Int?) {
        let removal = removalRange(block, text: text)
        return ([TextEdit(range: removal, replacement: "")], min(removal.location, max(text.length - removal.length, 0)))
    }

    static func duplicate(_ block: PageBlock, text: NSString) -> (edits: [TextEdit], caret: Int?) {
        let separator = block.isItem ? "\n" : "\n\n"
        let at = NSMaxRange(block.fullRange)
        return ([TextEdit(range: NSRange(location: at, length: 0), replacement: separator + blockText(block, text: text))],
                at + (separator as NSString).length)
    }

    /// Moves `block` (with its nested items) to just before `target`, or to the end of the text when `target` is nil.
    static func move(_ block: PageBlock, before target: PageBlock?, text: NSString) -> (edits: [TextEdit], caret: Int?) {
        let removal = removalRange(block, text: text)
        let t = target?.fullRange.location ?? text.length
        if t >= removal.location && t <= NSMaxRange(removal) { return ([], nil) }
        let body = blockText(block, text: text)
        var prefix = "", insertion: String
        if let target {
            let bothItems = block.isItem && target.isItem
            insertion = body + (bothItems ? "\n" : "\n\n")
            if !bothItems, t > 0, !isBlankLine(at: t - 1, text: text) { prefix = "\n" }
        } else {
            let whole = text as String
            if whole.hasSuffix("\n\n") || whole.isEmpty {
                prefix = ""
            } else if whole.hasSuffix("\n") {
                prefix = "\n"
            } else {
                prefix = "\n\n"
            }
            insertion = body
        }
        let insertedAt = t > removal.location ? t - removal.length : t
        return ([TextEdit(range: removal, replacement: ""), TextEdit(range: NSRange(location: t, length: 0), replacement: prefix + insertion)],
                insertedAt + (prefix as NSString).length)
    }

    /// The Markdown prefix a line of `kind` starts with.
    static func prefix(_ kind: PageBlockKind, number: Int = 1) -> String {
        switch kind {
        case .heading(let level): return String(repeating: "#", count: min(max(level, 1), 6)) + " "
        case .bulleted: return "- "
        case .numbered: return "\(number). "
        case .task(let checked): return checked ? "- [x] " : "- [ ] "
        case .quote: return "> "
        default: return ""
        }
    }

    /// Rewrites `block` as `kind`, reading its prefixes from the snapshot's markers: the first line's prefix changes;
    /// quotes change every line; code adds or removes the fence lines; list kinds keep the indentation, other kinds
    /// drop it; a heading joins the block's lines into one.
    static func turnInto(_ block: PageBlock, to kind: PageBlockKind, text: NSString, snapshot: Snapshot) -> (edits: [TextEdit], caret: Int?) {
        var lines = text.substring(with: block.range).components(separatedBy: "\n")
        var starts: [Int] = []
        var at = block.range.location
        for line in lines {
            starts.append(at)
            at += (line as NSString).length + 1
        }
        let markers = block.markerRanges
        var indent = ""
        var isHeading = false
        // A block with no prefix marker on its first line still loses its indentation there; list kinds put it back.
        func cutIndent() {
            let first = lines[0] as NSString
            var end = 0
            while end < first.length, first.character(at: end) == 32 || first.character(at: end) == 9 { end += 1 }
            indent = first.substring(to: end)
            lines[0] = first.substring(from: end)
        }
        if case .heading = block.kind { isHeading = true }
        if block.kind == .code, lines.count >= 2 {
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") || last.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                lines.removeLast()
            }
        } else if block.kind == .quote {
            lines = zip(lines, starts).map { line, start in
                let ns = line as NSString
                guard let marker = markers.first(where: { $0.location >= start && $0.location < start + ns.length }) else { return line }
                var cut = NSMaxRange(marker) - start
                if cut < ns.length, ns.character(at: cut) == 32 { cut += 1 }
                return ns.substring(from: cut)
            }
        } else if isHeading, let first = markers.first, lines.count >= 2, first.location >= starts[1] {
            // A setext heading: its `---` or `===` underline goes in the same edit as the prefix rewrite.
            lines.removeLast()
            cutIndent()
        } else if isHeading || block.isItem, let first = markers.first {
            let lineEnd = starts[0] + (lines[0] as NSString).length
            var end = NSMaxRange(first)
            if case .task = block.kind, markers.count >= 2 { end = NSMaxRange(markers[1]) }
            while end < lineEnd, text.character(at: end) == 32 || text.character(at: end) == 9 { end += 1 }
            indent = text.substring(with: NSRange(location: starts[0], length: first.location - starts[0]))
            lines[0] = text.substring(with: NSRange(location: end, length: lineEnd - end))
        } else if block.kind != .code {
            cutIndent()
        }
        if case .heading = kind {
            // A heading is one line, so a multi-line block's lines join with one space.
            lines = [lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }.joined(separator: " ")]
        }
        let result: String
        switch kind {
        case .code:
            result = "```\n" + lines.joined(separator: "\n") + "\n```"
        case .quote:
            result = lines.map { "> " + $0 }.joined(separator: "\n")
        default:
            var number = 1
            if kind == .numbered, block.range.location > 0,
               let above = PageBlocks.block(at: block.range.location - 1, snapshot: snapshot, text: text),
               above.kind == .numbered, above.depth == block.depth, let marker = above.markerRanges.first,
               let value = Int(text.substring(with: marker).prefix { $0.isNumber }) {
                number = value + 1
            }
            if let first = lines.first {
                lines[0] = (kind.isItem ? indent : "") + prefix(kind, number: number) + first
            }
            result = lines.joined(separator: "\n")
        }
        return ([TextEdit(range: block.range, replacement: result)], block.range.location)
    }

    /// The Markdown a `/` menu pick writes in place of `range`, with a blank line kept above and below.
    static func insert(_ kind: PageBlockKind, replacing range: NSRange, text: NSString, image: (alt: String, path: String)? = nil)
        -> (edits: [TextEdit], caret: Int?) {
        let body: String
        var caretInBody: Int?
        switch kind {
        case .code:
            body = "```\n\n```"
            caretInBody = 4
        case .table:
            body = "|   |   |\n|---|---|\n|   |   |"
            caretInBody = 2
        case .divider:
            body = "---\n"
        case .image:
            body = "![" + (image?.alt ?? "") + "](" + (image?.path ?? "") + ")"
        case .maths:
            body = "$$\n\n$$"
            caretInBody = 3
        default:
            body = prefix(kind)
        }
        let line = HiddenRanges.lineContents(at: range.location, in: text)
        let aboveBlank = line.location == 0 || isBlankLine(at: line.location - 1, text: text)
        let lineEnd = NSMaxRange(HiddenRanges.lineContents(at: NSMaxRange(range), in: text))
        let belowBlank = lineEnd >= text.length || isBlankLine(at: lineEnd + 1, text: text)
        let lead = aboveBlank ? "" : "\n"
        let trail = belowBlank ? "" : "\n"
        let caret = range.location + (lead as NSString).length + (caretInBody ?? (body as NSString).length)
        return ([TextEdit(range: range, replacement: lead + body + trail)], caret)
    }

    /// A new empty row after the table's last row, caret in its first cell.
    static func addRow(_ table: TextTable, text: NSString) -> (edits: [TextEdit], caret: Int?) {
        guard let last = table.rows.last else { return ([], nil) }
        let at = NSMaxRange(last.line)
        return ([TextEdit(range: NSRange(location: at, length: 0), replacement: "\n" + EditorTextView.emptyRow(like: table))],
                at + 1 + (table.leadingPipe ? 2 : 1))
    }

    /// A new empty column at the right of every row, caret in its header cell.
    static func addColumn(_ table: TextTable, text: NSString) -> (edits: [TextEdit], caret: Int?) {
        let edits = table.rows.enumerated().map { index, row -> TextEdit in
            let cell = index == table.dividerIndex ? "---" : "   "
            return TextEdit(range: NSRange(location: NSMaxRange(row.line), length: 0), replacement: table.trailingPipe ? cell + "|" : "|" + cell)
        }
        guard let header = table.rows.first else { return (edits, nil) }
        return (edits, NSMaxRange(header.line) + (table.trailingPipe ? 1 : 2))
    }
}

extension EditorTextView {
    /// Applies page block edits as one undo step, with the caret at `caret` in the new text.
    func apply(_ edits: [TextEdit], caret: Int?) {
        perform(edits.map { (range: $0.range, text: $0.replacement) }, select: caret.map { [NSRange(location: $0, length: 0)] })
    }

    /// The page's blocks; empty while a parse is pending.
    func pageBlocks() -> [PageBlock] {
        guard let snapshot else { return [] }
        return PageBlocks.blocks(in: snapshot, text: nsText)
    }

    func firstLineRect(of block: PageBlock) -> NSRect {
        rect(forCharacterRange: NSRange(location: block.range.location, length: 0))
    }
}
