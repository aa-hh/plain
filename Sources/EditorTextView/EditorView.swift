import AppKit
import GitStatus
import MarkdownDocument
import Observation
import PlainDocument
import Spellcheck
import SwiftUI

/// Where `EditorController.scrollTo` puts the offset's line.
public enum EditorScrollPosition: Sendable {
    case top
    case center
}

/// The window's handle on its editor: what the shell reads (selection, what is in view) and what it asks for.
@MainActor @Observable
public final class EditorController {
    public internal(set) var selectedRanges: [NSRange] = []
    public internal(set) var visibleCharacterRange = NSRange(location: 0, length: 0)
    /// The top-level block at the top of the view.
    public internal(set) var firstVisibleBlockID: BlockID?
    /// How far the view's top is into that block, from 0 (its top) to 1 (its bottom).
    public internal(set) var offsetWithinBlock: CGFloat = 0
    public internal(set) var findBarVisible = false
    /// Full preview makes the editor ignore input (spec 366).
    public var isReadOnly = false {
        didSet { editor?.isEditable = !isReadOnly }
    }
    /// Called after a typed line break; the shell asks `Backups` whether a backup is due.
    @ObservationIgnored public var onLineBreakInserted: (() -> Void)?
    @ObservationIgnored weak var editor: EditorTextView?
    /// One list for every editor this controller installs, so To Last Edit crosses files.
    @ObservationIgnored public let editLocations = EditLocations()
    /// A selection for a document whose editor is not installed yet (a tab that just opened).
    @ObservationIgnored private var pending: (document: PlainDocument.Document, range: NSRange, position: EditorScrollPosition?)?

    public init() {}

    /// Selects `range` in `document` and scrolls to it: now when its editor shows, else when that editor is installed.
    /// With no position the selection is only scrolled into view.
    public func show(range: NSRange, in document: PlainDocument.Document, position: EditorScrollPosition?) {
        pending = (document, range, position)
        if let editor { applyPending(to: editor) }
    }

    func applyPending(to editor: EditorTextView) {
        guard let pending, pending.document === editor.document else { return }
        self.pending = nil
        let length = editor.nsText.length
        let location = min(pending.range.location, length)
        let range = NSRange(location: location, length: min(pending.range.length, length - location))
        select(range: range)
        if let position = pending.position { scrollTo(offset: range.location, position: position) }
    }

    public func scrollTo(offset: Int, position: EditorScrollPosition) {
        guard let editor, let scrollView = editor.enclosingScrollView else { return }
        let length = editor.nsText.length
        let rect = editor.rect(forCharacterRange: NSRange(location: min(max(offset, 0), length), length: 0))
        let clip = scrollView.contentView
        let y: CGFloat
        switch position {
        case .top: y = rect.minY - editor.textContainerOrigin.y
        case .center: y = rect.midY - clip.bounds.height / 2
        }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(y, 0)))
        scrollView.reflectScrolledClipView(clip)
    }

    public func select(range: NSRange) {
        guard let editor else { return }
        editor.setAllSelections([range])
        editor.scrollRangeToVisible(range)
    }

    /// Replaces text through the editor's own edit path: one undo step that redo can repeat, seen by the parser.
    @discardableResult
    public func replace(range: NSRange, with text: String) -> Bool {
        guard let editor, NSMaxRange(range) <= editor.nsText.length else { return false }
        // Full preview makes the editor read-only, and the preview's checkboxes still edit (spec 366, 507).
        let editable = editor.isEditable
        editor.isEditable = true
        defer { editor.isEditable = editable }
        editor.perform([(range, text)], select: nil)
        return true
    }

    public func focus() {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
    }

    @discardableResult
    public func perform(commandID: String) -> Bool {
        editor?.perform(commandID: commandID) ?? false
    }

    /// Reads the editor's state after a selection change or scroll.
    func update(from editor: EditorTextView) {
        selectedRanges = editor.allSelections
        findBarVisible = editor.findBarVisible
        let visible = editor.visibleCharacterRange()
        visibleCharacterRange = visible
        guard let snapshot = editor.snapshot, let block = snapshot.block(at: visible.location) ?? snapshot.blocks.first(where: { $0.range.location >= visible.location }) else { return }
        firstVisibleBlockID = block.id
        let blockRect = editor.rect(forCharacterRange: block.range)
        let top = editor.visibleRect.minY
        offsetWithinBlock = blockRect.height > 0 ? min(max((top - blockRect.minY) / blockRect.height, 0), 1) : 0
    }
}

