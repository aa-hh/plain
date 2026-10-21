import Foundation
import XCTest
@testable import MarkdownDocument

final class FlavourTests: XCTestCase {
    private func parse(_ text: String) async -> Snapshot {
        await MarkdownDocument(text: text).currentSnapshot()
    }

    /// Every inline in the tree, depth first.
    private func allInlines(_ snapshot: Snapshot) -> [Inline] {
        var result: [Inline] = []
        func visit(_ list: [Inline]) {
            for inline in list {
                result.append(inline)
                visit(inline.children)
            }
        }
        for block in snapshot.blocks(where: { _ in true }) { visit(block.inlines) }
        return result
    }

    private func text(_ snapshot: Snapshot, _ range: NSRange) -> String {
        (snapshot.text as NSString).substring(with: range)
    }

    func testFrontMatter() async {
        // Fails if the pre-pass stops blanking a leading `---` block and swift-markdown sees a thematic break.
        let snapshot = await parse("---\ntitle: x\n---\n\n# Hi")
        XCTAssertEqual(snapshot.blocks.map(\.kind), [.frontMatter, .atxHeading(level: 1)])
        XCTAssertEqual(snapshot.blocks[0].lineRange, 0..<3)
        XCTAssertEqual(snapshot.blocks[0].markerRanges.map { text(snapshot, $0) }, ["---", "---"])
    }

    func testMathBlocks() async {
        // Fails if `$$` or `$$$` fence lines stop becoming math blocks, or spec 474's outer `$` stop being markers.
        let two = await parse("$$\nx^2\n$$\n\npara")
        XCTAssertEqual(two.blocks.map(\.kind), [.mathBlock, .paragraph])
        XCTAssertEqual(two.blocks[0].lineRange, 0..<3)
        let three = await parse("$$$\ny\n$$$")
        XCTAssertEqual(three.blocks.map(\.kind), [.mathBlock])
        let wrapped = await parse("$$\n$x + 1$\n$$")
        XCTAssertEqual(wrapped.blocks[0].markerRanges.map { text(wrapped, $0) }, ["$$", "$$", "$", "$"])
    }

    func testInlineMath() async {
        // Fails if the pre-pass stops turning `$x$` and `$$x$$` into code spans the post-pass maps back to math.
        let snapshot = await parse("a $x$ b $$y$$ c")
        let math = allInlines(snapshot).filter { $0.kind == .math }
        XCTAssertEqual(math.map { text(snapshot, $0.range) }, ["$x$", "$$y$$"])
        XCTAssertEqual(math.map { text(snapshot, $0.contentRange) }, ["x", "y"])
    }

    func testDollarInsideBackticksStaysCode() async {
        // Fails if inline math replacement stops skipping backtick code spans.
        let snapshot = await parse("see `$x$` here")
        XCTAssertEqual(allInlines(snapshot).filter { $0.kind != .text }.map(\.kind), [.code])
    }

    func testPageBreakSplitsParagraph() async {
        // Fails if `+++` lines stop becoming page breaks that interrupt a paragraph.
        for marker in ["+++", "+ + +"] {
            let snapshot = await parse("a\n\(marker)\nb")
            XCTAssertEqual(snapshot.blocks.map(\.kind), [.paragraph, .pageBreak, .paragraph], marker)
        }
    }

    func testTableOfContents() async {
        // Fails if a `[[TOC]]` paragraph stops being recognised regardless of letter case.
        let snapshot = await parse("[[TOC]]\n\n# A")
        XCTAssertEqual(snapshot.blocks.map(\.kind), [.toc, .atxHeading(level: 1)])
    }

    func testHighlightContainingBold() async {
        // Fails if `::` pairs stop wrapping the inlines between them, bold included.
        let snapshot = await parse("x ::a **b** c:: y")
        let highlight = snapshot.blocks[0].inlines.first { $0.kind == .highlight }
        XCTAssertEqual(highlight.map { text(snapshot, $0.range) }, "::a **b** c::")
        XCTAssertEqual(highlight?.children.map(\.kind), [.text, .strong, .text])
        XCTAssertEqual(highlight?.markerRanges.count, 2)
    }

    func testAttributesOnHeading() async {
        // Fails if a trailing `{...}` stops being read into attributes and cut from the heading text.
        let snapshot = await parse("# Title {.cls #id k=v}")
        XCTAssertEqual(snapshot.blocks[0].attributes, ["class": "cls", "id": "id", "k": "v"])
        XCTAssertEqual(snapshot.headings.map(\.text), ["Title"])
        XCTAssertEqual(snapshot.headings.map(\.slug), ["title"])
    }

