import AppKit
import MarkdownDocument
import PlainVendor
import WebKit

public enum ExportError: Error, Equatable {
    /// PDF export needs the preview's web view, and this controller's page is not one.
    case noWebView
    case printFailed
}

/// Builds the self-contained HTML file of spec 585–591 with Decision 13's fixes: the body sits in
/// `<section class="content">`, and documents with math carry KaTeX's stylesheet with its woff2 fonts inlined.
public enum Export {
    /// `themeCSS` and `baseCSS` get `:host` turned into `:root` and every `var(--x)` replaced by `computed[--x]`,
    /// else the value the stylesheets themselves declare, else the `var()` fallback.
    public static func html(body: String, title: String, themeCSS: String, baseCSS: String = previewBaseCSS,
                            padding: String?, computed: [String: String], includeMath: Bool) -> String {
        let declared = declarations(in: baseCSS + "\n" + themeCSS)
        func prepare(_ css: String) -> String {
            substituteVariables(in: css.replacingOccurrences(of: ":host", with: ":root"), computed: computed, declared: declared)
        }
        var html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>

        """
        if let padding, !padding.isEmpty { html += "<style>.content { padding: \(padding); }</style>\n" }
        html += "<style>\n\(prepare(baseCSS))\n</style>\n<style>\n\(prepare(themeCSS))\n</style>\n"
        if includeMath { html += "<style>\n\(katexCSSWithFonts())\n</style>\n" }
        html += "</head>\n<body>\n<section class=\"content\">\n\(body)</section>\n</body>\n</html>\n"
        return html
    }

    /// Whether any block or inline in the snapshot is math.
    public static func containsMath(_ snapshot: Snapshot) -> Bool {
        func visit(_ inlines: [Inline]) -> Bool {
            inlines.contains { $0.kind == .math || visit($0.children) }
        }
        func visit(_ blocks: [Block]) -> Bool {
            blocks.contains { $0.kind == .mathBlock || visit($0.inlines) || visit($0.children) }
        }
        return visit(snapshot.blocks)
    }

    private static let declarationPattern = try! NSRegularExpression(pattern: "(--[A-Za-z0-9_-]+)\\s*:\\s*([^;}]+)")
    private static let variablePattern = try! NSRegularExpression(pattern: "var\\(\\s*(--[A-Za-z0-9_-]+)\\s*(?:,\\s*([^()]*))?\\)")

    /// Custom property declarations; the first one of each name wins.
    static func declarations(in css: String) -> [String: String] {
        var result: [String: String] = [:]
        let text = css as NSString
        for match in declarationPattern.matches(in: css, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            if result[name] == nil { result[name] = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    /// Replaces `var(...)` until none is left, following values that use other variables (up to 10 levels).
    static func substituteVariables(in css: String, computed: [String: String], declared: [String: String]) -> String {
        var result = css
        for _ in 0..<10 {
            let text = result as NSString
            let matches = variablePattern.matches(in: result, range: NSRange(location: 0, length: text.length))
            guard !matches.isEmpty else { break }
            let mutable = NSMutableString(string: result)
            for match in matches.reversed() {
                let name = text.substring(with: match.range(at: 1))
                let fallback = match.range(at: 2).location == NSNotFound ? nil : text.substring(with: match.range(at: 2))
                let value = computed[name].flatMap { $0.isEmpty ? nil : $0 } ?? declared[name] ?? fallback ?? "initial"
                mutable.replaceCharacters(in: match.range, with: value)
            }
            result = mutable as String
        }
        return result
    }

    /// `katex.min.css` with each `@font-face` source list replaced by its woff2 file as a `data:` URL.
    static func katexCSSWithFonts() -> String {
        guard let css = try? String(contentsOf: VendorFiles.katexCSS, encoding: .utf8) else { return "" }
        let pattern = try! NSRegularExpression(pattern: "src:url\\(fonts/([A-Za-z0-9_-]+)\\.woff2\\) format\\(\"woff2\"\\)[^;}]*")
        let text = css as NSString
        let mutable = NSMutableString(string: css)
        for match in pattern.matches(in: css, range: NSRange(location: 0, length: text.length)).reversed() {
            let name = text.substring(with: match.range(at: 1))
            guard let data = try? Data(contentsOf: VendorFiles.katexFontsFolder.appendingPathComponent(name + ".woff2")) else { continue }
            mutable.replaceCharacters(in: match.range, with: "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")")
        }
        return mutable as String
    }
}

/// Finishes a print run started with `runModal(for:delegate:didRun:contextInfo:)`.
private final class PrintCompletion: NSObject {
    var continuation: CheckedContinuation<Bool, Never>?

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        continuation?.resume(returning: success)
        continuation = nil
    }
}

extension PreviewController {
    /// The HTML file for File > Export to HTML: paths as written, the theme with `:host` as `:root` and variables
    /// replaced by the preview's computed values, and the `.content` padding the preview has now. Every block is
    /// drawn in the kind it settled with, so a half-typed table exports as a paragraph.
    public func exportHTML(snapshot: Snapshot, themeCSS: String, title: String) async -> String {
        let body = HTMLRenderer(math: renderer.math).html(for: snapshot)
        let names = Set(Export.declarations(in: themeCSS).keys).sorted()
        let style = await page.computedStyle(variables: names)
        return Export.html(body: body, title: title, themeCSS: themeCSS, padding: style.padding, computed: style.variables,
                           includeMath: Export.containsMath(snapshot))
    }

    /// Prints the preview as it is now to an A4 PDF at `url` (Decision 13). A preview that is not on screen is laid
    /// out in an off-screen window for the print (spec 572).
    public func exportPDF(to url: URL) async throws {
        guard let webPage else { throw ExportError.noWebView }
        let webView = webPage.webView
        _ = await webPage.evaluate("1")

        let originalSuperview = webView.superview
        let originalFrame = webView.frame
        var window: NSWindow? = webView.window
        var borrowed: NSWindow?
        if window == nil || webView.isHiddenOrHasHiddenAncestor {
            let offscreen = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 1_000),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
            offscreen.isReleasedWhenClosed = false
            webView.removeFromSuperview()
            webView.frame = offscreen.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 1_000)
            offscreen.contentView?.addSubview(webView)
            offscreen.orderBack(nil)
            borrowed = offscreen
            window = offscreen
            _ = await webPage.evaluate("1")
        }
        defer {
            if let borrowed {
                webView.removeFromSuperview()
                if let originalSuperview {
                    webView.frame = originalFrame
                    originalSuperview.addSubview(webView)
                }
                borrowed.orderOut(nil)
            }
        }

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.orientation = .portrait
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let completion = PrintCompletion()
        let success = await withCheckedContinuation { continuation in
            completion.continuation = continuation
            operation.runModal(for: window!, delegate: completion,
                               didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard success else { throw ExportError.printFailed }
    }
}
