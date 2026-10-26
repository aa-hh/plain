import XCTest
import MarkdownDocument
@testable import PreviewRenderer

/// Writes math as `[I:tex]` (inline) or `[D:tex]` (display) so tests can see what reached the math renderer.
struct FakeMathRenderer: MathRenderer {
    func html(for tex: String, display: Bool) -> String { "[\(display ? "D" : "I"):\(tex)]" }
}

func renderHTML(_ markdown: String, math: any MathRenderer = FakeMathRenderer()) async -> String {
    let snapshot = await MarkdownDocument(text: markdown).currentSnapshot()
    return HTMLRenderer(math: math).html(for: snapshot)
}

final class HTMLRendererTests: XCTestCase {
    // Turns red if the renderer starts converting quotes or `--` (spec 459: typographer off) or escapes raw HTML.
    func testStraightQuotesAndRawHTML() async {
        let html = await renderHTML("\"quoted\" -- dash <kbd>K</kbd>")
        XCTAssertTrue(html.contains("&quot;quoted&quot; -- dash <kbd>K</kbd>"), html)
    }

    // Turns red if a single line break inside a paragraph becomes `<br>` (spec 460).
    func testSoftBreakStaysNewline() async {
        let html = await renderHTML("one\ntwo")
        XCTAssertTrue(html.contains(">one\ntwo</p>"), html)
        XCTAssertFalse(html.contains("<br>"))
    }

