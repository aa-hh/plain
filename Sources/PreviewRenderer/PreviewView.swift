import SwiftUI
import WebKit

/// The preview's web view in SwiftUI. Shows nothing when the controller's page is not a `WebPreviewPage`.
public struct PreviewView: NSViewRepresentable {
    public let controller: PreviewController

    public init(controller: PreviewController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> NSView {
        guard let webView = controller.webPage?.webView else { return NSView() }
        webView.removeFromSuperview()
        return webView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
