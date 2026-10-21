import AppKit
import MarkdownDocument
import PlainCore
import PlainVendor
import WebKit

/// Renders TeX to images with KaTeX in one hidden web view (Decision 11).
@MainActor
final class KaTeXRenderer: NSObject, WKNavigationDelegate {
    private let page: WKWebView
    private var loaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var cache: [String: NSImage] = [:]
    /// Renders run one at a time; each waits for the one before.
    private var last: Task<Void, Never>?

    override init() {
        page = WKWebView(frame: NSRect(x: 0, y: 0, width: 2000, height: 1200), configuration: WKWebViewConfiguration())
        super.init()
        page.setValue(false, forKey: "drawsBackground")
        page.navigationDelegate = self
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="\(VendorFiles.katexCSS.absoluteString)">
        <script src="\(VendorFiles.katexJS.absoluteString)"></script>
        <style>html,body{margin:0;padding:0;background:transparent}#m{display:inline-block;padding:2px}.katex-display{margin:0;text-align:left}</style>
        </head><body><div id="m"></div><script>
        function plainRender(tex, size, color) {
          const m = document.getElementById('m');
          m.style.fontSize = size + 'px';
          m.style.color = color;
          katex.render(tex, m, {displayMode: true, throwOnError: false});
          const r = m.getBoundingClientRect();
          return [Math.ceil(r.width), Math.ceil(r.height)];
        }
        </script></body></html>
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("plain-katex-\(ProcessInfo.processInfo.processIdentifier).html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        page.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded = true
            for waiter in loadWaiters { waiter.resume() }
            loadWaiters.removeAll()
        }
    }

    func cached(_ tex: String, size: CGFloat, color: String) -> NSImage? { cache[Self.key(tex, size, color)] }

    private static func key(_ tex: String, _ size: CGFloat, _ color: String) -> String { "\(size)|\(color)|\(tex)" }

    /// The rendering at 2× scale, sized in points; nil when the web view fails.
    func render(_ tex: String, size: CGFloat, color: String) async -> NSImage? {
        let key = Self.key(tex, size, color)
        if let image = cache[key] { return image }
        let previous = last
        let task = Task { @MainActor [weak self] () -> NSImage? in
            await previous?.value
            guard let self else { return nil }
            if let image = self.cache[key] { return image }
            if !self.loaded { await withCheckedContinuation { self.loadWaiters.append($0) } }
            guard let result = try? await self.page.callAsyncJavaScript("return plainRender(tex, size, color)",
                                                                             arguments: ["tex": tex, "size": size, "color": color],
                                                                             in: nil, contentWorld: .page) as? [Double],
                  result.count == 2, result[0] > 0, result[1] > 0 else { return nil }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: result[0], height: result[1])
            configuration.snapshotWidth = NSNumber(value: result[0] * 2)
            configuration.afterScreenUpdates = true
            guard let image = try? await self.page.takeSnapshot(configuration: configuration) else { return nil }
            image.size = NSSize(width: result[0], height: result[1])
            self.cache[key] = image
            return image
        }
        last = Task { _ = await task.value }
        return await task.value
    }
}

/// Rendered math blocks in place of their source (spec 242–246).
extension EditorTextView {
    /// Complete math blocks (opening fence, non-empty body, closing fence) among the blocks meeting `range`.
    func mathBlocks(in range: NSRange) -> [Block] {
        guard let snapshot else { return [] }
        var result: [Block] = []
        func visit(_ block: Block) {
            if block.kind == .mathBlock {
                if block.markerRanges.count >= 2, block.lineRange.count >= 3, !mathSource(block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(block)
                }
            } else {
                block.children.forEach(visit)
            }
        }
        var index = MarkdownStyler.firstBlockIndex(at: range.location, in: snapshot.blocks)
        while index < snapshot.blocks.count, snapshot.blocks[index].range.location <= NSMaxRange(range) {
            visit(snapshot.blocks[index])
            index += 1
        }
        return result
    }

    /// The TeX between the fences.
    func mathSource(_ block: Block) -> String {
        let first = lineContents(at: block.range.location)
        let lastStart = lineContents(at: NSMaxRange(block.range)).location
        let start = NSMaxRange(first) + 1
        guard lastStart > start else { return "" }
        return nsText.substring(with: NSRange(location: start, length: lastStart - 1 - start))
    }