    // Turns red if pipe tables lose their alignment or strikethrough stops rendering as `<s>` (spec 461).
    func testTableAndStrikethrough() async {
        let html = await renderHTML("| a | b |\n|:--|--:|\n| 1 | **2** |\n\n~~gone~~")
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">a</th>"), html)
        XCTAssertTrue(html.contains("<td style=\"text-align:right\"><strong>2</strong></td>"), html)
        XCTAssertTrue(html.contains("<s>gone</s>"), html)
    }

    // Turns red if a table row still under the caret stops rendering as a table, or its rows lose their cells.
    func testProvisionalTableRendersRows() async {
        let document = MarkdownDocument(text: "")
        let version = document.apply(TextEdit(range: NSRange(location: 0, length: 0),
                                             replacement: "| a | b |\n| c | d |"))
        let snapshot = await document.snapshot(atLeast: version)
        XCTAssertEqual(snapshot.provisionalKinds.count, 1)
        let html = HTMLRenderer(math: FakeMathRenderer()).html(for: snapshot)
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<th>b</th>"), html)
        XCTAssertTrue(html.contains("<td>c</td>"), html)
        XCTAssertTrue(html.contains("<td>d</td>"), html)
    }

    // Turns red if the first row of a table stops rendering before its delimiter row exists (issue 1).
    func testProvisionalTableWithOneRow() async {
        let document = MarkdownDocument(text: "")
        let version = document.apply(TextEdit(range: NSRange(location: 0, length: 0), replacement: "| a | b |"))
        let snapshot = await document.snapshot(atLeast: version)
        XCTAssertEqual(snapshot.provisionalKinds.count, 1)
        let html = HTMLRenderer(math: FakeMathRenderer()).html(for: snapshot)
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<th>b</th>"), html)
        XCTAssertFalse(html.contains("<tbody>"), html)
    }

    // Turns red if bare URLs without a scheme get linked or emails stop linking (spec 462).
    func testAutolinksNeedAScheme() async {
        let html = await renderHTML("https://a.b and www.a.b and a@b.c and <https://x.y>")
        XCTAssertTrue(html.contains("<a href=\"https://a.b\">https://a.b</a>"), html)
        XCTAssertFalse(html.contains("href=\"www"), html)
        XCTAssertTrue(html.contains("<a href=\"mailto:a@b.c\">a@b.c</a>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://x.y\">https://x.y</a>"), html)
    }

    // Turns red if `::text::` stops becoming `<mark>` or `==text==` starts to (spec 463).
    func testMark() async {
        let html = await renderHTML("::a **b**:: and ==c==")
        XCTAssertTrue(html.contains("<mark>a <strong>b</strong></mark>"), html)
        XCTAssertTrue(html.contains("==c=="), html)
    }

    // Turns red if emoji shortcodes lose the `emoji emoji-NAME` span (spec 464).
    func testEmoji() async {
        let html = await renderHTML("Hi :smile:")
        XCTAssertTrue(html.contains("<span class=\"emoji emoji-smile\">😄</span>"), html)
    }

    // Turns red if `{.class #id key=value}` stops adding attributes to the element (spec 465).
    func testAttributes() async {
        let html = await renderHTML("# Title {#top .big data-x=1}\n\nText {.note}")
        XCTAssertTrue(html.contains("id=\"top\""), html)
        XCTAssertTrue(html.contains("class=\"big\""), html)
        XCTAssertTrue(html.contains("data-x=\"1\""), html)
        XCTAssertTrue(html.contains("class=\"note\">Text</p>"), html)
        XCTAssertFalse(html.contains("{"), html)
    }

    // Turns red if footnote references or the footnotes section change shape (spec 466).
    func testFootnotes() async {
        let html = await renderHTML("A[^n] and again[^n].\n\n[^n]: The note.")
        XCTAssertTrue(html.contains("<sup class=\"footnote-ref\"><a href=\"#fn1\" id=\"fnref1\">[1]</a></sup>"), html)
        XCTAssertTrue(html.contains("id=\"fnref1:1\""), html)
        XCTAssertTrue(html.contains("<hr class=\"footnotes-sep\">"), html)
        XCTAssertTrue(html.contains("<section class=\"footnotes\">\n<ol class=\"footnotes-list\">"), html)
        XCTAssertTrue(html.contains("<li id=\"fn1\" class=\"footnote-item\"><p"), html)
        XCTAssertTrue(html.contains("The note. <a href=\"#fnref1\" class=\"footnote-backref\">↩︎</a>"), html)
    }

    // Turns red if front matter starts producing output (spec 467).
    func testFrontMatterIsHidden() async {
        let html = await renderHTML("---\ntitle: x\n---\n\nBody")
        XCTAssertFalse(html.contains("title"), html)
        XCTAssertTrue(html.contains(">Body</p>"), html)
    }

    // Turns red if task items stop rendering as clickable checkboxes in a label (spec 468).
    func testTaskList() async {
        let html = await renderHTML("- [x] done\n- [ ] open")
        XCTAssertTrue(html.contains("<li class=\"task-list-item\"><label><input type=\"checkbox\" class=\"task-list-item-checkbox\" checked> done</label>"), html)
        XCTAssertTrue(html.contains("<input type=\"checkbox\" class=\"task-list-item-checkbox\"> open</label>"), html)
        XCTAssertFalse(html.contains("disabled"))
    }

    // Turns red if heading ids stop using slugs or repeats lose their `-1` suffix (spec 469).
    func testHeadingIDs() async {
        let html = await renderHTML("# Héllo World\n\n## Héllo World")
        XCTAssertTrue(html.contains("<h1 data-block="), html)
        XCTAssertTrue(html.contains("id=\"hello-world\">Héllo World</h1>"), html)
        XCTAssertTrue(html.contains("id=\"hello-world-1\">Héllo World</h2>"), html)
    }

    // Turns red if `[[toc]]` stops producing a nested list of heading links (spec 470).
    func testTableOfContents() async {
        let html = await renderHTML("[[TOC]]\n\n# One\n\n## Two\n\n# Three")
        XCTAssertTrue(html.contains("<div class=\"table-of-contents\""), html)
        XCTAssertTrue(html.contains("<ul><li><a href=\"#one\">One</a><ul><li><a href=\"#two\">Two</a></li></ul></li><li><a href=\"#three\">Three</a></li></ul></div>"), html)
    }

    // Turns red if inline `$x$` or `$$x$$` stop reaching the math renderer as inline math (spec 471–472).
    func testInlineMath() async {
        let html = await renderHTML("Area $\\pi r^2$ and $$e^x$$ but `$code$`")
        XCTAssertTrue(html.contains("[I:\\pi r^2]"), html)
        XCTAssertTrue(html.contains("[I:e^x]"), html)
        XCTAssertTrue(html.contains("<code>$code$</code>"), html)
    }

    // Turns red if `$$` or `$$$` blocks stop rendering as display math, or the outer `$` of spec 474 stays.
    func testMathBlocks() async {
        let html = await renderHTML("$$\nx+1\n$$\n\n$$$\ny\n$$$\n\n$$\n$z$\n$$")
        XCTAssertTrue(html.contains("<div class=\"math-block\" data-block="), html)
        XCTAssertTrue(html.contains("[D:x+1]"), html)
        XCTAssertTrue(html.contains("[D:y]"), html)
        XCTAssertTrue(html.contains("[D:z]"), html)
    }

    // Turns red if KaTeX's own error display is turned off or the error class changes (spec 475).
    func testKaTeXErrorsShowInline() {
        let html = KaTeXJSRenderer().html(for: "\\frac{", display: true)
        XCTAssertTrue(html.contains("katex-error"), html)
    }

    // Turns red if the KaTeX renderer stops caching per source and mode (spec 476).
    func testKaTeXCachesPerSourceAndMode() {
        let renderer = KaTeXJSRenderer()
        let first = renderer.html(for: "x^2", display: false)
        XCTAssertTrue(first.contains("class=\"katex\""), first)
        XCTAssertEqual(renderer.html(for: "x^2", display: false), first)
        _ = renderer.html(for: "x^2", display: true)
        XCTAssertEqual(renderer.cachedCount, 2)
    }

    // Turns red if a `+++` or `+ + +` line stops splitting the paragraph around a page break div (spec 477).
    func testPageBreak() async {
        let html = await renderHTML("before\n+++\nafter\n\nx\n+ + +\ny")
        XCTAssertTrue(html.contains(">before</p>\n<div class=\"page-break\" data-block="), html)
        XCTAssertTrue(html.contains(">after</p>"), html)
        XCTAssertEqual(html.components(separatedBy: "class=\"page-break\"").count, 3, html)
    }

    // Turns red if known languages lose Prism token spans or unknown ones stop being escaped plain text (spec 478).
    func testFencedCode() async {
        let html = await renderHTML("```swift\nlet x = \"<a>\"\n```\n\n```nosuchlang\n<b>\n```")
        XCTAssertTrue(html.contains("<div class=\"code-block\" data-block="), html)
        XCTAssertTrue(html.contains("<code class=\"language-swift\"><span class=\"token keyword\">let</span>"), html)
        XCTAssertTrue(html.contains("&quot;&lt;a&gt;&quot;"), html)
        XCTAssertTrue(html.contains("<code class=\"language-nosuchlang\">&lt;b&gt;\n</code>"), html)
    }

    // Turns red if Mermaid blocks get special treatment instead of showing as a highlighted code block (spec 479).
    func testMermaidIsACodeBlock() async {
        let html = await renderHTML("```mermaid\ngraph TD\n```")
        XCTAssertTrue(html.contains("<div class=\"code-block\" data-block=\"0\" data-line=\"0\" role=\"group\" aria-label=\"mermaid code\">"), html)
        XCTAssertTrue(html.contains("<pre><code class=\"language-mermaid\">"), html)
        XCTAssertTrue(html.contains("graph</span> TD\n</code></pre>"), html)
        XCTAssertFalse(html.contains("<svg"), html)
    }

    // Turns red if a fenced code block loses the wrapper, the header, the language label or the copy button
    // (docs/claude-markdown-reference.md, section 3, "Code blocks").
    func testFencedCodeBlockHeader() async {
        let html = await renderHTML("```swift\nlet x = 1\n```")
        XCTAssertTrue(html.contains("<div class=\"code-block\" data-block=\"0\" data-line=\"0\" role=\"group\" aria-label=\"swift code\">"), html)
        XCTAssertTrue(html.contains("<div class=\"code-header\"><span class=\"code-language\">swift</span>"), html)
        XCTAssertTrue(html.contains("<button class=\"code-copy\" type=\"button\" aria-label=\"Copy code\">Copy</button></div>"), html)
        XCTAssertTrue(html.contains("</div>\n<pre><code class=\"language-swift\">"), html)
    }

    // Turns red if a fenced block with no language gains a language label or loses its copy button.
    func testFencedCodeBlockWithoutLanguage() async {
        let html = await renderHTML("```\nplain\n```")
        XCTAssertTrue(html.contains("<div class=\"code-block\" data-block=\"0\" data-line=\"0\" role=\"group\" aria-label=\"Code\">"), html)
        XCTAssertTrue(html.contains("<button class=\"code-copy\" type=\"button\" aria-label=\"Copy code\">Copy</button>"), html)
        XCTAssertFalse(html.contains("code-language"), html)
        XCTAssertTrue(html.contains("<pre><code>plain\n</code></pre>\n</div>\n"), html)
    }

    // Turns red if an indented code block gains the wrapper or the header.
    func testIndentedCodeBlockHasNoHeader() async {
        let html = await renderHTML("    let x = 1")
        XCTAssertTrue(html.contains("<pre data-block=\"0\" data-line=\"0\"><code>let x = 1\n</code></pre>\n"), html)
        XCTAssertFalse(html.contains("code-block"), html)
        XCTAssertFalse(html.contains("code-copy"), html)
    }

    // Turns red if the language string reaches the markup unescaped. The fence's info string keeps its first
    // word only, so the language here is `x"`.
    func testCodeBlockLanguageIsEscaped() async {
        let html = await renderHTML("```x\" onmouseover=alert(1)\ny\n```")
        XCTAssertTrue(html.contains("aria-label=\"x&quot; code\""), html)
        XCTAssertTrue(html.contains("<span class=\"code-language\">x&quot;</span>"), html)
        XCTAssertTrue(html.contains("<code class=\"language-x&quot;\">y\n</code>"), html)
        XCTAssertFalse(html.contains("x\""), html)
    }

    // Turns red if the code text changes: same escaping, same Prism token spans, only the wrapper around it is new.
    func testFencedCodeBlockBodyIsUnchanged() async {
        let html = await renderHTML("```swift\nlet x = \"<a>\"\n```\n\n```nosuchlang\n<b>\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\"><span class=\"token keyword\">let</span> x <span class=\"token operator\">=</span> <span class=\"token string\">&quot;&lt;a&gt;&quot;</span>\n</code></pre>"), html)
        XCTAssertTrue(html.contains("<pre><code class=\"language-nosuchlang\">&lt;b&gt;\n</code></pre>"), html)
    }

    // Turns red if the code block header starts showing in print output or in the exported PDF.
    func testPrintStylesHideTheCodeHeader() {
        let printRules = previewBaseCSS.components(separatedBy: "@media print {").last!
        XCTAssertTrue(printRules.contains(".code-header { display: none; }"), previewBaseCSS)
    }

    // Turns red if top-level elements lose their `data-block` or `data-line` attributes.
    func testTopLevelElementsCarryBlockAndLine() async {
        let snapshot = await MarkdownDocument(text: "a\n\n> b\n\n- c").currentSnapshot()
        let html = HTMLRenderer(math: FakeMathRenderer()).html(for: snapshot)
        for block in snapshot.blocks {
            XCTAssertTrue(html.contains("data-block=\"\(block.id.rawValue)\" data-line=\"\(block.lineRange.lowerBound)\""), html)
        }
        XCTAssertTrue(html.contains("<blockquote data-block="), html)
        XCTAssertTrue(html.contains("<ul data-block="), html)
    }

    // Turns red if quote continuation lines keep their `>` or code inside a quote keeps its prefix.
    func testContainerPrefixesAreRemoved() async {
        let html = await renderHTML("> one\n> two\n>\n> ```\n> code\n> ```")
        XCTAssertTrue(html.contains("<p>one\ntwo</p>"), html)
        XCTAssertTrue(html.contains("<pre><code>code\n</code></pre>"), html)
    }

    // Turns red if tight lists start wrapping items in `<p>` or loose lists stop doing so.
    func testTightAndLooseLists() async {
        let tight = await renderHTML("- a\n- b")
        XCTAssertTrue(tight.contains("<li>a\n</li>"), tight)
        let loose = await renderHTML("- a\n\n- b")
        XCTAssertTrue(loose.contains("<li><p>a</p>"), loose)
    }
}
