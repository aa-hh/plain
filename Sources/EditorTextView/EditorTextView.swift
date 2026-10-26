import AppKit
import CoreText
import os
import MarkdownDocument
import PlainCore
import PlainDocument
import GitStatus
import PlainVendor
import Spellcheck
import UniformTypeIdentifiers

/// The editor settings that change how text is laid out and drawn.
public struct EditorConfiguration: Equatable, Sendable {
    public var fontSize: CGFloat
    public var codeFontSize: CGFloat
    /// Line height as a multiple of `fontSize`.
    public var lineHeight: CGFloat
    /// Column width in widths of the letter "a" in the prose font.
    public var lineWidth: CGFloat
    public var largeHeadings: Bool
    public var typewriter: Bool
    public var darkMode: Bool
    public var tabSize: Int
    /// True for View > Show Markdown Source: the editor shows the Markdown as text. False shows the page, where the
    /// Markdown is hidden and blocks are drawn.
    public var showMarkdownSource: Bool

    public init(fontSize: CGFloat = 15, codeFontSize: CGFloat = 13, lineHeight: CGFloat = 1.6, lineWidth: CGFloat = 72,
                largeHeadings: Bool = true, typewriter: Bool = false, darkMode: Bool = false, tabSize: Int = 2,
                showMarkdownSource: Bool = false) {
        self.fontSize = fontSize
        self.codeFontSize = codeFontSize
        self.lineHeight = lineHeight
        self.lineWidth = lineWidth
        self.largeHeadings = largeHeadings
        self.typewriter = typewriter
        self.darkMode = darkMode
        self.tabSize = tabSize
        self.showMarkdownSource = showMarkdownSource
    }

    /// One text line in points.
    public var linePoints: CGFloat { (fontSize * lineHeight).rounded() }

    /// The prose size: `fontSize` in the source view, the page's fixed body size on the page.
    public var proseFontSize: CGFloat { showMarkdownSource ? fontSize : Tokens.page.bodySize }
}

/// Work the editor hands to other modules, injected by the window that owns it.
public struct EditorActions {
    /// Renders Markdown text to HTML (Copy as Rich Text, Copy as HTML).
    public var htmlRenderer: (String) async -> String = { _ in "" }
    /// Converts HTML to Markdown (Paste Formatted).
    public var htmlToMarkdown: (String) -> String = { $0 }
    /// The `.pastes` folder pasted images are saved in; nil when there is nowhere to save.
    public var pasteFolder: () -> URL? = { nil }
    /// Files and folders that complete a typed path; `EditorActions.listPath` is the file-system version.
    public var completePath: (_ typed: String, _ documentURL: URL?) -> [PathCompletion] = { _, _ in [] }
    /// Recently used emoji, most recent first, and where a newly used one is recorded.
    public var recentEmoji: () async -> [String] = { [] }
    public var recordEmoji: (String) -> Void = { _ in }
    /// The window's folder, for "Show in Sidebar" and `/` paths.
    public var folderURL: () -> URL? = { nil }
    /// Opens a file in the current tab, or in a new one when `newTab` (or with the system when Plain cannot open it).
    public var openPath: (URL, _ newTab: Bool) -> Void = { _, _ in }
    public var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    public var showInSidebar: (URL) -> Void = { _ in }
    /// Creates an empty file and opens it in a tab.
    public var createFile: (URL) -> Void = { _ in }
    public var visitURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Opens a web search for the text.
    public var searchWeb: (String) -> Void = { _ in }
    /// Shows an image zoomed over the window (spec 232).
    public var zoom: (NSImage) -> Void = { _ in }
    /// Opens a file at a text offset (To Last Edit across files).
    public var openFile: (URL, Int) -> Void = { _, _ in }
    /// Asks for a picture file (the `/` menu's Image block); nil when cancelled.
    public var chooseImage: @MainActor () -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OpenableFiles.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// Every file in the window's folder (the link editor's "Link to file…").
    public var folderFiles: () -> [URL] = { [] }

    public init() {}
}

/// Signpost intervals `keystroke` and `restyle`, for Instruments.
let editorSignposter = OSSignposter(subsystem: "com.alechenderson.Plain", category: "editor")