    func testFootnoteReferenceAndDefinition() async {
        // Fails if `[^1]` stops resolving against a `[^1]:` definition or the definition loses its parsed body.
        let snapshot = await parse("a[^1] b\n\n[^1]: the *note*")
        XCTAssertEqual(snapshot.blocks.map(\.kind), [.paragraph, .footnoteDefinition(label: "1")])
        XCTAssertTrue(snapshot.blocks[0].inlines.contains { $0.kind == .footnoteReference(label: "1") })
        let note = snapshot.blocks[1]
        XCTAssertEqual(note.markerRanges.map { text(snapshot, $0) }, ["[^1]:"])
        XCTAssertEqual(note.children.map(\.kind), [.paragraph])
        XCTAssertEqual(note.children.first.map { text(snapshot, $0.range) }, "the *note*")
        XCTAssertEqual(note.children.first?.inlines.map(\.kind), [.text, .emphasis])
    }

    func testEmoji() async {
        // Fails if `:name:` stops being looked up in the emoji table.
        let snapshot = await parse("hi :smile: :notanemoji:")
        XCTAssertEqual(allInlines(snapshot).filter { if case .emoji = $0.kind { true } else { false } }.map(\.kind),
                       [.emoji(name: "smile", character: "😄")])
    }

    func testBareURLsAndEmail() async {
        // Fails if bare links stop needing a scheme or bare email addresses stop linking.
        let snapshot = await parse("go https://a.b, or www.a.b, or a@b.c.")
        let links = allInlines(snapshot).compactMap { inline -> String? in
            if case .bareURL(let destination) = inline.kind { destination } else { nil }
        }
        XCTAssertEqual(links, ["https://a.b", "mailto:a@b.c"])
    }

    func testAutolink() async {
        // Fails if `<https://x>` stops mapping to an autolink.
        let snapshot = await parse("see <https://x>")
        XCTAssertTrue(allInlines(snapshot).contains { $0.kind == .autolink(destination: "https://x") })
    }

    func testLiquidTag() async {
        // Fails if `{{ ... }}` stops being split out as a Liquid tag.
        let snapshot = await parse("a {{ liquid }} b")
        let tag = allInlines(snapshot).first { $0.kind == .liquidTag }
        XCTAssertEqual(tag.map { text(snapshot, $0.range) }, "{{ liquid }}")
    }

    func testHardBreak() async {
        // Fails if two trailing spaces stop producing a line break inline over those spaces.
        let snapshot = await parse("a  \nb")
        let lineBreak = allInlines(snapshot).first { $0.kind == .lineBreak }
        XCTAssertEqual(lineBreak?.range, NSRange(location: 1, length: 2))
    }

    func testEscape() async {
        // Fails if `\*` stops producing an escape whose backslash is a marker.
        let snapshot = await parse("\\*a")
        let escape = allInlines(snapshot).first { $0.kind == .escape }
        XCTAssertEqual(escape?.markerRanges, [NSRange(location: 0, length: 1)])
    }

    func testTaskItems() async {
        // Fails if task list items lose their checked state or checkbox marker.
        let snapshot = await parse("- [x] done\n- [ ] todo")
        let items = snapshot.blocks[0].children
        XCTAssertEqual(items.map(\.kind), [.listItem(task: true, checked: true), .listItem(task: true, checked: false)])
        XCTAssertEqual(items[0].markerRanges.map { text(snapshot, $0) }, ["-", "[x]"])
    }

    func testTableMarkers() async {
        // Fails if table pipes and the divider row stop being markers.
        let snapshot = await parse("| a | b |\n|---|---|\n| c | d |")
        XCTAssertEqual(snapshot.blocks.map(\.kind), [.table])
        let markers = snapshot.blocks[0].markerRanges.map { text(snapshot, $0) }
        XCTAssertEqual(markers.filter { $0 == "|" }.count, 6)
        XCTAssertTrue(markers.contains("|---|---|"))
    }

    func testSetextHeading() async {
        // Fails if `===` under a line stops making a setext heading with the underline as its marker.
        let snapshot = await parse("Title\n===")
        XCTAssertEqual(snapshot.blocks.map(\.kind), [.setextHeading(level: 1)])
        XCTAssertEqual(snapshot.blocks[0].markerRanges.map { text(snapshot, $0) }, ["==="])
    }

    func testDuplicateSlugs() async {
        // Fails if repeated heading slugs stop getting `-1`, `-2` suffixes.
        let snapshot = await parse("# A\n\n# A\n\n# A")
        XCTAssertEqual(snapshot.headings.map(\.slug), ["a", "a-1", "a-2"])
    }

    func testDoubleHyphenStaysTwoHyphens() async {
        // Fails if `--` stops being plain text, for example if the post-pass splits it out as a dash.
        let snapshot = await parse("a -- b")
        XCTAssertEqual(snapshot.blocks[0].inlines.map(\.kind), [.text])
        XCTAssertEqual(snapshot.blocks[0].inlines.map { text(snapshot, $0.range) }, ["a -- b"])
    }
}
