import AppKit
import PlainCore

/// The editor's scrollbar (spec 41, 1513): a 16 pt track with no visible slot and a 7 pt slider, 2 pt from the right,
/// radius 3, at least 20 pt tall, in `--material-thumb`. It shows while scrolling or while the pointer is over the
/// track and fades out over 0.3 s, 750 ms later, unless the pointer is over it. Dragging is the system's.
final class EditorScrollbar: NSScroller {
    private var hideWork: DispatchWorkItem?
    private var pointerInside = false
    private var tracking: NSTrackingArea?

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 16 }
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var doubleValue: Double {
        didSet { if doubleValue != oldValue { reveal() } }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) { drawKnob() }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let height = max(knob.height, 20)
        let slider = NSRect(x: bounds.maxX - 2 - 7, y: knob.midY - height / 2, width: 7, height: height)
        Tokens.materialThumb.setFill()
        NSBezierPath(roundedRect: slider, xRadius: Tokens.smallRadius, yRadius: Tokens.smallRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        reveal()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        scheduleHide()
    }

    /// Shows the slider at once and schedules the fade.
    func reveal() {
        hideWork?.cancel()
        alphaValue = 1
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pointerInside else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    self.animator().alphaValue = 0
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750), execute: work)
    }
}
