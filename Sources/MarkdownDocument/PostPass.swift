import Foundation
import Markdown
import PlainCore

/// Turns swift-markdown's tree for a run of lines into `Block`s and `Inline`s with UTF-16 ranges, and adds the
/// syntax swift-markdown leaves as plain text: `[[toc]]`, reference definitions, footnote references, autolinks,
/// bare URLs and emails, `::highlight::`, `:emoji:`, Liquid tags, `{...}` attributes, hard breaks and escapes.
struct PostPass {
    let source: Source
    /// Absolute line of parsed line 1.
    let lineBase: Int
    /// Parsed lines at or past this count are appended definitions; nodes starting there are dropped.
    let lineLimit: Int
    /// Per parsed line, UTF-8 bytes removed from the line start before parsing (footnote bodies).
    var byteShifts: [Int] = []
    let pageBreakLines: Set<Int>
    let footnoteLabels: Set<String>
    var nextID: Int

    private var units: [UInt16] { source.units }

    // MARK: Pipeline

    /// Pre-pass, swift-markdown, post-pass over `lines`, which must start outside any block.
    /// `extraDefinitions` are reference definition lines from outside the lines, appended so links resolve.
    /// `caretOffset` is where the caret sits, when the text came from an edit rather than a file on disk.
    static func parse(_ source: Source, lines: Range<Int>, kinds: [LineScanner.LineKind], extraDefinitions: [String],
                      outsideFootnoteLabels: Set<String>, caretOffset: Int?, nextID: inout Int)
        -> (blocks: [Block], provisional: ProvisionalBlock?) {
        let pre = PrePass.run(source, lines: lines, kinds: kinds)
        var text = pre.text
        if !extraDefinitions.isEmpty { text += "\n\n" + extraDefinitions.joined(separator: "\n") }
        let document = Document(parsing: text, options: [.disableSmartOpts])
        var pass = PostPass(source: source, lineBase: lines.lowerBound, lineLimit: lines.count,
                            pageBreakLines: pre.pageBreakLines,
                            footnoteLabels: outsideFootnoteLabels.union(pre.footnotes.map(\.label)), nextID: nextID)
        var blocks = pass.blocks(in: document)
        if let frontMatter = pre.frontMatter { blocks.append(pass.frontMatterBlock(frontMatter)) }
        for footnote in pre.footnotes { blocks.append(pass.footnoteBlock(footnote)) }

        var covered = [Bool](repeating: false, count: lines.count)
        for block in blocks {
            for line in block.lineRange where lines.contains(line) { covered[line - lines.lowerBound] = true }
        }
        for (index, kind) in kinds.enumerated() where kind == .normal && !covered[index] {
            if let block = pass.referenceDefinitionBlock(line: lines.lowerBound + index) { blocks.append(block) }
        }
        blocks.sort { $0.lineRange.lowerBound < $1.lineRange.lowerBound }
        nextID = pass.nextID

        // The caret's block keeps its settled kind; the snapshot carries the kind to show for it.
        var provisional: ProvisionalBlock?
        if let caretOffset {
            let caretLine = source.line(containing: caretOffset)
            if let index = blocks.firstIndex(where: { $0.lineRange.contains(caretLine) }),
               case .paragraph = blocks[index].kind, let pipes = pass.provisionalTablePipes(blocks[index]) {
                provisional = ProvisionalBlock(id: blocks[index].id, kind: .table, pipeOffsets: pipes)
            }
        }
        return (blocks, provisional)
    }

    // MARK: Ambiguous kinds

    /// The pipe offsets for the caret's top-level paragraph, when a run of `|` lines should be held as one table
    /// while that kind is still ambiguous (issue 1). Nil when it should not.
    /// A setext underline and a bare list marker settle the block the moment their first character lands, and a
    /// fence, math block or blockquote opens on its own first line, so a table is the only kind left: a line holding
    /// a `|` is a table once a delimiter row follows it, and until then a run of `|` lines is held as one, the way
    /// Claude's scanner opens a table on any line holding a `|` and closes it at a blank line.
    func provisionalTablePipes(_ paragraph: Block) -> [Int]? {
        let lines = paragraph.lineRange
        guard !lines.isEmpty else { return nil }
        // A run of table lines starts after a blank line, or at the top of the document.
        if lines.lowerBound > 0 && !source.isBlank(lines.lowerBound - 1) { return nil }
        var pipes: [Int] = []
        for line in lines {
            let linePipes = source.pipeOffsets(from: source.lineStart(line), to: source.lineEnd(line))
            guard !linePipes.isEmpty else { return nil }
            pipes.append(contentsOf: linePipes)
        }
        return pipes
    }

