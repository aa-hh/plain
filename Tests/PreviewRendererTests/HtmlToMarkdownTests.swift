import XCTest
@testable import PreviewRenderer

final class HtmlToMarkdownTests: XCTestCase {
    func md(_ html: String) -> String { RichText.htmlToMarkdown(html) }

    // Turns red if h1 to h6 stop becoming `#` headings with blank lines around them (spec 620).
    func testHeadings() {
        XCTAssertEqual(md("<p>a</p><h2>Title</h2><p>b</p>"), "a\n\n\n## Title\n\nb")
        XCTAssertEqual(md("<h6>x</h6>"), "###### x")
    }

    // Turns red if list items keep their nesting or ordered lists keep numbers (spec 621).
    func testListItems() {
        XCTAssertEqual(md("<ol><li>one</li><li>two<ul><li>inner</li></ul></li></ol>"), "- one\n- two - inner")
    }

    // Turns red if block quotes lose their single `> ` (spec 622).
    func testBlockquote() {
        XCTAssertEqual(md("<blockquote>quoted</blockquote>"), "> quoted")
    }

    // Turns red if `pre` stops becoming a bare fence or inline `code` loses its backticks (spec 623).
    func testCode() {
        XCTAssertEqual(md("<pre><code class=\"language-js\">let a = 1;\n  b();</code></pre>"), "```\nlet a = 1;\n  b();\n```")
        XCTAssertEqual(md("<p>use <code>x</code> here</p>"), "use `x` here")
    }

    // Turns red if `em`, `strong` or `strike` change, or `b`, `i`, `s`, `del` gain a rule (spec 624).
    func testInlineFormatting() {
        XCTAssertEqual(md("<em>a</em> <strong>b</strong> <strike>c</strike>"), "*a* **b** ~~c~~")
        XCTAssertEqual(md("<b>a</b> <i>b</i> <s>c</s> <del>d</del>"), "a b c d")
    }

    // Turns red if any of the four link rules change (spec 625).
    func testLinks() {
        XCTAssertEqual(md("<a href=\"https://x.y/a\">text</a>"), "[text](https://x.y/a)")
        XCTAssertEqual(md("a<a href=\"https://x.y\"></a>b"), "a b")
        XCTAssertEqual(md("<a>only text</a>"), "only text")
        XCTAssertEqual(md("<a href=\"https://x.y/\">https://x.y</a>"), "https://x.y/")
    }

    // Turns red if images stop becoming `![alt](src)` (spec 626).
    func testImages() {
        XCTAssertEqual(md("<img src=\"a.png\" alt=\"A\">"), "![A](a.png)")
    }

    // Turns red if tables stop being padded or a missing header row is not added (spec 627).
    func testTables() {
        XCTAssertEqual(md("<table><tr><th>Name</th><th>N</th></tr><tr><td>apple</td><td>3</td></tr></table>"),
                       "| Name  | N   |\n| ----- | --- |\n| apple | 3   |")
        XCTAssertEqual(md("<table><tr><td>a</td><td>b</td></tr></table>"),
                       "|     |     |\n| --- | --- |\n| a   | b   |")
    }

    // Turns red if `br` stops giving a newline or `hr` stops giving `***` (spec 628).
    func testBreaksAndRules() {
        XCTAssertEqual(md("a<br>b<hr>c"), "a\nb ***\nc")
    }

    // Turns red if head, style, script, hidden elements or Apple helper spans are no longer skipped (spec 629).
    func testSkippedElements() {
        let html = "<head><title>t</title></head><style>p{}</style><script>x()</script><p>keep</p>" +
            "<span style=\"display: none\">hidden</span><span style=\"opacity:0\">faded</span><span class=\"Apple-converted-space\"> </span>"
        XCTAssertEqual(md(html), "keep")
    }

    // Turns red if text trimming, the space between touching pieces, block newlines or the final trim change (spec 630).
    func testWhitespace() {
        XCTAssertEqual(md("  <p>  one  </p><p><b>bold</b>text</p>  "), "one\nbold text")
        XCTAssertEqual(md("line one\n   line two"), "line one\n   line two")
    }
}
