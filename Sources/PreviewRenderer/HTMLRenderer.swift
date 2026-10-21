import Foundation
import JavaScriptCore
import MarkdownDocument
import PlainCore
import PlainVendor

/// Turns TeX source into HTML.
public protocol MathRenderer: Sendable {
    func html(for tex: String, display: Bool) -> String
}

/// Renders math with `katex.min.js` in one `JSContext`, created on first use, with KaTeX's own error display on.
/// When KaTeX still throws, the source shows in a `katex--error` span. Keeps the 1,024 most recent results.
public final class KaTeXJSRenderer: MathRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var context: JSContext?
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 1024

    public init() {}

    /// Number of cached results.
    var cachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public func html(for tex: String, display: Bool) -> String {
        let key = (display ? "D" : "I") + tex
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let context = context ?? makeContext()
        var result = context.objectForKeyedSubscript("__plainKatex")?.call(withArguments: [tex, display])
        if result?.isString != true { result = nil }
        let html = result?.toString() ?? "<span class=\"\(display ? "katex-display" : "katex") katex--error\">\(escapeHTML(tex))</span>"
        cache[key] = html
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return html
    }

    private func makeContext() -> JSContext {
        let context = JSContext()!
        if let script = try? String(contentsOf: VendorFiles.katexJS, encoding: .utf8) { context.evaluateScript(script) }
        context.evaluateScript("""
        function __plainKatex(tex, display) {
          try { return katex.renderToString(tex, { displayMode: display, throwOnError: false }); }
          catch (e) { return null; }
        }
        """)
        self.context = context
        return context
    }
}

/// Escapes `&`, `<`, `>` and `"`.
func escapeHTML(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf16.count)
    for character in text.unicodeScalars {
        switch character {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        default: result.unicodeScalars.append(character)
        }
    }
    return result
}

/// HTML for snapshots, in the shape markdown-it and its plugins give (spec 459–479). Raw HTML passes through and
/// every top-level block holding raw HTML or `{...}` attributes goes through `Sanitizer`; link and image URLs are
/// checked by `Sanitizer.isSafeURL`. Every top-level element carries `data-block` (the block id) and `data-line`.
public struct HTMLRenderer: Sendable {
    public var math: any MathRenderer
    /// Rewrites `a href`, `img src` and `object data` values. The on-screen preview sets it to `LinkResolver`;
    /// export and copy leave it nil so paths stay as written.
    public var resolveURL: (@Sendable (String) -> String)?

    /// The `data-block` value of the footnotes section, which follows every block.
    public static let footnotesID = "footnotes"

    public init(math: any MathRenderer = KaTeXJSRenderer(), resolveURL: (@Sendable (String) -> String)? = nil) {
        self.math = math
        self.resolveURL = resolveURL
    }

    /// One top-level block, or an empty string for blocks that show nothing (front matter, reference and footnote
    /// definitions, HTML comments).
    public func html(for block: Block, in snapshot: Snapshot) -> String {
        var writer = Writer(snapshot: snapshot, renderer: self)
        return writer.topLevel(block)
    }

    /// The whole document: every block, then the footnotes section.
    public func html(for snapshot: Snapshot) -> String {
        var writer = Writer(snapshot: snapshot, renderer: self)
        var result = ""
        for block in snapshot.blocks { result += writer.topLevel(block) }
        return result + writer.footnotesSection()
    }

    /// Several top-level blocks from one snapshot, sharing the document-wide lookups.
    func html(for blocks: [Block], in snapshot: Snapshot) -> (blocks: [BlockID: String], footnotes: String, footnoteOrder: [String]) {
        var writer = Writer(snapshot: snapshot, renderer: self)
        var result: [BlockID: String] = [:]
        for block in blocks { result[block.id] = writer.topLevel(block) }
        return (result, writer.footnotesSection(), writer.footnotes.order)
    }
}

/// Footnote numbers, in the order references first appear.
struct Footnotes {
    var order: [String] = []
    var numbers: [String: Int] = [:]
    /// Reference location to (number, how many references to that label came before it).
    var references: [Int: (number: Int, occurrence: Int)] = [:]
    var counts: [String: Int] = [:]
    var definitions: [String: Block] = [:]

    init() {}

