import AppKit
import MarkdownDocument
import PlainCore

extension NSAttributedString.Key {
    /// Marks a line drawn on the full-column `--highlight` band (fenced code, math, front matter, HTML blocks).
    static let plainBand = NSAttributedString.Key("plainBand")
    /// `h1`…`h6`: the margin label drawn left of an ATX heading's first line.
    static let plainHeadingLabel = NSAttributedString.Key("plainHeadingLabel")
    /// The trailing spaces of a hard line break; the fragment draws `↓` after the line.
    static let plainLineBreak = NSAttributedString.Key("plainLineBreak")
    /// A `PageMarker` on the first character of a page list line or footnote definition: the bullet, number or box.
    static let plainPageMarker = NSAttributedString.Key("plainPageMarker")
    /// The quote depth (Int) of a page quote line; the fragment draws one bar per level.
    static let plainPageQuote = NSAttributedString.Key("plainPageQuote")
    /// A page divider line; the fragment draws the rule.
    static let plainPageDivider = NSAttributedString.Key("plainPageDivider")
    /// A `PagePanelSlice` on a code panel line; the fragment fills the panel and draws the language label.
    static let plainPagePanel = NSAttributedString.Key("plainPagePanel")
    /// Inline code on the page; the fragment fills a rounded chip behind it.
    static let plainPageChip = NSAttributedString.Key("plainPageChip")
    /// A `PageTableRow` on a page table row; the fragment draws the grid lines and the header fill.
    static let plainPageTableRow = NSAttributedString.Key("plainPageTableRow")
    /// The number (String) of a page footnote reference, on its first character.
    static let plainPageFootnote = NSAttributedString.Key("plainPageFootnote")
    /// A note (String) drawn under the line, such as "Too wide to show as a table".
    static let plainPageNote = NSAttributedString.Key("plainPageNote")
    /// A caption (String) drawn under an image line's picture.
    static let plainPageCaption = NSAttributedString.Key("plainPageCaption")
}

/// What the fragment draws in a page list line's marker box, or for a footnote definition, at `x` from the column's left.
final class PageMarker: NSObject {
    enum Kind: Equatable {
        case bullet
        case number(String)
        case task(checked: Bool)
        case footnote(String)
    }

    let kind: Kind
    let x: CGFloat

    init(_ kind: Kind, x: CGFloat) {
        self.kind = kind
        self.x = x
    }
}

/// One line's part of a code panel.
final class PagePanelSlice: NSObject {
    enum Slice { case top, middle, bottom, single }

    let slice: Slice
    /// The language label drawn on the top slice.
    let label: String?

    init(_ slice: Slice, label: String? = nil) {
        self.slice = slice
        self.label = label
    }
}

/// A page table row: column edges from the column's left (from `HiddenRanges.tableColumns`) and whether it is the header.
final class PageTableRow: NSObject {
    let columnEdges: [CGFloat]
    let isHeader: Bool

    init(columnEdges: [CGFloat], isHeader: Bool) {
        self.columnEdges = columnEdges
        self.isHeader = isHeader
    }
}

/// Sets display attributes on the document's text storage from a snapshot (spec 53–78, 1442–1479).
@MainActor
final class MarkdownStyler {
    let storage: NSTextStorage
    var configuration: EditorConfiguration {
        didSet { paragraphStyles.removeAll() }
    }
    private var paragraphStyles: [String: NSParagraphStyle] = [:]
    private var pageStyles: [String: NSParagraphStyle] = [:]
    /// Called with every range this styler sets attributes on; find, spelling and math redraw over it.
    var didRestyle: ((NSRange) -> Void)?
    /// The text container's width, set by the editor; page tables are laid out in it.
    var pageColumnWidth: CGFloat = 0
    /// Every selection, set by the editor on the page; front matter and setext underlines show their source near them.
    var pageSelections: [NSRange] = []
    /// Whether the last page restyle showed the front matter as source because a selection touched it.
    var frontMatterShownAsSource = false
    let page = Tokens.page

    init(storage: NSTextStorage, configuration: EditorConfiguration) {
        self.storage = storage
        self.configuration = configuration
    }

    var isPage: Bool { !configuration.showMarkdownSource }
    var proseFont: NSFont { EditorFonts.prose(configuration.proseFontSize) }
    var codeFont: NSFont { EditorFonts.code(isPage ? Tokens.page.codeSize : configuration.codeFontSize) }

