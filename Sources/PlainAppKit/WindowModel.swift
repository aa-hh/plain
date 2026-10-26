import AppKit
import Combine
import EditorTextView
import FolderIndex
import GitStatus
import MarkdownDocument
import Observation
import PlainCore
import PlainDocument
import PlainShell
import PreviewRenderer
import QuickLookUI
import Spellcheck
import UniformTypeIdentifiers
import Yams

public enum PreviewMode: String, Codable, Sendable {
    case none, split, full
}

// MARK: - Rules kept apart from the window so tests can check them

/// Where opening a path leads (spec 757–762).
public enum OpenTarget: Equatable, Sendable {
    case tab(URL, anchor: String?)
    case quickLook(URL)
    case system(URL)
    case browser(URL)
    case nothing

    public static func decide(_ path: String) -> OpenTarget {
        if let url = URL(string: path), let scheme = url.scheme?.lowercased(), scheme != "file", scheme.count > 1 {
            return .browser(url)
        }
        let plainPath = path.hasPrefix("file://") ? (URL(string: path)?.path ?? String(path.dropFirst(7))) : path
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        if manager.fileExists(atPath: plainPath, isDirectory: &isFolder) {
            let url = URL(fileURLWithPath: plainPath, isDirectory: isFolder.boolValue)
            if isFolder.boolValue { return .system(url) }
            if OpenableFiles.isOpenable(url) { return .tab(url, anchor: nil) }
            if OpenableFiles.imageExtensions.contains(url.pathExtension.lowercased()) { return .quickLook(url) }
            return .system(url)
        }
        // Rule 1: `#anchor`, `?query` or a trailing `/` on a file that exists without it.
        for separator in ["#", "?"] {
            if let cut = plainPath.range(of: separator, options: .backwards) {
                let base = String(plainPath[..<cut.lowerBound])
                if Self.isOpenableFile(base) {
                    let suffix = String(plainPath[cut.upperBound...])
                    return .tab(URL(fileURLWithPath: base), anchor: suffix.isEmpty ? nil : suffix)
                }
            }
        }
        if plainPath.hasSuffix("/"), Self.isOpenableFile(String(plainPath.dropLast())) {
            return .tab(URL(fileURLWithPath: String(plainPath.dropLast())), anchor: nil)
        }
        return .nothing
    }

    private static func isOpenableFile(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && OpenableFiles.isOpenable(URL(fileURLWithPath: path))
    }
}

/// Which tab a file opened in place lands in (docs/navigation-spec.md, "Which tab the file lands in").
public enum Placement: Equatable, Sendable {
    /// Rule 1: the file is the current tab's file.
    case stay
    /// Rule 2: the file is open in another tab.
    case switchTo(UUID)
    /// Rule 3: there is no current tab, or it cannot be left.
    case newTab
    /// Rule 4: the current tab shows the file instead.
    case replace

    /// `tabs` are every open tab's id and standardized path; `canLeave` runs only when rules 1 and 2 do not fit.
    public static func decide(target: String, currentID: UUID?, tabs: [(id: UUID, path: String)], canLeave: () -> Bool) -> Placement {
        if let currentID, tabs.contains(where: { $0.id == currentID && $0.path == target }) { return .stay }
        if let other = tabs.first(where: { $0.path == target && $0.id != currentID }) { return .switchTo(other.id) }
        guard currentID != nil, canLeave() else { return .newTab }
        return .replace
    }

    /// A tab can be left when its file is a saved, ordinary file: not untitled, a settings file or a backup, and
    /// with no changes left after autosave has been flushed.
    public static func canLeave(isUntitled: Bool, isPreferences: Bool, isBackup: Bool, isEdited: Bool) -> Bool {
        !(isUntitled || isPreferences || isBackup || isEdited)
    }
}

/// Whether closing a tab asks `"<name>" has changes, do you want to save them?` (spec 747, 869–871).
public enum ClosePrompt {
    public static func isNeeded(isEdited: Bool, autosave: Bool, isUntitled: Bool, isPreferences: Bool, isBackup: Bool) -> Bool {
        guard isEdited, !isBackup else { return false }
        return !(autosave && !isUntitled && !isPreferences)
    }
}

/// A file opened in a folder and when.
public struct RecentFile: Codable, Equatable, Sendable {
    public var path: String
    public var lastUsed: Date
    public init(path: String, lastUsed: Date) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

/// A window's tabs for one folder (spec 830) and the folder's recent files (spec 810).
public struct TabMemory: Codable, Equatable, Sendable {
    public static let closedLimit = 20
    public static let recentLimit = 40

    public var files: [String]
    public var current: Int?
    public var closed: [String]
    public var recents: [RecentFile]
    /// Each tab's back and forward lists, in the order of `files`.
    public var history: [TabHistory]

    public init(files: [String] = [], current: Int? = nil, closed: [String] = [], recents: [RecentFile] = [],
                history: [TabHistory] = []) {
        self.files = files
        self.current = current
        self.closed = closed
        self.recents = recents
        self.history = history
    }

    enum CodingKeys: String, CodingKey { case files, current, closed, recents, history }

    /// Files written before tabs had back and forward lists have no `history`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([String].self, forKey: .files)
        current = try container.decodeIfPresent(Int.self, forKey: .current)
        closed = try container.decodeIfPresent([String].self, forKey: .closed) ?? []
        recents = try container.decodeIfPresent([RecentFile].self, forKey: .recents) ?? []
        history = try container.decodeIfPresent([TabHistory].self, forKey: .history) ?? []
    }

    /// Stored per window in `state/tabs-w<N>.json`, keyed by folder path ("" for no folder).
    public static func load(from store: StateStore, window: Int, folder: URL?) async -> TabMemory? {
        let all = await store.load(StateName.tabs(window), as: [String: TabMemory].self) ?? [:]
        return all[folder?.standardizedFileURL.path ?? ""]
    }

    public static func save(_ memory: TabMemory, to store: StateStore, window: Int, folder: URL?) async throws {
        var all = await store.load(StateName.tabs(window), as: [String: TabMemory].self) ?? [:]
        all[folder?.standardizedFileURL.path ?? ""] = memory
        try await store.save(StateName.tabs(window), all)
    }

    static func addingRecent(_ path: String, to recents: [RecentFile], now: Date) -> [RecentFile] {
        Array(([RecentFile(path: path, lastUsed: now)] + recents.filter { $0.path != path }).prefix(recentLimit))
    }
}

/// The Preferences file (spec 1034–1041): the YAML block is read with Yams on save.
public enum PreferencesFile {
    public enum ParseError: Error { case noYAMLBlock, unreadable, wrongType(String) }

    /// The visible preference values the file sets. Throws when the YAML does not parse or a value has the wrong type.
    public static func parse(_ markdown: String) throws -> [String: PreferenceValue] {
        guard let block = Shortcuts.yamlBlocks(in: markdown).first else { throw ParseError.noYAMLBlock }
        let loaded: Any?
        do { loaded = try Yams.load(yaml: block) } catch { throw ParseError.unreadable }
        guard let map = loaded as? [String: Any] else { throw ParseError.unreadable }
        var result: [String: PreferenceValue] = [:]
        for (name, raw) in map {
            guard let key = PreferenceKey.byName[name], !key.silent else { continue }
            switch (key.defaultValue, raw) {
            case (.bool, let value as Bool): result[name] = .bool(value)
            case (.number, let value as Int): result[name] = .number(Double(value))
            case (.number, let value as Double): result[name] = .number(value)
            case (.string, let value as String): result[name] = .string(value)
            case (.string, let value): result[name] = .string("\(value)")
            default: throw ParseError.wrongType(name)
            }
        }
        return result
    }

    /// Applies the file's values (clamped). Returns false and changes nothing when it does not parse.
    @MainActor
    public static func apply(_ markdown: String, to preferences: Preferences) -> Bool {
        guard let values = try? parse(markdown) else { return false }
        for (name, value) in values { preferences.set(name, value) }
        return true
    }

    /// A stored value's text, read back with `value(_:like:)`.
    static func text(_ value: PreferenceValue) -> String {
        switch value {
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): String(number)
        case .string(let string): string
        }
    }

    static func value(_ text: String, like example: PreferenceValue) -> PreferenceValue? {
        switch example {
        case .bool: text == "true" ? .bool(true) : text == "false" ? .bool(false) : nil
        case .number: Double(text).map(PreferenceValue.number)
        case .string: .string(text)
        }
    }
}

