import AppKit
import PlainCore

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
        if let overlay = overlay { bounds.size.height = max(bounds.size.height, overlay.topSpacing + overlay.size.height + 2) }
        return bounds
    }

    var overlay: OverlayImage? {
        guard let attributes, attributes.length > 0 else { return nil }
        return attributes.attribute(.plainOverlay, at: 0, effectiveRange: nil) as? OverlayImage
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let attributes, attributes.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        if let label = attributes.attribute(.plainHeadingLabel, at: 0, effectiveRange: nil) as? String, let line = textLineFragments.first {
            let font = Tokens.headingLabelFont(codeFontSize: Self.labelCodeSize)
            let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: Tokens.colorTertiary])
            let size = string.size()
            let lineFrame = line.typographicBounds
            let y = point.y + lineFrame.minY + (lineFrame.height - size.height) / 2
            string.draw(at: NSPoint(x: point.x - size.width - 2, y: y))
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
            let rect = NSRect(x: point.x + overlay.left, y: point.y + overlay.topSpacing, width: overlay.size.width, height: overlay.size.height)
            overlay.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if overlay.selected {
                Tokens.selectionBlue.withAlphaComponent(0.7).setFill()
                rect.fill(using: .sourceOver)
            }
        }
    }

    /// The code font size the label is measured from; set by the editor when its configuration changes.
    nonisolated(unsafe) static var labelCodeSize: CGFloat = 13
}
