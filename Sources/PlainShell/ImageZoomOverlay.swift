import AppKit
import PlainCore
import SwiftUI

/// The zoomed image: the window covered by the translucent material colour, the image centred and scaled to fit
/// the window minus 120 pt, never above its natural size. A click, Esc or Space closes it.
public struct ImageZoomOverlay: View {
    let image: NSImage
    let onClose: () -> Void
    @FocusState private var focused: Bool

    public init(image: NSImage, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
    }

    /// The image size fitted inside `container` minus 120 pt each way, never larger than `natural`.
    public static func fittedSize(natural: CGSize, container: CGSize) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let scale = min(1, (container.width - 120) / natural.width, (container.height - 120) / natural.height)
        return CGSize(width: natural.width * max(scale, 0), height: natural.height * max(scale, 0))
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = Self.fittedSize(natural: image.size, container: proxy.size)
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.materialTransparent)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.escape, .space]) { _ in onClose(); return .handled }
        .onHover { inside in if inside { NSCursor.zoomOut.push() } else { NSCursor.pop() } }
    }
}
