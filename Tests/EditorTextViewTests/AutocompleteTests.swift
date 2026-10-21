import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class AutocompleteTests: XCTestCase {
    // Spec 186. Turns red if `:smi` stops offering emoji or accepting stops inserting the character and a space.
    func testEmojiSuggestionInsertsCharacter() async {
        let editor = await makeEditor()
        await editor.set("hi |")
        await editor.type(":smile")
        let session = try? XCTUnwrap(editor.autocomplete)
        XCTAssertNotNil(session)
        XCTAssertLessThanOrEqual(session?.suggestions.count ?? 99, 6)
        XCTAssertEqual(session?.suggestions.first?.insert, "😄 ")
        await editor.enter()
        XCTAssertEqual(editor.marked, "hi 😄 |")
        XCTAssertEqual(editor.recentEmoji.first, "😄")
    }

    // Spec 183. Turns red if Down stops moving the selection or Esc stops closing the list.
    func testKeysMoveAndClose() async {
        let editor = await makeEditor()
        await editor.set("|")
        await editor.type(":sm")
        XCTAssertEqual(editor.autocomplete?.selected, 0)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(editor.autocomplete?.selected, 1)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(editor.autocomplete)
        XCTAssertNil(editor.autocompletePopup?.superview)
    }

    // Spec 189. Turns red if the fence line stops offering language names.
    func testFenceLanguage() async {
        let editor = await makeEditor()
        await editor.set("```swi|")
        editor.showSuggestions(editor.suggestions(at: 6))
        XCTAssertEqual(editor.autocomplete?.suggestions.first?.insert, "swift")
        await editor.tab()
        XCTAssertEqual(editor.text, "```swift")
    }

    // Spec 188. Turns red if a `#` link URL stops offering heading slugs.
    func testHeadingAnchors() async {
        let editor = await makeEditor()
        await editor.set("# Hello World\n\nsee [x](#he|)")
        let session = editor.suggestions(at: editor.selectedRange().location)
        XCTAssertEqual(session?.suggestions.first?.insert, "#hello-world")
    }

    // Spec 190. Turns red if `>` after a known tag stops inserting its closing tag, or attributes stop being offered.
    func testHTMLClosingTagAndAttributes() async {
        let editor = await makeEditor()
        await editor.set("<div|")
        await editor.type(">")
        XCTAssertEqual(editor.marked, "<div>|</div>")
        await editor.set("<a hr|")
        let session = editor.suggestions(at: editor.selectedRange().location)
        XCTAssertEqual(session?.suggestions.first?.insert, "href=\"\"")
        editor.showSuggestions(session)
        await editor.enter()
        XCTAssertEqual(editor.marked, "<a href=\"|\"")
    }

    // Spec 187. Turns red if path completion stops listing the folder's files, hiding dot files and junk, or folders
    // stop getting a trailing slash.
    func testPathCompletion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("notes.md"))
        try Data().write(to: folder.appendingPathComponent(".hidden"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        let names = EditorActions.listPath("./", documentURL: folder.appendingPathComponent("doc.md"), root: folder).map(\.name)
        XCTAssertEqual(names, ["images", "notes.md"])
        let editor = await makeEditor("", url: folder.appendingPathComponent("doc.md"))
        editor.actions.completePath = { EditorActions.listPath($0, documentURL: $1, root: folder) }
        await editor.set("[a](./im|)")
        let session = editor.suggestions(at: editor.selectedRange().location)
        XCTAssertEqual(session?.suggestions.first?.insert, "./images/")
        XCTAssertEqual(session?.suggestions.first?.reask, true)
    }

    // Spec 182. Turns red if the list appears when the only suggestion equals the typed text.
    func testNoListWhenOnlySuggestionIsTyped() async {
        let editor = await makeEditor()
        await editor.set("```swift|")
        XCTAssertNil(editor.suggestions(at: 8))
    }

    // Spec 186. Turns red if the editor goes back to loading recent emoji in init, before EditorView injects the
    // window's closures, so it always reads the empty default.
    func testRecentEmojiLoadThroughInjectedActions() async {
        let editor = await makeEditor()
        var actions = EditorActions()
        actions.recentEmoji = { ["🎉"] }
        editor.actions = actions
        let loaded = await waitUntil { editor.recentEmoji == ["🎉"] }
        XCTAssertTrue(loaded)
    }
}