    // MARK: Positions

    private func shift(_ parsedLine: Int) -> Int {
        parsedLine < byteShifts.count ? byteShifts[parsedLine] : 0
    }

    /// The UTF-16 range and absolute lines of a node, or nil for nodes without a position or in the appended tail.
    func span(_ markup: Markup) -> (range: NSRange, lines: Range<Int>)? {
        guard let range = markup.range else { return nil }
        let startLine = range.lowerBound.line - 1
        guard startLine < lineLimit else { return nil }
        let start = source.offset(line: lineBase + startLine, utf8Column: range.lowerBound.column + shift(startLine))
        var endLine = range.upperBound.line - 1
        var toLineEnd = false
        if range.upperBound.column == 1 && endLine > startLine {
            endLine -= 1
            toLineEnd = true
        }
        if endLine >= lineLimit {
            endLine = lineLimit - 1
            toLineEnd = true
        }
        let end = toLineEnd
            ? source.lineEnd(lineBase + endLine)
            : source.offset(line: lineBase + endLine, utf8Column: range.upperBound.column + shift(endLine))
        return (NSRange(location: start, length: max(end - start, 0)), (lineBase + startLine)..<(lineBase + endLine + 1))
    }

    /// The trimmed text of a line as a range.
    private func trimmedLineRange(_ line: Int) -> NSRange {
        let start = source.firstNonSpace(line)
        return NSRange(location: start, length: max(source.trimmedEnd(line) - start, 0))
    }

    private mutating func make(_ kind: BlockKind, _ range: NSRange, _ lines: Range<Int>, markers: [NSRange] = [],
                               inlines: [Inline] = [], children: [Block] = [], tokens: [CodeToken]? = nil,
                               attributes: [String: String] = [:], headingText: String? = nil,
                               definition: (label: String, destination: String)? = nil) -> Block {
        let id = BlockID(rawValue: nextID)
        nextID += 1
        let storage = BlockStorage(range: range, lineRange: lines, markerRanges: markers, inlines: inlines, children: children,
                                   codeTokens: tokens, attributes: attributes, headingText: headingText, definition: definition)
        return Block(id: id, kind: kind, storage: storage)
    }

    // MARK: Blocks

    mutating func blocks(in container: Markup) -> [Block] {
        var result: [Block] = []
        for child in container.children {
            if let block = block(child) { result.append(block) }
        }
        return result
    }