    init(snapshot: Snapshot) {
        for block in snapshot.blocks {
            if case .footnoteDefinition(let label) = block.kind, definitions[label] == nil { definitions[label] = block }
        }
        guard !definitions.isEmpty else { return }
        func visit(_ inlines: [Inline]) {
            for inline in inlines {
                if case .footnoteReference(let label) = inline.kind, definitions[label] != nil {
                    let number: Int
                    if let existing = numbers[label] {
                        number = existing
                    } else {
                        order.append(label)
                        number = order.count
                        numbers[label] = number
                    }
                    let occurrence = counts[label, default: 0]
                    counts[label] = occurrence + 1
                    references[inline.range.location] = (number, occurrence)
                }
                visit(inline.children)
            }
        }
        func visit(_ blocks: [Block]) {
            for block in blocks {
                visit(block.inlines)
                visit(block.children)
            }
        }
        visit(snapshot.blocks)
    }
}

struct Writer {
    let snapshot: Snapshot
    let renderer: HTMLRenderer
    let units: [UInt16]
    let slugs: [BlockID: String]
    private var footnotesStorage: Footnotes?
    private var out: [UInt16] = []
    private var needsSanitizing = false

    init(snapshot: Snapshot, renderer: HTMLRenderer) {
        self.snapshot = snapshot
        self.renderer = renderer
        let text = snapshot.text as NSString
        var units = [UInt16](repeating: 0, count: text.length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { text.getCharacters(base, range: NSRange(location: 0, length: text.length)) }
        }
        self.units = units
        var slugs: [BlockID: String] = [:]
        for heading in snapshot.headings { slugs[heading.blockID] = heading.slug }
        self.slugs = slugs
    }

    var footnotes: Footnotes {
        mutating get {
            if let footnotesStorage { return footnotesStorage }
            let built = Footnotes(snapshot: snapshot)
            footnotesStorage = built
            return built
        }
    }

    // MARK: Output

    private mutating func raw(_ text: String) { out.append(contentsOf: text.utf16) }

    private mutating func escaped(_ text: String) {
        for unit in text.utf16 { escapeUnit(unit) }
    }

    private mutating func escapeUnit(_ unit: UInt16) {
        switch unit {
        case 38: raw("&amp;")
        case 60: raw("&lt;")
        case 62: raw("&gt;")
        case 34: raw("&quot;")
        default: out.append(unit)
        }
    }

    private func string(_ range: NSRange) -> String {
        String(decoding: units[range.location..<NSMaxRange(range)], as: UTF16.self)
    }

    private func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    /// Length of a character entity (`&copy;`, `&#169;`, `&#xA9;`) starting at `index`, or nil.
    private func entityLength(at index: Int, end: Int) -> Int? {
        var cursor = index + 1
        guard cursor < end else { return nil }
        if units[cursor] == 35 {
            cursor += 1
            let hex = cursor < end && (units[cursor] == 120 || units[cursor] == 88)
            if hex { cursor += 1 }
            let start = cursor
            while cursor < end && cursor - start < (hex ? 6 : 7) && Self.isDigit(units[cursor], hex: hex) { cursor += 1 }
            guard cursor > start, cursor < end, units[cursor] == 59 else { return nil }
        } else {
            let start = cursor
            while cursor < end && cursor - start < 32 && Self.isAlphanumeric(units[cursor]) { cursor += 1 }
            guard cursor > start, Self.isLetter(units[start]), cursor < end, units[cursor] == 59 else { return nil }
        }
        return cursor + 1 - index
    }

