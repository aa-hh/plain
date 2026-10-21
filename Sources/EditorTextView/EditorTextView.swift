import AppKit
import CoreText
import os
import MarkdownDocument
import PlainCore
import PlainDocument
import GitStatus
import PlainVendor
import Spellcheck

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

    public init(fontSize: CGFloat = 15, codeFontSize: CGFloat = 13, lineHeight: CGFloat = 1.6, lineWidth: CGFloat = 72,
                largeHeadings: Bool = true, typewriter: Bool = false, darkMode: Bool = false, tabSize: Int = 2) {
        self.fontSize = fontSize
        self.codeFontSize = codeFontSize
        self.lineHeight = lineHeight
        self.lineWidth = lineWidth
        self.largeHeadings = largeHeadings
        self.typewriter = typewriter
        self.darkMode = darkMode
        self.tabSize = tabSize
    }

    /// One text line in points.
    public var linePoints: CGFloat { (fontSize * lineHeight).rounded() }
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
    /// Opens a file in a tab (or with the system when Plain cannot open it).
    public var openPath: (URL) -> Void = { _ in }
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
    public var actions = EditorActions()
    let styler: MarkdownStyler

    /// The latest snapshot whose version equals the text's version; nil while a parse is pending.
    public private(set) var snapshot: Snapshot?
    /// The version of the last edit sent to `markdown`.
    public private(set) var appliedVersion = TextVersion(rawValue: 0)
    private var handledVersion = TextVersion(rawValue: -1)
    /// Edits sent but not yet covered by a delivered snapshot: version, location, old length, new length.
    private var editLog: [(version: Int, location: Int, oldLength: Int, newLength: Int)] = []
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
        insertionPointColor = Tokens.color
        drawsBackground = true
        backgroundColor = Tokens.material
        selectedTextAttributes = [.backgroundColor: Tokens.selectionBlue]

        EditorLayoutFragment.labelCodeSize = configuration.codeFontSize
        applyBaseAttributes()
        updateGeometry()
        styler.didRestyle = { [weak self] range in self?.applyOverlays(in: range) }
        observeEdits()
        consumeSnapshots()
        let load = actions.recentEmoji
        Task { [weak self] in self?.recentEmoji = await load() }
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
        configuration = newConfiguration
        styler.configuration = newConfiguration
        EditorLayoutFragment.labelCodeSize = newConfiguration.codeFontSize
        appearance = NSAppearance(named: newConfiguration.darkMode ? .darkAqua : .aqua)
        applyBaseAttributes()
        updateGeometry()
        if let snapshot { restyleAll(snapshot) }
        typewriterConfigurationChanged()
    }

    /// `ceil(lineWidth × width of "a")` in the prose font (spec 38, 1364).
    public var columnWidth: CGFloat {
        let a = NSAttributedString(string: "a", attributes: [.font: EditorFonts.prose(configuration.fontSize)]).size().width
        return ceil(configuration.lineWidth * a)
    }

    /// Padding above the first line and below the last; half the visible height each in typewriter mode (spec 334).
    var verticalPadding: (top: CGFloat, bottom: CGFloat) {
        if configuration.typewriter {
            let half = ((enclosingScrollView?.contentSize.height ?? bounds.height) / 2).rounded()
            return (half, half)
        }
        return (Tokens.editorTopPadding, Tokens.editorBottomPadding)
    }

    func updateGeometry() {
        let available = bounds.width - 2 * Tokens.editorSidePadding
        let width = max(min(columnWidth, available), 40)
        let side = ((bounds.width - width) / 2).rounded(.down)
        textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let padding = verticalPadding
        textContainerInset = NSSize(width: max(side, 0), height: (padding.top + padding.bottom) / 2)
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
        snapshotTask = Task { [weak self] in
            let first = await markdown.currentSnapshot()
            self?.received(first, initial: true)
            for await snapshot in stream {
                guard let self else { return }
                self.received(snapshot, initial: false)
            }
        }
    }

    /// Waits until a snapshot for the current text has been applied.
    public func settle() async {
        let snapshot = await markdown.snapshot(atLeast: appliedVersion)
        received(snapshot, initial: false)
    }

    private func received(_ snapshot: Snapshot, initial isFirst: Bool) {
        guard snapshot.version > handledVersion else { return }
        let initial = isFirst || handledVersion.rawValue < 0
        handledVersion = snapshot.version
        if initial && snapshot.version == TextVersion(rawValue: 0) && appliedVersion == snapshot.version
            && (snapshot.text as NSString).length != document.textStorage.length {
            // The parser was made from different text: send the whole text once.
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
        if initial {
            restyleAll(snapshot)
        } else if let range = dirtyRange {
            styler.restyle(snapshot: snapshot, range: range)
        }
        dirtyRange = nil
        needsDisplay = true
        spellingSnapshotArrived()
        for observer in snapshotObservers { observer(snapshot) }
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
        if autocomplete != nil { return closeAutocomplete() }
        if find != nil { return closeFind() }
        if !extraSelections.isEmpty { return setAllSelections([selectedRange()]) }
        _ = listEscape()
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = allSelections
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if autocomplete != nil { closeAutocomplete() }
        if !settingSelections && helperDepth == 0 {
            if !extraSelections.isEmpty { clearExtraSelections() }
            if !adjustingExtend { extendStack = [] }
        }
        if !stillSelecting { selectionMoved(from: previous) }
    }

    public override func mouseDown(with event: NSEvent) {
        if clickedLink(event) { return }
        if handleSelectionClick(event) { return }
        if clickedImage(event) { return }
        super.mouseDown(with: event)
        typewriterCenter()
    }

    public override func becomeFirstResponder() -> Bool {
        if gitStatus != nil { scheduleGitMarks(after: .zero) }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        closeAutocomplete()
        linkMode = false
        return super.resignFirstResponder()
    }

    /// Re-applies the pictures drawn over source lines after the styler reset `range` (images, math).
    func applyOverlays(in range: NSRange) {
        applyImageOverlays(in: range)
        applyMathOverlays(in: range)
    }

    /// Runs after every selection change that is not a drag in progress.
    func selectionMoved(from previous: [NSRange]) {
        imageSelectionMoved(from: previous)
        mathSelectionMoved(from: previous)
        typewriterCenter()
        stateChanged()
    }

    func stateChanged() {
        for observer in stateObservers { observer() }
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
