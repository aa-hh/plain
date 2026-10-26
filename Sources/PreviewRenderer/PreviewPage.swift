import AppKit
import PlainVendor
import WebKit

/// Replaces the element whose `data-block` is `id` with `html`; when there is no such element, inserts `html`
/// before the element `before` names, or at the end. `plain.patch` applies a list last to first, so `before` may
/// name a block inserted by an earlier entry of the same list.
public struct PreviewPatch: Codable, Equatable, Sendable {
    public var id: String
    public var html: String
    public var before: String?

    public init(id: String, html: String, before: String? = nil) {
        self.id = id
        self.html = html
        self.before = before
    }
}

/// One call into the page's `window.plain` object.
public enum PreviewMessage: Equatable, Sendable {
    /// `plain.remove(removals)` then `plain.patch(patches)`.
    case update(patches: [PreviewPatch], removals: [String])
    case replaceAll(String)
    /// Scrolls so the point `fraction` of the way down the block is at the top; smooth unless over 5,000 px away.
    case scrollToBlock(id: String, fraction: Double)
    case scrollToTop
    case scrollToBottom
    case scrollToAnchor(String)
    /// Loads the stylesheet, then removes the previous theme.
    case setTheme(URL)
}

/// The preview page as the controller sees it: `WebPreviewPage` in the app, a recorder in tests.
@MainActor
public protocol PreviewPage: AnyObject {
    /// Called with the index of a ticked or unticked task checkbox among all task checkboxes in the page.
    var onTask: ((Int) -> Void)? { get set }
    /// Called with the `href` of a clicked link that is not a `#` link, and whether it opens in a new tab
    /// (Option+click or middle-click).
    var onLink: ((String, Bool) -> Void)? { get set }
    func send(_ message: PreviewMessage)
    /// `data-block` value to the element's top in page coordinates.
    func blockTops() async -> [String: Double]
    /// Computed values of the given CSS custom properties on the preview root, and `.content`'s padding.
    func computedStyle(variables: [String]) async -> (variables: [String: String], padding: String?)
}

/// Plain's stylesheet under every theme (spec 511): no top margin on the first block or bottom margin on the last,
/// a page break before `.page-break`, the fenced code block's header, and print rules (48/32 px padding, exact
/// colours, wrapped code lines).
public let previewBaseCSS = """
.content > :first-child { margin-top: 0 !important; }
.content > :last-child { margin-bottom: 0 !important; }
.content img { max-width: 100%; }
/* The language label and copy button above a fenced code block. The theme supplies the surface and the block's
   own spacing; this only lays the header out and keeps it quiet until it is needed. */
.code-header { display: flex; align-items: center; justify-content: flex-end; gap: 8px; padding: 8px 8px 6px; }
.code-language { margin-right: auto; font-size: 0.8125em; line-height: 1.2; opacity: 0.6; }
.code-copy {
  font: inherit; font-size: 0.8125em; line-height: 1.2; color: inherit;
  background: none; border: 0; border-radius: 4px; padding: 3px 7px; cursor: pointer;
  opacity: 0; transition: opacity 120ms ease;
}
.code-block:hover .code-copy, .code-copy:focus-visible { opacity: 0.75; }
.code-copy:hover { opacity: 1; }
@media (hover: none) { .code-copy { opacity: 0.75; } }
.page-break { height: 0; margin: 0; break-before: page; page-break-before: always; }
@media print {
  .content { max-width: none !important; height: auto; padding: 48px 32px !important; }
  pre, pre code { white-space: pre-wrap !important; overflow-wrap: anywhere; }
  .code-header { display: none; }
  * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
}
"""