    var baseParagraphStyle: NSParagraphStyle {
        isPage ? pageParagraphStyle(lineHeight: pageLine) : paragraphStyle(lineHeight: configuration.linePoints, font: proseFont)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: proseFont, .foregroundColor: isPage ? Tokens.page.text : Tokens.color, .paragraphStyle: baseParagraphStyle,
         .ligature: 0, .kern: 0]
    }

    /// A paragraph style with a fixed line height and the font's glyphs centred in it.
    func paragraphStyle(lineHeight: CGFloat, font: NSFont, headIndent: CGFloat = 0) -> NSParagraphStyle {
        let key = "\(lineHeight)|\(font.pointSize)|\(headIndent)"
        if let cached = paragraphStyles[key] { return cached }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.headIndent = headIndent
        style.lineBreakStrategy = .standard
        style.lineBreakMode = .byWordWrapping
        style.tabStops = []
        let space = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        style.defaultTabInterval = space * CGFloat(configuration.tabSize)
        paragraphStyles[key] = style
        return style
    }

    /// Baseline shift that centres the font's glyphs in a line of `lineHeight` points.
    func baselineOffset(_ font: NSFont, lineHeight: CGFloat) -> CGFloat {
        ((lineHeight - (font.ascender - font.descender)) / 2).rounded()
    }

    // MARK: Restyling

    /// Restyles the top-level blocks that intersect `range`, and the lines between them. Returns their ids.
    @discardableResult
    func restyle(snapshot: Snapshot, range: NSRange) -> [BlockID] {
        let length = storage.length
        guard length > 0, (snapshot.text as NSString).length == length else { return [] }
        let signpost = editorSignposter.beginInterval("restyle")
        defer { editorSignposter.endInterval("restyle", signpost) }
        let text = storage.string as NSString
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
        var extended = text.paragraphRange(for: clamped)
        if isPage {
            // Separators and setext underlines depend on the lines next to them.
            if extended.location > 0 { extended = NSUnionRange(extended, text.paragraphRange(for: NSRange(location: extended.location - 1, length: 0))) }
            if NSMaxRange(extended) < length { extended = NSUnionRange(extended, text.paragraphRange(for: NSRange(location: NSMaxRange(extended), length: 0))) }
        }
        var touched: [Block] = []
        var index = Self.firstBlockIndex(at: extended.location, in: snapshot.blocks)
        while index < snapshot.blocks.count {
            let block = snapshot.blocks[index]
            if block.range.location > NSMaxRange(extended) { break }
            touched.append(block)
            index += 1
        }
        for block in touched { extended = NSUnionRange(extended, text.paragraphRange(for: block.range)) }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: extended)
        if isPage {
            stylePage(touched, snapshot: snapshot, range: extended)
        } else {
            for block in touched { style(block, snapshot: snapshot) }
            applyHangingIndents(in: extended, text: text)
        }
        storage.endEditing()
        didRestyle?(extended)
        return touched.map(\.id)
    }

    static func firstBlockIndex(at offset: Int, in blocks: [Block]) -> Int {
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(blocks[mid].range) < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Blocks

    private func style(_ block: Block, snapshot: Snapshot, inSecondary: Bool = false) {
        let range = block.range
        switch block.kind {
        case .paragraph:
            styleInlines(block.inlines)
            fade(block.markerRanges)
        case .atxHeading(let level):
            styleATXHeading(block, level: level)
        case .setextHeading(let level):
            let size = headingSize(level)
            setFont(EditorFonts.code(size, bold: true), range, lineHeight: headingLineHeight(level, setext: true))
            set(.foregroundColor, Tokens.colorEm, range)
            styleInlines(block.inlines)
            fade(block.markerRanges)
        case .blockQuote:
            styleMarkers(block.markerRanges)
            for child in block.children { style(child, snapshot: snapshot, inSecondary: inSecondary) }
        case .bulletList, .orderedList:
            for child in block.children { style(child, snapshot: snapshot, inSecondary: inSecondary) }
        case .listItem:
            // The marker includes the item's leading spaces so nested markers line up (spec 1465).
            var markers = block.markerRanges
            if let first = markers.first {
                let lineStart = (storage.string as NSString).lineRange(for: NSRange(location: first.location, length: 0)).location
                markers[0] = NSRange(location: lineStart, length: NSMaxRange(first) - lineStart)
            }
            styleMarkers(markers)
            for child in block.children { style(child, snapshot: snapshot, inSecondary: inSecondary) }
        case .table:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorSecondary, range)
            styleInlines(block.inlines, secondary: true)
            fade(block.markerRanges)
        case .fencedCode:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorSecondary, range)
            band(bodyRange(block))
            for token in block.codeTokens ?? [] {
                if let colour = Self.tokenColours[token.type] { set(.foregroundColor, colour, token.range) }
            }
            fade(block.markerRanges)
        case .mathBlock:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorSecondary, range)
            band(range)
            styleMathSource(range)
            fade(block.markerRanges)
        case .frontMatter:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorSecondary, range)
            band(bodyRange(block))
            fade(block.markerRanges)
        case .htmlBlock:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorSecondary, range)
            band(range)
        case .indentedCode, .htmlComment, .referenceDefinition:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorSecondary, range)
        case .footnoteDefinition:
            set(.foregroundColor, Tokens.colorSecondary, range)
            for marker in block.markerRanges { setFont(codeFont, marker) }
            for child in block.children { style(child, snapshot: snapshot, inSecondary: true) }
            set(.foregroundColor, Tokens.colorSecondary, range)
        case .toc:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorBlue, range)
        case .thematicBreak:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorTertiary, range)
        case .pageBreak:
            setFont(codeFont, range)
            set(.foregroundColor, Tokens.colorRed, range)
        }
    }

    func headingSize(_ level: Int) -> CGFloat {
        guard configuration.largeHeadings else { return configuration.fontSize }
        switch level {
        case 1: return (configuration.fontSize * 1.4).rounded()
        case 2: return (configuration.fontSize * 1.2).rounded()
        default: return configuration.fontSize
        }
    }

    /// 33.6 and 28.8 points for large h1 and h2 at the default sizes (spec 1342–1343); setext uses 1.5em.
    func headingLineHeight(_ level: Int, setext: Bool = false) -> CGFloat {
        guard configuration.largeHeadings, level <= 2 else { return configuration.linePoints }
        let scale: CGFloat = level == 1 ? 1.4 : 1.2
        return configuration.fontSize * scale * (setext ? 1.5 : configuration.lineHeight)
    }

    private func styleATXHeading(_ block: Block, level: Int) {
        let range = block.range
        let size = headingSize(level)
        let font = NSFont.boldSystemFont(ofSize: size)
        setFont(font, range, lineHeight: headingLineHeight(level))
        set(.foregroundColor, Tokens.colorEm, range)
        styleInlines(block.inlines)
        let markers = block.markerRanges
        if let open = markers.first {
            // The `#` run and the space after it take no width; the fragment draws `hN` in the margin (spec 76).
            var hidden = open
            let text = storage.string as NSString
            if NSMaxRange(hidden) < text.length, text.character(at: NSMaxRange(hidden)) == 32 { hidden.length += 1 }
            collapse(hidden, font: font)
            storage.addAttribute(.plainHeadingLabel, value: "h\(level)", range: NSRange(location: range.location, length: 1))
        }
        fade(Array(markers.dropFirst()))
    }

    /// Draws the characters at zero width: each gets a negative kern equal to its own advance and a clear colour.
    private func collapse(_ range: NSRange, font: NSFont) {
        let text = storage.string as NSString
        for offset in range.location..<NSMaxRange(range) {
            let character = text.substring(with: NSRange(location: offset, length: 1))
            let width = NSAttributedString(string: character, attributes: [.font: font]).size().width
            storage.addAttributes([.kern: -width, .foregroundColor: NSColor.clear], range: NSRange(location: offset, length: 1))
        }
    }

    /// Lines between the first and last fence (the last only when it closes the block).
    private func bodyRange(_ block: Block) -> NSRange {
        let markers = block.markerRanges
        let text = storage.string as NSString
        guard let open = markers.first else { return block.range }
        let start = NSMaxRange(text.lineRange(for: open))
        let end = markers.count > 1 ? text.lineRange(for: markers[1]).location : NSMaxRange(block.range)
        return NSRange(location: min(start, end), length: max(end - start, 0))
    }

    private func band(_ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.plainBand, value: true, range: range)
    }

    /// `\command` names red, braces faded (spec 1469).
    private func styleMathSource(_ range: NSRange) {
        let text = storage.string as NSString
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let c = text.character(at: index)
            if c == 92 {
                var stop = index + 1
                while stop < end, let scalar = UnicodeScalar(text.character(at: stop)), CharacterSet.letters.contains(scalar) { stop += 1 }
                if stop > index + 1 { set(.foregroundColor, Tokens.colorRed, NSRange(location: index, length: stop - index)) }
                index = max(stop, index + 1)
            } else {
                if c == 123 || c == 125 { set(.foregroundColor, Tokens.colorTertiary, NSRange(location: index, length: 1)) }
                index += 1
            }
        }
    }

    // MARK: Inlines

    private func styleInlines(_ inlines: [Inline], secondary: Bool = false) {
        for inline in inlines { style(inline) }
    }

    private func style(_ inline: Inline) {
        let range = inline.range
        switch inline.kind {
        case .text:
            break
        case .emphasis:
            addTrait(.italicFontMask, range)
            fade(inline.markerRanges)
        case .strong:
            addTrait(.boldFontMask, range)
            fade(inline.markerRanges)
        case .strike:
            set(.foregroundColor, Tokens.colorSecondary, inline.contentRange)
            set(.strikethroughStyle, NSUnderlineStyle.single.rawValue, inline.contentRange)
            fade(inline.markerRanges)
        case .highlight:
            set(.backgroundColor, Tokens.highlightInfo, range)
            for marker in inline.markerRanges { set(.foregroundColor, Tokens.colorSecondary, marker) }
        case .code, .math:
            setFont(EditorFonts.code(configuration.codeFontSize), range, keepParagraph: true)
            set(.foregroundColor, Tokens.colorGold, range)
            fade(inline.markerRanges)
        case .link, .referenceLink, .footnoteReference, .autolink:
            set(.foregroundColor, Tokens.colorTertiary, range)
            set(.foregroundColor, Tokens.colorBlue, inline.contentRange)
            fade(inline.markerRanges)
        case .bareURL:
            set(.foregroundColor, Tokens.colorBlue, range)
        case .image, .referenceImage:
            set(.foregroundColor, Tokens.colorTertiary, range)
            set(.foregroundColor, Tokens.colorSecondary, inline.contentRange)
        case .emoji:
            set(.foregroundColor, Tokens.colorSecondary, range)
            fade(inline.markerRanges)
        case .htmlTag:
            setFont(codeFont, range, keepParagraph: true)
            set(.foregroundColor, Tokens.colorSecondary, range)
            let text = storage.string as NSString
            for offset in range.location..<NSMaxRange(range) where "<>=\"'/".utf16.contains(text.character(at: offset)) {
                set(.foregroundColor, Tokens.colorTertiary, NSRange(location: offset, length: 1))
            }
        case .liquidTag:
            setFont(codeFont, range, keepParagraph: true)
            set(.foregroundColor, Tokens.colorSecondary, range)
            fade(inline.markerRanges)
        case .lineBreak:
            storage.addAttribute(.plainLineBreak, value: true, range: range)
        case .escape, .shortcutReference:
            fade(inline.markerRanges)
        }
        for child in inline.children { style(child) }
    }

    // MARK: Hanging indents

    /// Wrapped lines of list items and indented lines start under the text after the marker (spec 38).
    private func applyHangingIndents(in range: NSRange, text: NSString) {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let prefix = ListPattern.prefixLength(of: text, lineStart: line.location, lineEnd: NSMaxRange(line))
            if prefix > 0 {
                let width = storage.attributedSubstring(from: NSRange(location: line.location, length: prefix)).size().width
                if let current = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle {
                    let font = (storage.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont) ?? proseFont
                    let style = paragraphStyle(lineHeight: current.minimumLineHeight, font: font, headIndent: width.rounded())
                    storage.addAttribute(.paragraphStyle, value: style, range: line)
                }
            }
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
    }

    // MARK: Attribute helpers

    private func set(_ key: NSAttributedString.Key, _ value: Any, _ range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(key, value: value, range: range)
    }

    private func fade(_ ranges: [NSRange]) {
        for range in ranges { set(.foregroundColor, Tokens.colorTertiary, range) }
    }

    /// Block markers (list, quote): code font, secondary colour (spec 67).
    private func styleMarkers(_ ranges: [NSRange]) {
        for range in ranges {
            setFont(codeFont, range, keepParagraph: true)
            set(.foregroundColor, Tokens.colorSecondary, range)
        }
    }

    /// Sets the font, a matching centred baseline and, unless `keepParagraph`, the paragraph's line height.
    private func setFont(_ font: NSFont, _ range: NSRange, lineHeight: CGFloat? = nil, keepParagraph: Bool = false) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let height = lineHeight ?? configuration.linePoints
        storage.addAttribute(.font, value: font, range: range)
        storage.addAttribute(.baselineOffset, value: baselineOffset(font, lineHeight: height), range: range)
        if !keepParagraph { storage.addAttribute(.paragraphStyle, value: paragraphStyle(lineHeight: height, font: font), range: range) }
    }

    private func addTrait(_ trait: NSFontTraitMask, _ range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
        }
    }

    static let tokenColours: [String: NSColor] = Tokens.prismTokenColours.mapValues(\.dynamic)
}