    private mutating func block(_ markup: Markup) -> Block? {
        guard let (range, lines) = span(markup) else { return nil }
        switch markup {
        case let paragraph as Paragraph:
            if source.find(Array("[[toc]]".utf16), from: range.location, to: min(range.location + 7, NSMaxRange(range))) == range.location {
                return make(.toc, range, lines)
            }
            var markers: [NSRange] = []
            var items = inlineList(paragraph.children)
            let attributes = extractAttributes(&items, markers: &markers)
            return make(.paragraph, range, lines, markers: markers, inlines: scanTexts(items), attributes: attributes)

        case let heading as Markdown.Heading:
            var markers: [NSRange] = []
            let kind: BlockKind
            if units[range.location] == 35 {
                kind = .atxHeading(level: heading.level)
                var index = range.location
                while index < NSMaxRange(range) && units[index] == 35 { index += 1 }
                markers.append(NSRange(location: range.location, length: index - range.location))
                let end = source.trimmedEnd(lines.lowerBound)
                var closing = end
                while closing > index && units[closing - 1] == 35 { closing -= 1 }
                if closing < end && closing > index && (units[closing - 1] == 32 || units[closing - 1] == 9) {
                    markers.append(NSRange(location: closing, length: end - closing))
                }
            } else {
                kind = .setextHeading(level: heading.level)
                markers.append(trimmedLineRange(lines.upperBound - 1))
            }
            var items = inlineList(heading.children)
            let attributes = extractAttributes(&items, markers: &markers)
            let inlines = scanTexts(items)
            let text = plainText(inlines).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return make(kind, range, lines, markers: markers, inlines: inlines, attributes: attributes, headingText: text)

        case is BlockQuote:
            return make(.blockQuote, range, lines, markers: quoteMarkers(range, lines), children: blocks(in: markup))

        case is UnorderedList:
            return make(.bulletList, range, lines, children: blocks(in: markup))

        case let list as OrderedList:
            return make(.orderedList(start: Int(list.startIndex)), range, lines, children: blocks(in: markup))

        case let item as ListItem:
            var markers: [NSRange] = []
            var index = range.location
            let end = source.lineEnd(lines.lowerBound)
            if index < end && [45, 42, 43].contains(units[index]) {
                index += 1
            } else {
                while index < end && isASCIIDigit(units[index]) { index += 1 }
                if index < end && (units[index] == 46 || units[index] == 41) { index += 1 }
            }
            markers.append(NSRange(location: range.location, length: index - range.location))
            if item.checkbox != nil {
                while index < end && (units[index] == 32 || units[index] == 9) { index += 1 }
                if index + 3 <= end && units[index] == 91 { markers.append(NSRange(location: index, length: 3)) }
            }
            let kind = BlockKind.listItem(task: item.checkbox == nil ? nil : true, checked: item.checkbox == .checked)
            return make(kind, range, lines, markers: markers, children: blocks(in: item))

        case is Table:
            var inlines: [Inline] = []
            collectCells(markup, into: &inlines)
            var markers: [NSRange] = []
            for line in lines {
                if line == lines.lowerBound + 1 {
                    markers.append(trimmedLineRange(line))
                    continue
                }
                for pipe in source.pipeOffsets(from: source.lineStart(line), to: source.lineEnd(line)) {
                    markers.append(NSRange(location: pipe, length: 1))
                }
            }
            return make(.table, range, lines, markers: markers, inlines: inlines)

        case let code as CodeBlock:
            return codeBlock(code, range, lines)

        case let html as HTMLBlock:
            if pageBreakLines.contains(lines.lowerBound) {
                return make(.pageBreak, range, lines, markers: [trimmedLineRange(lines.lowerBound)])
            }
            let isComment = html.rawHTML.trimmingCharacters(in: .whitespaces).hasPrefix("<!--")
            return make(isComment ? .htmlComment : .htmlBlock, range, lines)

        case is ThematicBreak:
            return make(.thematicBreak, range, lines, markers: [trimmedLineRange(lines.lowerBound)])

        default:
            return nil
        }
    }

    private mutating func collectCells(_ markup: Markup, into inlines: inout [Inline]) {
        for child in markup.children {
            if let cell = child as? Table.Cell {
                inlines.append(contentsOf: scanTexts(inlineList(cell.children)))
            } else {
                collectCells(child, into: &inlines)
            }
        }
    }

    /// The `>` of each line: at the quote's start on its first line, else the first `>` at or after the quote's
    /// column with only spaces and other `>` before it. Lazy continuation lines get none.
    private func quoteMarkers(_ range: NSRange, _ lines: Range<Int>) -> [NSRange] {
        var markers: [NSRange] = []
        let column = range.location - source.lineStart(lines.lowerBound)
        for line in lines {
            let start = source.lineStart(line)
            if line == lines.lowerBound {
                if units[range.location] == 62 { markers.append(NSRange(location: range.location, length: 1)) }
                continue
            }
            var index = start
            while index < source.lineEnd(line) {
                let unit = units[index]
                if unit == 62 && index - start >= column {
                    markers.append(NSRange(location: index, length: 1))
                    break
                }
                guard unit == 32 || unit == 9 || unit == 62 else { break }
                index += 1
            }
        }
        return markers
    }

