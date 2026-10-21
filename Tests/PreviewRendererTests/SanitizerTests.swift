import XCTest
@testable import PreviewRenderer

final class SanitizerTests: XCTestCase {
    // Turns red if `script` or `style` elements, or their contents, survive sanitising.
    func testDropsScriptAndStyleWithContent() {
        let html = Sanitizer.sanitize("<p>a</p><script>alert(1)</script><STYLE>p{}</STYLE><p>b</p>")
        XCTAssertEqual(html, "<p>a</p><p>b</p>")
    }

    // Turns red if `iframe`, `object` or `embed` elements survive.
    func testDropsEmbeddedContent() {
        let html = Sanitizer.sanitize("x<iframe src=\"https://a\"></iframe><object data=\"y\">z</object><embed src=\"q\">w")
        XCTAssertEqual(html, "xw")
    }

    // Turns red if event handler attributes are kept.
    func testDropsEventHandlers() {
        XCTAssertEqual(Sanitizer.sanitize("<img src=\"a.png\" onerror=\"alert(1)\" OnClick='x'>"), "<img src=\"a.png\">")
    }

    // Turns red if `javascript:` URLs, entity-hidden ones included, are kept.
    func testDropsScriptURLs() {
        XCTAssertEqual(Sanitizer.sanitize("<a href=\"javascript:alert(1)\">a</a>"), "<a>a</a>")
        XCTAssertEqual(Sanitizer.sanitize("<a href=\"java&#115;cript:x\">a</a>"), "<a>a</a>")
        XCTAssertEqual(Sanitizer.sanitize("<a href=\" JAVASCRIPT:x\">a</a>"), "<a>a</a>")
    }

    // Turns red if non-image `data:` URLs are kept or image ones dropped.
    func testDataURLs() {
        XCTAssertEqual(Sanitizer.sanitize("<a href=\"data:text/html,x\">a</a>"), "<a>a</a>")
        XCTAssertEqual(Sanitizer.sanitize("<img src=\"data:image/png;base64,AA\">"), "<img src=\"data:image/png;base64,AA\">")
    }

    // Turns red if `style` attributes, `details`, `kbd` or `img` stop passing through (spec 491).
    func testKeepsHarmlessMarkup() {
        let source = "<details><summary>s</summary><kbd style=\"color: red\">K</kbd><img src=\"a.png\" alt=\"x\"></details>"
        XCTAssertEqual(Sanitizer.sanitize(source), source)
    }

    // Turns red if broken markup makes the sanitiser fail instead of escaping the stray `<`.
    func testToleratesBrokenMarkup() {
        XCTAssertEqual(Sanitizer.sanitize("a < b <c"), "a &lt; b &lt;c")
        XCTAssertEqual(Sanitizer.sanitize("<p>open<!-- note -->end"), "<p>openend")
        XCTAssertEqual(Sanitizer.sanitize("<script>never closed"), "")
    }

    // Turns red if raw HTML from a document reaches the preview without sanitising.
    func testRendererSanitisesRawHTML() async {
        let html = await renderHTML("<div onclick=\"x()\">\n<script>bad()</script>\n</div>\n\nText <b onmouseover=\"y\">bold</b>")
        XCTAssertFalse(html.contains("onclick"), html)
        XCTAssertFalse(html.contains("bad()"), html)
        XCTAssertFalse(html.contains("onmouseover"), html)
        XCTAssertTrue(html.contains("<b>bold</b>"), html)
    }

    // Turns red if a Markdown link with a `javascript:` destination keeps its href.
    func testRendererDropsScriptLinks() async {
        let html = await renderHTML("[x](javascript:alert(1))")
        XCTAssertTrue(html.contains("<a>x</a>"), html)
    }
}
