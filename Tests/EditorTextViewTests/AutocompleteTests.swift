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

    // MARK: The page's `/` menu and language list

    // Turns red if typing `/` alone on a line stops opening the `/` menu with every block kind.
    func testSlashOpensMenu() async {
        let editor = await makeEditor("", configuration: EditorConfiguration())
        await editor.type("/")
        XCTAssertNotNil(editor.slashMenu.host?.superview)
        XCTAssertEqual(editor.slashMenu.rows, PageBlockKind.slashKinds)
    }

    // Turns red if the text after `/` stops filtering the rows by block name.
    func testSlashQueryListsHeadings() async {
        let editor = await makeEditor("", configuration: EditorConfiguration())
        await editor.type("/hea")
        XCTAssertEqual(editor.slashMenu.rows, [.heading(1), .heading(2), .heading(3)])
    }

    // Turns red if Down stops moving the highlight from Heading 1 to Heading 2, Return stops writing that kind's
    // prefix in place of `/hea`, or the insertion takes more than one undo step.
    func testSlashDownReturnWritesHeading() async {
        let editor = await makeEditor("", configuration: EditorConfiguration())
        await editor.type("/hea")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(editor.slashMenu.highlighted, 1)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await editor.settle()
        XCTAssertEqual(editor.text, "## ")
        XCTAssertNil(editor.slashMenu.host)
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "/hea")
    }

    // Turns red if inserting any `/` menu kind, the Image pick included, takes more than one undo step.
    func testSlashEachKindIsOneUndoStep() async {
        for (index, kind) in PageBlockKind.slashKinds.enumerated() {
            let editor = await makeEditor("", configuration: EditorConfiguration())
            editor.actions.chooseImage = { URL(fileURLWithPath: "/tmp/pic.png") }
            await editor.type("/")
            for _ in 0..<index { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
            XCTAssertEqual(editor.slashMenu.rows[editor.slashMenu.highlighted], kind, kind.title)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await editor.settle()
            XCTAssertNotEqual(editor.text, "/", kind.title)
            editor.undoManager?.undo()
            await editor.settle()
            XCTAssertEqual(editor.text, "/", kind.title)
        }
    }

    // Turns red if Esc stops closing the `/` menu or starts removing the typed `/hea`.
    func testSlashEscapeKeepsText() async {
        let editor = await makeEditor("", configuration: EditorConfiguration())
        await editor.type("/hea")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(editor.slashMenu.host)
        XCTAssertEqual(editor.text, "/hea")
    }

    // Turns red if Return with no matching rows stops closing the menu and inserting a line break.
    func testSlashReturnWithNoRowsInsertsLineBreak() async {
        let editor = await makeEditor("", configuration: EditorConfiguration())
        await editor.type("/qqq")
        XCTAssertEqual(editor.slashMenu.rows, [])
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await editor.settle()
        XCTAssertNil(editor.slashMenu.host)
        XCTAssertEqual(editor.text, "/qqq\n")
    }

    // Turns red if the `/` menu stops shrinking to the rows that fit when neither side of the line has room for ten.
    func testSlashMenuFitsVisibleRect() async throws {
        let editor = await makeEditor("", configuration: EditorConfiguration())
        editor.enclosingScrollView?.setFrameSize(NSSize(width: 900, height: 300))
        await editor.type("/")
        let host = try XCTUnwrap(editor.slashMenu.host)
        XCTAssertLessThanOrEqual(host.frame.height, editor.visibleRect.height)
        XCTAssertTrue(editor.visibleRect.contains(host.frame))
    }

    // Turns red if `LanguageListView.items` lists every `fenceLanguages` id, so `js` and `javascript` both show a
    // "JavaScript" row.
    func testLanguageListShowsEachNameOnce() {
        let items = LanguageListView.items
        XCTAssertEqual(items.filter { $0.name == "JavaScript" }.map(\.id), ["javascript"])
        XCTAssertEqual(Set(items.map(\.name)).count, items.count)
        XCTAssertEqual(items.first?.name, "Plain text")
    }

    // Turns red if a language pick stops rewriting the text after the opening backtick run, or takes more than one
    // undo step.
    func testLanguagePickRewritesFence() async {
        let editor = await makeEditor("```swift\nlet x\n```", configuration: EditorConfiguration())
        editor.openLanguageList(fenceLineStart: 0)
        XCTAssertNotNil(editor.slashMenu.languageHost?.superview)
        editor.pickLanguage("python")
        await editor.settle()
        XCTAssertEqual(editor.text, "```python\nlet x\n```")
        XCTAssertNil(editor.slashMenu.languageHost)
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "```swift\nlet x\n```")
        editor.openLanguageList(fenceLineStart: 0)
        editor.pickLanguage("")
        await editor.settle()
        XCTAssertEqual(editor.text, "```\nlet x\n```")
    }

    // Turns red if the editor giving up focus to the list's own search field closes the language list.
    func testLanguageSearchFieldFocusKeepsListOpen() async throws {
        let editor = await makeEditor("```swift\nlet x\n```", configuration: EditorConfiguration())
        editor.openLanguageList(fenceLineStart: 0)
        let host = try XCTUnwrap(editor.slashMenu.languageHost)
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(Self.textField(in: host))
        XCTAssertTrue(editor.window?.makeFirstResponder(field) ?? false)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(editor.slashMenu.languageHost?.superview)
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }
}