    private mutating func codeBlock(_ code: CodeBlock, _ range: NSRange, _ lines: Range<Int>) -> Block {
        let first = lines.lowerBound
        let last = lines.upperBound - 1
        if code.language == PrePass.mathLanguage {
            let dollars = source.trimmedLine(first, equals: "$$$") ? 3 : 2
            var markers = [trimmedLineRange(first)]
            let closed = last > first && source.trimmedLine(last, equals: String(repeating: "$", count: dollars))
            if closed { markers.append(trimmedLineRange(last)) }
            let contentLast = closed ? last - 1 : last
            if dollars == 2 && contentLast > first {
                let open = source.firstNonSpace(first + 1)
                let close = source.trimmedEnd(contentLast) - 1
                if close > open + 1 && units[open] == 36 && units[close] == 36 && units[open + 1] != 36 && units[close - 1] != 36 {
                    markers.append(NSRange(location: open, length: 1))
                    markers.append(NSRange(location: close, length: 1))
                }
            }
            return make(.mathBlock, range, lines, markers: markers)
        }
        let fence = units[range.location]
        guard fence == 96 || fence == 126 else { return make(.indentedCode, range, lines) }
        var openEnd = range.location
        while openEnd < source.lineEnd(first) && units[openEnd] == fence { openEnd += 1 }
        let fenceLength = openEnd - range.location
        var markers = [NSRange(location: range.location, length: max(source.trimmedEnd(first) - range.location, 0))]
        var closed = false
        if last > first {
            let start = source.firstNonSpace(last)
            let end = source.trimmedEnd(last)
            closed = end - start >= fenceLength && source.units[start..<end].allSatisfy { $0 == fence }
            if closed { markers.append(NSRange(location: start, length: end - start)) }
        }
        let language = code.language.flatMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        var tokens: [CodeToken]?
        let contentLast = closed ? last - 1 : last
        if let language, contentLast > first {
            let start = source.lineStart(first + 1)
            let text = source.string(start..<source.lineEnd(contentLast))
            tokens = CodeHighlighter.shared.tokens(for: text, language: language)?.map {
                CodeToken(range: NSRange(location: $0.range.location + start, length: $0.range.length), type: $0.type)
            }
        }
        return make(.fencedCode(language: language), range, lines, markers: markers, tokens: tokens)
    }

    mutating func frontMatterBlock(_ lines: Range<Int>) -> Block {
        let last = lines.upperBound - 1
        let range = NSRange(location: source.lineStart(lines.lowerBound), length: source.lineEnd(last) - source.lineStart(lines.lowerBound))
        let markers = [lines.lowerBound, last].map { NSRange(location: source.lineStart($0), length: source.lineEnd($0) - source.lineStart($0)) }
        return make(.frontMatter, range, lines, markers: markers)
    }

    /// Parses the definition's body on its own (the `[^label]:` prefix and up to four leading spaces removed per line)
    /// and maps the result back with per-line shifts.
    mutating func footnoteBlock(_ footnote: PrePass.Footnote) -> Block {
        let first = footnote.lines.lowerBound
        let lineStart = source.lineStart(first)
        var prefixEnd = lineStart
        while units[prefixEnd] != 58 { prefixEnd += 1 }
        prefixEnd += 1
        let marker = NSRange(location: lineStart, length: prefixEnd - lineStart)
        var shifts: [Int] = []
        var body: [UInt16] = []
        for line in footnote.lines {
            var start = line == first ? prefixEnd : source.lineStart(line)
            let end = source.lineEnd(line)
            if line == first {
                while start < end && (units[start] == 32 || units[start] == 9) { start += 1 }
            } else {
                var removed = 0
                while start < end && removed < 4 && units[start] == 32 {
                    start += 1
                    removed += 1
                }
                if removed == 0 && start < end && units[start] == 9 { start += 1 }
            }
            if line != first { body.append(10) }
            var copy = Array(units[start..<end])
            PrePass.replaceInlineMath(&copy)
            body.append(contentsOf: copy)
            shifts.append(String(decoding: units[source.lineStart(line)..<start], as: UTF16.self).utf8.count)
        }
        let document = Document(parsing: String(decoding: body, as: UTF16.self), options: [.disableSmartOpts])
        var pass = PostPass(source: source, lineBase: first, lineLimit: footnote.lines.count, byteShifts: shifts,
                            pageBreakLines: [], footnoteLabels: footnoteLabels, nextID: nextID)
        let children = pass.blocks(in: document)
        nextID = pass.nextID
        let last = footnote.lines.upperBound - 1
        let range = NSRange(location: lineStart, length: source.lineEnd(last) - lineStart)
        return make(.footnoteDefinition(label: footnote.label), range, footnote.lines, markers: [marker], children: children)
    }

    /// A `[label]: destination` line (up to three spaces of indent) that no other block covers.
    mutating func referenceDefinitionBlock(line: Int) -> Block? {
        guard source.indent(line) <= 3 else { return nil }
        let end = source.lineEnd(line)
        var index = source.firstNonSpace(line)
        guard index < end, units[index] == 91 else { return nil }
        let labelStart = index + 1
        index = labelStart
        while index < end && units[index] != 93 { index += 1 }
        guard index > labelStart, index + 1 < end, units[index + 1] == 58 else { return nil }
        let label = source.string(labelStart..<index)
        index += 2
        while index < end && (units[index] == 32 || units[index] == 9) { index += 1 }
        guard index < end else { return nil }
        let destinationStart = index
        while index < end && !isWhitespace(units[index]) { index += 1 }
        var destination = source.string(destinationStart..<index)
        if destination.hasPrefix("<") && destination.hasSuffix(">") && destination.count >= 2 {
            destination = String(destination.dropFirst().dropLast())
        }
        let range = NSRange(location: source.lineStart(line), length: end - source.lineStart(line))
        return make(.referenceDefinition, range, line..<(line + 1), definition: (normalizedLabel(label), destination))
    }

