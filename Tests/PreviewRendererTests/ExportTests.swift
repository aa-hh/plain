import XCTest
import MarkdownDocument
import PlainCore
@testable import PreviewRenderer

@MainActor
final class ExportTests: XCTestCase {
    func export(_ markdown: String) async -> String {
        let page = RecordingPage()
        page.computedVariables = ["--link": "rgb(1, 2, 3)"]
        let controller = PreviewController(page: page, math: FakeMathRenderer())
        let snapshot = await MarkdownDocument(text: markdown).currentSnapshot()
        return await controller.exportHTML(snapshot: snapshot, themeCSS: Themes.css(for: Tokens.previewDefault), title: "Notes.md")
    }

    // Turns red if the exported body is not wrapped in `section.content` (Decision 13 fix for spec 588).
    func testBodyIsWrappedInContentSection() async {
        let html = await export("# Hi\n\n![p](pics/a.png)")
        XCTAssertTrue(html.contains("<body>\n<section class=\"content\">\n<h1"), html)
        XCTAssertTrue(html.contains("<title>Notes.md</title>"), html)
        XCTAssertTrue(html.contains("<style>.content { padding: 10px 20px; }</style>"), html)
        XCTAssertTrue(html.contains("src=\"pics/a.png\""), html)
    }

    // Turns red if `:host` survives in the exported CSS or any `var(` is left unreplaced (spec 587).
    func testHostBecomesRootAndVariablesAreReplaced() async {
        let html = await export("text")
        XCTAssertTrue(html.contains(":root {"), html)
        XCTAssertFalse(html.contains(":host"))
        XCTAssertFalse(html.contains("var("))
        XCTAssertTrue(html.contains("color: rgb(1, 2, 3)"), "computed values should win over declared ones")
        XCTAssertTrue(html.contains("background: #FFFFFF"))
    }

    // Turns red if KaTeX's stylesheet is left out of documents with math or added to documents without (Decision 13).
    func testKaTeXStylesheetOnlyWithMath() async {
        let withMath = await export("Euler $e^{i\\pi}$")
        XCTAssertTrue(withMath.contains("font-family:KaTeX_Main"), "KaTeX CSS missing")
        XCTAssertTrue(withMath.contains("url(data:font/woff2;base64,"))
        XCTAssertFalse(withMath.contains("url(fonts/"))
        let without = await export("No math here")
        XCTAssertFalse(without.contains("KaTeX_Main"))
    }
}