/// A backup tab's diff and where it came from (spec 886–887).
struct BackupTab {
    var original: URL
    var backup: BackupInfo
    var lines: [DiffLine]
}

/// Answers to a prompt, by button index.
public typealias Ask = @MainActor (_ message: String, _ buttons: [String]) -> Int

// MARK: - Window model

/// Everything one window shows and does: its folder, tabs, sidebars, popups, preview and the editor wiring.
@MainActor @Observable
public final class WindowModel {
    public let id: Int
    @ObservationIgnored let context: AppContext
    @ObservationIgnored public weak var window: NSWindow? {
        didSet { window?.title = folder?.lastPathComponent ?? "Plain" }
    }
    /// Runs a command id: `(id, fromCommandsPopup)`. Set by the app delegate.
    @ObservationIgnored public var runCommand: (String, Bool) -> Void = { _, _ in }
    /// Asked when the minimum window width changes (spec 725).
    @ObservationIgnored var minimumWidthChanged: (CGFloat) -> Void = { _ in }
    /// Shows a prompt; tests replace it.
    @ObservationIgnored public var ask: Ask = { message, buttons in
        let alert = NSAlert()
        alert.messageText = message
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    public private(set) var folder: URL?
    public private(set) var tree: FolderNode?
    public private(set) var allFiles: [URL] = []
    public private(set) var gitMarks: [URL: GitMark] = [:]
    @ObservationIgnored public private(set) var index: FolderIndex?
    @ObservationIgnored public private(set) var git: GitStatus?

    public let tabs = TabsState()
    public private(set) var memory = TabMemory()
    public let sidebar = SidebarState()
    public let popup = PopupState()
    public private(set) var previewMode: PreviewMode = .none
    /// View > Show Markdown Source: the editor shows the Markdown as text instead of the page; saved per window.
    public private(set) var markdownSource = false
    public private(set) var interfaceHidden = false
    public private(set) var notifications: [ShellNotification] = []
    public var zoomImage: NSImage?
    public var screenWidth: CGFloat = 1680

    public let editor = EditorController()
    public let preview: PreviewController
    @ObservationIgnored let scrollSync: ScrollSync
    public let spellcheck: SpellcheckController
    /// The parser for the current tab; each tab gets its own on first activation and keeps it until it closes.
    public private(set) var markdown: MarkdownDocument?
    @ObservationIgnored private(set) var parsers: [ObjectIdentifier: MarkdownDocument] = [:]
    public private(set) var snapshot: Snapshot? {
        didSet { if outlineShowing { refreshChangedHeadings() } }
    }
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    public private(set) var changedHeadings: Set<BlockID> = []
    @ObservationIgnored private var changedHeadingsTask: Task<Void, Never>?
    @ObservationIgnored private var autosaves: [ObjectIdentifier: AutosaveController] = [:]
    @ObservationIgnored private let richTextMath = KaTeXJSRenderer()
    @ObservationIgnored let modifierFlags = PassthroughSubject<NSEvent.ModifierFlags, Never>()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var historyTimer: Timer?
    @ObservationIgnored private var backupTimer: Timer?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var fileClipboard: (urls: [URL], cut: Bool)?
    @ObservationIgnored private var quickLook: QuickLookSource?
    @ObservationIgnored private var lastSaveAsFolder: URL?
    var backupTabs: [UUID: BackupTab] = [:]

    public private(set) var searchHits: [SearchHit] = []
    public private(set) var backupsList: [BackupInfo] = []

    static func projectName(_ id: Int) -> String { "project-w\(id)" }
    static func sidebarName(_ id: Int) -> String { "sidebar-w\(id)" }
    static func previewModeName(_ id: Int) -> String { "preview-modes-w\(id)" }
    static func markdownSourceName(_ id: Int) -> String { "markdown-source-w\(id)" }
    static let hideInterfaceName = "hide-interface"

    public init(id: Int, context: AppContext) {
        self.id = id
        self.context = context
        preview = PreviewController(themeURL: context.themeURL)
        scrollSync = ScrollSync(controller: preview)
        spellcheck = SpellcheckController(engine: SystemSpellingEngine())
        spellcheck.enabled = context.preferences.bool("spellcheck")
        spellcheck.autocorrect = context.preferences.bool("autoCorrectSpelling")
        preview.openPath = { [weak self] path, newTab in self?.openLink(path, newTab: newTab) }
        preview.applyEdit = { [weak self] edit in self?.applyPreviewEdit(edit) }
        editor.onLineBreakInserted = { [weak self] in self?.lineBreakInserted() }
        observers.append(NotificationCenter.default.addObserver(forName: .documentDiskChanged, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self, let document = object as? Document,
                      self.tabs.current?.document === document, self.window?.isKeyWindow == true else { return }
                Task { await self.checkDisk(document) }
            }
        })
        historyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordHistoryIfFocused() }
        }
        backupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestBackup(self?.tabs.current?.document) }
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        historyTimer?.invalidate()
        backupTimer?.invalidate()
        for task in tasks { task.cancel() }
        snapshotTask?.cancel()
        searchTask?.cancel()
    }

    // MARK: Derived state

    public var currentDocument: Document? { tabs.current?.document }

    /// Editor settings from the preferences.
    public var configuration: EditorConfiguration {
        let p = context.preferences
        return EditorConfiguration(
            fontSize: p.number("fontSize"), codeFontSize: p.number("codeFontSize"), lineHeight: p.number("lineHeight"),
            lineWidth: p.number("lineWidth"), largeHeadings: p.bool("useLargeFontInHeadings"), typewriter: p.bool("typewriter"),
            darkMode: p.bool("nightMode"), tabSize: Int(p.number("tabSize")), showMarkdownSource: markdownSource)
    }

    public var statsVisible: Bool { context.preferences.bool("text-stats.visible") && !interfaceHidden }
    public var statsMode: TextStatsMode { TextStatsMode(rawValue: context.preferences.string("text-stats.type")) ?? .wordCount }

    /// The text the stats label counts: the selection when there is one (spec 1015).
    public var statsText: (text: String, isSelection: Bool) {
        guard let document = currentDocument else { return ("", false) }
        let text = document.textStorage.string as NSString
        let selected = editor.selectedRanges.filter { $0.length > 0 && NSMaxRange($0) <= text.length }
        if !selected.isEmpty { return (selected.map { text.substring(with: $0) }.joined(separator: "\n"), true) }
        return (document.text, false)
    }

    public var commands: [Command] { context.commands }
    public var commandHistory: [String] { context.commandHistory }
    public var recentFolders: [URL] { context.recentFolders }

    /// This folder's recent files, newest first.
    public var recentURLs: [URL] { memory.recents.map { URL(fileURLWithPath: $0.path) } }

    /// Tabs in most-recently-used order for the Ctrl+Tab switcher (spec 972).
    public var tabsByRecentUse: [TabItem] {
        let order = Dictionary(memory.recents.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return tabs.items.enumerated().sorted { a, b in
            let x = a.element.document.url.flatMap { order[$0.path] } ?? Int.max
            let y = b.element.document.url.flatMap { order[$0.path] } ?? Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    func backupTab(_ id: TabItem.ID?) -> BackupTab? { id.flatMap { backupTabs[$0] } }

    /// Minimum window width: 400, doubled with a preview, plus the sidebar's width and 60 while it shows
    /// (spec 725, 1431; 260 at the default width).
    public static func minimumWidth(sidebarWidth: CGFloat?, previewVisible: Bool) -> CGFloat {
        WindowController.minimumSize.width * (previewVisible ? 2 : 1) + (sidebarWidth.map { $0 + 60 } ?? 0)
    }

    public var sidebarVisible: Bool { sidebar.visible && !interfaceHidden }

    /// The Outline section is on screen: the sidebar shows and the section is neither hidden nor folded.
    var outlineShowing: Bool {
        let outline = context.sidebarSections[.outline]
        return sidebarVisible && !outline.hidden && !outline.folded
    }

    /// The Pinned section's files: this folder's pins.
    public var pinnedFiles: [URL] { context.pins.files(in: folder) }

    /// The Recent section's files: the 6 most recently opened in this folder, without the current tab's file and
    /// files that no longer exist.
    public var recentFiles: [URL] {
        let current = currentDocument?.url?.standardizedFileURL.path
        var files: [URL] = []
        for recent in memory.recents where recent.path != current {
            guard FileManager.default.fileExists(atPath: recent.path) else { continue }
            files.append(URL(fileURLWithPath: recent.path))
            if files.count == SidebarLayout.recentRows { break }
        }
        return files
    }

    /// A header for each section with something to show (docs/navigation-spec.md, The sidebar).
    func sidebarTitles(pinned: [URL], recent: [URL]) -> [SidebarSectionKind: String] {
        var titles: [SidebarSectionKind: String] = [.outline: SidebarSectionKind.outline.title]
        if !pinned.isEmpty { titles[.pinned] = SidebarSectionKind.pinned.title }
        if !recent.isEmpty { titles[.recent] = SidebarSectionKind.recent.title }
        if let tree { titles[.files] = tree.name }
        return titles
    }

    // MARK: Restoring

    /// Reads this window's folder, sidebar, preview mode and hide-interface state, then opens the folder.
    public func restore() async {
        let store = context.store
        if let saved = await store.load(Self.sidebarName(id), as: SidebarState.Saved.self) {
            sidebar.apply(saved)
        } else if let oldMode = await store.load(Self.sidebarName(id), as: String.self) {
            sidebar.apply(oldMode: oldMode)
        }
        if let saved = await store.load(Self.previewModeName(id), as: PreviewMode.self) { previewMode = saved }
        if let saved = await store.load(Self.markdownSourceName(id), as: Bool.self) { markdownSource = saved }
        editor.isReadOnly = previewMode == .full
        interfaceHidden = await store.load(Self.hideInterfaceName, as: Bool.self) ?? false
        await sidebar.loadExpansion(from: store)
        if let path = await store.load(Self.projectName(id), as: String.self),
           FileManager.default.fileExists(atPath: path) {
            await setFolder(URL(fileURLWithPath: path, isDirectory: true), prompt: false)
        } else {
            // First launch: the welcome folder, with Welcome.md open (spec 806).
            context.installIntroduction()
            let intro = context.introductionFolder
            guard FileManager.default.fileExists(atPath: intro.path) else { return }
            await setFolder(intro, prompt: false)
            if tabs.items.isEmpty { await openInTab(intro.appendingPathComponent("Welcome.md")) }
        }
        updateMinimumWidth()
    }

    // MARK: Folder

    /// Makes `url` the window's folder (spec 806–810): prompts for unsaved tabs, swaps the tab set and starts the
    /// index and git status.
    public func setFolder(_ url: URL, prompt: Bool = true) async {
        let url = url.standardizedFileURL
        if prompt, url != folder {
            let edited = tabs.items.filter { closeNeedsPrompt($0.document) }
            if !edited.isEmpty {
                switch ask("Project has changes, do you want to save them?", ["Save", "Cancel", "Don't save"]) {
                case 0: for tab in edited { _ = await save(tab.document) }
                case 1: return
                default: for tab in edited { if let path = tab.document.url?.path { try? await context.fileHistory.discard(path: path) } }
                }
            }
        }
        if folder != nil { leaveFolder() }
        folder = url
        window?.title = url.lastPathComponent
        let store = context.store, id = id
        Task { try? await store.save(Self.projectName(id), url.path) }
        context.addRecentFolder(url)

        let index = FolderIndex(root: url)
        let git = GitStatus(folder: url)
        self.index = index
        self.git = git
        preview.projectRoot = git.repositoryRoot ?? url
        tasks.append(Task { [weak self] in
            for await _ in index.changes { await self?.refreshTree() }
        })
        tasks.append(Task { [weak self] in
            for await marks in git.updates {
                self?.gitMarks = marks
                self?.refreshChangedHeadings()
            }
        })
        await index.start()
        await refreshTree()
        Task { await git.refreshStatus() }

        memory = await TabMemory.load(from: store, window: id, folder: url) ?? TabMemory()
        var opened: [TabItem] = []
        for (position, path) in memory.files.enumerated() {
            if let document = await loadDocument(URL(fileURLWithPath: path)) {
                let history = memory.history.indices.contains(position) ? memory.history[position] : TabHistory()
                opened.append(TabItem(document: document, mark: mark(for: document), history: history))
                prepare(document)
            }
        }
        tabs.items = opened
        if let current = memory.current, opened.indices.contains(current) {
            activate(opened[current].id)
        } else if let first = opened.first {
            activate(first.id)
        }
    }

    /// Saves and closes everything belonging to the old folder.
    private func leaveFolder() {
        flushAll()
        saveMemory()
        for task in tasks { task.cancel() }
        tasks = []
        for tab in tabs.items { forget(tab.document) }
        tabs.items = []
        tabs.currentID = nil
        detachCurrent()
        backupTabs = [:]
        index = nil
        git = nil
        tree = nil
        allFiles = []
        gitMarks = [:]
    }

    private func refreshTree() async {
        guard let index else { return }
        tree = await index.tree
        allFiles = await index.allFiles()
    }

    /// File > Open (spec 764): a file opens in a tab, a folder becomes the window's folder.
    public func showOpenDialog() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let file = currentDocument?.url {
            panel.directoryURL = file.deletingLastPathComponent()
        } else if let folder, !folder.path.hasPrefix(context.userData.path) {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openDropped(url) }
    }

    /// A dropped or picked URL: folders become the window folder (spec 766), files open.
    public func openDropped(_ url: URL) async {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        if isFolder.boolValue { await setFolder(url) } else { open(url, newTab: true) }
    }

    // MARK: Opening

    /// Opens a path from a link, the sidebar or a popup by the rules in spec 757–762. A file that opens in a tab goes
    /// in place, or in a new tab when `newTab` (docs/navigation-spec.md).
    public func open(_ url: URL, newTab: Bool = false) {
        openLink(url.isFileURL ? url.path : url.absoluteString, newTab: newTab)
    }

    func openLink(_ path: String, newTab: Bool = false) {
        switch OpenTarget.decide(path) {
        case .tab(let url, let anchor):
            Task {
                if newTab { await openInTab(url) } else { await openInPlace(url) }
                if let anchor { await scrollToAnchor(anchor, in: url) }
            }
        case .quickLook(let url): showQuickLook(url)
        case .system(let url): NSWorkspace.shared.open(url)
        case .browser(let url): NSWorkspace.shared.open(url)
        case .nothing: break
        }
    }

    /// Waits for the opened tab's parse, then puts its editor at the heading once that editor is installed.
    private func scrollToAnchor(_ anchor: String, in url: URL) async {
        guard let document = openDocument(url), let parser = parsers[ObjectIdentifier(document)] else { return }
        let snapshot = await parser.snapshot(atLeast: parser.version)
        guard let heading = snapshot.headings.first(where: { $0.slug == anchor.lowercased() || $0.slug == anchor }) else { return }
        editor.show(range: NSRange(location: heading.range.location, length: 0), in: document, position: .top)
    }

    /// The open tab's document for a file.
    private func openDocument(_ url: URL) -> Document? {
        tabs.items.first { $0.document.url?.standardizedFileURL == url.standardizedFileURL }?.document
    }

    /// Opens a file in a tab after the current one, or switches to it when already open (spec 831).
    public func openInTab(_ url: URL) async {
        let url = url.standardizedFileURL
        if let existing = tabs.items.first(where: { $0.document.url?.standardizedFileURL == url || $0.document.untitledURL?.standardizedFileURL == url }) {
            activate(existing.id)
            return
        }
        guard let document = await loadDocument(url) else { return }
        insertTab(TabItem(document: document, mark: mark(for: document)))
    }

    /// Shows a file in the current tab by `Placement`'s rules; the file the tab leaves goes on its back list.
    public func openInPlace(_ url: URL) async {
        let url = url.standardizedFileURL
        switch placement(for: url.path) {
        case .stay: return
        case .switchTo(let id): activate(id)
        case .newTab: await openInTab(url)
        case .replace:
            guard let tab = tabs.current, let leaving = Self.path(of: tab.document) else { return }
            guard let document = await loadDocument(url) else { return }
            var history = tab.history
            history.push(leaving)
            show(document, in: tab.id, history: history)
        }
    }

    /// Back and Forward: `steps` entries along the current tab's lists (docs/navigation-spec.md, Back and forward).
    public func goBack(steps: Int = 1) { Task { await step(back: true, steps: steps) } }
    public func goForward(steps: Int = 1) { Task { await step(back: false, steps: steps) } }

    func step(back: Bool, steps: Int) async {
        guard let tab = tabs.current, let current = Self.path(of: tab.document) else { return }
        var history = tab.history
        guard let target = back ? history.goBack(steps, from: current) : history.goForward(steps, from: current) else { return }
        switch placement(for: target) {
        case .stay: return
        case .switchTo(let id): activate(id)
        case .newTab:
            setHistory(of: tab.id) { $0.remove(under: [target]) }
            await openInTab(URL(fileURLWithPath: target))
        case .replace:
            guard let document = await loadDocument(URL(fileURLWithPath: target)) else {
                // A file that no longer loads leaves the list, and the next entry is tried.
                setHistory(of: tab.id) { $0.remove(under: [target]) }
                if tabs.currentID == tab.id { await step(back: back, steps: 1) }
                return
            }
            show(document, in: tab.id, history: history)
        }
    }

    private func placement(for target: String) -> Placement {
        let open = tabs.items.compactMap { tab in Self.path(of: tab.document).map { (id: tab.id, path: $0) } }
        return Placement.decide(target: target, currentID: tabs.currentID, tabs: open) {
            guard let document = currentDocument else { return false }
            autosaves[ObjectIdentifier(document)]?.flushSync()
            return Placement.canLeave(isUntitled: document.isUntitled, isPreferences: document.isPreferencesFile,
                                      isBackup: document.isBackupTab, isEdited: document.isEdited)
        }
    }

    /// Puts a loaded document in a tab in place of its file. When the tab stopped being current while the file
    /// loaded, or the file opened in another tab meanwhile, it goes to a tab of its own instead.
    private func show(_ document: Document, in tabID: TabItem.ID, history: TabHistory) {
        if let url = document.url, let existing = openDocument(url) {
            document.stopWatching()
            if let id = tabs.items.first(where: { $0.document === existing })?.id { activate(id) }
            return
        }
        guard tabs.currentID == tabID, let position = tabs.items.firstIndex(where: { $0.id == tabID }) else {
            insertTab(TabItem(document: document, mark: mark(for: document)))
            return
        }
        let old = tabs.items[position].document
        leave(old)
        forget(old)
        detachCurrent()
        tabs.items[position].document = document
        tabs.items[position].mark = mark(for: document)
        tabs.items[position].history = history
        prepare(document)
        activate(tabID)
    }

    private func setHistory(of tabID: TabItem.ID, _ change: (inout TabHistory) -> Void) {
        guard let position = tabs.items.firstIndex(where: { $0.id == tabID }) else { return }
        change(&tabs.items[position].history)
        saveMemory()
    }

    /// The standardized path a tab's history and placement compare.
    static func path(of document: Document) -> String? {
        (document.url ?? document.untitledURL)?.standardizedFileURL.path
    }

    private func insertTab(_ item: TabItem) {
        let position = tabs.items.firstIndex { $0.id == tabs.currentID }.map { $0 + 1 } ?? tabs.items.count
        tabs.items.insert(item, at: position)
        prepare(item.document)
        activate(item.id)
    }

    /// Reads a file, restoring unsaved text and, within six hours, scroll and selection (spec 855–856).
    private func loadDocument(_ url: URL) async -> Document? {
        let history = context.fileHistory
        let document: Document
        do {
            if url.path.hasPrefix(context.untitledFolder.standardizedFileURL.path) {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                document = Document(text: text, untitledURL: url)
            } else {
                document = try await Document.open(url: url)
            }
        } catch DocumentError.readProtected(let file) {
            post("This file is read-protected: \(file.lastPathComponent)", isError: true)
            return nil
        } catch {
            return nil
        }
        let path = url.path
        if let unsaved = await history.unsavedText(for: path), unsaved != document.text {
            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: unsaved)
        }
        if let state = await history.restorableState(for: path) {
            document.scrollOffset = CGFloat(state.scrollOffset)
            document.selectedRanges = state.selection.map { NSRange(location: $0.location, length: $0.length) }
        }
        if url.standardizedFileURL == context.preferencesFile.standardizedFileURL
            || url.standardizedFileURL == context.shortcutsFile.standardizedFileURL {
            document.isPreferencesFile = true
        }
        if document.url != nil { document.startWatching() }
        return document
    }

    /// Autosave for a newly opened document.
    private func prepare(_ document: Document) {
        let autosave = AutosaveController(document: document, enabled: context.preferences.bool("file.autosave"))
        // A history entry written mid-edit would otherwise keep saying "unsaved" for text autosave has written.
        autosave.onSaved = { [weak self, weak document] in self?.recordHistory(document) }
        autosaves[ObjectIdentifier(document)] = autosave
    }

    private func forget(_ document: Document) {
        autosaves[ObjectIdentifier(document)]?.flushSync()
        autosaves[ObjectIdentifier(document)] = nil
        parsers[ObjectIdentifier(document)] = nil
        document.stopWatching()
    }

    /// The tab's edited dot: hidden while autosave is on for a normal file (spec 871).
    func showsEditedMark(_ tab: TabItem) -> Bool {
        autosaves[ObjectIdentifier(tab.document)]?.showsEditedMark ?? tab.document.isEdited
    }

    private func mark(for document: Document) -> TabMark {
        guard let url = document.url, let folder else { return .none }
        return url.standardizedFileURL.path.hasPrefix(folder.path + "/") ? .none : .outsideFolder
    }

    // MARK: Switching tabs

    /// Makes a tab current: saves the one being left, attaches the new one's parser and remembers it.
    public func activate(_ tabID: TabItem.ID) {
        guard tabs.items.contains(where: { $0.id == tabID }) else { return }
        if tabs.currentID == tabID, markdown != nil { return }
        if let old = currentDocument, tabs.currentID != tabID { leave(old) }
        tabs.currentID = tabID
        attachCurrent()
        guard let document = currentDocument else { return }
        requestBackup(document)
        if let url = document.url, !document.isBackupTab {
            memory.recents = TabMemory.addingRecent(url.path, to: memory.recents, now: Date())
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        saveMemory()
        if window?.isKeyWindow == true { Task { await checkDisk(document) } }
    }

    /// What leaving a file in a tab saves: autosave's pending text, its scroll and selection, a backup.
    private func leave(_ document: Document) {
        autosaves[ObjectIdentifier(document)]?.flushSync()
        recordHistory(document)
        requestBackup(document)
    }

    /// The editor forwards edits to the tab's `MarkdownDocument` only while it is attached; an editor attaching to a
    /// parser whose text differs from the tab's (a background edit) sends the whole text once.
    private func attachCurrent() {
        detachCurrent()
        guard let document = currentDocument, !document.isBackupTab else { return }
        let parser = parsers[ObjectIdentifier(document)] ?? MarkdownDocument(text: document.text)
        parsers[ObjectIdentifier(document)] = parser
        markdown = parser
        let stream = parser.snapshots
        snapshotTask = Task { [weak self] in
            let first = await parser.currentSnapshot()
            self?.snapshot = first
            for await next in stream { self?.snapshot = next }
        }
        if previewMode != .none { showPreview() }
    }

    private func detachCurrent() {
        snapshotTask?.cancel()
        snapshotTask = nil
        markdown = nil
        snapshot = nil
        preview.stop()
    }

    public func selectTab(number: Int) {
        guard tabs.items.indices.contains(number - 1) else { return }
        activate(tabs.items[number - 1].id)
    }

    /// Next and previous tab wrap around (spec 837).
    public func cycleTab(by step: Int) {
        guard !tabs.items.isEmpty else { return }
        let index = tabs.items.firstIndex { $0.id == tabs.currentID } ?? 0
        activate(tabs.items[(index + step + tabs.items.count) % tabs.items.count].id)
    }

    public func moveTab(_ tabID: TabItem.ID, to target: Int) {
        guard let from = tabs.items.firstIndex(where: { $0.id == tabID }) else { return }
        let item = tabs.items.remove(at: from)
        tabs.items.insert(item, at: min(max(target, 0), tabs.items.count))
        saveMemory()
    }

    func moveCurrentTab(by step: Int) {
        guard let id = tabs.currentID, let index = tabs.items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + step
        if tabs.items.indices.contains(target) { moveTab(id, to: target) }
    }

    // MARK: Closing tabs

    func closeNeedsPrompt(_ document: Document) -> Bool {
        ClosePrompt.isNeeded(isEdited: document.isEdited, autosave: context.preferences.bool("file.autosave"),
                             isUntitled: document.isUntitled, isPreferences: document.isPreferencesFile, isBackup: document.isBackupTab)
    }

    /// Closes a tab; false when the user cancelled the save prompt (spec 747).
    @discardableResult
    public func closeTab(_ tabID: TabItem.ID) -> Bool {
        guard let position = tabs.items.firstIndex(where: { $0.id == tabID }) else { return true }
        let document = tabs.items[position].document
        if closeNeedsPrompt(document) {
            switch ask("\"\(document.displayName)\" has changes, do you want to save them?", ["Save", "Cancel", "Don't save"]) {
            case 0:
                if document.isUntitled {
                    guard saveAsSync(document) else { return false }
                } else if (try? document.saveSync()) == nil {
                    return false
                }
            case 1: return false
            default:
                if let path = (document.url ?? document.untitledURL)?.path {
                    let history = context.fileHistory
                    Task { try? await history.discard(path: path) }
                }
            }
        } else {
            autosaves[ObjectIdentifier(document)]?.flushSync()
            recordHistory(document)
            requestBackup(document)
        }
        forget(document)
        if let path = document.url?.path, !document.isBackupTab {
            memory.closed = Array(([path] + memory.closed.filter { $0 != path }).prefix(TabMemory.closedLimit))
        }
        backupTabs[tabID] = nil
        let wasCurrent = tabs.currentID == tabID
        tabs.items.remove(at: position)
        if wasCurrent {
            tabs.currentID = nil
            detachCurrent()
            if !tabs.items.isEmpty { activate(tabs.items[max(position - 1, 0)].id) }
        }
        saveMemory()
        return true
    }

    public func closeOtherTabs(_ keep: TabItem.ID) {
        for tab in tabs.items where tab.id != keep { guard closeTab(tab.id) else { return } }
    }

    public func closeAllTabs() {
        for tab in tabs.items { guard closeTab(tab.id) else { return } }
    }

    public func reopenClosedTab() {
        guard let path = memory.closed.first else { return }
        memory.closed.removeFirst()
        Task { await openInTab(URL(fileURLWithPath: path)) }
    }

    /// The window close button closes the current tab first (spec 743).
    func closeCurrentTabForWindowClose() -> Bool {
        guard let current = tabs.currentID else { return true }
        return closeTab(current)
    }

    // MARK: New, save, save as

    public func newFile() {
        guard let document = try? Document.untitled(in: context.untitledFolder) else { return }
        insertTab(TabItem(document: document))
    }

    /// Save (spec 839): untitled runs Save As; the settings files are applied after saving.
    public func saveCurrent() {
        guard let document = currentDocument else { return }
        if document.isUntitled {
            _ = saveAsSync(document)
            return
        }
        Task { _ = await save(document) }
    }

    /// Saves, offering to fix permissions when the file or folder is protected (spec 842).
    @discardableResult
    func save(_ document: Document) async -> Bool {
        guard !document.isBackupTab else { return false }
        do {
            try await document.save()
        } catch let error as DocumentError {
            guard let message = Self.protectionMessage(error),
                  ask(message, ["Overwrite", "Cancel"]) == 0 else { return false }
            do {
                try document.makeWritable()
                try await document.save()
            } catch {
                post("Could not save \(document.displayName).", isError: true)
                return false
            }
        } catch {
            post("Could not save \(document.displayName).", isError: true)
            return false
        }
        afterSave(document)
        return true
    }

    static func protectionMessage(_ error: DocumentError) -> String? {
        switch error {
        case .writeProtected: "This file is write-protected."
        case .readProtected: "This file is read-protected."
        case .folderProtected: "This folder is write-protected."
        case .untitled: nil
        }
    }

    private func afterSave(_ document: Document) {
        recordHistory(document)
        if let git { Task { await git.refreshStatus() } }
        guard document.isPreferencesFile, let url = document.url else { return }
        let applied = url.standardizedFileURL == context.shortcutsFile.standardizedFileURL
            ? context.applyShortcutsFile(document.text) : context.applyPreferencesFile(document.text)
        if !applied { post("Could not read the settings in this file. Nothing was changed.", isError: true) }
    }

    /// Save As (spec 840). Returns false when cancelled or failed.
    @discardableResult
    func saveAsSync(_ document: Document) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save as..."
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = document.isUntitled ? formatter.string(from: Date()) : (document.url?.lastPathComponent ?? "")
        panel.directoryURL = lastSaveAsFolder ?? folder ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        if url.pathExtension.isEmpty { url.appendPathExtension("md") }
        lastSaveAsFolder = url.deletingLastPathComponent()
        let target = url
        Task {
            do {
                try await document.saveAs(url: target)
                afterSave(document)
                if let index = tabs.items.firstIndex(where: { $0.document === document }) {
                    tabs.items[index].mark = mark(for: document)
                }
                saveMemory()
            } catch {
                post("Could not save \(target.lastPathComponent).", isError: true)
            }
        }
        return true
    }

    // MARK: Disk changes

    /// Re-reads the current file when the window regains focus (spec 841).
    func checkDisk(_ document: Document) async {
        guard let url = document.url,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              date != document.lastDiskModificationDate, date != document.ignoredModificationDate else { return }
        if document.isEdited {
            if ask("\(document.displayName) has changed, do you want to reload it?", ["Cancel", "Reload"]) == 0 {
                document.ignoredModificationDate = date
                return
            }
        }
        try? await document.reload()
    }

    // MARK: Settings files

    /// Preferences… and Keyboard Shortcuts… (spec 1037, 1076): opens the file with its block regenerated, or closes
    /// it when it is the current tab.
    public func toggleSettingsFile(_ url: URL, text: String) {
        if let current = tabs.current, current.document.url?.standardizedFileURL == url.standardizedFileURL {
            closeTab(current.id)
            return
        }
        if !replaceText(of: url, with: text) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        Task { await openInTab(url) }
    }

    /// Puts new text in an open tab of `url` and saves it. False when no tab shows that file.
    func replaceText(of url: URL, with text: String) -> Bool {
        guard let tab = tabs.items.first(where: { $0.document.url?.standardizedFileURL == url.standardizedFileURL }) else { return false }
        let storage = tab.document.textStorage
        if storage.string != text { storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text) }
        try? tab.document.saveSync()
        return true
    }

    /// Every window hears preference changes; the editor configuration is computed from them.
    func preferencesChanged() {
        let preferences = context.preferences
        spellcheck.enabled = preferences.bool("spellcheck")
        spellcheck.autocorrect = preferences.bool("autoCorrectSpelling")
        for controller in autosaves.values { controller.enabled = preferences.bool("file.autosave") }
    }

    /// View > Font Size (spec 675–684): both sizes up or down by 1, or both back to their defaults.
    func changeFontSize(by step: Double?) {
        let preferences = context.preferences
        for name in ["fontSize", "codeFontSize"] {
            if let step { preferences.set(name, .number(preferences.number(name) + step)) } else { preferences.reset(name) }
        }
        context.preferencesChanged(rewriteFile: true)
    }

    private func toggle(_ name: String) {
        context.setPreference(name, .bool(!context.preferences.bool(name)))
    }

    // MARK: Commands

    /// `editor:` commands: the spelling toggles are app-wide preferences; the rest go to the editor.
    func performEditorCommand(_ id: String) {
        switch id {
        case "editor:toggle-spellcheck": toggle("spellcheck")
        case "editor:toggle-autocorrect": toggle("autoCorrectSpelling")
        default:
            guard currentDocument != nil else { return }
            editor.focus()
            editor.perform(commandID: id)
        }
    }

    /// Window commands from the menu, the key monitor and the Commands popup.
    public func perform(_ id: String) {
        switch id {
        case "window:new-file": newFile()
        case "window:open": showOpenDialog()
        case "window:recent-folders": openPopup(.recentFolders)
        case "file:save": saveCurrent()
        case "file:save-as": if let document = currentDocument { _ = saveAsSync(document) }
        case "window:toggle-autosave": toggle("file.autosave")
        case "window:backups": openBackups()
        case "window:export-to-pdf": exportPDF()
        case "window:export-to-html": exportHTML()
        case "window:close-tab": if let current = tabs.currentID { closeTab(current) }
        case "window:close-other-tabs": if let current = tabs.currentID { closeOtherTabs(current) }
        case "window:close-all-tabs": closeAllTabs()
        case "window:reopen-closed-tab": reopenClosedTab()
        case "window:find-in-files": openFindInFolder()
        case "window:files": openPopup(.files)
        case "window:titles": openPopup(.headings)
        case "window:commands": openPopup(.commands)
        case "window:next-tab": cycleTab(by: 1)
        case "window:previous-tab": cycleTab(by: -1)
        case "window:go-back": goBack()
        case "window:go-forward": goForward()
        case "window:sidebar": showSection(.files)
        case "window:headings-bar": showSection(.outline)
        case "window:toggle-sidebar":
            interfaceHidden = false
            sidebar.visible.toggle()
            sidebarChanged()
        case "window:toggle-live-preview": setPreviewMode(previewMode == .split ? .none : .split)
        case "window:toggle-preview": setPreviewMode(previewMode == .full ? .none : .full)
        case "window:typewriter-mode": toggle("typewriter")
        case "window:toggle-markdown-source":
            markdownSource.toggle()
            let store = context.store, window = self.id, value = markdownSource
            Task { try? await store.save(Self.markdownSourceName(window), value) }
        case "window:toggle-text-stats":
            if interfaceHidden { setInterfaceHidden(false) }
            toggle("text-stats.visible")
        case "window:font-size-increase": changeFontSize(by: 1)
        case "window:font-size-decrease": changeFontSize(by: -1)
        case "window:font-size-default": changeFontSize(by: nil)
        case "window:hide-interface": setInterfaceHidden(!interfaceHidden)
        case "window:move-tab-left": moveCurrentTab(by: -1)
        case "window:move-tab-right": moveCurrentTab(by: 1)
        case "window:show-in-finder": if let url = currentDocument?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "window:revert-to-backup": if let current = tabs.currentID { revertToBackup(current) }
        default: break
        }
    }

    /// Check marks for window-level commands.
    func isOn(_ id: String) -> Bool {
        switch id {
        case "window:toggle-sidebar": sidebarVisible
        case "window:toggle-live-preview": previewMode == .split
        case "window:toggle-preview": previewMode == .full
        case "window:toggle-markdown-source": markdownSource
        default: false
        }
    }

    /// Show Files / Show Outline (spec 897, 921): shows the sidebar with the section unfolded and focused; pressed
    /// again while the section shows and the editor does not have focus, hides the sidebar.
    private func showSection(_ kind: SidebarSectionKind) {
        if previewMode == .full { setPreviewMode(.none) }
        let editorFocused = window?.firstResponder is EditorTextView
        let section = context.sidebarSections[kind]
        if interfaceHidden {
            setInterfaceHidden(false)
            sidebar.visible = true
        } else if sidebar.visible, !section.hidden, !section.folded, !editorFocused {
            sidebar.visible = false
            editor.focus()
        } else {
            sidebar.visible = true
        }
        if sidebar.visible {
            context.sidebarSections.reveal(kind)
            saveSections()
            if kind == .files {
                if let url = currentDocument?.url { expandFolders(to: url) }
                sidebar.filesFocusRequested = true
            } else {
                sidebar.outlineFocusRequested = true
            }
        }
        sidebarChanged()
    }

    private func sidebarChanged() {
        let store = context.store, id = id, saved = sidebar.saved
        Task { try? await store.save(Self.sidebarName(id), saved) }
        updateMinimumWidth()
        refreshChangedHeadings()
    }

    private func saveSections() {
        let sections = context.sidebarSections, store = context.store
        Task { try? await sections.save(to: store) }
    }

    private func savePins() {
        let pins = context.pins, store = context.store
        Task { try? await pins.save(to: store) }
    }

    /// Pin from a file's menu in Files or Recent, or Pin in Sidebar on a tab.
    func pin(_ url: URL) {
        guard let folder else { return }
        context.pins.pin(url, in: folder)
        savePins()
    }

    /// The header row's clicks, menu and drags, and the right edge's drag (docs/navigation-spec.md, The sidebar).
    var sidebarSectionActions: SidebarActions {
        SidebarActions(
            toggleFold: { [weak self] kind in
                self?.context.sidebarSections.toggleFold(kind)
                self?.saveSections()
                self?.refreshChangedHeadings()
            },
            setHidden: { [weak self] kind, hidden in
                self?.context.sidebarSections.setHidden(kind, hidden)
                self?.saveSections()
                self?.refreshChangedHeadings()
            },
            move: { [weak self] kind, target in
                self?.context.sidebarSections.move(kind, before: target)
                self?.saveSections()
            },
            resize: { [weak self] proposed in
                guard let self else { return }
                if let width = SidebarState.draggedWidth(proposed) {
                    sidebar.width = width
                } else {
                    sidebar.visible = false
                    sidebarChanged()
                }
            },
            resizeEnded: { [weak self] in self?.sidebarChanged() },
            resetWidth: { [weak self] in
                self?.sidebar.width = Tokens.sidebarWidth
                self?.sidebarChanged()
            })
    }

    /// The Pinned and Recent rows.
    var fileListActions: FileListActions {
        FileListActions(
            open: { [weak self] url, newTab in self?.open(url, newTab: newTab) },
            pin: { [weak self] url in self?.pin(url) },
            unpin: { [weak self] url in
                guard let self, let folder else { return }
                context.pins.unpin(url, in: folder)
                savePins()
            },
            movePin: { [weak self] url, index in
                guard let self, let folder else { return }
                context.pins.move(url, to: index, in: folder)
                savePins()
            },
            revealInFinder: { FileOperations.revealInFinder($0) })
    }

    /// Headings whose section has a git line mark (spec 923); worked out only while the Outline section shows.
    private func refreshChangedHeadings() {
        changedHeadingsTask?.cancel()
        guard outlineShowing, let git, let url = currentDocument?.url, let snapshot else {
            changedHeadings = []
            return
        }
        changedHeadingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let committed = await git.committedText(of: url) else { return }
            let changed = await Task.detached {
                Self.changedHeadings(snapshot.headings, text: snapshot.text, marks: marks(for: snapshot.text, committed: committed))
            }.value
            guard !Task.isCancelled else { return }
            self?.changedHeadings = changed
        }
    }

    /// A heading's section runs from its line to the next heading's line; it is changed when a line in it has a mark.
    nonisolated static func changedHeadings(_ headings: [Heading], text: String, marks: [LineMark]) -> Set<BlockID> {
        guard !marks.isEmpty, !headings.isEmpty else { return [] }
        let string = text as NSString
        var lineStarts = [0]
        var location = 0
        while true {
            let found = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound else { break }
            location = NSMaxRange(found)
            lineStarts.append(location)
        }
        func line(at offset: Int) -> Int {
            var low = 0, high = lineStarts.count
            while low < high {
                let mid = (low + high) / 2
                if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
            }
            return low - 1
        }
        let marked = Set(marks.map(\.line))
        var result: Set<BlockID> = []
        for (index, heading) in headings.enumerated() {
            let first = line(at: heading.range.location)
            let end = index + 1 < headings.count ? line(at: headings[index + 1].range.location) : lineStarts.count
            if marked.contains(where: { $0 >= first && $0 < end }) { result.insert(heading.blockID) }
        }
        return result
    }

    /// Hide Interface (spec 1023–1032): hides the tab bar, stats and sidebars; survives restart.
    func setInterfaceHidden(_ hidden: Bool) {
        interfaceHidden = hidden
        let store = context.store
        Task { try? await store.save(Self.hideInterfaceName, hidden) }
        updateMinimumWidth()
    }

    func updateMinimumWidth() {
        minimumWidthChanged(Self.minimumWidth(sidebarWidth: sidebarVisible ? sidebar.width : nil, previewVisible: previewMode != .none))
    }

    // MARK: Preview

    /// Split and full preview exclude each other; the mode is saved per window (spec 535).
    public func setPreviewMode(_ mode: PreviewMode) {
        let old = previewMode
        previewMode = mode
        editor.isReadOnly = mode == .full
        if mode == .none {
            preview.stop()
            editor.focus()
        } else if old == .none {
            showPreview()
        }
        if mode == .split { scrollSync.reset() }
        if mode == .full, let block = editor.firstVisibleBlockID { preview.scrollToBlock(block, fraction: Double(editor.offsetWithinBlock)) }
        let store = context.store, id = id
        Task { try? await store.save(Self.previewModeName(id), mode) }
        updateMinimumWidth()
    }

    private func showPreview() {
        guard let markdown else { return }
        let url = currentDocument?.url
        Task { await preview.show(document: markdown, fileURL: url) }
    }

    /// Called when the editor scrolls; the split preview follows 100 ms later (spec 527).
    func editorScrolled() {
        guard previewMode == .split, let document = currentDocument else { return }
        let visible = editor.visibleCharacterRange
        scrollSync.editorDidScroll(firstVisibleBlockID: editor.firstVisibleBlockID, fraction: Double(editor.offsetWithinBlock),
                                   atTop: visible.location == 0, atBottom: NSMaxRange(visible) >= document.textStorage.length)
    }

    /// A task checkbox clicked in the preview edits the document, so the editor and undo see it (spec 507).
    func applyPreviewEdit(_ edit: TextEdit) {
        guard currentDocument != nil else { return }
        editor.replace(range: edit.range, with: edit.replacement)
    }

    private func exportPDF() {
        guard let document = currentDocument, let markdown else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.displayName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let showing = previewMode != .none
        Task {
            if !showing { await preview.show(document: markdown, fileURL: document.url) }
            do { try await preview.exportPDF(to: url) } catch { post("Could not export \(url.lastPathComponent).", isError: true) }
            if !showing { preview.stop() }
        }
    }

    private func exportHTML() {
        guard let document = currentDocument, let markdown else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = document.displayName + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let showing = previewMode != .none
        let themeCSS = context.themeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        Task {
            if !showing { await preview.show(document: markdown, fileURL: document.url) }
            let snapshot = await markdown.currentSnapshot()
            let html = await preview.exportHTML(snapshot: snapshot, themeCSS: themeCSS, title: document.displayName)
            if !showing { preview.stop() }
            do { try html.write(to: url, atomically: true, encoding: .utf8) } catch { post("Could not export \(url.lastPathComponent).", isError: true) }
        }
    }

    // MARK: Popups

    public func openPopup(_ kind: PopupKind) {
        if previewMode == .full, kind != .commands { setPreviewMode(.none) }
        popup.open(kind)
    }

    /// Popups close on Esc, a pick or focus loss, and the editor gets focus back (spec 937).
    public func closePopup() {
        let wasOpen = popup.active != nil
        popup.close()
        searchTask?.cancel()
        searchHits = []
        if wasOpen { editor.focus() }
    }

    public func openTabSwitcher() {
        if popup.active == .tabSwitcher { return moveTabSwitcher(by: 1) }
        popup.open(.tabSwitcher)
        popup.selection = TabSwitcherPopup.initialSelection(tabs: tabsByRecentUse, currentID: tabs.currentID)
    }

    func moveTabSwitcher(by step: Int) {
        let count = tabsByRecentUse.count
        guard count > 0 else { return }
        popup.selection = (popup.selection + step + count) % count
    }

    /// Find in Folder (spec 984): a one-line selection becomes the search and runs at once.
    func openFindInFolder() {
        var query = ""
        if let document = currentDocument, let range = editor.selectedRanges.first, range.length > 0, NSMaxRange(range) <= document.textStorage.length {
            let selected = (document.text as NSString).substring(with: range)
            if !selected.contains("\n") { query = selected }
        }
        openPopup(.findInFolder)
        popup.filter = query
        runSearch(query)
    }

    /// A new search stops the previous one (spec 985).
    public func runSearch(_ query: String) {
        searchTask?.cancel()
        searchHits = []
        guard let index, !query.isEmpty else { return }
        searchTask = Task { [weak self] in
            for await batch in search(query, in: index) {
                guard !Task.isCancelled else { return }
                self?.searchHits += batch
            }
        }
    }

    /// Opens a hit in its tab, selected and centred (spec 989).
    public func openHit(_ hit: SearchHit, newTab: Bool = false) {
        closePopup()
        Task {
            if newTab { await openInTab(hit.url) } else { await openInPlace(hit.url) }
            guard let document = openDocument(hit.url) else { return }
            editor.show(range: hit.range, in: document, position: .center)
        }
    }

    public func jump(to heading: Heading, focus: Bool) {
        editor.select(range: NSRange(location: heading.range.location, length: 0))
        editor.scrollTo(offset: heading.range.location, position: .top)
        if focus { editor.focus() }
    }

    // MARK: Backups

    private func openBackups() {
        guard let path = currentDocument?.url?.path else { return }
        let backups = context.backups
        Task {
            backupsList = (try? await backups.list(for: path)) ?? []
            openPopup(.backups)
        }
    }

    /// A backup opens read-only as a tab showing the merged diff (spec 886).
    public func openBackup(_ backup: BackupInfo) {
        closePopup()
        guard let original = currentDocument, let url = original.url,
              let text = try? String(contentsOf: backup.url, encoding: .utf8) else { return }
        let lines = BackupDiff.lines(old: text, new: original.text)
        let document = Document(text: text, url: backup.url)
        document.isBackupTab = true
        let item = TabItem(document: document, title: "\(url.lastPathComponent) | \(backup.friendlyDate)")
        backupTabs[item.id] = BackupTab(original: url, backup: backup, lines: lines)
        insertTab(item)
    }

    /// Revert to This (spec 887): the backup's text replaces the original, which opens; the backup tab closes.
    public func revertToBackup(_ tabID: TabItem.ID) {
        guard let info = backupTabs[tabID] else { return }
        let backups = context.backups
        Task {
            guard let text = try? await backups.revert(to: info.backup) else { return }
            await openInTab(info.original)
            if let document = tabs.items.first(where: { $0.document.url?.standardizedFileURL == info.original.standardizedFileURL })?.document {
                try? await document.revert(to: text)
            }
            closeTab(tabID)
        }
    }

    private func requestBackup(_ document: Document?) {
        guard let document, let path = document.url?.path, !document.isBackupTab, !document.isPreferencesFile else { return }
        let backups = context.backups, text = document.text
        Task { try? await backups.requestBackup(path: path, text: text) }
    }

    /// A typed line break writes an armed backup (spec 883).
    private func lineBreakInserted() {
        guard let document = currentDocument, let path = document.url?.path, !document.isBackupTab, !document.isPreferencesFile else { return }
        let backups = context.backups, text = document.text
        Task { try? await backups.recordLineBreakInserted(path: path, text: text) }
    }

    // MARK: History and focus

    private func recordHistory(_ document: Document?) {
        guard let document else { return }
        let history = context.fileHistory
        Task { try? await history.record(document) }
    }

    private func recordHistoryIfFocused() {
        guard window?.isKeyWindow == true, window?.firstResponder is EditorTextView else { return }
        recordHistory(currentDocument)
    }

    func windowBecameKey() {
        if let quickLook, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            _ = quickLook
            self.quickLook = nil
        }
        if let document = currentDocument { Task { await checkDisk(document) } }
        if let git { Task { await git.refreshStatus() } }
    }

    func windowResignedKey() {
        if let document = currentDocument, let autosave = autosaves[ObjectIdentifier(document)] {
            Task { await autosave.flush() }
        }
        recordHistory(currentDocument)
    }

    /// Closing or quitting: save what autosave would, remember view state and tabs.
    func windowWillHide() {
        flushAll()
        saveMemory()
    }

    private func flushAll() {
        for tab in tabs.items {
            autosaves[ObjectIdentifier(tab.document)]?.flushSync()
            recordHistory(tab.document)
        }
    }

    private func saveMemory() {
        updateMemory()
        let memory = memory, store = context.store, id = id, folder = folder
        Task { try? await TabMemory.save(memory, to: store, window: id, folder: folder) }
    }

    private func updateMemory() {
        let saved = tabs.items.compactMap { tab -> (path: String, history: TabHistory)? in
            tab.document.isBackupTab ? nil : (tab.document.url ?? tab.document.untitledURL).map { ($0.path, tab.history) }
        }
        memory.files = saved.map(\.path)
        memory.history = saved.map(\.history)
        let real = tabs.items.filter { !$0.document.isBackupTab }
        memory.current = real.firstIndex { $0.id == tabs.currentID }
    }

    /// Quitting (spec 746, 852–854): saves what autosave would, then writes every tab's history and unsaved text
    /// and the tab list, returning only when all of it is on disk.
    func saveForQuit() async {
        let history = context.fileHistory
        for tab in tabs.items {
            autosaves[ObjectIdentifier(tab.document)]?.flushSync()
            try? await history.record(tab.document)
        }
        updateMemory()
        try? await TabMemory.save(memory, to: context.store, window: id, folder: folder)
    }

    // MARK: Esc and notifications

    /// Esc (spec 1098, 366): leaves full preview; with the editor focused hides notifications; with nothing focused
    /// focuses the editor. Returns true when the key was used up.
    func escape(editorFocused: Bool) -> Bool {
        if previewMode == .full {
            setPreviewMode(.none)
            return true
        }
        if popup.active != nil { return false }
        if editorFocused {
            notifications = []
            return false
        }
        if window?.firstResponder is NSText || window?.firstResponder is NSTextView { return false }
        editor.focus()
        return true
    }

    public func post(_ message: String, isError: Bool = false, buttons: [(String, @MainActor @Sendable () -> Void)] = []) {
        notifications.append(ShellNotification(message: message, isError: isError, buttons: buttons.map { ShellNotification.Button(label: $0.0, action: $0.1) }))
    }

    public func dismissNotification() {
        if !notifications.isEmpty { notifications.removeLast() }
    }

    // MARK: Quick Look

    private func showQuickLook(_ url: URL) {
        let source = QuickLookSource(url: url)
        quickLook = source
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Files sidebar

    var sidebarActions: FilesSidebarActions {
        FilesSidebarActions(
            open: { [weak self] url, newTab in self?.open(url, newTab: newTab) },
            createFile: { [weak self] folder, name in
                let url = try FileOperations.createFile(in: folder, name: name)
                if OpenableFiles.isOpenable(url) { self?.open(url) }
            },
            createFolder: { folder, name in _ = try FileOperations.createFolder(in: folder, name: name) },
            rename: { [weak self] url, name in
                let renamed = try FileOperations.rename(url, to: name)
                self?.fileMoved(from: url, to: renamed)
            },
            trash: { [weak self] urls in
                try? FileOperations.trash(urls)
                self?.closeTabs(under: urls)
            },
            copy: { [weak self] urls in self?.fileClipboard = (urls, false) },
            cut: { [weak self] urls in self?.fileClipboard = (urls, true) },
            paste: { [weak self] folder in self?.pasteFiles(into: folder) },
            revealInFinder: { FileOperations.revealInFinder($0) },
            focusEditor: { [weak self] in self?.editor.focus() },
            pin: { [weak self] url in self?.pin(url) })
    }

    /// Renamed files keep their tab, unsaved text and backups; the tab is updated, not reloaded (spec 843, 885).
    private func fileMoved(from old: URL, to new: URL) {
        let backups = context.backups
        Task { try? await backups.rename(from: old.path, to: new.path) }
        for position in tabs.items.indices {
            tabs.items[position].history.rename(from: old.standardizedFileURL.path, to: new.standardizedFileURL.path)
        }
        context.pins.rename(from: old.standardizedFileURL.path, to: new.standardizedFileURL.path)
        savePins()
        saveMemory()
        guard let position = tabs.items.firstIndex(where: { $0.document.url?.standardizedFileURL == old.standardizedFileURL }) else { return }
        let document = tabs.items[position].document
        document.moved(to: new)
        recordHistory(document)
        let history = context.fileHistory
        Task { try? await history.discard(path: old.path) }
        tabs.items[position].mark = mark(for: document)
        saveMemory()
    }

    /// Trashed or cut files close their tabs without prompting.
    private func closeTabs(under urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        for position in tabs.items.indices { tabs.items[position].history.remove(under: paths) }
        context.pins.remove(under: paths)
        savePins()
        for tab in tabs.items {
            guard let path = tab.document.url?.standardizedFileURL.path,
                  paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            forget(tab.document)
            if let position = tabs.items.firstIndex(where: { $0.id == tab.id }) {
                let wasCurrent = tabs.currentID == tab.id
                tabs.items.remove(at: position)
                if wasCurrent {
                    tabs.currentID = nil
                    detachCurrent()
                    if !tabs.items.isEmpty { activate(tabs.items[max(position - 1, 0)].id) }
                }
            }
        }
        saveMemory()
    }

    /// Paste copies; after a cut the sources go to the Trash (spec 909).
    private func pasteFiles(into folder: URL) {
        guard let clip = fileClipboard else { return }
        _ = try? FileOperations.copy(clip.urls, to: folder)
        if clip.cut {
            try? FileOperations.trash(clip.urls)
            closeTabs(under: clip.urls)
            fileClipboard = nil
        }
    }

    // MARK: Editor wiring

    /// The closures the editor calls (Decision 15; spec 171, 187, 197–212, 232, 292).
    var editorActions: EditorActions {
        var actions = EditorActions()
        let math = richTextMath
        let store = context.store
        actions.htmlRenderer = { markdown in await RichText.html(for: markdown, math: math) }
        actions.htmlToMarkdown = { RichText.htmlToMarkdown($0) }
        actions.pasteFolder = { [weak self] in
            guard let self else { return nil }
            return (self.folder ?? self.currentDocument?.url?.deletingLastPathComponent())?.appendingPathComponent(".pastes", isDirectory: true)
        }
        actions.completePath = { [weak self] typed, documentURL in self?.completePath(typed, documentURL: documentURL) ?? [] }
        actions.recentEmoji = { await EmojiTable.shared.recent(in: store) }
        actions.recordEmoji = { emoji in Task { try? await EmojiTable.shared.recordRecent(emoji, in: store) } }
        actions.folderURL = { [weak self] in self?.folder }
        actions.openPath = { [weak self] url, newTab in self?.open(url, newTab: newTab) }
        actions.showInSidebar = { [weak self] url in self?.showInSidebar(url) }
        actions.createFile = { [weak self] url in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
            self?.open(url)
        }
        actions.searchWeb = { text in
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
        actions.zoom = { [weak self] image in self?.zoomImage = image }
        actions.folderFiles = { [weak self] in self?.allFiles ?? [] }
        actions.openFile = { [weak self] url, offset in
            guard let self else { return }
            Task {
                await self.openInTab(url)
                guard let document = self.openDocument(url) else { return }
                self.editor.show(range: NSRange(location: offset, length: 0), in: document, position: nil)
            }
        }
        return actions
    }

    private func showInSidebar(_ url: URL) {
        interfaceHidden = false
        sidebar.visible = true
        context.sidebarSections.reveal(.files)
        saveSections()
        expandFolders(to: url)
        sidebarChanged()
    }

    /// Expands the folders above a file so the Files sidebar shows it.
    private func expandFolders(to url: URL) {
        var folder = url.deletingLastPathComponent().standardizedFileURL
        while let root = self.folder, folder.path.hasPrefix(root.path + "/") {
            sidebar.expandedFolders.insert(folder)
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Path completion from the folder index for paths inside the folder; the file system elsewhere (spec 187).
    func completePath(_ typed: String, documentURL: URL?) -> [PathCompletion] {
        guard let tree, let root = folder else { return EditorActions.listPath(typed, documentURL: documentURL, root: folder) }
        let decoded = typed.removingPercentEncoding ?? typed
        let partial = decoded.hasSuffix("/") ? "" : (decoded as NSString).lastPathComponent
        let folderPart = decoded.hasSuffix("/") ? decoded : (decoded as NSString).deletingLastPathComponent
        let base: URL?
        if decoded.hasPrefix("~/") {
            base = nil
        } else if decoded.hasPrefix("/") {
            base = root.appendingPathComponent(String(folderPart.dropFirst()), isDirectory: true)
        } else {
            base = documentURL?.deletingLastPathComponent().appendingPathComponent(folderPart, isDirectory: true)
        }
        let target = base?.standardizedFileURL.path
        guard let target, target == root.path || target.hasPrefix(root.path + "/") else {
            return EditorActions.listPath(typed, documentURL: documentURL, root: folder)
        }
        var node: FolderNode? = tree
        for part in target.dropFirst(root.path.count).split(separator: "/") {
            node = node?.children.first { $0.name == String(part) }
        }
        guard let node else { return [] }
        let caseSensitive = partial.contains { $0.isUppercase }
        return node.children.compactMap { child in
            let matches = caseSensitive ? child.name.hasPrefix(partial) : child.name.lowercased().hasPrefix(partial.lowercased())
            return matches ? PathCompletion(name: child.name, isFolder: child.kind == .folder) : nil
        }
    }
}

/// Supplies one file to the Quick Look panel (spec 760).
final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL }
}
