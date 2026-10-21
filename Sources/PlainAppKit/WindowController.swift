import AppKit
import PlainCore
import SwiftUI

/// A window's saved frame in `state/window-bounds-w<N>.json`.
public struct WindowBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var zoomed: Bool

    public init(frame: NSRect, zoomed: Bool) {
        x = frame.minX
        y = frame.minY
        width = frame.width
        height = frame.height
        self.zoomed = zoomed
    }

    public var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

/// One Plain window: an `NSWindow` with a transparent title bar over full-size content, showing `WindowView`.
@MainActor
public final class WindowController: NSObject, NSWindowDelegate {
    public static let minimumSize = NSSize(width: 400, height: 400)

    public let id: Int
    public let window: NSWindow
    public let model: WindowModel
    private let context: AppContext
    private var saveTask: Task<Void, Never>?
    /// Called after the close button hides the window.
    var onHide: (WindowController) -> Void = { _ in }

    public init(id: Int, model: WindowModel, context: AppContext, frame: NSRect?, zoomed: Bool) {
        self.id = id
        self.model = model
        self.context = context
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = frame.map { Self.fitted($0, screens: NSScreen.screens.map(\.visibleFrame)) }
            ?? NSRect(x: screen.minX, y: screen.minY, width: min(screen.width, 1200), height: min(screen.height, 800))
        window = NSWindow(
            contentRect: initial, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        window.setFrame(initial, display: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        applyBackground()
        model.window = window
        model.minimumWidthChanged = { [weak self] width in self?.applyMinimumWidth(width) }
        window.contentView = NSHostingView(rootView: WindowView(model: model))
        // A window with no saved size starts maximised (spec 722).
        if frame == nil || zoomed, !window.isZoomed { window.setFrame(screen, display: false) }
        model.screenWidth = window.screen?.frame.width ?? NSScreen.main?.frame.width ?? initial.width
    }

    /// The loading background (spec 727): `#F9F9F9` light, `#1D1D1D` dark.
    func applyBackground() {
        let dark = context.preferences.bool("nightMode")
        window.backgroundColor = dark ? NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1D / 255, alpha: 1)
            : NSColor(srgbRed: 0xF9 / 255, green: 0xF9 / 255, blue: 0xF9 / 255, alpha: 1)
    }

    /// A saved frame on a display that no longer exists moves to the main display and shrinks to fit (spec 721).
    static func fitted(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard !screens.contains(where: { $0.intersects(frame) }), let main = screens.first else { return frame }
        let width = min(frame.width, main.width), height = min(frame.height, main.height)
        return NSRect(x: main.minX, y: main.maxY - height, width: width, height: height)
    }

    /// The minimum width grows with the preview and the sidebar; a narrower window is widened (spec 725).
    func applyMinimumWidth(_ width: CGFloat) {
        window.minSize = NSSize(width: width, height: Self.minimumSize.height)
        if window.frame.width < width {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true, animate: false)
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Delegate

    public func windowDidMove(_ notification: Notification) { scheduleSave() }

    public func windowDidResize(_ notification: Notification) {
        model.screenWidth = window.screen?.frame.width ?? model.screenWidth
        scheduleSave()
    }

    /// Saves the frame 200 ms after the last move or resize (spec 723).
    private func scheduleSave() {
        saveTask?.cancel()
        let bounds = WindowBounds(frame: window.frame, zoomed: window.isZoomed)
        let store = context.store, id = id
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            try? await store.save(StateName.windowBounds(id), bounds)
        }
    }

    /// `window:close` (spec 743): full screen closes; otherwise close the current tab (stopping if the user cancels),
    /// forget this window's size and hide the window.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if window.styleMask.contains(.fullScreen) { return true }
        guard model.closeCurrentTabForWindowClose() else { return false }
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: context.stateFolder.appendingPathComponent("\(StateName.windowBounds(id)).json"))
        model.windowWillHide()
        window.orderOut(nil)
        onHide(self)
        return false
    }

    public func windowDidBecomeKey(_ notification: Notification) { model.windowBecameKey() }
    public func windowDidResignKey(_ notification: Notification) { model.windowResignedKey() }
}
