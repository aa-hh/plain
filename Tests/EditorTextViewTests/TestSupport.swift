import AppKit
import MarkdownDocument
import PlainDocument
import XCTest
@testable import EditorTextView

/// An editor in a scroll view in an off-screen window, with its first snapshot applied. It shows the Markdown source
/// unless `configuration` says otherwise; page tests pass `EditorConfiguration()`.
@MainActor
func makeEditor(_ text: String = "", url: URL? = nil, configuration: EditorConfiguration = EditorConfiguration(showMarkdownSource: true)) async -> EditorTextView {
    let document = Document(text: text, url: url)
    let markdown = MarkdownDocument(text: text)
    let editor = EditorTextView(document: document, markdown: markdown, configuration: configuration)
    host(editor)
    await editor.settle()
    return editor
}

/// Puts the editor in a scroll view in an off-screen window, like `EditorView` does.
@MainActor
func host(_ editor: EditorTextView) {
    let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    editor.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    container.scrollView.documentView = editor
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = container
    window.makeFirstResponder(editor)
    retainedWindows.append(window)
}

@MainActor var retainedWindows: [NSWindow] = []

/// A mouse event at the character `offset`, just right of its caret position, in the editor's window.
@MainActor
func mouseEvent(_ type: NSEvent.EventType, at offset: Int, in editor: EditorTextView, clickCount: Int = 1,
                flags: NSEvent.ModifierFlags = []) -> NSEvent {
    let rect = editor.rect(forCharacterRange: NSRange(location: offset, length: 0))
    return NSEvent.mouseEvent(with: type, location: windowPoint(x: rect.minX + 0.5, y: rect.midY, in: editor), modifierFlags: flags,
                              timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                              clickCount: clickCount, pressure: 1)!
}

/// A point in the editor's coordinates converted to its window's.
@MainActor
func windowPoint(x: CGFloat, y: CGFloat, in editor: EditorTextView) -> NSPoint {
    editor.convert(NSPoint(x: x, y: y), to: nil)
}

/// Waits for main-actor work started by the editor (image loads, git, renders).
@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

extension EditorTextView {
    var text: String { document.textStorage.string }

    /// Sets the text and selection from a marked string: `|` is a caret, `«…»` a selection; several of either make
    /// extra carets.
    func set(_ marked: String, caret marker: Character = "|") async {
        var text = ""
        var selections: [NSRange] = []
        var selectionStart: Int?
        for character in marked {
            let offset = (text as NSString).length
            switch character {
            case marker: selections.append(NSRange(location: offset, length: 0))
            case "«": selectionStart = offset
            case "»": selections.append(NSRange(location: selectionStart!, length: offset - selectionStart!))
            default: text.append(character)
            }
        }
        replace(all: text)
        await settle()
        setAllSelections(selections.isEmpty ? [NSRange(location: 0, length: 0)] : selections)
    }

    func replace(all text: String) {
        let range = NSRange(location: 0, length: document.textStorage.length)
        if shouldChangeText(in: range, replacementString: text) {
            document.textStorage.replaceCharacters(in: range, with: text)
            didChangeText()
        }
    }

    /// The text with `|` at each caret and `«…»` around each selection.
    var marked: String { marked(caret: "|") }

    func marked(caret marker: String) -> String {
        let string = NSMutableString(string: text)
        for range in allSelections.reversed() {
            if range.length == 0 {
                string.insert(marker, at: range.location)
            } else {
                string.insert("»", at: NSMaxRange(range))
                string.insert("«", at: range.location)
            }
        }
        return string as String
    }

    func type(_ string: String) async {
        for character in string {
            insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
        }
    }

    func enter() async {
        insertNewline(nil)
        await settle()
    }

    func backspace() async {
        deleteBackward(nil)
        await settle()
    }

    func tab() async {
        insertTab(nil)
        await settle()
    }

    func command(_ id: String) async {
        perform(commandID: id)
        await settle()
    }

    func attribute(_ key: NSAttributedString.Key, at offset: Int) -> Any? {
        document.textStorage.attribute(key, at: offset, effectiveRange: nil)
    }

    func font(at offset: Int) -> NSFont? { attribute(.font, at: offset) as? NSFont }

    func isBold(at offset: Int) -> Bool { font(at: offset)?.fontDescriptor.symbolicTraits.contains(.bold) == true }
}
