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
}

/// Sets display attributes on the document's text storage from a snapshot (spec 53–78, 1442–1479).
@MainActor
final class MarkdownStyler {
    let storage: NSTextStorage
    var configuration: EditorConfiguration {
        didSet { paragraphStyles.removeAll() }
    }
    private var paragraphStyles: [String: NSParagraphStyle] = [:]
    /// Called with every range this styler sets attributes on; find, spelling and math redraw over it.
    var didRestyle: ((NSRange) -> Void)?

    init(storage: NSTextStorage, configuration: EditorConfiguration) {
        self.storage = storage
        self.configuration = configuration
    }

    var proseFont: NSFont { EditorFonts.prose(configuration.fontSize) }
    var codeFont: NSFont { EditorFonts.code(configuration.codeFontSize) }

    var baseParagraphStyle: NSParagraphStyle { paragraphStyle(lineHeight: configuration.linePoints, font: proseFont) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: proseFont, .foregroundColor: Tokens.color, .paragraphStyle: baseParagraphStyle, .ligature: 0, .kern: 0]
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
        for block in touched { style(block, snapshot: snapshot) }
        applyHangingIndents(in: extended, text: text)
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