// MARK: - Page

/// Page styling (docs/wysiwyg-spec.md): Markdown hidden at a 0.01 pt clear font, blocks drawn by the layout fragment.
extension MarkdownStyler {
    /// Quote and list nesting around a block, and the indent its lines start at.
    struct PageContext {
        var quoteDepth = 0
        var listDepth = 0
        var indent: CGFloat = 0
    }

    /// The body line height: 16 × 1.5.
    var pageLine: CGFloat { page.bodySize * page.bodyLine }
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    static let pageCodeFont = EditorFonts.code(Tokens.page.codeSize)
    static let pageTokenColours: [String: NSColor] = Tokens.page.codeTokenColours.mapValues(\.dynamic)

    /// A paragraph style with a fixed line height, cached by its values.
    func pageParagraphStyle(lineHeight: CGFloat, indent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0,
                            tailIndent: CGFloat = 0) -> NSParagraphStyle {
        let key = "\(lineHeight)|\(indent)|\(spacingBefore)|\(spacingAfter)|\(tailIndent)"
        if let cached = pageStyles[key] { return cached }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.tailIndent = tailIndent
        style.lineBreakStrategy = .standard
        style.lineBreakMode = .byWordWrapping
        style.tabStops = []
        style.defaultTabInterval = 4 * NSAttributedString(string: " ", attributes: [.font: proseFont]).size().width
        pageStyles[key] = style
        return style
    }

