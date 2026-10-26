import AppKit
import PlainCore
import PlainVendor

extension NSAttributedString.Key {
    /// An image drawn over the paragraph's source text, which is coloured clear (inline images and math renders).
    static let plainOverlay = NSAttributedString.Key("plainOverlay")
}

/// An image shown in place of source lines. `selected` draws the blue cover of spec 1509.
final class OverlayImage: NSObject {
    let image: NSImage
    let size: NSSize
    let topSpacing: CGFloat
    /// Distance from the column's left edge (the line's indent).
    let left: CGFloat
    let selected: Bool

    init(image: NSImage, size: NSSize, topSpacing: CGFloat, left: CGFloat = 0, selected: Bool = false) {
        self.image = image
        self.size = size
        self.topSpacing = topSpacing
        self.left = left
        self.selected = selected
    }
}

/// Draws what TextKit cannot draw from attributes alone, without adding characters to the text: the `h1`…`h6` margin
/// label (spec 76, 1405–1408), the hard-break `↓` (spec 63, 1478) and overlay images.
final class EditorLayoutFragment: NSTextLayoutFragment {
    private static let labelMargin: CGFloat = 60

    private var attributes: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        bounds.origin.x -= Self.labelMargin
        bounds.size.width += Self.labelMargin * 2
        // Page panels, rules and grids span the whole column.
        bounds = bounds.union(CGRect(x: -Self.labelMargin, y: 0, width: columnWidth + 2 * Self.labelMargin, height: layoutFragmentFrame.height))
        if let overlay = overlay { bounds.size.height = max(bounds.size.height, overlay.topSpacing + overlay.size.height + 2) }
        return bounds
    }

    private var columnWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width }

    var overlay: OverlayImage? {
        guard let attributes, attributes.length > 0 else { return nil }
        return attributes.attribute(.plainOverlay, at: 0, effectiveRange: nil) as? OverlayImage
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let attributes, attributes.length > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            drawPageBackground(attributes, at: point)
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(at: point, in: context)
        guard let attributes, attributes.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawPageForeground(attributes, at: point)

        if let label = attributes.attribute(.plainHeadingLabel, at: 0, effectiveRange: nil) as? String, let line = textLineFragments.first {
            let font = Tokens.headingLabelFont(codeFontSize: Self.labelCodeSize)
            let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: Tokens.colorTertiary])
            let size = string.size()
            let lineFrame = line.typographicBounds
            let y = point.y + lineFrame.minY + (lineFrame.height - size.height) / 2
            string.draw(at: NSPoint(x: columnX(at: point) - size.width - 2, y: y))
        }

        var lineBreaks: [NSRange] = []
        attributes.enumerateAttribute(.plainLineBreak, in: NSRange(location: 0, length: attributes.length)) { value, range, _ in
            if value != nil { lineBreaks.append(range) }
        }
        if !lineBreaks.isEmpty, let line = textLineFragments.last {
            let font = EditorFonts.code(Self.labelCodeSize)
            let arrow = NSAttributedString(string: "↓", attributes: [.font: font, .foregroundColor: Tokens.colorSecondary])
            let end = line.locationForCharacter(at: line.characterRange.upperBound)
            let lineFrame = line.typographicBounds
            let size = arrow.size()
            arrow.draw(at: NSPoint(x: point.x + end.x + font.pointSize * 0.15, y: point.y + lineFrame.minY + (lineFrame.height - size.height) / 2))
        }

        if let overlay {
            let rect = NSRect(x: columnX(at: point) + overlay.left, y: point.y + overlay.topSpacing, width: overlay.size.width, height: overlay.size.height)
            overlay.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if overlay.selected {
                Tokens.selectionBlue.withAlphaComponent(0.7).setFill()
                rect.fill(using: .sourceOver)
            }
        }
    }

    /// The code font size the label is measured from; set by the editor when its configuration changes.
    nonisolated(unsafe) static var labelCodeSize: CGFloat = 13

    // MARK: Page

    private var page: PageTokens { Tokens.page }

    /// The baseline of `line` in drawing coordinates.
    private func baseline(_ line: NSTextLineFragment, at point: CGPoint) -> CGFloat {
        point.y + line.typographicBounds.minY + line.glyphOrigin.y
    }

    /// The column's left edge in drawing coordinates. TextKit 2 puts the paragraph's first-line indent into the fragment
    /// frame's x, so `point.x` is the text's left edge and this is the column's.
    private func columnX(at point: CGPoint) -> CGFloat { point.x - layoutFragmentFrame.minX }

    /// The bullet, number, footnote or checkbox box of a list item, from the column's left edge; nil without a marker.
    func markerBox(at point: CGPoint) -> NSRect? {
        guard let attributes, attributes.length > 0,
              let marker = attributes.attribute(.plainPageMarker, at: 0, effectiveRange: nil) as? PageMarker,
              let line = textLineFragments.first else { return nil }
        return NSRect(x: columnX(at: point) + marker.x, y: baseline(line, at: point) - page.bodySize, width: page.markerBox, height: page.bodySize)
    }

    /// The code panel strip of this fragment, from `panelLeft` to the column's right edge; nil when not in a panel.
    func panelRect(at point: CGPoint) -> NSRect? {
        guard let left = panelLeft else { return nil }
        return NSRect(x: columnX(at: point) + left, y: point.y, width: columnWidth - left, height: layoutFragmentFrame.height)
    }

    /// The x of the character at `index` (an offset in the paragraph) and the line holding it.
    private func position(of index: Int, at point: CGPoint) -> (x: CGFloat, line: NSTextLineFragment)? {
        guard let line = textLineFragments.first(where: { NSLocationInRange(index, $0.characterRange) || NSMaxRange($0.characterRange) == index })
        else { return nil }
        return (point.x + line.typographicBounds.minX + line.locationForCharacter(at: index).x, line)
    }

    /// Where this line's code panel starts, from the column's left edge; nil when the line is not in a panel. It is the
    /// indent `pageCode` gives the block's code lines less the 32 pt code padding, so a code block in a list item starts
    /// at the item's text. Hidden fence lines carry no indent of their own, so a top or bottom slice reads the code line
    /// next to it.
    var panelLeft: CGFloat? {
        guard let attributes, attributes.length > 0,
              let slice = attributes.attribute(.plainPagePanel, at: 0, effectiveRange: nil) as? PagePanelSlice else { return nil }
        var style = attributes.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        if slice.slice == .top || slice.slice == .bottom, let content = textLayoutManager?.textContentManager as? NSTextContentStorage,
           let storage = content.textStorage {
            let start = content.offset(from: content.documentRange.location, to: rangeInElement.location)
            let end = content.offset(from: content.documentRange.location, to: rangeInElement.endLocation)
            let neighbour = slice.slice == .top ? end : start - 1
            if neighbour >= 0, neighbour < storage.length, storage.attribute(.plainPagePanel, at: neighbour, effectiveRange: nil) != nil {
                style = storage.attribute(.paragraphStyle, at: neighbour, effectiveRange: nil) as? NSParagraphStyle
            }
        }
        return max((style?.headIndent ?? 0) - page.codePadSides, 0)
    }

    /// Panel fills, the table header fill and inline code chips, drawn under the text.
    private func drawPageBackground(_ attributes: NSAttributedString, at point: CGPoint) {
        let frame = layoutFragmentFrame
        if let slice = attributes.attribute(.plainPagePanel, at: 0, effectiveRange: nil) as? PagePanelSlice, let rect = panelRect(at: point) {
            let radius = page.radius
            page.codeBackground.setFill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            switch slice.slice {
            case .single: NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            case .top: NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + radius), xRadius: radius, yRadius: radius).fill()
            case .bottom: NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY - radius, width: rect.width, height: rect.height + radius), xRadius: radius, yRadius: radius).fill()
            case .middle: rect.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let row = attributes.attribute(.plainPageTableRow, at: 0, effectiveRange: nil) as? PageTableRow, row.isHeader,
           let first = row.columnEdges.first, let last = row.columnEdges.last {
            page.codeBackground.setFill()
            NSRect(x: columnX(at: point) + first, y: point.y, width: last - first, height: frame.height).fill()
        }
        let code = EditorFonts.code(page.codeSize)
        attributes.enumerateAttribute(.plainPageChip, in: NSRange(location: 0, length: attributes.length)) { value, run, _ in
            guard value != nil, run.length > 0 else { return }
            for line in textLineFragments {
                let part = NSIntersectionRange(run, line.characterRange)
                guard part.length > 0 else { continue }
                let lineX = point.x + line.typographicBounds.minX
                let start = lineX + line.locationForCharacter(at: part.location).x
                let end = lineX + line.locationForCharacter(at: NSMaxRange(part)).x
                let base = baseline(line, at: point)
                let rect = NSRect(x: start - page.chipPadH, y: base - code.ascender - page.chipPadV,
                                  width: end - start + 2 * page.chipPadH, height: code.ascender - code.descender + 2 * page.chipPadV)
                page.codeBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: page.chipRadius, yRadius: page.chipRadius).fill()
            }
        }
    }

    /// Markers, quote bars, rules, grid lines, footnote numbers, the code label, notes and captions.
    private func drawPageForeground(_ attributes: NSAttributedString, at point: CGPoint) {
        let frame = layoutFragmentFrame
        let firstLine = textLineFragments.first
        if let marker = attributes.attribute(.plainPageMarker, at: 0, effectiveRange: nil) as? PageMarker, let line = firstLine,
           let box = markerBox(at: point) {
            let base = baseline(line, at: point)
            switch marker.kind {
            case .bullet:
                drawCentred("•", font: .systemFont(ofSize: page.bodySize * 1.5), colour: page.text, in: box.minX, width: box.width, baseline: base)
            case .number(let number):
                drawCentred(number, font: .systemFont(ofSize: page.bodySize), colour: page.text, in: box.minX, width: box.width, baseline: base)
            case .footnote(let number):
                let font = NSFont.systemFont(ofSize: page.smallTextSize)
                NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: page.textSecondary])
                    .draw(at: NSPoint(x: box.minX, y: base - font.ascender))
            case .task(let checked):
                let size = page.checkbox
                let centreY = base - page.bodySize * 0.35
                let rect = NSRect(x: box.minX + (box.width - size) / 2, y: centreY - size / 2, width: size, height: size)
                if checked {
                    page.accent.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: page.checkboxRadius, yRadius: page.checkboxRadius).fill()
                    Self.checkImage.draw(in: rect.insetBy(dx: 2, dy: 2), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: page.checkboxStroke / 2, dy: page.checkboxStroke / 2),
                                            xRadius: page.checkboxRadius, yRadius: page.checkboxRadius)
                    path.lineWidth = page.checkboxStroke
                    page.textSecondary.setStroke()
                    path.stroke()
                }
            }
        }
        if let depth = attributes.attribute(.plainPageQuote, at: 0, effectiveRange: nil) as? Int, depth > 0 {
            page.text.setFill()
            for level in 1...depth {
                NSRect(x: columnX(at: point) + CGFloat(level - 1) * page.quoteIndent, y: point.y, width: page.quoteBar, height: frame.height).fill()
            }
        }
        if attributes.attribute(.plainPageDivider, at: 0, effectiveRange: nil) != nil {
            page.border.setFill()
            NSRect(x: columnX(at: point), y: point.y + page.dividerSpace, width: columnWidth, height: 1).fill()
        }
        if let row = attributes.attribute(.plainPageTableRow, at: 0, effectiveRange: nil) as? PageTableRow,
           let first = row.columnEdges.first, let last = row.columnEdges.last {
            page.border.setFill()
            for edge in row.columnEdges {
                NSRect(x: columnX(at: point) + min(edge, last - 1), y: point.y, width: 1, height: frame.height).fill()
            }
            NSRect(x: columnX(at: point) + first, y: point.y, width: last - first, height: 1).fill()
            NSRect(x: columnX(at: point) + first, y: point.y + frame.height - 1, width: last - first, height: 1).fill()
        }
        attributes.enumerateAttribute(.plainPageFootnote, in: NSRange(location: 0, length: attributes.length)) { value, run, _ in
            guard let number = value as? String, let (x, line) = position(of: run.location, at: point) else { return }
            let font = NSFont.systemFont(ofSize: page.footnoteSize)
            let base = baseline(line, at: point) - page.footnoteRaise
            NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: page.accent]).draw(at: NSPoint(x: x, y: base - font.ascender))
        }
        if let slice = attributes.attribute(.plainPagePanel, at: 0, effectiveRange: nil) as? PagePanelSlice, let label = slice.label {
            let font = NSFont.systemFont(ofSize: page.codeHeaderSize)
            let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: page.textSecondary])
            let origin = NSPoint(x: columnX(at: point) + (panelLeft ?? 0) + page.codePadSides, y: point.y + page.codePadTop)
            string.draw(at: origin)
            let size = string.size()
            Self.chevronImage.draw(in: NSRect(x: origin.x + size.width + 4, y: origin.y + (size.height - page.codeHeaderSize) / 2,
                                              width: page.codeHeaderSize, height: page.codeHeaderSize),
                                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for key in [NSAttributedString.Key.plainPageNote, .plainPageCaption] {
            guard let note = attributes.attribute(key, at: 0, effectiveRange: nil) as? String, !note.isEmpty else { continue }
            let font = NSFont.systemFont(ofSize: page.captionSize)
            let string = NSAttributedString(string: note, attributes: [.font: font, .foregroundColor: page.textSecondary])
            let left = key == .plainPageCaption ? (overlay?.left ?? 0) : 0
            string.draw(at: NSPoint(x: columnX(at: point) + left, y: point.y + frame.height - 21 + (21 - string.size().height) / 2))
        }
    }

    private func drawCentred(_ text: String, font: NSFont, colour: NSColor, in x: CGFloat, width: CGFloat, baseline: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
        string.draw(at: NSPoint(x: x + (width - string.size().width) / 2, y: baseline - font.ascender))
    }

    /// A Lucide icon recoloured: the file's strokes filled with `colour` at draw time.
    private static func icon(_ name: String, colour: NSColor) -> NSImage {
        let base = NSImage(contentsOf: VendorFiles.lucideIcon(name)) ?? NSImage()
        return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            base.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static let checkImage = icon("check", colour: .white)
    private static let chevronImage = icon("chevron-down", colour: Tokens.page.textSecondary)
}