    // MARK: Inlines

    /// Converts sibling inline nodes, joining neighbouring text nodes into one `.text` inline, then pairs `::`.
    private mutating func inlineList(_ children: some Sequence<Markup>) -> [Inline] {
        var items: [Inline] = []
        var run: NSRange?
        var lastLine: Int?
        func flush() {
            if let range = run, range.length > 0 { items.append(Inline(kind: .text, range: range)) }
            run = nil
        }
        for child in children {
            switch child {
            case is Text, is SoftBreak, is SymbolLink, is CustomInline:
                guard let (range, lines) = span(child) else { continue }
                run = run.map { NSUnionRange($0, range) } ?? range
                lastLine = lines.upperBound - 1
            case is LineBreak:
                guard let line = lastLine else { continue }
                let lineBreak = hardBreak(on: line)
                if let range = run, NSMaxRange(range) > lineBreak.location {
                    run = NSRange(location: range.location, length: max(lineBreak.location - range.location, 0))
                }
                flush()
                items.append(Inline(kind: .lineBreak, range: lineBreak, markerRanges: [lineBreak]))
            case let attributes as InlineAttributes:
                flush()
                items.append(contentsOf: scanTexts(inlineList(attributes.children)))
            default:
                flush()
                if let inline = convertInline(child) {
                    items.append(inline)
                    lastLine = source.line(containing: max(NSMaxRange(inline.range) - 1, inline.range.location))
                }
            }
        }
        flush()
        return pairHighlights(items)
    }

    private mutating func inlinesFull(_ children: some Sequence<Markup>) -> [Inline] {
        scanTexts(inlineList(children))
    }

    /// Two or more trailing spaces, or a trailing backslash, on the line.
    private func hardBreak(on line: Int) -> NSRange {
        let start = source.lineStart(line)
        let end = source.lineEnd(line)
        var index = end
        while index > start && units[index - 1] == 32 { index -= 1 }
        if end - index >= 2 { return NSRange(location: index, length: end - index) }
        if end > start && units[end - 1] == 92 { return NSRange(location: end - 1, length: 1) }
        return NSRange(location: end, length: 0)
    }

    private func delimited(_ kind: InlineKind, _ range: NSRange, _ count: Int, children: [Inline] = []) -> Inline {
        let count = min(count, range.length / 2)
        return Inline(kind: kind, range: range,
                      markerRanges: [NSRange(location: range.location, length: count), NSRange(location: NSMaxRange(range) - count, length: count)],
                      contentRange: NSRange(location: range.location + count, length: range.length - 2 * count),
                      children: children)
    }

    private func run(of unit: UInt16, from index: Int, limit: Int) -> Int {
        var end = index
        while end < limit && units[end] == unit { end += 1 }
        return end - index
    }

    private mutating func convertInline(_ markup: Markup) -> Inline? {
        guard let (range, _) = span(markup), range.length > 0 else { return nil }
        let start = range.location
        let end = NSMaxRange(range)
        switch markup {
        case let emphasis as Emphasis:
            return delimited(.emphasis, range, 1, children: inlinesFull(emphasis.children))
        case let strong as Strong:
            return delimited(.strong, range, 2, children: inlinesFull(strong.children))
        case let strike as Strikethrough:
            return delimited(.strike, range, run(of: 126, from: start, limit: end), children: inlinesFull(strike.children))
        case is InlineCode:
            let delimiter = units[start]
            return delimited(delimiter == 36 ? .math : .code, range, run(of: delimiter, from: start, limit: end))
        case is InlineHTML:
            return delimited(.htmlTag, range, 1)
        case let link as Link:
            if units[start] == 60 {
                return delimited(.autolink(destination: link.destination ?? ""), range, 1)
            }
            let children = inlinesFull(link.children)
            if start + 1 < end && units[start + 1] == 94 {
                let label = source.string((start + 2)..<max(end - 1, start + 2))
                return Inline(kind: .footnoteReference(label: label), range: range,
                              markerRanges: [NSRange(location: start, length: 2), NSRange(location: end - 1, length: 1)],
                              contentRange: NSRange(location: start + 2, length: max(end - start - 3, 0)))
            }
            return linkLike(range, openLength: 1, children: children) { inline, label in
                inline ? .link(destination: link.destination ?? "") : .referenceLink(label: label)
            }
        case let image as Image:
            let children = inlinesFull(image.children)
            let alt = plainText(children)
            return linkLike(range, openLength: 2, children: children) { inline, label in
                inline ? .image(destination: image.source ?? "", alt: alt) : .referenceImage(label: label)
            }
        default:
            return nil
        }
    }