    /// The main caret when it is one empty selection; setext underlines under it stay visible.
    var pageCaret: Int? {
        guard let first = pageSelections.first, first.length == 0 else { return nil }
        return first.location
    }

    func stylePage(_ blocks: [Block], snapshot: Snapshot, range: NSRange) {
        let text = storage.string as NSString
        for block in blocks { pageStyle(block, snapshot: snapshot, context: PageContext()) }
        let hidden = HiddenRanges.list(in: range, snapshot: snapshot, text: text, columnWidth: pageColumnWidth, caret: pageCaret)
        for item in hidden {
            let part = NSIntersectionRange(item.range, range)
            guard part.length > 0 else { continue }
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: part)
            if item.kind == .separator {
                storage.addAttribute(.paragraphStyle, value: pageParagraphStyle(lineHeight: 2), range: part)
            }
        }
        for block in blocks where block.kind == .table { pushTableCells(block, text: text, range: range) }
    }

    private func pageStyle(_ block: Block, snapshot: Snapshot, context: PageContext) {
        let text = storage.string as NSString
        let range = block.range
        switch block.kind {
        case .paragraph:
            pageInlines(block.inlines, snapshot: snapshot)
            for marker in block.markerRanges { set(.foregroundColor, page.textSecondary, marker) }
        case .atxHeading(let level):
            pageHeading(block, level: level, content: range, snapshot: snapshot, context: context)
        case .setextHeading(let level):
            guard let underline = block.markerRanges.first else { return }
            let line = HiddenRanges.lineContents(at: underline.location, in: text)
            if let caret = pageCaret, caret >= line.location, caret <= NSMaxRange(line) {
                pageInlines(block.inlines, snapshot: snapshot)
                return
            }
            let content = NSRange(location: range.location, length: max(line.location - 1 - range.location, 0))
            pageHeading(block, level: level, content: content, snapshot: snapshot, context: context)
            set(.paragraphStyle, pageParagraphStyle(lineHeight: 1), text.lineRange(for: line))
        case .blockQuote:
            var inner = context
            inner.quoteDepth += 1
            inner.indent = CGFloat(inner.quoteDepth) * page.quoteIndent
            forEachLine(of: range) { line in
                set(.paragraphStyle, pageParagraphStyle(lineHeight: pageLine, indent: inner.indent), text.lineRange(for: line))
                set(.plainPageQuote, inner.quoteDepth, text.lineRange(for: line))
            }
            for child in block.children { pageStyle(child, snapshot: snapshot, context: inner) }
        case .bulletList, .orderedList:
            var ordered = false
            if case .orderedList = block.kind { ordered = true }
            for item in block.children { pageListItem(item, ordered: ordered, snapshot: snapshot, context: context) }
        case .listItem:
            pageListItem(block, ordered: false, snapshot: snapshot, context: context)
        case .table:
            pageTable(block, snapshot: snapshot)
        case .fencedCode(let language):
            pageCode(block, language: language, fenced: true, context: context)
        case .indentedCode:
            pageCode(block, language: nil, fenced: false, context: context)
        case .mathBlock:
            setFont(codeFont, range, keepParagraph: true)
            set(.foregroundColor, page.textSecondary, range)
        case .frontMatter:
            pageFrontMatter(block)
        case .htmlBlock, .htmlComment, .referenceDefinition, .toc, .pageBreak:
            set(.foregroundColor, page.textSecondary, range)
        case .footnoteDefinition(let label):
            let small = NSFont.systemFont(ofSize: page.smallTextSize)
            storage.addAttribute(.font, value: small, range: range)
            set(.paragraphStyle, pageParagraphStyle(lineHeight: pageLine, indent: context.indent + page.markerBox), text.paragraphRange(for: range))
            var inner = context
            inner.indent += page.markerBox
            for child in block.children { pageStyle(child, snapshot: snapshot, context: inner) }
            set(.foregroundColor, page.textSecondary, range)
            if let number = snapshot.footnotes.order.firstIndex(of: label).map({ $0 + 1 }) {
                set(.plainPageMarker, PageMarker(.footnote("\(number)."), x: context.indent), NSRange(location: text.lineRange(for: NSRange(location: range.location, length: 0)).location, length: 1))
            }
        case .thematicBreak:
            let line = text.lineRange(for: NSRange(location: range.location, length: 0))
            set(.paragraphStyle, pageParagraphStyle(lineHeight: 2 * page.dividerSpace + 1), line)
            set(.plainPageDivider, true, line)
        }
    }

    /// Calls `body` with each line of `range`, without its line break.
    private func forEachLine(of range: NSRange, _ body: (NSRange) -> Void) {
        let text = storage.string as NSString
        var location = range.location
        repeat {
            let line = HiddenRanges.lineContents(at: location, in: text)
            body(line)
            location = NSMaxRange(line) + 1
        } while location <= NSMaxRange(range) && location < text.length
    }

    private func pageHeading(_ block: Block, level: Int, content: NSRange, snapshot: Snapshot, context: PageContext) {
        let index = min(max(level, 1), 6) - 1
        let size = page.headingSizes[index]
        let font = NSFont.boldSystemFont(ofSize: size)
        let lineHeight = size * page.bodyLine
        guard content.length > 0 else { return }
        storage.addAttribute(.font, value: font, range: content)
        storage.addAttribute(.baselineOffset, value: baselineOffset(font, lineHeight: lineHeight), range: content)
        let style = pageParagraphStyle(lineHeight: lineHeight, indent: context.indent, spacingBefore: page.headingSpaceAbove[index],
                                       spacingAfter: page.headingSpaceBelow)
        set(.paragraphStyle, style, (storage.string as NSString).paragraphRange(for: content))
        pageInlines(block.inlines, snapshot: snapshot)
        for marker in block.markerRanges where marker.length > 0 && (storage.string as NSString).character(at: marker.location) == 123 {
            set(.foregroundColor, page.textSecondary, marker)
        }
    }

    private func pageListItem(_ item: Block, ordered: Bool, snapshot: Snapshot, context: PageContext) {
        guard case .listItem(let task, let checked) = item.kind, let marker = item.markerRanges.first else {
            return pageStyle(item, snapshot: snapshot, context: context)
        }
        let text = storage.string as NSString
        let x = CGFloat(context.quoteDepth) * page.quoteIndent + CGFloat(context.listDepth) * page.levelIndent
        let indent = x + page.markerBox + page.markerGap
        let nested = item.children.filter {
            switch $0.kind {
            case .bulletList, .orderedList: return true
            default: return false
            }
        }.map(\.range)
        var own: [NSRange] = []
        forEachLine(of: item.range) { line in
            if !nested.contains(where: { NSLocationInRange(line.location, $0) || (line.location <= $0.location && $0.location <= NSMaxRange(line)) }) {
                own.append(line)
            }
        }
        let style = pageParagraphStyle(lineHeight: pageLine, indent: indent)
        for line in own { set(.paragraphStyle, style, text.lineRange(for: line)) }
        let first = HiddenRanges.lineContents(at: marker.location, in: text)
        let kind: PageMarker.Kind
        if task == true {
            kind = .task(checked: checked)
        } else if ordered {
            kind = .number(text.substring(with: marker).trimmingCharacters(in: .whitespaces))
        } else {
            kind = .bullet
        }
        set(.plainPageMarker, PageMarker(kind, x: x), NSRange(location: first.location, length: 1))
        var inner = context
        inner.indent = indent
        for child in item.children {
            switch child.kind {
            case .bulletList, .orderedList:
                var deeper = context
                deeper.listDepth += 1
                pageStyle(child, snapshot: snapshot, context: deeper)
            default:
                pageStyle(child, snapshot: snapshot, context: inner)
            }
        }
        if task == true, checked, let last = own.last {
            let start = item.markerRanges.count > 1 ? NSMaxRange(item.markerRanges[1]) : NSMaxRange(marker)
            let done = NSRange(location: start, length: max(NSMaxRange(last) - start, 0))
            set(.foregroundColor, page.textTertiary, done)
            set(.strikethroughStyle, NSUnderlineStyle.single.rawValue, done)
        }
    }

    private func pageCode(_ block: Block, language: String?, fenced: Bool, context: PageContext) {
        let text = storage.string as NSString
        let range = block.range
        let font = Self.pageCodeFont
        let bodyLine = page.codeSize * page.codeLine
        storage.addAttribute(.font, value: font, range: range)
        storage.addAttribute(.baselineOffset, value: baselineOffset(font, lineHeight: bodyLine), range: range)
        set(.foregroundColor, page.text, range)
        for token in block.codeTokens ?? [] {
            if let colour = Self.pageTokenColours[token.type] { set(.foregroundColor, colour, token.range) }
        }
        var lines: [NSRange] = []
        forEachLine(of: range) { lines.append(text.lineRange(for: $0)) }
        let markers = block.markerRanges
        let closed = fenced && markers.count >= 2
        let hidesFences = fenced && lines.count - 1 - (closed ? 1 : 0) >= 1
        let body = pageParagraphStyle(lineHeight: bodyLine, indent: context.indent + page.codePadSides, tailIndent: -page.codePadSides)
        for (index, line) in lines.enumerated() {
            var slice: PagePanelSlice.Slice = .middle
            if lines.count == 1 { slice = .single } else if index == 0 { slice = .top } else if index == lines.count - 1 { slice = .bottom }
            var style = body
            var label: String?
            if hidesFences && index == 0 {
                style = pageParagraphStyle(lineHeight: page.codePadTop + 18 + page.codeHeaderGap)
                label = PageBlocks.languageName(language)
            } else if hidesFences && closed && index == lines.count - 1 {
                style = pageParagraphStyle(lineHeight: page.codePadBottom)
            }
            set(.paragraphStyle, style, line)
            set(.plainPagePanel, PagePanelSlice(slice, label: label), line)
        }
    }

    private func pageTable(_ block: Block, snapshot: Snapshot) {
        let text = storage.string as NSString
        let range = block.range
        let columns = HiddenRanges.tableColumns(table: block, text: text, columnWidth: pageColumnWidth)
        var lines: [NSRange] = []
        forEachLine(of: range) { lines.append($0) }
        if columns.wide {
            setFont(codeFont, range, lineHeight: pageLine)
            set(.foregroundColor, page.textSecondary, range)
            pageInlines(block.inlines, snapshot: snapshot)
            for marker in block.markerRanges { set(.foregroundColor, page.textTertiary, marker) }
            if let last = lines.last {
                let full = text.lineRange(for: last)
                set(.plainPageNote, "Too wide to show as a table", full)
                set(.paragraphStyle, pageParagraphStyle(lineHeight: pageLine + 21), full)
                storage.addAttribute(.baselineOffset, value: baselineOffset(codeFont, lineHeight: pageLine) + 21, range: last)
            }
            return
        }
        let rowHeight = 2 * page.cellPadV + 21
        for (index, line) in lines.enumerated() {
            let full = text.lineRange(for: line)
            if index == 1 {
                set(.paragraphStyle, pageParagraphStyle(lineHeight: 1), full)
                continue
            }
            let font = index == 0 ? NSFont.boldSystemFont(ofSize: page.cellTextSize) : NSFont.systemFont(ofSize: page.cellTextSize)
            storage.addAttribute(.font, value: font, range: line)
            storage.addAttribute(.baselineOffset, value: baselineOffset(font, lineHeight: rowHeight), range: line)
            set(.paragraphStyle, pageParagraphStyle(lineHeight: rowHeight), full)
            set(.plainPageTableRow, PageTableRow(columnEdges: columns.edges, isHeader: index == 0), full)
        }
        pageInlines(block.inlines, snapshot: snapshot)
    }

    /// Kerns the first hidden character of each gap so cell `i`'s text starts at `edges[i] + 10`.
    private func pushTableCells(_ block: Block, text: NSString, range: NSRange) {
        let columns = HiddenRanges.tableColumns(table: block, text: text, columnWidth: pageColumnWidth)
        guard !columns.wide else { return }
        var lines: [NSRange] = []
        forEachLine(of: block.range) { lines.append($0) }
        for (index, line) in lines.enumerated() where index != 1 && NSIntersectionRange(line, range).length > 0 {
            var x: CGFloat = 0
            var gapStart = line.location
            for (column, cell) in HiddenRanges.cells(of: line, in: text).enumerated() where column + 1 < columns.edges.count {
                let target = columns.edges[column] + page.cellPadH
                if cell.location > gapStart { storage.addAttribute(.kern, value: target - x, range: NSRange(location: gapStart, length: 1)) }
                x = target + (cell.length > 0 ? storage.attributedSubstring(from: cell).size().width : 0)
                gapStart = NSMaxRange(cell)
            }
        }
    }

    /// True when a selection touches the block or the line just above or below it (the zone `showsMathSource` uses).
    static func selectionsTouch(_ block: Block, selections: [NSRange], text: NSString) -> Bool {
        let range = block.range
        let first = HiddenRanges.lineContents(at: range.location, in: text)
        let start = first.location > 0 ? HiddenRanges.lineContents(at: first.location - 1, in: text).location : first.location
        let lastLine = HiddenRanges.lineContents(at: NSMaxRange(range), in: text)
        let end = NSMaxRange(lastLine) < text.length ? NSMaxRange(HiddenRanges.lineContents(at: NSMaxRange(lastLine) + 1, in: text)) : NSMaxRange(lastLine)
        let zone = NSRange(location: start, length: end - start)
        return selections.contains {
            NSLocationInRange($0.location, zone) || NSLocationInRange(NSMaxRange($0), zone)
                || ($0.location <= zone.location && NSMaxRange($0) >= NSMaxRange(zone))
        }
    }

    private func pageFrontMatter(_ block: Block) {
        let text = storage.string as NSString
        let range = block.range
        let touched = Self.selectionsTouch(block, selections: pageSelections, text: text)
        frontMatterShownAsSource = touched
        var lines: [NSRange] = []
        forEachLine(of: range) { lines.append($0) }
        if touched {
            let font = Self.pageCodeFont
            let bodyLine = page.codeSize * page.codeLine
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.baselineOffset, value: baselineOffset(font, lineHeight: bodyLine), range: range)
            set(.foregroundColor, page.text, range)
            let style = pageParagraphStyle(lineHeight: bodyLine, indent: page.codePadSides, tailIndent: -page.codePadSides)
            for (index, line) in lines.enumerated() {
                var slice: PagePanelSlice.Slice = .middle
                if lines.count == 1 { slice = .single } else if index == 0 { slice = .top } else if index == lines.count - 1 { slice = .bottom }
                let full = text.lineRange(for: line)
                set(.paragraphStyle, style, full)
                set(.plainPagePanel, PagePanelSlice(slice), full)
            }
            return
        }
        let small = NSFont.systemFont(ofSize: page.smallTextSize)
        let rowHeight = 21 + 2 * page.frontRowPad
        for (index, line) in lines.enumerated() {
            let full = text.lineRange(for: line)
            if index == 0 || (index == lines.count - 1 && lines.count > 1) {
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: line)
                set(.paragraphStyle, pageParagraphStyle(lineHeight: 1), full)
                continue
            }
            storage.addAttribute(.font, value: small, range: line)
            set(.paragraphStyle, pageParagraphStyle(lineHeight: rowHeight), full)
            let string = text.substring(with: line) as NSString
            let colon = string.range(of: ":")
            guard colon.location != NSNotFound, colon.location > 0, !" -\t".contains(string.substring(to: 1)) else {
                set(.foregroundColor, page.textSecondary, line)
                continue
            }
            let key = NSRange(location: line.location, length: colon.location)
            var valueStart = colon.location + 1
            while valueStart < string.length, string.character(at: valueStart) == 32 { valueStart += 1 }
            let hidden = NSRange(location: line.location + colon.location, length: valueStart - colon.location)
            set(.foregroundColor, page.textSecondary, key)
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: hidden)
            let keyWidth = storage.attributedSubstring(from: key).size().width
            storage.addAttribute(.kern, value: page.frontKeyWidth - keyWidth, range: NSRange(location: hidden.location, length: 1))
            let value = string.substring(from: valueStart).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]") {
                let open = line.location + valueStart + (string.substring(from: valueStart) as NSString).range(of: "[").location
                let close = line.location + (string as NSString).range(of: "]", options: .backwards).location
                for bracket in [open, close] {
                    storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: bracket, length: 1))
                }
            }
        }
    }

    // MARK: Page inlines

    private func pageInlines(_ inlines: [Inline], snapshot: Snapshot) {
        for inline in inlines { pageInline(inline, snapshot: snapshot) }
    }

    private func pageInline(_ inline: Inline, snapshot: Snapshot) {
        let range = inline.range
        switch inline.kind {
        case .text, .lineBreak, .escape, .shortcutReference:
            break
        case .emphasis:
            addTrait(.italicFontMask, range)
        case .strong:
            addTrait(.boldFontMask, range)
        case .strike:
            set(.foregroundColor, page.textSecondary, inline.contentRange)
            set(.strikethroughStyle, NSUnderlineStyle.single.rawValue, inline.contentRange)
        case .code:
            storage.addAttribute(.font, value: Self.pageCodeFont, range: range)
            set(.foregroundColor, Tokens.colorRed, range)
            set(.plainPageChip, true, inline.contentRange)
            for marker in inline.markerRanges where marker.length > 0 {
                storage.addAttribute(.kern, value: page.chipPadH, range: NSRange(location: NSMaxRange(marker) - 1, length: 1))
            }
        case .math, .emoji, .htmlTag, .liquidTag:
            set(.foregroundColor, page.textSecondary, range)
        case .highlight:
            set(.backgroundColor, Tokens.selectionYellow, inline.contentRange)
        case .link(let destination), .autolink(let destination):
            pageLink(inline.contentRange, destination: destination)
        case .bareURL(let destination):
            pageLink(range, destination: destination)
        case .referenceLink(let label):
            pageLink(inline.contentRange, destination: snapshot.referenceDefinitions[label] ?? "")
        case .image, .referenceImage:
            set(.foregroundColor, page.textSecondary, inline.contentRange)
        case .footnoteReference:
            if let number = snapshot.footnotes.references[range.location]?.number, range.length > 0 {
                let label = "\(number)"
                set(.plainPageFootnote, label, NSRange(location: range.location, length: 1))
                let width = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: page.footnoteSize)]).size().width
                storage.addAttribute(.kern, value: ceil(width), range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            }
        }
        for child in inline.children { pageInline(child, snapshot: snapshot) }
    }

    private func pageLink(_ range: NSRange, destination: String) {
        set(.foregroundColor, page.text, range)
        set(.underlineStyle, NSUnderlineStyle.single.rawValue, range)
        set(.underlineColor, page.textTertiary, range)
        if !destination.isEmpty { set(.toolTip, destination, range) }
    }
}