/// Fonts the editor draws with.
enum EditorFonts {
    /// Registers the bundled Roboto Mono for this process once.
    static let registered: Bool = {
        for url in [VendorFiles.robotoMonoRegular, VendorFiles.robotoMonoBold] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    static func prose(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }

    static func code(_ size: CGFloat, bold: Bool = false) -> NSFont {
        _ = registered
        return NSFont(name: bold ? "RobotoMono-Bold" : "RobotoMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

/// The TextKit 2 Markdown editor. Its text storage is the open `Document`'s; every character edit is forwarded to the
/// `MarkdownDocument`, and each snapshot that matches the current text restyles the blocks it changed.
@MainActor
public final class EditorTextView: NSTextView, @preconcurrency NSTextLayoutManagerDelegate {
    public let document: Document
    public let markdown: MarkdownDocument
    public private(set) var configuration: EditorConfiguration
    /// Injected by `EditorView` after init; the first injection loads the recent emoji through it.
    public var actions = EditorActions() {
        didSet {
            guard !recentEmojiRequested else { return }
            recentEmojiRequested = true
            let load = actions.recentEmoji
            Task { [weak self] in self?.recentEmoji = await load() }
        }
    }
    private var recentEmojiRequested = false
    let styler: MarkdownStyler

    /// The latest snapshot whose version equals the text's version; nil while a parse is pending.
    public private(set) var snapshot: Snapshot?
    /// The version of the last edit sent to `markdown`.
    public private(set) var appliedVersion = TextVersion(rawValue: 0)
    private var handledVersion = TextVersion(rawValue: -1)
    /// False until a snapshot of this editor's text has been applied to the whole text.
    private var styledOnce = false
    /// Edits sent but not yet covered by a delivered snapshot: version, location, old length, new length.
    private var editLog: [(version: Int, location: Int, oldLength: Int, newLength: Int)] = []
    /// The smallest location edited since `lastAppliedSnapshot` was applied; nil when nothing was edited since. Text
    /// before it has the same offsets as in that snapshot.
    private(set) var lowestEditSinceApplied: Int?
    /// The last snapshot applied to the text; unlike `snapshot` it stays set while a parse is pending.
    private(set) var lastAppliedSnapshot: Snapshot?
    /// Bold or italic chosen with an empty caret on the page: the next character typed at `at` is wrapped in `marker`.
    var pendingInline: (kind: InlineKind, marker: String, at: Int)?
    /// A caret position the page keeps although it lies in hidden Markdown (inside a just-made `**…**`).
    var allowedCaret: Int?
    /// Set by the arrow-key overrides around their `super` call; nil for every other selection change.
    var pageMove: (direction: Int, vertical: Bool)?
    let slashMenu = SlashMenuController()
    let blockHandle = BlockHandleController()
    let selectionToolbar = SelectionToolbarController()
    let tableGrid = TableGridController()
    /// Text that needs restyling once a current snapshot arrives, in current text offsets.
    private var dirtyRange: NSRange?
    private var editObserver: NSObjectProtocol?
    private var snapshotTask: Task<Void, Never>?
    /// Called on the main actor after each snapshot that matches the text has been applied.
    var snapshotObservers: [(Snapshot) -> Void] = []
    /// Called after every character edit with the edited range in the new text and the change in length.
    var editObservers: [(NSRange, Int) -> Void] = []
    /// The character just typed, or just deleted with Backspace, for spellcheck (spec 320).
    var lastTypedCharacter: Character?
    var lastEditTime = Date.distantPast
    /// Set while a helper makes its own edits, so they are not treated as typing.
    var helperDepth = 0
    var autocomplete: AutocompleteSession?
    var autocompletePopup: AutocompletePopup?
    var recentEmoji: [String] = []
    /// Bound by `bind(spellcheck:)`; nil while spelling is not wired.
    public internal(set) var spellcheck: SpellcheckController?
    /// True while Cmd is held: links show a pointing hand (spec 217).
    var linkMode = false
    /// Loaded pictures by file URL; nil marks a picture that failed to load.
    var imageCache: [URL: NSImage?] = [:]
    /// The start of the image line shown as text after Enter, until the caret leaves it.
    var expandedImageLine: Int?
    var pendingImageLoads: Set<URL> = []
    var adjustingImageSelection = false
    var mathRenderer: KaTeXRenderer?
    /// Carets and selections beyond the text view's own selection (see Selections.swift).
    var extraSelections: [NSRange] = []
    var settingSelections = false
    var occurrenceStack: [NSRange] = []
    var extendStack: [NSRange] = []
    var adjustingExtend = false
    var extraCaretsOn = true
    var blinkTimer: Timer?
    /// Shared by a window's editors so To Last Edit crosses files.
    public var editLocations = EditLocations()
    /// True while the find bar is open; math shows its source (spec 245).
    public internal(set) var findBarVisible = false {
        didSet {
            guard findBarVisible != oldValue else { return }
            refreshMath()
            stateChanged()
        }
    }
    /// Set by the window while the split preview shows; math shows its source (spec 245).
    public var splitPreviewShowing = false {
        didSet { if splitPreviewShowing != oldValue { refreshMath() } }
    }
    private var scrollObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    var find: FindState?
    /// Code ranges spelling skips, kept in step with edits between snapshots.
    var spellingExcluded: [NSRange] = []
    public internal(set) var gitStatus: GitStatus?
    /// Called after selection changes, scrolling and Find opening or closing (EditorController reads them).
    var stateObservers: [() -> Void] = []
    /// Called after an edit that inserted a line break.
    var lineBreakObserver: (() -> Void)?
    /// Git marks by zero-based line of the text they were computed from.
    var gitMarks: [Int: LineMark.Kind] = [:]
    var gitLineStarts: [Int] = [0]
    var gitRefreshTask: Task<Void, Never>?
    var findBar: FindBar?

    public init(document: Document, markdown: MarkdownDocument, configuration: EditorConfiguration = EditorConfiguration()) {
        self.document = document
        self.markdown = markdown
        self.configuration = configuration
        styler = MarkdownStyler(storage: document.textStorage, configuration: configuration)
        // A parser kept for the tab's life has seen earlier edits; this editor's edits continue from its version.
        appliedVersion = markdown.version

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 562, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.textContainer = container
        contentStorage.textStorage = document.textStorage
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        layoutManager.delegate = self

        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindBar = false
        usesFindPanel = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        drawsBackground = true
        applyColours()

        EditorLayoutFragment.labelCodeSize = configuration.codeFontSize
        applyBaseAttributes()
        updateGeometry()
        styler.didRestyle = { [weak self] range in self?.applyOverlays(in: range) }
        observeEdits()
        consumeSnapshots()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        snapshotTask?.cancel()
        blinkTimer?.invalidate()
    }

    public override var undoManager: UndoManager? { document.undoManager }

    // MARK: Configuration and geometry

    public func apply(_ newConfiguration: EditorConfiguration) {
        guard newConfiguration != configuration else { return }
        let previous = configuration
        configuration = newConfiguration
        styler.configuration = newConfiguration
        EditorLayoutFragment.labelCodeSize = newConfiguration.codeFontSize
        appearance = NSAppearance(named: newConfiguration.darkMode ? .darkAqua : .aqua)
        let modeChanged = newConfiguration.showMarkdownSource != previous.showMarkdownSource
        applyColours()
        applyBaseAttributes()
        updateGeometry()
        if let snapshot { restyleAll(snapshot) }
        typewriterConfigurationChanged()
        if modeChanged {
            closeSlashMenu()
            closeBlockHandle()
            closeSelectionToolbar()
            closeTableGrid()
            setAllSelections(allSelections)
        }
    }

    var isPage: Bool { !configuration.showMarkdownSource }

    /// Background, caret and selection colours: the page's on the page, today's in the source view.
    private func applyColours() {
        if isPage {
            backgroundColor = Tokens.page.background
            insertionPointColor = Tokens.page.text
            selectedTextAttributes = [.backgroundColor: Tokens.page.selection]
        } else {
            backgroundColor = Tokens.material
            insertionPointColor = Tokens.color
            selectedTextAttributes = [.backgroundColor: Tokens.selectionBlue]
        }
    }

    /// `ceil(lineWidth × width of "a")` in the prose font (spec 38, 1364).
    public var columnWidth: CGFloat {
        let a = NSAttributedString(string: "a", attributes: [.font: EditorFonts.prose(configuration.proseFontSize)]).size().width
        return ceil(configuration.lineWidth * a)
    }

    /// Padding above the first line and below the last; half the visible height each in typewriter mode (spec 334).
    var verticalPadding: (top: CGFloat, bottom: CGFloat) {
        if configuration.typewriter {
            let half = ((enclosingScrollView?.contentSize.height ?? bounds.height) / 2).rounded()
            return (half, half)
        }
        return (isPage ? Tokens.page.topPadding : Tokens.editorTopPadding, Tokens.editorBottomPadding)
    }

    func updateGeometry() {
        let available = bounds.width - 2 * Tokens.editorSidePadding
        let width = max(min(columnWidth, available), 40)
        let side = ((bounds.width - width) / 2).rounded(.down)
        textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let padding = verticalPadding
        textContainerInset = NSSize(width: max(side, 0), height: (padding.top + padding.bottom) / 2)
        if styler.pageColumnWidth != width {
            styler.pageColumnWidth = width
            if isPage, let snapshot {
                for table in snapshot.blocks(where: { $0.kind == .table }) { styler.restyle(snapshot: snapshot, range: table.range) }
            }
        }
        needsDisplay = true
    }

    /// The top padding differs from the bottom padding, so the origin is set here instead of from the inset alone.
    public override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: verticalPadding.top)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            updateGeometry()
            closeAutocomplete()
            closePageTools()
        }
    }

    /// The x of the text column's left edge in view coordinates.
    var columnLeft: CGFloat { textContainerOrigin.x }
    var columnRight: CGFloat { textContainerOrigin.x + (textContainer?.size.width ?? 0) }

    private func applyBaseAttributes() {
        let attributes = styler.baseAttributes
        typingAttributes = attributes
        defaultParagraphStyle = styler.baseParagraphStyle
        let storage = document.textStorage
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    // MARK: Keeping MarkdownDocument in step

    private func observeEdits() {
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: document.textStorage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let edited = storage.editedRange
            let delta = storage.changeInLength
            let replacement = (storage.string as NSString).substring(with: edited)
            MainActor.assumeIsolated { self?.textEdited(edited, delta: delta, replacement: replacement) }
        }
    }

    private func textEdited(_ edited: NSRange, delta: Int, replacement: String) {
        let old = NSRange(location: edited.location, length: edited.length - delta)
        appliedVersion = markdown.apply(TextEdit(range: old, replacement: replacement))
        editLog.append((appliedVersion.rawValue, old.location, old.length, edited.length))
        lowestEditSinceApplied = min(lowestEditSinceApplied ?? old.location, old.location)
        dirtyRange = dirtyRange.map { NSUnionRange(Self.map($0, location: old.location, oldLength: old.length, newLength: edited.length), edited) } ?? edited
        snapshot = nil
        if helperDepth == 0, !extraSelections.isEmpty {
            extraSelections = extraSelections.map { Self.map($0, location: old.location, oldLength: old.length, newLength: edited.length) }
        }
        recordEditLocation(edited)
        findTextChanged()
        spellingTextEdited(edited, delta: delta)
        if gitStatus != nil { scheduleGitMarks() }
        if delta > 0, replacement.contains("\n") { lineBreakObserver?() }
        for observer in editObservers { observer(edited, delta) }
    }

    /// Moves a range through one replacement of `oldLength` characters at `location` by `newLength` characters.
    static func map(_ range: NSRange, location: Int, oldLength: Int, newLength: Int) -> NSRange {
        let delta = newLength - oldLength
        var start = range.location
        var end = NSMaxRange(range)
        if start >= location + oldLength { start += delta } else if start > location { start = location }
        if end >= location + oldLength { end += delta } else if end > location { end = location + newLength }
        return NSRange(location: start, length: max(end - start, 0))
    }

    private func consumeSnapshots() {
        let stream = markdown.snapshots
        let markdown = markdown
        let version = appliedVersion
        snapshotTask = Task { [weak self] in
            let first = await markdown.snapshot(atLeast: version)
            self?.received(first, initial: true)
            for await snapshot in stream {
                guard let self else { return }
                self.received(snapshot, initial: false)
            }
        }
    }

    /// Waits until a snapshot for the current text has been applied.
    public func settle() async {
        // A second pass covers the whole-text edit sent when the parser held other text.
        for _ in 0..<2 where snapshot?.version != appliedVersion {
            received(await markdown.snapshot(atLeast: appliedVersion), initial: false)
        }
    }

    func received(_ snapshot: Snapshot, initial isFirst: Bool) {
        guard snapshot.version > handledVersion else { return }
        let first = isFirst || handledVersion.rawValue < 0
        let initial = !styledOnce
        handledVersion = snapshot.version
        if first && snapshot.version == appliedVersion && !(snapshot.text as NSString).isEqual(to: document.textStorage.string) {
            // The parser holds other text (made from it, or edited while no editor was attached): send the whole text once.
            let length = (snapshot.text as NSString).length
            appliedVersion = markdown.apply(TextEdit(range: NSRange(location: 0, length: length), replacement: document.textStorage.string))
            return
        }
        // Bring this snapshot's changed range forward through the edits it does not contain yet.
        editLog.removeAll { $0.version <= snapshot.version.rawValue }
        var changed = snapshot.changedRange
        for edit in editLog { changed = Self.map(changed, location: edit.location, oldLength: edit.oldLength, newLength: edit.newLength) }
        dirtyRange = initial ? nil : (dirtyRange.map { NSUnionRange($0, changed) } ?? changed)
        guard snapshot.version == appliedVersion else { return }
        self.snapshot = snapshot
        lastAppliedSnapshot = snapshot
        lowestEditSinceApplied = nil
        if initial {
            styledOnce = true
            restyleAll(snapshot)
        } else if let range = dirtyRange {
            styler.restyle(snapshot: snapshot, range: range)
        }
        dirtyRange = nil
        needsDisplay = true
        spellingSnapshotArrived()
        for observer in snapshotObservers { observer(snapshot) }
        if isPage, find != nil { findTextChanged() }
    }

    /// Restyles the visible text now and the rest in slices on later main-actor turns.
    private var restyleAllTask: Task<Void, Never>?
    func restyleAll(_ snapshot: Snapshot) {
        restyleAllTask?.cancel()
        let total = document.textStorage.length
        let visible = visibleCharacterRange()
        styler.restyle(snapshot: snapshot, range: visible)
        restyleAllTask = Task { [weak self] in
            var location = 0
            while location < total {
                await Task.yield()
                guard let self, !Task.isCancelled, self.snapshot?.version == snapshot.version else { return }
                let slice = NSRange(location: location, length: min(64_000, total - location))
                self.styler.restyle(snapshot: snapshot, range: slice)
                location = NSMaxRange(slice)
            }
        }
    }

    /// The characters in the visible part of the view, or the first 20,000 when the view is not in a window.
    public func visibleCharacterRange() -> NSRange {
        let length = document.textStorage.length
        guard let layoutManager = textLayoutManager, let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              enclosingScrollView != nil,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: min(length, 20_000))
        }
        let start = contentStorage.offset(from: contentStorage.documentRange.location, to: viewport.location)
        let end = contentStorage.offset(from: contentStorage.documentRange.location, to: viewport.endLocation)
        return NSRange(location: start, length: max(end - start, 0))
    }

    // MARK: Drawing

    /// Extra drawing behind the text, added by later files (find matches, git marks).
    var backgroundDrawers: [(NSRect) -> Void] = []

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawBands(in: rect)
        drawExtraSelections(in: rect)
        drawGitMarks(in: rect)
        for drawer in backgroundDrawers { drawer(rect) }
        drawPlaceholder(in: rect)
    }

    /// "Type / for blocks" on the page's empty line holding the only caret, outside code, maths, front matter and HTML.
    private func drawPlaceholder(in rect: NSRect) {
        guard isPage, window?.firstResponder === self, let offset = caret, lineContents(at: offset).length == 0,
              let snapshot else { return }
        switch snapshot.deepestBlock(at: offset)?.kind {
        case .fencedCode?, .indentedCode?, .mathBlock?, .frontMatter?, .htmlBlock?, .htmlComment?: return
        default: break
        }
        let line = self.rect(forCharacterRange: NSRange(location: offset, length: 0))
        guard line.intersects(rect) || rect.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: Tokens.page.bodySize)
        let string = NSAttributedString(string: "Type / for blocks", attributes: [.font: font, .foregroundColor: Tokens.page.textTertiary])
        string.draw(at: NSPoint(x: line.minX, y: line.minY + (line.height - string.size().height) / 2))
    }

    /// Marks the lines of the empty carets in `ranges` for redrawing, so the placeholder follows the caret.
    private func redrawCaretLines(_ ranges: [NSRange]) {
        guard isPage else { return }
        for range in ranges where range.length == 0 && range.location <= nsText.length {
            let line = rect(forCharacterRange: NSRange(location: range.location, length: 0))
            setNeedsDisplay(NSRect(x: columnLeft, y: line.minY, width: columnRight - columnLeft, height: line.height))
        }
    }

    /// The full-column `--highlight` band behind fenced code, math, front matter and HTML block lines (spec 72, 1300).
    private func drawBands(in rect: NSRect) {
        Tokens.highlight.setFill()
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? 0
        enumerateFragments(in: rect) { fragment in
            guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
                  paragraph.attributedString.attribute(.plainBand, at: 0, effectiveRange: nil) != nil else { return }
            let frame = fragment.layoutFragmentFrame
            NSRect(x: origin.x, y: origin.y + frame.minY, width: width, height: frame.height).fill(using: .sourceOver)
        }
    }

    /// Calls `body` for each laid-out fragment whose frame meets `rect` (view coordinates).
    func enumerateFragments(in rect: NSRect, _ body: (NSTextLayoutFragment) -> Void) {
        guard let layoutManager = textLayoutManager else { return }
        let top = rect.minY - textContainerOrigin.y
        let bottom = rect.maxY - textContainerOrigin.y
        let start = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(top, 0)))?.rangeInElement.location
            ?? layoutManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > bottom { return false }
            if frame.maxY >= top { body(fragment) }
            return true
        }
    }

    /// The union of the line segments covering `range`, in view coordinates; an empty range gives the caret's line box.
    public func rect(forCharacterRange range: NSRange) -> NSRect {
        guard let layoutManager = textLayoutManager, let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return .zero }
        layoutManager.ensureLayout(for: textRange)
        var result = NSRect.null
        let options: NSTextLayoutManager.SegmentOptions = range.length == 0 ? [.rangeNotRequired] : [.rangeNotRequired, .middleFragmentsExcluded]
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: options) { _, frame, _, _ in
            result = result.union(frame)
            return true
        }
        guard !result.isNull else { return .zero }
        let origin = textContainerOrigin
        return result.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Layout fragments

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        EditorLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    // MARK: Keys and focus

    public override func doCommand(by selector: Selector) {
        if slashMenuHandles(selector) { return }
        if autocompleteCommand(selector) { return }
        switch selector {
        case #selector(insertNewlineIgnoringFieldEditor(_:)):
            askForSuggestions()
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            escapePressed()
        default:
            super.doCommand(by: selector)
        }
    }

    /// Esc arrives here, not at the system word-completion popup.
    public override func cancelOperation(_ sender: Any?) { escapePressed() }
    public override func complete(_ sender: Any?) { escapePressed() }

    /// Esc: closes the autocomplete list, else clears an empty list item (spec 128, 183).
    func escapePressed() {
        if slashMenuHandles(#selector(NSResponder.cancelOperation(_:))) { return }
        if autocomplete != nil { return closeAutocomplete() }
        if find != nil { return closeFind() }
        if !extraSelections.isEmpty { return setAllSelections([selectedRange()]) }
        _ = listEscape()
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = allSelections
        var ranges = ranges
        if isPage, let main = ranges.first?.rangeValue {
            ranges[0] = NSValue(range: pageAdjusted(main, previous: selectedRange()))
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if isPage {
            if helperDepth == 0 {
                let main = selectedRange()
                if main.length != 0 || main.location != allowedCaret { allowedCaret = nil }
                if main.length != 0 || main.location != pendingInline?.at { pendingInline = nil }
            }
            pageTypingAttributes()
            styler.pageSelections = allSelections
        }
        if autocomplete != nil { closeAutocomplete() }
        if !settingSelections && helperDepth == 0 {
            if !extraSelections.isEmpty { clearExtraSelections() }
            if !adjustingExtend { extendStack = [] }
        }
        if !stillSelecting { selectionMoved(from: previous) }
    }

    public override func mouseDown(with event: NSEvent) {
        if isPage {
            closeSlashMenu()
            closeBlockHandle()
            closeSelectionToolbar()
        }
        if clickedLink(event) { return }
        if isPage {
            if clickedTaskBox(event) { return }
            if clickedCodeLabel(event) { return }
            if tableGridMouseDown(event) {
                selectionToolbarAfterMouseUp()
                return
            }
        }
        if handleSelectionClick(event) { return }
        if clickedImage(event) { return }
        super.mouseDown(with: event)
        typewriterCenter()
        if isPage { selectionToolbarAfterMouseUp() }
    }

    /// A single click in a page task line's box ticks or unticks it; the later clicks of a double or triple click in the
    /// box do nothing, so the box is not ticked twice.
    private func clickedTaskBox(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let line = lineContents(at: characterIndexForInsertion(at: point))
        guard line.location < nsText.length,
              let marker = document.textStorage.attribute(.plainPageMarker, at: line.location, effectiveRange: nil) as? PageMarker,
              case .task = marker.kind else { return false }
        let first = rect(forCharacterRange: NSRange(location: line.location, length: 0))
        guard NSRect(x: columnLeft + marker.x, y: first.minY, width: Tokens.page.markerBox, height: first.height).contains(point) else { return false }
        if event.clickCount == 1 { toggleTask(at: line.location) }
        return true
    }

    /// A click on a code panel's language label opens the language list.
    private func clickedCodeLabel(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let line = lineContents(at: characterIndexForInsertion(at: point))
        guard line.location < nsText.length,
              let slice = document.textStorage.attribute(.plainPagePanel, at: line.location, effectiveRange: nil) as? PagePanelSlice,
              let label = slice.label else { return false }
        let page = Tokens.page
        let width = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: page.codeHeaderSize)]).size().width
        let first = rect(forCharacterRange: NSRange(location: line.location, length: 0))
        let hit = NSRect(x: columnLeft + page.codePadSides, y: first.minY + page.codePadTop, width: width + 4 + page.codeHeaderSize, height: 18)
        guard hit.contains(point) else { return false }
        openLanguageList(fenceLineStart: line.location)
        return true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["plainPage"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["plainPage": true]))
    }

    /// Closes the `/` menu, the block handle, the selection toolbar and the table grid.
    func closePageTools() {
        closeSlashMenu()
        closeBlockHandle()
        closeSelectionToolbar()
        closeTableGrid()
    }

    public override func becomeFirstResponder() -> Bool {
        if gitStatus != nil { scheduleGitMarks(after: .zero) }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        closeAutocomplete()
        linkMode = false
        if isPage {
            // A tool's own text field taking focus keeps its tool open.
            Task { @MainActor [weak self] in
                guard let self, !((self.window?.firstResponder as? NSView)?.isDescendant(of: self) ?? false) else { return }
                self.closePageTools()
            }
        }
        return super.resignFirstResponder()
    }

    /// Re-applies the pictures drawn over source lines after the styler reset `range` (images, math).
    func applyOverlays(in range: NSRange) {
        applyImageOverlays(in: range)
        applyMathOverlays(in: range)
    }

    /// Runs after every selection change that is not a drag in progress.
    func selectionMoved(from previous: [NSRange]) {
        redrawCaretLines(previous + allSelections)
        if isPage {
            slashMenuSelectionMoved()
            blockHandleSelectionMoved()
            selectionToolbarSelectionMoved()
            tableGridSelectionMoved()
            restyleSourceZones(previous: previous)
        }
        imageSelectionMoved(from: previous)
        mathSelectionMoved(from: previous)
        typewriterCenter()
        stateChanged()
    }

    func stateChanged() {
        for observer in stateObservers { observer() }
    }

    /// Restyles the front matter when a selection entered or left its zone, and each setext heading whose underline
    /// holds the previous or the new main caret, so their source shows or hides.
    private func restyleSourceZones(previous: [NSRange]) {
        guard let snapshot else { return }
        if let front = snapshot.blocks.first, front.kind == .frontMatter,
           MarkdownStyler.selectionsTouch(front, selections: allSelections, text: nsText) != styler.frontMatterShownAsSource {
            styler.restyle(snapshot: snapshot, range: front.range)
        }
        for range in [previous.first, allSelections.first].compactMap({ $0 }) where range.length == 0 && range.location <= nsText.length {
            guard let block = snapshot.deepestBlock(at: range.location), case .setextHeading = block.kind,
                  let underline = block.markerRanges.first else { continue }
            let line = lineContents(at: underline.location)
            if range.location >= line.location, range.location <= NSMaxRange(line) { styler.restyle(snapshot: snapshot, range: block.range) }
        }
    }

    /// Leaving its scroll view ends this editor: a later editor for the tab takes over the tab's parser, so this one
    /// stops sending it edits and taking its snapshots.
    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        guard newSuperview == nil, superview != nil else { return }
        closePageTools()
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        editObserver = nil
        snapshotTask?.cancel()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.typewriterViewportResized() }
        }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibleAreaChanged() }
        }
    }

    /// After scrolling: render math that came into view.
    func visibleAreaChanged() {
        applyMathOverlays(in: visibleCharacterRange())
        stateChanged()
    }

}
