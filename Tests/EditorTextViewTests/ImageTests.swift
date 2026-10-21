import AppKit
import MarkdownDocument
import PlainDocument
import XCTest
@testable import EditorTextView

@MainActor
final class ImageTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 480, height: 270))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 480, height: 270).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appendingPathComponent("photo.png"))
    }

    private func editorWithImage() async -> EditorTextView {
        let editor = await makeEditor("before\n\n![alt](photo.png)\n\nafter\n", url: folder.appendingPathComponent("doc.md"))
        _ = await waitUntil { editor.attribute(.plainOverlay, at: 8) != nil }
        return editor
    }

    // Spec 229, 1472. Turns red if an image line stops showing its picture, capped at 200 pt, over clear source text.
    func testImageLineShowsPicture() async {
        let editor = await editorWithImage()
        let overlay = editor.attribute(.plainOverlay, at: 8) as? OverlayImage
        XCTAssertNotNil(overlay)
        XCTAssertEqual(overlay?.size.height, 200)
        XCTAssertEqual(overlay?.size.width ?? 0, 356, accuracy: 1)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 10) as? NSColor, .clear)
        let style = editor.attribute(.paragraphStyle, at: 8) as? NSParagraphStyle
        XCTAssertEqual(style?.minimumLineHeight, 212)
    }

    // Spec 229. Turns red if a broken image stops falling back to its text.
    func testBrokenImageShowsText() async {
        let editor = await makeEditor("![x](missing.png)\n", url: folder.appendingPathComponent("doc.md"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(editor.attribute(.plainOverlay, at: 0))
    }

    // Spec 230. Turns red if the caret can land inside a rendered image line, or the blue cover stops following it.
    func testCaretSkipsImageLine() async {
        let editor = await editorWithImage()
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        XCTAssertEqual(editor.selectedRange().location, 25)
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        XCTAssertEqual(editor.selectedRange().location, 8)
        XCTAssertEqual((editor.attribute(.plainOverlay, at: 8) as? OverlayImage)?.selected, true)
    }

    // Spec 231. Turns red if Enter at the image line start stops showing its Markdown, or Backspace stops deleting it.
    func testEnterExpandsAndBackspaceDeletes() async {
        let editor = await editorWithImage()
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        await editor.enter()
        XCTAssertEqual(editor.text, "before\n\n![alt](photo.png)\n\nafter\n")
        XCTAssertNil(editor.attribute(.plainOverlay, at: 8))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        _ = await waitUntil { editor.attribute(.plainOverlay, at: 8) != nil }
        XCTAssertNotNil(editor.attribute(.plainOverlay, at: 8))
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        await editor.backspace()
        XCTAssertEqual(editor.text, "before\n\n\nafter\n")
    }

    // Spec 231. Turns red if Space at the image line start stops zooming the picture.
    func testSpaceZooms() async {
        let editor = await editorWithImage()
        var zoomed: NSImage?
        editor.actions.zoom = { zoomed = $0 }
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        await editor.type(" ")
        XCTAssertNotNil(zoomed)
        XCTAssertEqual(editor.text, "before\n\n![alt](photo.png)\n\nafter\n")
    }

    // Spec 233. Turns red if a linked image in dropped HTML stops becoming `[![alt](src)](url)`.
    func testLinkedImageFromHTML() {
        let html = #"<a href="https://x.y"><img src="https://x.y/a.png" alt="A"></a>"#
        XCTAssertEqual(EditorTextView.linkedImage(in: html), "[![A](https://x.y/a.png)](https://x.y)")
    }

    // Spec 242. Turns red if a complete math block stops being rendered by KaTeX and drawn over its source.
    func testMathBlockRenders() async {
        let editor = await makeEditor("text\n\n$$\nx^2\n$$\n\nend\n")
        editor.setSelectedRange(NSRange(location: editor.text.utf16.count, length: 0))
        let rendered = await waitUntil(timeout: 10) { editor.attribute(.plainOverlay, at: 6) != nil }
        XCTAssertTrue(rendered)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 9) as? NSColor, .clear)
        // A caret on the block shows the source again (spec 243).
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertNil(editor.attribute(.plainOverlay, at: 6))
    }

    // Coordinator rule for the drawn pictures. Turns red if showing an image, math or a hard break adds any character
    // to the document's text, so saving writes something other than what was typed.
    func testSavingWritesExactlyTheOriginalText() async throws {
        let original = "Line one  \nline two\n\n![alt](photo.png)\n\n$$\nx^2\n$$\n"
        let url = folder.appendingPathComponent("round.md")
        try original.write(to: url, atomically: true, encoding: .utf8)
        let editor = await makeEditor(original, url: url)
        _ = await waitUntil(timeout: 10) { editor.attribute(.plainOverlay, at: 22) != nil }
        XCTAssertNotNil(editor.attribute(.plainLineBreak, at: 8))
        XCTAssertEqual(editor.text, original)
        try await editor.document.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }
}