/// The page script. Builds `div.preview`'s shadow root (KaTeX CSS, `base.css`, the theme, `section.content`) and
/// exposes `window.plain`.
let previewScript = """
(function () {
  var host = document.querySelector('.preview');
  var root = host.attachShadow({ mode: 'open' });
  var setup = JSON.parse(document.getElementById('plain-setup').textContent);
  root.innerHTML = '<link rel="stylesheet" href="' + setup.katex + '"><style></style>' +
    '<link id="theme" rel="stylesheet"' + (setup.theme ? ' href="' + setup.theme + '"' : '') + '><section class="content"></section>';
  root.querySelector('style').textContent = setup.base;
  var content = root.querySelector('section.content');
  var theme = root.getElementById('theme');
  theme.onload = syncBackground;

  function find(id) {
    if (id === null || id === undefined) return null;
    return content.querySelector(':scope > [data-block="' + id + '"]');
  }
  function fragment(html) {
    var template = document.createElement('template');
    template.innerHTML = html;
    return template.content;
  }
  function syncBackground() {
    document.documentElement.style.background = getComputedStyle(host).backgroundColor;
  }
  function scrollToY(y) {
    var smooth = Math.abs(y - window.scrollY) <= 5000;
    window.scrollTo({ top: y, behavior: smooth ? 'smooth' : 'instant' });
  }

  window.plain = {
    patch: function (list) {
      for (var i = list.length - 1; i >= 0; i--) {
        var entry = list[i];
        var element = find(entry.id);
        if (element) { element.replaceWith(fragment(entry.html)); continue; }
        content.insertBefore(fragment(entry.html), find(entry.before));
      }
    },
    remove: function (ids) {
      ids.forEach(function (id) { var element = find(id); if (element) element.remove(); });
    },
    replaceAll: function (html) { content.innerHTML = html; },
    scrollToBlock: function (id, fraction) {
      var element = find(id);
      if (!element) return;
      var rect = element.getBoundingClientRect();
      scrollToY(window.scrollY + rect.top + rect.height * fraction);
    },
    scrollToTop: function () { window.scrollTo({ top: 0, behavior: 'instant' }); },
    scrollToBottom: function () { scrollToY(document.documentElement.scrollHeight); },
    blockTops: function () {
      var result = {};
      content.querySelectorAll(':scope > [data-block]').forEach(function (element) {
        result[element.getAttribute('data-block')] = element.getBoundingClientRect().top + window.scrollY;
      });
      return result;
    },
    scrollToAnchor: function (id) {
      var element = root.getElementById(id);
      if (element) element.scrollIntoView({ behavior: 'smooth' });
    },
    setTheme: function (href) {
      var old = root.getElementById('theme');
      var link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = href;
      link.onload = function () { if (old) old.remove(); link.id = 'theme'; syncBackground(); };
      (old || content).before(link);
    },
    computed: function (names) {
      var hostStyle = getComputedStyle(host);
      var values = {};
      names.forEach(function (name) { values[name] = hostStyle.getPropertyValue(name).trim(); });
      return { variables: values, padding: getComputedStyle(content).padding };
    }
  };

  function followLink(event, newTab) {
    var link = event.target.closest ? event.target.closest('a') : null;
    if (!link) return;
    var href = link.getAttribute('href');
    if (!href) return;
    event.preventDefault();
    if (href.charAt(0) === '#') { plain.scrollToAnchor(decodeURIComponent(href.slice(1))); return; }
    window.webkit.messageHandlers.link.postMessage({ href: href, newTab: newTab });
  }
  root.addEventListener('auxclick', function (event) { if (event.button === 1) followLink(event, true); });
  root.addEventListener('click', function (event) {
    followLink(event, event.altKey);
  });
  root.addEventListener('click', function (event) {
    var button = event.target.closest ? event.target.closest('.code-copy') : null;
    if (!button) return;
    var wrapper = button.closest('.code-block');
    var code = wrapper ? wrapper.querySelector('pre code') : null;
    if (!code) return;
    var text = code.textContent;
    function copied() {
      button.textContent = 'Copied';
      window.setTimeout(function () { button.textContent = 'Copy'; }, 1500);
    }
    function selectAndCopy() {
      var range = document.createRange();
      range.selectNodeContents(code);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      var ok = document.execCommand('copy');
      selection.removeAllRanges();
      if (ok) copied();
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(copied, selectAndCopy);
    } else {
      selectAndCopy();
    }
  });
  root.addEventListener('change', function (event) {
    var box = event.target;
    if (!box.classList || !box.classList.contains('task-list-item-checkbox')) return;
    var all = Array.prototype.slice.call(content.querySelectorAll('input.task-list-item-checkbox'));
    window.webkit.messageHandlers.task.postMessage(all.indexOf(box));
  });
})();
"""