    /// True when the source should show: a selection touches the block or the line before or after it, Find is open,
    /// or the split preview is showing.
    func showsMathSource(_ block: Block) -> Bool {
        if findBarVisible || splitPreviewShowing { return true }
        let first = lineContents(at: block.range.location)
        let start = first.location > 0 ? lineContents(at: first.location - 1).location : first.location
        let lastLine = lineContents(at: NSMaxRange(block.range))
        let end = NSMaxRange(lastLine) < nsText.length ? NSMaxRange(lineContents(at: NSMaxRange(lastLine) + 1)) : NSMaxRange(lastLine)
        let zone = NSRange(location: start, length: end - start)
        return allSelections.contains { NSLocationInRange($0.location, zone) || NSLocationInRange(NSMaxRange($0), zone)
            || ($0.location <= zone.location && NSMaxRange($0) >= NSMaxRange(zone)) }
    }

    private var mathFontSize: CGFloat { configuration.codeFontSize * 1.5 }

    private var mathColor: String {
        let isDark = (appearance ?? effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = Tokens.palette(dark: isDark).color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    func applyMathOverlays(in range: NSRange) {
        let blocks = mathBlocks(in: range)
        guard !blocks.isEmpty else { return }
        let visible = visibleCharacterRange()
        let renderer = mathRenderer ?? KaTeXRenderer()
        mathRenderer = renderer
        for block in blocks where !showsMathSource(block) {
            let tex = mathSource(block)
            if let image = renderer.cached(tex, size: mathFontSize, color: mathColor) {
                coverMath(block, with: image)
            } else if NSIntersectionRange(block.range, visible).length > 0 || NSLocationInRange(block.range.location, visible) {
                let size = mathFontSize, color = mathColor
                Task { [weak self] in
                    guard await renderer.render(tex, size: size, color: color) != nil, let self, let snapshot = self.snapshot else { return }
                    // Restyle so the picture is applied to the block where it is now.
                    for current in self.mathBlocks(in: NSRange(location: 0, length: self.nsText.length)) where self.mathSource(current) == tex {
                        self.styler.restyle(snapshot: snapshot, range: current.range)
                    }
                }
            }
        }
    }

    /// Clears the source text and band of the block and draws `image` over its first line; the last line gets extra
    /// spacing when the picture is taller than the lines.
    private func coverMath(_ block: Block, with image: NSImage) {
        let storage = document.textStorage
        let lines = CGFloat(block.lineRange.count) * configuration.linePoints
        let overlay = OverlayImage(image: image, size: image.size, topSpacing: max((lines - image.size.height) / 2, 0))
        let firstLine = lineContents(at: block.range.location)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: block.range)
        storage.removeAttribute(.plainBand, range: block.range)
        storage.addAttribute(.plainOverlay, value: overlay, range: firstLine)
        if image.size.height > lines {
            let lastLine = lineContents(at: NSMaxRange(block.range))
            if let current = storage.attribute(.paragraphStyle, at: lastLine.location, effectiveRange: nil) as? NSParagraphStyle,
               let style = current.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacing = image.size.height - lines
                storage.addAttribute(.paragraphStyle, value: style, range: lastLine)
            }
        }
        storage.endEditing()
    }

    /// Restyles math blocks near the old and new selections so each shows its source or its picture.
    func mathSelectionMoved(from previous: [NSRange]) {
        guard let snapshot else { return }
        for range in previous + allSelections {
            let around = nsText.lineRange(for: NSRange(location: min(range.location, nsText.length), length: 0))
            let zone = NSUnionRange(around, NSRange(location: max(around.location - 1, 0), length: min(around.length + 2, nsText.length - max(around.location - 1, 0))))
            for block in mathBlocks(in: zone) { styler.restyle(snapshot: snapshot, range: block.range) }
        }
    }

    /// Restyles every math block in view, for Find and split preview changes.
    func refreshMath() {
        guard let snapshot else { return }
        for block in mathBlocks(in: NSRange(location: 0, length: nsText.length)) { styler.restyle(snapshot: snapshot, range: block.range) }
    }
}
