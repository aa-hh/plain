import Foundation
import MarkdownDocument

/// Follows the editor's scrolling in the split preview, one way (spec 527–528). The first scroll after the preview
/// opens is ignored. 100 ms after the editor stops, the preview scrolls to the same block and fraction of it, or to
/// its top or bottom when the editor is at its top or bottom. The page scrolls smoothly unless the jump is over
/// 5,000 px.
@MainActor
public final class ScrollSync {
    private let controller: PreviewController
    private var ignoredFirst = false
    private var pending: Task<Void, Never>?
    private let delay: Duration

    public init(controller: PreviewController, delay: Duration = .milliseconds(100)) {
        self.controller = controller
        self.delay = delay
    }

    /// Call when the preview opens, so its first editor scroll is ignored again.
    public func reset() {
        pending?.cancel()
        ignoredFirst = false
    }

    /// Call on every editor scroll. `fraction` is how far down `firstVisibleBlockID` the viewport's top sits (0–1).
    public func editorDidScroll(firstVisibleBlockID: BlockID?, fraction: Double, atTop: Bool, atBottom: Bool) {
        guard ignoredFirst else {
            ignoredFirst = true
            return
        }
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if atTop {
                controller.scrollToTop()
            } else if atBottom {
                controller.scrollToBottom()
            } else if let firstVisibleBlockID {
                controller.scrollToBlock(firstVisibleBlockID, fraction: min(max(fraction, 0), 1))
            }
        }
    }
}