/// The page loaded once into the web view; content arrives through `window.plain`.
func previewShell(themeURL: URL?) -> String {
    let setup: [String: String] = [
        "katex": VendorFiles.katexCSS.absoluteString,
        "theme": themeURL?.absoluteString ?? "",
        "base": previewBaseCSS,
    ]
    let json = (try? JSONSerialization.data(withJSONObject: setup)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>html, body { margin: 0; padding: 0; } .preview { display: block; min-height: 100vh; outline: none; }</style>
    </head><body><div class="preview" tabindex="0"></div>
    <script type="application/json" id="plain-setup">\(json.replacingOccurrences(of: "</", with: "<\\/"))</script>
    <script>\(previewScript)</script>
    </body></html>
    """
}

/// Forwards script messages without the user content controller keeping the page alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebPreviewPage?
    init(_ target: WebPreviewPage) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message) }
    }
}

/// The preview's `WKWebView`. Messages sent before the page finishes loading wait and go in order once it has.
@MainActor
public final class WebPreviewPage: NSObject, PreviewPage, WKNavigationDelegate {
    public let webView: WKWebView
    public var onTask: ((Int) -> Void)?
    public var onLink: ((String, Bool) -> Void)?
    private var loaded = false
    private var waiting: [String] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    public init(themeURL: URL?) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        let handler = WeakMessageHandler(self)
        configuration.userContentController.add(handler, name: "task")
        configuration.userContentController.add(handler, name: "link")
        webView.navigationDelegate = self
        webView.loadHTMLString(previewShell(themeURL: themeURL), baseURL: URL(fileURLWithPath: "/"))
    }

    fileprivate func received(_ message: WKScriptMessage) {
        switch message.name {
        case "task": if let index = (message.body as? NSNumber)?.intValue, index >= 0 { onTask?(index) }
        case "link":
            if let body = message.body as? [String: Any], let href = body["href"] as? String {
                onLink?(href, (body["newTab"] as? Bool) ?? false)
            }
        default: break
        }
    }

    /// Returns once the page shell has loaded.
    public func waitUntilLoaded() async {
        if loaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    public func send(_ message: PreviewMessage) {
        let script = Self.script(for: message)
        if loaded { webView.evaluateJavaScript(script, completionHandler: nil) } else { waiting.append(script) }
    }

    /// Runs a script and returns its JSON-compatible result.
    func evaluate(_ script: String) async -> Any? {
        await waitUntilLoaded()
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                nonisolated(unsafe) let value = result
                continuation.resume(returning: value)
            }
        }
    }

    public func blockTops() async -> [String: Double] {
        let result = await evaluate("plain.blockTops()") as? [String: Any] ?? [:]
        return result.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    public func computedStyle(variables: [String]) async -> (variables: [String: String], padding: String?) {
        let result = await evaluate("plain.computed(\(Self.json(variables)))") as? [String: Any] ?? [:]
        return ((result["variables"] as? [String: String]) ?? [:], result["padding"] as? String)
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func script(for message: PreviewMessage) -> String {
        switch message {
        case .update(let patches, let removals):
            return "plain.remove(\(json(removals))); plain.patch(\(json(patches)));"
        case .replaceAll(let html): return "plain.replaceAll(\(json(html)));"
        case .scrollToBlock(let id, let fraction): return "plain.scrollToBlock(\(json(id)), \(fraction));"
        case .scrollToTop: return "plain.scrollToTop();"
        case .scrollToBottom: return "plain.scrollToBottom();"
        case .scrollToAnchor(let id): return "plain.scrollToAnchor(\(json(id)));"
        case .setTheme(let url): return "plain.setTheme(\(json(url.absoluteString)));"
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        for script in waiting { webView.evaluateJavaScript(script, completionHandler: nil) }
        waiting.removeAll()
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Only the shell itself loads in the web view; any other navigation is handed to `onLink` instead.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if !loaded {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url { onLink?(url.isFileURL ? url.path : url.absoluteString, false) }
        decisionHandler(.cancel)
    }
}