    private static func isLetter(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) }
    private static func isAlphanumeric(_ unit: UInt16) -> Bool { isLetter(unit) || (unit >= 48 && unit <= 57) }
    private static func isDigit(_ unit: UInt16, hex: Bool) -> Bool {
        (unit >= 48 && unit <= 57) || (hex && ((unit >= 65 && unit <= 70) || (unit >= 97 && unit <= 102)))
    }

    /// Escaped source text. After each line break, quote markers and indentation up to `column` are skipped, so
    /// text continuing inside a block quote or list item loses its `>` and indent. Character entities pass through.
    private mutating func source(_ range: NSRange, column: Int) {
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = units[index]
            if unit == 10 {
                out.append(10)
                index = skipPrefix(from: index + 1, column: column, end: end)
                continue
            }
            if unit == 38, let length = entityLength(at: index, end: end) {
                out.append(contentsOf: units[index..<(index + length)])
                index += length
                continue
            }
            escapeUnit(unit)
            index += 1
        }
    }

    private func skipPrefix(from start: Int, column: Int, end: Int) -> Int {
        var index = start
        while index < end && index - start < column && (units[index] == 32 || units[index] == 62 || units[index] == 9) { index += 1 }
        return index
    }

    /// Column of an offset within its line.
    private func column(of offset: Int) -> Int {
        var index = offset
        while index > 0 && units[index - 1] != 10 { index -= 1 }
        return offset - index
    }

    /// The block's lines as ranges, each with the container prefix (quote markers, indent) up to the block's own
    /// starting column removed.
    private func lineSegments(_ block: Block) -> [NSRange] {
        let range = block.range
        let column = column(of: range.location)
        let end = NSMaxRange(range)
        var result: [NSRange] = []
        var start = range.location
        while true {
            var lineEnd = start
            while lineEnd < end && units[lineEnd] != 10 { lineEnd += 1 }
            result.append(NSRange(location: start, length: lineEnd - start))
            guard lineEnd < end else { break }
            start = skipPrefix(from: lineEnd + 1, column: column, end: end)
        }
        return result
    }

    // MARK: Blocks

    mutating func topLevel(_ block: Block) -> String {
        out.removeAll(keepingCapacity: true)
        needsSanitizing = false
        self.block(block, tight: false, extra: " data-block=\"\(block.id.rawValue)\" data-line=\"\(block.lineRange.lowerBound)\"")
        let html = String(decoding: out, as: UTF16.self)
        return needsSanitizing ? Sanitizer.sanitize(html, rewriteURL: renderer.resolveURL) : html
    }

    /// Writes one block. `extra` goes inside the first opening tag; `tight` drops `<p>` around paragraphs.
    private mutating func block(_ block: Block, tight: Bool, extra: String = "", suffix: String = "") {
        let column = column(of: block.range.location)
        switch block.kind {
        case .paragraph:
            if tight && extra.isEmpty && block.attributes.isEmpty {
                inlines(block.inlines, column: column)
                raw(suffix)
                raw("\n")
                return
            }
            raw("<p" + extra + userAttributes(block.attributes) + ">")
            inlines(block.inlines, column: column)
            raw(suffix + "</p>\n")

        case .atxHeading(let level), .setextHeading(let level):
            var attributes = block.attributes
            let id = attributes.removeValue(forKey: "id") ?? slugs[block.id]
            raw("<h\(level)" + extra)
            if let id { raw(" id=\"" + escapeHTML(id) + "\"") }
            raw(userAttributes(attributes) + ">")
            inlines(block.inlines, column: column)
            raw("</h\(level)>\n")

        case .blockQuote:
            raw("<blockquote" + extra + ">\n")
            for child in block.children { self.block(child, tight: false) }
            raw("</blockquote>\n")

        case .bulletList, .orderedList:
            list(block, extra: extra)

        case .listItem:
            listItem(block, tight: tight)

        case .table:
            table(block, extra: extra)

        case .fencedCode(let language):
            code(block, language: language, fenced: true, extra: extra)

        case .indentedCode:
            code(block, language: nil, fenced: false, extra: extra)

        case .mathBlock:
            raw("<div class=\"math-block\"" + extra + ">")
            raw(renderer.math.html(for: mathSource(block), display: true))
            raw("</div>\n")

        case .htmlBlock:
            needsSanitizing = true
            raw("<div class=\"html-block\"" + extra + ">\n")
            let segments = lineSegments(block)
            for (index, segment) in segments.enumerated() {
                out.append(contentsOf: units[segment.location..<NSMaxRange(segment)])
                if index < segments.count - 1 { out.append(10) }
            }
            raw("\n</div>\n")

        case .toc:
            tableOfContents(extra: extra)

        case .thematicBreak:
            raw("<hr" + extra + ">\n")

        case .pageBreak:
            raw("<div class=\"page-break\"" + extra + "></div>\n")

        case .frontMatter, .referenceDefinition, .htmlComment, .footnoteDefinition:
            break
        }
    }

    private mutating func userAttributes(_ attributes: [String: String]) -> String {
        guard !attributes.isEmpty else { return "" }
        needsSanitizing = true
        var result = ""
        for key in attributes.keys.sorted() {
            guard key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }) else { continue }
            result += " \(key)=\"\(escapeHTML(attributes[key]!))\""
        }
        return result
    }

    /// Loose when any two items, or two blocks in one item, are separated by a blank line.
    private func isLoose(_ list: Block) -> Bool {
        let items = list.children
        for (index, item) in items.enumerated() {
            if index + 1 < items.count && item.lineRange.upperBound < items[index + 1].lineRange.lowerBound { return true }
            let children = item.children
            for (childIndex, child) in children.enumerated() where childIndex + 1 < children.count {
                if child.lineRange.upperBound < children[childIndex + 1].lineRange.lowerBound { return true }
            }
        }
        return false
    }

    private mutating func list(_ block: Block, extra: String) {
        let hasTasks = block.children.contains { if case .listItem(task: .some, _) = $0.kind { true } else { false } }
        let taskClass = hasTasks ? " class=\"contains-task-list\"" : ""
        if case .orderedList(let start) = block.kind {
            raw("<ol" + (start != 1 ? " start=\"\(start)\"" : "") + taskClass + extra + ">\n")
        } else {
            raw("<ul" + taskClass + extra + ">\n")
        }
        let tight = !isLoose(block)
        for item in block.children { self.block(item, tight: tight) }
        raw(block.kind == .bulletList ? "</ul>\n" : "</ol>\n")
    }

    private mutating func listItem(_ block: Block, tight: Bool) {
        guard case .listItem(let task, let checked) = block.kind, task != nil else {
            raw("<li>")
            for child in block.children { self.block(child, tight: tight) }
            raw("</li>\n")
            return
        }
        raw("<li class=\"task-list-item\">")
        let box = "<label><input type=\"checkbox\" class=\"task-list-item-checkbox\"" + (checked ? " checked" : "") + "> "
        var children = block.children[...]
        if let first = children.first, first.kind == .paragraph {
            children = children.dropFirst()
            if !tight { raw("<p>") }
            raw(box)
            inlines(first.inlines, column: column(of: first.range.location))
            raw("</label>")
            raw(tight ? "\n" : "</p>\n")
        } else {
            raw(box + "</label>\n")
        }
        for child in children { self.block(child, tight: tight) }
        raw("</li>\n")
    }

    private mutating func table(_ block: Block, extra: String) {
        let segments = lineSegments(block)
        guard segments.count >= 2 else { return }
        let pipes = block.markerRanges.filter { $0.length == 1 && units[$0.location] == 124 }.map(\.location)

        func cells(_ segment: NSRange) -> [NSRange] {
            let start = segment.location
            let end = NSMaxRange(segment)
            let inside = pipes.filter { $0 >= start && $0 < end }
            let bounds = [start - 1] + inside + [end]
            var result: [NSRange] = []
            for index in 0..<(bounds.count - 1) {
                result.append(NSRange(location: bounds[index] + 1, length: bounds[index + 1] - bounds[index] - 1))
            }
            let firstText = (start..<end).first { units[$0] != 32 && units[$0] != 9 }
            if let first = inside.first, firstText == first { result.removeFirst() }
            let lastText = (start..<end).last { units[$0] != 32 && units[$0] != 9 }
            if let last = inside.last, lastText == last, !result.isEmpty { result.removeLast() }
            return result
        }

        var alignments: [String?] = []
        var delimiterRow = string(segments[1]).trimmingCharacters(in: .whitespaces)
        if delimiterRow.hasPrefix("|") { delimiterRow.removeFirst() }
        if delimiterRow.hasSuffix("|") { delimiterRow.removeLast() }
        for cell in delimiterRow.split(separator: "|", omittingEmptySubsequences: false) {
            let text = cell.trimmingCharacters(in: .whitespaces)
            switch (text.hasPrefix(":"), text.hasSuffix(":")) {
            case (true, true): alignments.append("center")
            case (false, true): alignments.append("right")
            case (true, false): alignments.append("left")
            default: alignments.append(nil)
            }
        }
        let header = cells(segments[0])
        let columns = header.count

        func row(_ cellRanges: [NSRange], tag: String) {
            raw("<tr>\n")
            for index in 0..<columns {
                let alignment = index < alignments.count ? alignments[index] : nil
                raw("<\(tag)" + (alignment.map { " style=\"text-align:\($0)\"" } ?? "") + ">")
                if index < cellRanges.count {
                    let cell = cellRanges[index]
                    let content = block.inlines.filter { $0.range.location >= cell.location && NSMaxRange($0.range) <= NSMaxRange(cell) }
                    inlines(content, column: 0)
                }
                raw("</\(tag)>\n")
            }
            raw("</tr>\n")
        }

        raw("<table" + extra + ">\n<thead>\n")
        row(header, tag: "th")
        raw("</thead>\n")
        if segments.count > 2 {
            raw("<tbody>\n")
            for segment in segments[2...] { row(cells(segment), tag: "td") }
            raw("</tbody>\n")
        }
        raw("</table>\n")
    }

    private mutating func code(_ block: Block, language: String?, fenced: Bool, extra: String) {
        var segments = lineSegments(block)
        if fenced {
            let fence = units[block.range.location]
            let first = segments.removeFirst()
            var openLength = 0
            while openLength < first.length && units[first.location + openLength] == fence { openLength += 1 }
            if let last = segments.last {
                let text = string(last).trimmingCharacters(in: .whitespaces)
                if text.utf16.count >= openLength && text.utf16.allSatisfy({ $0 == fence }) { segments.removeLast() }
            }
        }
        raw("<pre" + extra + "><code" + (language.map { " class=\"language-\(escapeHTML($0))\"" } ?? "") + ">")
        let tokens = block.codeTokens ?? []
        var tokenIndex = 0
        for segment in segments {
            var position = segment.location
            let end = NSMaxRange(segment)
            while tokenIndex < tokens.count && NSMaxRange(tokens[tokenIndex].range) <= position { tokenIndex += 1 }
            var scan = tokenIndex
            while scan < tokens.count && tokens[scan].range.location < end {
                let token = tokens[scan]
                let start = max(token.range.location, position)
                let stop = min(NSMaxRange(token.range), end)
                if stop > start {
                    for index in position..<start { escapeUnit(units[index]) }
                    raw("<span class=\"token \(token.type)\">")
                    for index in start..<stop { escapeUnit(units[index]) }
                    raw("</span>")
                    position = stop
                }
                if NSMaxRange(token.range) > end { break }
                scan += 1
            }
            tokenIndex = scan
            for index in position..<end { escapeUnit(units[index]) }
            out.append(10)
        }
        raw("</code></pre>\n")
    }

    /// The text between the `$$` lines, without the outer `$` signs spec 474 removes.
    private func mathSource(_ block: Block) -> String {
        var segments = lineSegments(block)
        let markers = block.markerRanges
        segments.removeFirst()
        if markers.count >= 2, let last = segments.last, NSLocationInRange(markers[1].location, last) { segments.removeLast() }
        let skipped = Set(markers.dropFirst(2).map(\.location))
        var result: [UInt16] = []
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(10) }
            for offset in segment.location..<NSMaxRange(segment) where !skipped.contains(offset) { result.append(units[offset]) }
        }
        return String(decoding: result, as: UTF16.self)
    }

    private mutating func tableOfContents(extra: String) {
        raw("<div class=\"table-of-contents\"" + extra + ">")
        var levels: [Int] = []
        for heading in snapshot.headings {
            let attributeID = snapshot.deepestBlock(at: heading.range.location).flatMap { $0.id == heading.blockID ? $0.attributes["id"] : nil }
            if levels.isEmpty {
                raw("<ul>")
                levels = [heading.level]
            } else if heading.level > levels.last! {
                raw("<ul>")
                levels.append(heading.level)
            } else {
                raw("</li>")
                while levels.count > 1 && heading.level < levels.last! {
                    raw("</ul></li>")
                    levels.removeLast()
                }
            }
            raw("<li><a href=\"#" + escapeHTML(attributeID ?? heading.slug) + "\">")
            escaped(heading.text)
            raw("</a>")
        }
        if levels.isEmpty {
            raw("<ul></ul>")
        } else {
            raw("</li>")
            for _ in 1..<levels.count { raw("</ul></li>") }
            raw("</ul>")
        }
        raw("</div>\n")
    }

    /// The separator rule and numbered list of referenced footnotes, wrapped in one element so the preview can
    /// replace it as a unit. Empty when nothing references a footnote.
    mutating func footnotesSection() -> String {
        let notes = footnotes
        guard !notes.order.isEmpty else { return "" }
        out.removeAll(keepingCapacity: true)
        needsSanitizing = false
        raw("<div class=\"footnotes-wrapper\" data-block=\"\(HTMLRenderer.footnotesID)\">\n<hr class=\"footnotes-sep\">\n")
        raw("<section class=\"footnotes\">\n<ol class=\"footnotes-list\">\n")
        for (index, label) in notes.order.enumerated() {
            let number = index + 1
            var backrefs = ""
            for occurrence in 0..<(notes.counts[label] ?? 1) {
                let id = occurrence == 0 ? "fnref\(number)" : "fnref\(number):\(occurrence)"
                backrefs += " <a href=\"#\(id)\" class=\"footnote-backref\">\u{21A9}\u{FE0E}</a>"
            }
            raw("<li id=\"fn\(number)\" class=\"footnote-item\">")
            let children = notes.definitions[label]?.children ?? []
            if let last = children.last, last.kind == .paragraph {
                for child in children.dropLast() { block(child, tight: false) }
                block(last, tight: false, suffix: backrefs)
            } else {
                for child in children { block(child, tight: false) }
                raw(backrefs)
            }
            raw("</li>\n")
        }
        raw("</ol>\n</section>\n</div>\n")
        let html = String(decoding: out, as: UTF16.self)
        return needsSanitizing ? Sanitizer.sanitize(html, rewriteURL: renderer.resolveURL) : html
    }

    // MARK: Inlines

    private mutating func inlines(_ list: [Inline], column: Int) {
        for inline in list { self.inline(inline, column: column) }
    }

    private mutating func wrap(_ tag: String, _ inline: Inline, column: Int) {
        raw("<\(tag)>")
        if inline.children.isEmpty { source(inline.contentRange, column: column) } else { inlines(inline.children, column: column) }
        raw("</\(tag)>")
    }

    /// A URL as markdown-it writes it: non-ASCII and spaces percent-encoded, existing `%XX` kept.
    private static let urlAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")

    private func href(_ destination: String, image: Bool) -> String? {
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: Self.urlAllowed) ?? destination
        guard Sanitizer.isSafeURL(encoded, image: image) else { return nil }
        return renderer.resolveURL?(encoded) ?? encoded
    }

    private mutating func link(_ destination: String, _ inline: Inline, column: Int) {
        if let url = href(destination, image: false) {
            raw("<a href=\"" + escapeHTML(url) + "\">")
        } else {
            raw("<a>")
        }
        if inline.children.isEmpty { source(inline.contentRange, column: column) } else { inlines(inline.children, column: column) }
        raw("</a>")
    }

    private mutating func image(_ destination: String, alt: String) {
        raw("<img")
        if let url = href(destination, image: true) { raw(" src=\"" + escapeHTML(url) + "\"") }
        raw(" alt=\"" + escapeHTML(alt) + "\">")
    }

    private mutating func inline(_ inline: Inline, column: Int) {
        switch inline.kind {
        case .text, .liquidTag, .shortcutReference:
            source(inline.range, column: column)
        case .emphasis: wrap("em", inline, column: column)
        case .strong: wrap("strong", inline, column: column)
        case .strike: wrap("s", inline, column: column)
        case .highlight: wrap("mark", inline, column: column)
        case .code:
            var text = string(inline.contentRange).replacingOccurrences(of: "\n", with: " ")
            if text.count >= 2, text.hasPrefix(" "), text.hasSuffix(" "), text.contains(where: { $0 != " " }) {
                text = String(text.dropFirst().dropLast())
            }
            raw("<code>")
            escaped(text)
            raw("</code>")
        case .math:
            raw(renderer.math.html(for: string(inline.contentRange), display: false))
        case .link(let destination):
            link(destination, inline, column: column)
        case .referenceLink(let label):
            if let destination = snapshot.referenceDefinitions[label] {
                link(destination, inline, column: column)
            } else {
                source(inline.range, column: column)
            }
        case .image(let destination, let alt):
            image(destination, alt: alt)
        case .referenceImage(let label):
            if let destination = snapshot.referenceDefinitions[label] {
                image(destination, alt: string(inline.contentRange))
            } else {
                source(inline.range, column: column)
            }
        case .footnoteReference:
            if let reference = footnotes.references[inline.range.location] {
                let id = reference.occurrence == 0 ? "fnref\(reference.number)" : "fnref\(reference.number):\(reference.occurrence)"
                raw("<sup class=\"footnote-ref\"><a href=\"#fn\(reference.number)\" id=\"\(id)\">[\(reference.number)]</a></sup>")
            } else {
                source(inline.range, column: column)
            }
        case .autolink(let destination):
            if let url = href(destination, image: false) { raw("<a href=\"" + escapeHTML(url) + "\">") } else { raw("<a>") }
            source(inline.contentRange, column: column)
            raw("</a>")
        case .bareURL(let destination):
            if let url = href(destination, image: false) { raw("<a href=\"" + escapeHTML(url) + "\">") } else { raw("<a>") }
            source(inline.range, column: column)
            raw("</a>")
        case .emoji(let name, let character):
            raw("<span class=\"emoji emoji-" + escapeHTML(name) + "\">" + character + "</span>")
        case .htmlTag:
            needsSanitizing = true
            out.append(contentsOf: units[inline.range.location..<NSMaxRange(inline.range)])
        case .lineBreak:
            raw("<br>\n")
        case .escape:
            source(inline.contentRange, column: column)
        }
    }
}