/// Holds the scroll view so the find bar can sit above it.
final class EditorContainerView: NSView {
    let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller = EditorScrollbar(frame: NSRect(x: 0, y: 0, width: 16, height: 100))
        scrollView.drawsBackground = false
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The editor for one document, for SwiftUI.
public struct EditorView: NSViewRepresentable {
    public let document: PlainDocument.Document
    public let markdown: MarkdownDocument
    public var configuration: EditorConfiguration
    public let spellcheck: SpellcheckController
    public var gitStatus: GitStatus?
    public var actions: EditorActions
    public let controller: EditorController
    public var splitPreviewShowing: Bool

    public init(document: PlainDocument.Document, markdown: MarkdownDocument, configuration: EditorConfiguration, spellcheck: SpellcheckController,
                gitStatus: GitStatus? = nil, actions: EditorActions = EditorActions(), controller: EditorController,
                splitPreviewShowing: Bool = false) {
        self.document = document
        self.markdown = markdown
        self.configuration = configuration
        self.spellcheck = spellcheck
        self.gitStatus = gitStatus
        self.actions = actions
        self.controller = controller
        self.splitPreviewShowing = splitPreviewShowing
    }

    public func makeNSView(context: Context) -> NSView {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        install(in: container)
        return container
    }

    public func updateNSView(_ view: NSView, context: Context) {
        guard let container = view as? EditorContainerView else { return }
        guard let editor = container.scrollView.documentView as? EditorTextView, editor.document === document, editor.markdown === markdown else {
            if let old = container.scrollView.documentView as? EditorTextView { save(old) }
            install(in: container)
            return
        }
        configure(editor)
    }

    /// Makes the text view for the current document and restores its scroll position and selection.
    private func install(in container: EditorContainerView) {
        let editor = EditorTextView(document: document, markdown: markdown, configuration: configuration)
        editor.editLocations = controller.editLocations
        editor.frame = NSRect(origin: .zero, size: container.scrollView.contentSize)
        container.scrollView.documentView = editor
        configure(editor)
        editor.bind(spellcheck: spellcheck)
        editor.bind(gitStatus: gitStatus)
        let length = editor.nsText.length
        let ranges = document.selectedRanges.filter { NSMaxRange($0) <= length }
        if !ranges.isEmpty { editor.setAllSelections(ranges) }
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: document.scrollOffset))
        container.scrollView.reflectScrolledClipView(clip)
        controller.editor = editor
        let controller = controller
        editor.stateObservers.append { [weak editor] in
            guard let editor else { return }
            controller.update(from: editor)
            editor.document.selectedRanges = editor.allSelections
            editor.document.scrollOffset = editor.enclosingScrollView?.contentView.bounds.minY ?? 0
            // The caret reaches the parser on a move as well as on an edit, so leaving a half-typed table clears
            // it (issue 4). Fire and forget: the parser publishes only when the kind to show actually changes.
            if let caret = editor.allSelections.first?.location {
                let markdown = editor.markdown
                Task { await markdown.caretMoved(to: caret) }
            }
        }
        editor.lineBreakObserver = { controller.onLineBreakInserted?() }
        controller.applyPending(to: editor)
        controller.update(from: editor)
    }

    private func configure(_ editor: EditorTextView) {
        editor.actions = actions
        editor.apply(configuration)
        editor.splitPreviewShowing = splitPreviewShowing
        editor.isEditable = !controller.isReadOnly
        if editor.spellcheck !== spellcheck { editor.bind(spellcheck: spellcheck) }
        if editor.gitStatus !== gitStatus { editor.bind(gitStatus: gitStatus) }
    }

    private func save(_ editor: EditorTextView) {
        editor.document.selectedRanges = editor.allSelections
        editor.document.scrollOffset = editor.enclosingScrollView?.contentView.bounds.minY ?? 0
        editor.clearGitMarks()
    }
}
