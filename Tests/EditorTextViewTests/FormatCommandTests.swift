import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class FormatCommandTests: XCTestCase {
    override func setUp() async throws {
        NSPasteboard.general.clearContents()
    }

    // Spec 160. Turns red if Bold stops wrapping the word at the caret or stops removing markers inside bold text.
    func testBoldWrapsWordAndUnwraps() async {
        let editor = await makeEditor()
        await editor.set("a wo|rd b")
        await editor.command("editor:bold")
        XCTAssertEqual(editor.marked, "a **wo|rd** b")
        await editor.command("editor:bold")
        XCTAssertEqual(editor.marked, "a wo|rd b")
        await editor.set("«x y»")
        await editor.command("editor:italic")
        XCTAssertEqual(editor.marked, "_«x y»_")
        await editor.set("«x»")
        await editor.command("editor:code")
        XCTAssertEqual(editor.text, "`x`")
    }

    // Spec 161. Turns red if Link stops building `[text]()` with the caret in the URL, or a selected URL stops
    // becoming the link target.
    func testLink() async {
        let editor = await makeEditor()
        await editor.set("«text»")
        await editor.command("editor:link")
        XCTAssertEqual(editor.marked, "[text](|)")
        await editor.set("«https://a.b»")
        await editor.command("editor:link")
        XCTAssertEqual(editor.marked, "[|](https://a.b)")
        await editor.set("[te|xt](u)")
        await editor.command("editor:link")
        XCTAssertEqual(editor.text, "text")
        NSPasteboard.general.setString("https://c.d/pic.png", forType: .string)
        await editor.set("«pic»")
        await editor.command("editor:link")
        XCTAssertEqual(editor.marked, "![pic](https://c.d/pic.png)|")
    }

    // Spec 162. Turns red if Image stops building `![…](…)`.
    func testImage() async {
        let editor = await makeEditor()
        await editor.set("«alt»")
        await editor.command("editor:image")
        XCTAssertEqual(editor.marked, "![alt](|)")
    }

    // Spec 163. Turns red if Code Block stops wrapping lines in fences or stops removing them inside a block.
    func testCodeBlockWrapsAndUnwraps() async {
        let editor = await makeEditor()
        await editor.set("«a\nb»")
        await editor.command("editor:code-block")
        XCTAssertEqual(editor.text, "```\na\nb\n```")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        await editor.command("editor:code-block")
        XCTAssertEqual(editor.text, "a\nb")
        await editor.set("«x»")
        await editor.command("editor:math-block")
        XCTAssertEqual(editor.text, "$$$\nx\n$$$")
    }

    // Spec 164–165. Turns red if the table of contents stops going at the top or breaks stop following the block.
    func testTocAndBreaks() async {
        let editor = await makeEditor()
        await editor.set("para|\n")
        await editor.command("editor:table-of-contents")
        XCTAssertEqual(editor.text, "[[toc]]\n\npara\n")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        await editor.command("editor:thematic-break")
        XCTAssertEqual(editor.text, "[[toc]]\n\npara\n\n---\n")
        await editor.command("editor:page-break")
        XCTAssertEqual(editor.text, "[[toc]]\n\npara\n\n---\n\n+++\n")
    }

    // Spec 166. Turns red if Comment stops wrapping lines in `<!-- -->` or stops unwrapping them.
    func testComment() async {
        let editor = await makeEditor()
        await editor.set("«note»")
        await editor.command("editor:comment")
        XCTAssertEqual(editor.text, "<!-- note -->")
        await editor.command("editor:comment")
        XCTAssertEqual(editor.text, "note")
    }

    // Spec 167. Turns red if Clear Syntax stops deleting the markers of the element at the caret.
    func testClearSyntax() async {
        let editor = await makeEditor()
        await editor.set("a **b _c|_** d")
        await editor.command("editor:clear-syntax")
        XCTAssertEqual(editor.text, "a b c d")
    }

    // Spec 168. Turns red if pasting a URL over selected text stops making a link.
    func testPasteURLOverSelection() async {
        let editor = await makeEditor()
        await editor.set("see «docs» now")
        NSPasteboard.general.setString("https://x.y", forType: .string)
        editor.paste(nil)
        await editor.settle()
        XCTAssertEqual(editor.text, "see [docs](https://x.y) now")
    }

    // Spec 172. Turns red if Cut with no selection stops cutting the whole line.
    func testCutWholeLine() async {
        let editor = await makeEditor()
        await editor.set("one\ntw|o\nthree")
        editor.cut(nil)
        await editor.settle()
        XCTAssertEqual(editor.text, "one\nthree")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "two\n")
    }

    // Spec 93. Turns red if Heading 2 stops toggling the marker on the selected lines.
    func testHeadingToggle() async {
        let editor = await makeEditor()
        await editor.set("ti|tle")
        await editor.command("editor:heading2")
        XCTAssertEqual(editor.text, "## title")
        await editor.command("editor:heading2")
        XCTAssertEqual(editor.text, "title")
        await editor.set("- it|em")
        await editor.command("editor:heading1")
        XCTAssertEqual(editor.text, "# item")
    }

    // Spec 171. Turns red if a pasted image stops being saved as a PNG in `.pastes` and linked.
    func testPasteImageSavesFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let editor = await makeEditor("", url: folder.appendingPathComponent("doc.md"))
        editor.actions.pasteFolder = { folder.appendingPathComponent(".pastes") }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        editor.paste(nil)
        await editor.settle()
        XCTAssertTrue(editor.text.hasPrefix("![](.pastes/"), editor.text)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".pastes").path)
        XCTAssertEqual(files.count, 1)
        editor.paste(nil)
        let again = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".pastes").path)
        XCTAssertEqual(again.count, 1, "an identical image should reuse the file")
    }
}