    /// Links and images: `[` (or `![`) is one marker, `](...)` or `][label]` the other.
    private func linkLike(_ range: NSRange, openLength: Int, children: [Inline], kind: (_ inline: Bool, _ label: String) -> InlineKind) -> Inline {
        let start = range.location
        let end = NSMaxRange(range)
        let close = matchingBracket(from: start + openLength - 1, limit: end) ?? end - 1
        let content = NSRange(location: start + openLength, length: max(close - start - openLength, 0))
        let after = close + 1
        let isInline = after < end && units[after] == 40
        var label = source.string(content)
        if after < end && units[after] == 91 && end - after > 2 {
            label = source.string((after + 1)..<(end - 1))
        }
        return Inline(kind: kind(isInline, normalizedLabel(label)), range: range,
                      markerRanges: [NSRange(location: start, length: openLength), NSRange(location: close, length: end - close)],
                      contentRange: content, children: children)
    }

    private func matchingBracket(from open: Int, limit: Int) -> Int? {
        var depth = 0
        var index = open
        while index < limit {
            switch units[index] {
            case 92: index += 1
            case 91: depth += 1
            case 93:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// Wraps `::...::` pairs found in sibling text inlines into `.highlight` inlines holding what lies between.
    private func pairHighlights(_ items: [Inline]) -> [Inline] {
        var candidates: [(position: Int, canOpen: Bool, canClose: Bool)] = []
        for item in items where item.kind == .text {
            var index = item.range.location
            let end = NSMaxRange(item.range)
            while index < end {
                guard units[index] == 58 else {
                    index += 1
                    continue
                }
                let length = run(of: 58, from: index, limit: end)
                if length == 2 && (index == 0 || units[index - 1] != 58) {
                    let previous: UInt16 = index > 0 ? units[index - 1] : 32
                    let next: UInt16 = index + 2 < units.count ? units[index + 2] : 32
                    candidates.append((index, !isWhitespace(next), !isWhitespace(previous)))
                }
                index += length
            }
        }
        var pairs: [(Int, Int)] = []
        var opener: Int?
        for candidate in candidates {
            if let open = opener {
                if candidate.canClose && candidate.position > open + 2 {
                    pairs.append((open, candidate.position))
                    opener = nil
                }
            } else if candidate.canOpen {
                opener = candidate.position
            }
        }
        guard !pairs.isEmpty else { return items }
        var result: [Inline] = []
        var cursor = Int.min
        for (open, close) in pairs {
            result += clip(items, cursor, open)
            result.append(Inline(kind: .highlight, range: NSRange(location: open, length: close + 2 - open),
                                 markerRanges: [NSRange(location: open, length: 2), NSRange(location: close, length: 2)],
                                 contentRange: NSRange(location: open + 2, length: close - open - 2),
                                 children: clip(items, open + 2, close)))
            cursor = close + 2
        }
        return result + clip(items, cursor, Int.max)
    }

    /// Items inside `low..<high`; text inlines are cut to fit.
    private func clip(_ items: [Inline], _ low: Int, _ high: Int) -> [Inline] {
        var result: [Inline] = []
        for item in items {
            let start = item.range.location
            let end = NSMaxRange(item.range)
            if item.kind == .text {
                let clippedStart = max(start, low)
                let clippedEnd = min(end, high)
                if clippedEnd > clippedStart { result.append(Inline(kind: .text, range: NSRange(location: clippedStart, length: clippedEnd - clippedStart))) }
            } else if start >= low && end <= high {
                result.append(item)
            }
        }
        return result
    }

    /// Reads a trailing `{.class #id key=value}` off the last text inline.
    private func extractAttributes(_ items: inout [Inline], markers: inout [NSRange]) -> [String: String] {
        guard let last = items.last, last.kind == .text else { return [:] }
        let start = last.range.location
        var end = NSMaxRange(last.range)
        while end > start && (units[end - 1] == 32 || units[end - 1] == 9) { end -= 1 }
        guard end > start + 2, units[end - 1] == 125 else { return [:] }
        var open = end - 2
        while open >= start && units[open] != 123 && units[open] != 125 { open -= 1 }
        guard open >= start, units[open] == 123 else { return [:] }
        let body = source.string((open + 1)..<(end - 1))
        var attributes: [String: String] = [:]
        var classes: [String] = []
        let tokens = body.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return [:] }
        for token in tokens {
            if token.hasPrefix("."), token.count > 1 {
                classes.append(String(token.dropFirst()))
            } else if token.hasPrefix("#"), token.count > 1 {
                attributes["id"] = String(token.dropFirst())
            } else if let equals = token.firstIndex(of: "="), equals != token.startIndex {
                var value = String(token[token.index(after: equals)...])
                if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                    value = String(value.dropFirst().dropLast())
                }
                attributes[String(token[..<equals])] = value
            } else {
                return [:]
            }
        }
        if !classes.isEmpty { attributes["class"] = classes.joined(separator: " ") }
        var textEnd = open
        while textEnd > start && (units[textEnd - 1] == 32 || units[textEnd - 1] == 9) { textEnd -= 1 }
        items.removeLast()
        if textEnd > start { items.append(Inline(kind: .text, range: NSRange(location: start, length: textEnd - start))) }
        markers.append(NSRange(location: open, length: end - open))
        return attributes
    }

    /// Splits text inlines (also inside highlights) around escapes, Liquid tags, footnote references, shortcut
    /// references, bare URLs and emails, and emoji shortcodes.
    private func scanTexts(_ items: [Inline]) -> [Inline] {
        var result: [Inline] = []
        for item in items {
            switch item.kind {
            case .text:
                result.append(contentsOf: scanText(item.range))
            case .highlight:
                var copy = item
                copy.children = scanTexts(item.children)
                result.append(copy)
            default:
                result.append(item)
            }
        }
        return result
    }

    private func scanText(_ range: NSRange) -> [Inline] {
        var result: [Inline] = []
        let end = NSMaxRange(range)
        var pending = range.location
        var index = range.location
        while index < end {
            guard let special = special(at: index, end: end) else {
                index += 1
                continue
            }
            if special.range.location > pending {
                result.append(Inline(kind: .text, range: NSRange(location: pending, length: special.range.location - pending)))
            }
            result.append(special)
            index = NSMaxRange(special.range)
            pending = index
        }
        if end > pending { result.append(Inline(kind: .text, range: NSRange(location: pending, length: end - pending))) }
        return result
    }

    private func special(at index: Int, end: Int) -> Inline? {
        let unit = units[index]
        switch unit {
        case 92:
            if index + 1 < end && isASCIIPunctuation(units[index + 1]) {
                return Inline(kind: .escape, range: NSRange(location: index, length: 2),
                              markerRanges: [NSRange(location: index, length: 1)], contentRange: NSRange(location: index + 1, length: 1))
            }
        case 123:
            guard index + 1 < end else { return nil }
            let closer: [UInt16]
            switch units[index + 1] {
            case 123: closer = [125, 125]
            case 37: closer = [37, 125]
            default: return nil
            }
            if let close = source.find(closer, from: index + 2, to: end) {
                return Inline(kind: .liquidTag, range: NSRange(location: index, length: close + 2 - index),
                              markerRanges: [NSRange(location: index, length: 2), NSRange(location: close, length: 2)],
                              contentRange: NSRange(location: index + 2, length: close - index - 2))
            }
        case 91:
            return bracketed(at: index, end: end)
        case 58:
            var close = index + 1
            while close < end, case let name = units[close],
                  (name >= 97 && name <= 122) || isASCIIDigit(name) || name == 95 || name == 43 || name == 45 {
                close += 1
            }
            if close > index + 1, close < end, units[close] == 58 {
                let name = source.string((index + 1)..<close)
                if let character = EmojiTable.shared.byShortcode[name] {
                    return Inline(kind: .emoji(name: name, character: character), range: NSRange(location: index, length: close + 1 - index),
                                  markerRanges: [NSRange(location: index, length: 1), NSRange(location: close, length: 1)],
                                  contentRange: NSRange(location: index + 1, length: close - index - 1))
                }
            }
        default:
            break
        }
        if lowercased(unit) == 104 || lowercased(unit) == 109, index == 0 || !isASCIIAlphanumeric(units[index - 1]),
           let url = bareURL(at: index, end: end) { return url }
        if isEmailLocal(unit) && (index == 0 || !isEmailLocal(units[index - 1])), let email = email(at: index, end: end) { return email }
        return nil
    }

    private func bracketed(at index: Int, end: Int) -> Inline? {
        if index + 1 < end && units[index + 1] == 94 {
            var close = index + 2
            while close < end && units[close] != 93 && units[close] != 91 && !isWhitespace(units[close]) { close += 1 }
            guard close < end, units[close] == 93, close > index + 2 else { return nil }
            let label = source.string((index + 2)..<close)
            guard footnoteLabels.contains(label) else { return nil }
            return Inline(kind: .footnoteReference(label: label), range: NSRange(location: index, length: close + 1 - index),
                          markerRanges: [NSRange(location: index, length: 2), NSRange(location: close, length: 1)],
                          contentRange: NSRange(location: index + 2, length: close - index - 2))
        }
        var close = index + 1
        while close < end && units[close] != 93 && units[close] != 91 && units[close] != 10 { close += 1 }
        guard close < end, units[close] == 93, units[(index + 1)..<close].contains(where: { !isWhitespace($0) }) else { return nil }
        let next: UInt16 = close + 1 < units.count ? units[close + 1] : 0
        guard next != 40 && next != 91 && next != 58 else { return nil }
        return Inline(kind: .shortcutReference, range: NSRange(location: index, length: close + 1 - index),
                      markerRanges: [NSRange(location: index, length: 1), NSRange(location: close, length: 1)],
                      contentRange: NSRange(location: index + 1, length: close - index - 1))
    }

    private static let schemes: [[UInt16]] = ["https://", "http://", "mailto:"].map { Array($0.utf16) }
    private static let trailingPunctuation: Set<UInt16> = Set(".,:;!?'\"*_~".utf16)

    /// `http://`, `https://` or `mailto:` followed by text up to white space; trailing punctuation and an unbalanced
    /// closing parenthesis are left out.
    private func bareURL(at index: Int, end: Int) -> Inline? {
        guard let scheme = Self.schemes.first(where: { source.find($0, from: index, to: min(index + $0.count, end)) == index }) else { return nil }
        let bodyStart = index + scheme.count
        var close = bodyStart
        while close < end && !isWhitespace(units[close]) && units[close] != 60 && units[close] != 62 && units[close] != 34 { close += 1 }
        while close > bodyStart {
            let last = units[close - 1]
            if Self.trailingPunctuation.contains(last) {
                close -= 1
            } else if last == 41 {
                let slice = units[index..<close]
                guard slice.filter({ $0 == 41 }).count > slice.filter({ $0 == 40 }).count else { break }
                close -= 1
            } else {
                break
            }
        }
        guard close > bodyStart else { return nil }
        let range = NSRange(location: index, length: close - index)
        return Inline(kind: .bareURL(destination: source.string(range)), range: range)
    }

    private func isEmailLocal(_ unit: UInt16) -> Bool {
        isASCIIAlphanumeric(unit) || unit == 46 || unit == 95 || unit == 37 || unit == 43 || unit == 45
    }

    private func email(at index: Int, end: Int) -> Inline? {
        var at = index
        while at < end && isEmailLocal(units[at]) { at += 1 }
        guard at > index, at < end, units[at] == 64 else { return nil }
        var close = at + 1
        while close < end && (isASCIIAlphanumeric(units[close]) || units[close] == 45 || units[close] == 46) { close += 1 }
        while close > at + 1 && (units[close - 1] == 46 || units[close - 1] == 45) { close -= 1 }
        guard close > at + 1, units[(at + 1)..<close].contains(46), units[at + 1] != 46 else { return nil }
        let range = NSRange(location: index, length: close - index)
        return Inline(kind: .bareURL(destination: "mailto:" + source.string(range)), range: range)
    }

    /// Text of inlines without syntax: used for heading slugs and image alt text.
    func plainText(_ inlines: [Inline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline.kind {
            case .text, .bareURL, .liquidTag: result += source.string(inline.range)
            case .code, .math, .escape: result += source.string(inline.contentRange)
            case .lineBreak: result += " "
            case .emoji, .footnoteReference, .htmlTag, .image, .referenceImage: break
            default: result += inline.children.isEmpty ? source.string(inline.contentRange) : plainText(inline.children)
            }
        }
        return result
    }
}

/// Lower case with runs of white space collapsed to one space.
func normalizedLabel(_ label: String) -> String {
    label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
