import AppKit

/// Typewriter mode (spec 330–340): padding of half the editor height above and below, and the caret's line kept at
/// the vertical middle.
extension EditorTextView {
    func typewriterConfigurationChanged() {
        updateGeometry()
        typewriterCenter(animated: false)
    }

    /// Scrolls so the caret's line sits at the middle. Jumps over 1.5 lines scroll smoothly; smaller ones snap.
    /// Nothing happens while a mouse button is down.
    func typewriterCenter(animated: Bool = true) {
        guard configuration.typewriter, let scrollView = enclosingScrollView, NSEvent.pressedMouseButtons == 0 else { return }
        let clip = scrollView.contentView
        let caretRect = rect(forCharacterRange: NSRange(location: selectedRange().location, length: 0))
        guard caretRect != .zero else { return }
        let target = NSPoint(x: clip.bounds.minX, y: max((caretRect.midY - clip.bounds.height / 2).rounded(), 0))
        let distance = abs(target.y - clip.bounds.minY)
        guard distance >= 1 else { return }
        if animated && distance > 1.5 * configuration.linePoints {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                clip.animator().setBoundsOrigin(target)
            } completionHandler: {
                MainActor.assumeIsolated { scrollView.reflectScrolledClipView(clip) }
            }
        } else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Other scroll-into-view requests are ignored while typewriter mode is on (spec 336).
    public override func scrollRangeToVisible(_ range: NSRange) {
        guard !configuration.typewriter else { return }
        super.scrollRangeToVisible(range)
    }

    /// The visible height changed: the padding follows it.
    func typewriterViewportResized() {
        guard configuration.typewriter else { return }
        updateGeometry()
        typewriterCenter(animated: false)
    }
}