/// The leading part of a line that list continuation repeats: indentation, then a bullet, task box, number or quote
/// marker and the spaces after it (spec 125).
enum ListPattern {
    static func prefixLength(of text: NSString, lineStart: Int, lineEnd: Int) -> Int {
        var index = lineStart
        func skipSpaces() { while index < lineEnd, text.character(at: index) == 32 || text.character(at: index) == 9 { index += 1 } }
        skipSpaces()
        let indentEnd = index
        guard index < lineEnd else { return 0 }
        let c = text.character(at: index)
        if c == 45 || c == 42 || c == 43 {
            guard index + 1 < lineEnd, text.character(at: index + 1) == 32 else { return indentEnd - lineStart }
            index += 1
            skipSpaces()
            if index + 3 < lineEnd + 1, index + 2 < lineEnd, text.character(at: index) == 91,
               [32, 120, 88].contains(text.character(at: index + 1)), text.character(at: index + 2) == 93,
               index + 3 < lineEnd, text.character(at: index + 3) == 32 {
                index += 3
                skipSpaces()
            }
            return index - lineStart
        }
        if c >= 48 && c <= 57 {
            var digits = index
            while digits < lineEnd, digits - index < 9, text.character(at: digits) >= 48, text.character(at: digits) <= 57 { digits += 1 }
            guard digits < lineEnd, text.character(at: digits) == 46 || text.character(at: digits) == 41,
                  digits + 1 < lineEnd, text.character(at: digits + 1) == 32 else { return indentEnd - lineStart }
            index = digits + 1
            skipSpaces()
            return index - lineStart
        }
        if c == 62 {
            while index < lineEnd, text.character(at: index) == 62 {
                index += 1
                skipSpaces()
            }
            return index - lineStart
        }
        return indentEnd - lineStart
    }
}
