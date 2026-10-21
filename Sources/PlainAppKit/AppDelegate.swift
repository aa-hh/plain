import AppKit
import PlainCore
import PlainDocument
import PreviewRenderer

/// State shared by every window: preferences, shortcuts, history files and the app's folders. The app delegate makes
/// one and passes it to each window; nothing reaches it through a global.
@MainActor
public final class AppContext {
    public let userData: URL
    public let store: StateStore
    /// `state/`, the folder `store` writes to.
    public let stateFolder: URL
    public let preferences: Preferences
    /// The command table with the Keyboard Shortcuts file applied.
    public private(set) var commands: [Command] = Command.all
    public let themes: Themes
    public let fileHistory: FileHistory
    public let backups: Backups
    public var welcomeSource: URL?
    public var licencesFile: URL?
    public var recentFolders: [URL] = []
    public var commandHistory: [String] = []
    public var themeURL: URL?
    public var themeFiles: [ThemeFile] = []
    /// The open window models, for changes every window must hear about.
    var windows: () -> [WindowModel] = { [] }
    var commandsChanged: ([Command]) -> Void = { _ in }

    public static let foldersName = "folders"

    public init(userData: URL = UserData.folder) {
        self.userData = userData
        stateFolder = userData.appendingPathComponent("state", isDirectory: true)
        store = StateStore(folder: stateFolder)
        preferences = Preferences()
        themes = Themes(folder: userData.appendingPathComponent("Themes", isDirectory: true), store: store)
        fileHistory = FileHistory(store: store, unsaved: UnsavedFiles(folder: userData.appendingPathComponent("unsaved-files", isDirectory: true)))
        backups = Backups(folder: userData.appendingPathComponent("file-revisions", isDirectory: true), store: store)
    }

    public var configFolder: URL { userData.appendingPathComponent("config", isDirectory: true) }
    public var untitledFolder: URL { userData.appendingPathComponent("untitled-files", isDirectory: true) }
    public var introductionFolder: URL { userData.appendingPathComponent("Introduction", isDirectory: true) }
    public var preferencesFile: URL { configFolder.appendingPathComponent("Preferences.md") }
    public var shortcutsFile: URL { configFolder.appendingPathComponent("Keyboard Shortcuts.md") }

    /// Reads preferences, shortcuts, recent folders and command history, and writes the built-in themes.
    public func load() async {
        let visible = await store.load(StateName.preferences, as: [String: String].self) ?? [:]
        let silent = await store.load(StateName.silentPreferences, as: [String: String].self) ?? [:]
        for (name, text) in visible.merging(silent, uniquingKeysWith: { a, _ in a }) {
            if let key = PreferenceKey.byName[name], let value = PreferencesFile.value(text, like: key.defaultValue) {
                preferences.set(name, value)
            }
        }
        let stored = await store.load(StateName.keyboardShortcuts, as: [String: [String]].self) ?? [:]
        commands = Shortcuts.overriding(Shortcuts.decode(stored), in: Command.all)
        recentFolders = (await store.load(Self.foldersName, as: [String].self) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        commandHistory = await store.load(CommandDispatcher.historyName, as: [String].self) ?? []
        try? themes.writeBuiltIns()
        themeFiles = themes.list()
        themeURL = await themes.startupTheme()
    }

    // MARK: Preferences

    /// Sets a preference, saves it, rewrites an existing Preferences file and tells every window.
    public func setPreference(_ name: String, _ value: PreferenceValue) {
        preferences.set(name, value)
        preferencesChanged(rewriteFile: !(PreferenceKey.byName[name]?.silent ?? true))
    }

    func preferencesChanged(rewriteFile: Bool) {
        savePreferences()
        if rewriteFile { rewritePreferencesFile() }
        for window in windows() { window.preferencesChanged() }
    }

    func savePreferences() {
        var visible: [String: String] = [:]
        var silent: [String: String] = [:]
        for key in PreferenceKey.all {
            let text = PreferencesFile.text(preferences[key.name] ?? key.defaultValue)
            if key.silent { silent[key.name] = text } else { visible[key.name] = text }
        }
        let store = store
        Task {
            try? await store.save(StateName.preferences, visible)
            try? await store.save(StateName.silentPreferences, silent)
        }
    }

    public func preferencesMarkdown() -> String {
        SettingsFiles.preferencesMarkdown(yamlBody: preferences.yamlBody())
    }

    /// Regenerates the YAML block (spec 1039): in the open tab if a window has the file open, else on disk if it exists.
    func rewritePreferencesFile() {
        let text = preferencesMarkdown()
        for window in windows() where window.replaceText(of: preferencesFile, with: text) { return }
        if FileManager.default.fileExists(atPath: preferencesFile.path) {
            try? text.write(to: preferencesFile, atomically: true, encoding: .utf8)
        }
    }

    /// Applies a saved Preferences file. False (and nothing changed) when its YAML does not parse.
    @discardableResult
    public func applyPreferencesFile(_ markdown: String) -> Bool {
        guard PreferencesFile.apply(markdown, to: preferences) else { return false }
        preferencesChanged(rewriteFile: false)
        return true
    }

    // MARK: Shortcuts

    public func shortcutsMarkdown() -> String { Shortcuts.markdown(commands: commands) }

    /// Applies a saved Keyboard Shortcuts file to the menu, the key monitor and the editor. False when it does not parse.
    @discardableResult
    public func applyShortcutsFile(_ markdown: String) -> Bool {
        guard let parsed = try? Shortcuts.parse(markdown) else { return false }
        setCommands(Shortcuts.apply(parsed, to: commands))
        return true
    }

    func setCommands(_ newCommands: [Command]) {
        commands = newCommands
        let overrides = Shortcuts.overrides(newCommands)
        let store = store
        Task { try? await store.save(StateName.keyboardShortcuts, overrides) }
        commandsChanged(newCommands)
    }

    // MARK: Recent folders

    public func addRecentFolder(_ url: URL) {
        recentFolders = RecentFolders.adding(url, to: recentFolders)
        let paths = recentFolders.map(\.path)
        let store = store
        Task { try? await store.save(Self.foldersName, paths) }
    }

    /// Copies the bundled welcome folder into user data the first time (spec 806). True when it copied.
    @discardableResult
    public func installIntroduction() -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: introductionFolder.path), let welcomeSource else { return false }
        try? manager.createDirectory(at: userData, withIntermediateDirectories: true)
        return (try? manager.copyItem(at: welcomeSource, to: introductionFolder)) != nil
    }
}

/// The global folder history: newest first, no duplicates (spec 819).
public enum RecentFolders {
    public static func adding(_ url: URL, to list: [URL]) -> [URL] {
        let standard = url.standardizedFileURL
        return [standard] + list.filter { $0.standardizedFileURL.path != standard.path }
    }
}

/// The application delegate: owns the windows, the menu and the key monitor (Decision 15).
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The bundled welcome folder and licence list, set by the executable before launch.
    public var welcomeSource: URL?
    public var licencesFile: URL?

    public private(set) var context: AppContext!
    private(set) var controllers: [Int: WindowController] = [:]
    private var dispatcher: CommandDispatcher!
    private var menuBuilder: MenuBuilder!
    private var keyMonitor: KeyMonitor!
    private var pendingOpen: [URL] = []
    private var ready = false
    /// The last closed window's frame, for sizing a new window when none is focused (spec 724).
    private var lastClosedFrame: NSRect?

    static let appStateName = "app"
    struct AppState: Codable { var focusedWindowID: Int? }

    public override init() { super.init() }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        let context = AppContext()
        context.welcomeSource = welcomeSource
        context.licencesFile = licencesFile
        context.windows = { [weak self] in self?.models ?? [] }
        context.commandsChanged = { [weak self] commands in self?.commandsChanged(commands) }
        self.context = context
        dispatcher = CommandDispatcher(context: context) { [weak self] id, model in self?.runAppCommand(id, model) ?? false }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await context.load()
            NSApp.appearance = NSAppearance(named: context.preferences.bool("nightMode") ? .darkAqua : .aqua)
            installMenuAndKeys()
            await restoreWindows()
            ready = true
            let queued = pendingOpen
            pendingOpen = []
            for url in queued { openFromSystem(url) }
        }
    }

    private func installMenuAndKeys() {
        menuBuilder = MenuBuilder(
            commands: context.commands, themes: context.themeFiles,
            run: { [weak self] id in self?.runFromMenu(id) },
            state: { [weak self] id in self?.isOn(id) ?? false })
        NSApp.mainMenu = menuBuilder.build()
        keyMonitor = KeyMonitor(
            commands: context.commands, modelFor: { [weak self] window in self?.model(for: window) },
            run: { [weak self] id, model in self?.dispatcher.run(id, in: model) })
        keyMonitor.start()
    }

    var models: [WindowModel] { controllers.keys.sorted().compactMap { controllers[$0]?.model } }

    func model(for window: NSWindow?) -> WindowModel? {
        guard let window else { return nil }
        return controllers.values.first { $0.window === window }?.model
    }

    private var keyModel: WindowModel? {
        model(for: NSApp.keyWindow) ?? model(for: NSApp.mainWindow)
    }

    // MARK: Windows

    /// One window per saved `window-bounds-w<N>.json`, else window 1 maximised (spec 720–722).
    private func restoreWindows() async {
        let ids = savedWindowIDs()
        if ids.isEmpty {
            await openWindow(id: 1, frame: nil, zoomed: true)
        } else {
            for id in ids {
                let bounds = await context.store.load(StateName.windowBounds(id), as: WindowBounds.self)
                await openWindow(id: id, frame: bounds.map { $0.frame }, zoomed: bounds?.zoomed ?? true)
            }
        }
        let focused = await context.store.load(Self.appStateName, as: AppState.self)?.focusedWindowID
        (controllers[focused ?? -1] ?? controllers[controllers.keys.min() ?? 1])?.window.makeKeyAndOrderFront(nil)
    }

    private func savedWindowIDs() -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: context.stateFolder.path)) ?? []
        let prefix = "window-bounds-w", suffix = ".json"
        return names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(suffix.count))
        }.sorted()
    }

    @discardableResult
    private func openWindow(id: Int, frame: NSRect?, zoomed: Bool) async -> WindowController {
        let model = WindowModel(id: id, context: context)
        model.runCommand = { [weak self, weak model] id, fromPopup in
            guard let self else { return }
            if fromPopup { self.dispatcher.runFromPopup(id, in: model) } else { self.dispatcher.run(id, in: model) }
        }
        let controller = WindowController(id: id, model: model, context: context, frame: frame, zoomed: zoomed)
        controller.onHide = { [weak self] controller in self?.lastClosedFrame = controller.window.frame }
        controllers[id] = controller
        controller.window.makeKeyAndOrderFront(nil)
        await model.restore()
        return controller
    }

    /// File > New Window: 40 pt right and down from the focused window, with its size (spec 724).
    func newWindow() {
        let id = (controllers.keys.max() ?? 0) + 1
        var frame: NSRect?
        if let key = NSApp.keyWindow, controllers.values.contains(where: { $0.window === key }) {
            frame = key.isZoomed ? key.frame : key.frame.offsetBy(dx: 40, dy: -40)
        } else if let lastClosedFrame {
            frame = lastClosedFrame
        }
        Task { await openWindow(id: id, frame: frame, zoomed: frame == nil) }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let first = controllers[controllers.keys.min() ?? 1] { first.show() }
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Remembers the focused window, then lets every window save and quits once the saves are on disk (spec 746).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let focused = controllers.first { $0.value.window === NSApp.keyWindow }?.key
        if let data = try? JSONEncoder().encode(AppState(focusedWindowID: focused)) {
            try? FileManager.default.createDirectory(at: context.stateFolder, withIntermediateDirectories: true)
            try? data.write(to: context.stateFolder.appendingPathComponent("\(Self.appStateName).json"), options: .atomic)
        }
        let models = models
        Task {
            await Self.saveBeforeQuit(models)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Everything the windows must write before the app exits.
    static func saveBeforeQuit(_ models: [WindowModel]) async {
        for model in models { await model.saveForQuit() }
    }

    // MARK: Opening from the system

    /// Files from Finder or `plain` (spec 719, 763): queued until the first window is ready; folders ignored.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where Self.isRegularFile(url) {
            if ready { openFromSystem(url) } else { pendingOpen.append(url) }
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func openFromSystem(_ url: URL) {
        let target = controllers.values.first { $0.window === NSApp.keyWindow } ?? controllers[controllers.keys.min() ?? 1]
        guard let target else { return }
        target.show()
        Task { await target.model.openInTab(url) }
    }

    // MARK: Commands

    private func runFromMenu(_ id: String) {
        dispatcher.run(id, in: keyModel)
    }

    /// App-wide commands. False for ids a window handles.
    private func runAppCommand(_ id: String, _ model: WindowModel?) -> Bool {
        switch id {
        case "file:new-window":
            newWindow()
        case "application:preferences":
            model?.toggleSettingsFile(context.preferencesFile, text: context.preferencesMarkdown())
        case "application:keyboard-shortcuts":
            model?.toggleSettingsFile(context.shortcutsFile, text: context.shortcutsMarkdown())
        case "application:welcome":
            context.installIntroduction()
            if let model { Task { await model.setFolder(context.introductionFolder) } }
        case "application:licences":
            if let model, let file = context.licencesFile { Task { await model.openInTab(file) } }
        case "application:add-custom-theme":
            context.themes.addTheme { message, title, action in
                model?.post(message, buttons: [(title, action)])
            }
        case "window:dark-mode":
            let dark = !context.preferences.bool("nightMode")
            context.setPreference("nightMode", .bool(dark))
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for controller in controllers.values { controller.applyBackground() }
        default:
            guard id.hasPrefix("windows:"), let theme = context.themeFiles.first(where: { $0.commandID == id }) else { return false }
            context.themeURL = theme.url
            for window in models { window.preview.setTheme(theme.url) }
            let themes = context.themes
            Task { try? await themes.select(theme.url) }
        }
        return true
    }

    /// Check marks for the menu (spec 1092).
    private func isOn(_ id: String) -> Bool {
        let preferences = context.preferences
        switch id {
        case "window:toggle-autosave": return preferences.bool("file.autosave")
        case "editor:toggle-spellcheck": return preferences.bool("spellcheck")
        case "editor:toggle-autocorrect": return preferences.bool("autoCorrectSpelling")
        case "window:dark-mode": return preferences.bool("nightMode")
        case "window:typewriter-mode": return preferences.bool("typewriter")
        case "window:toggle-text-stats": return preferences.bool("text-stats.visible")
        default: break
        }
        if let theme = context.themeFiles.first(where: { $0.commandID == id }) {
            return theme.url.standardizedFileURL == context.themeURL?.standardizedFileURL
        }
        return keyModel?.isOn(id) ?? false
    }

    private func commandsChanged(_ commands: [Command]) {
        menuBuilder?.applyShortcuts(commands, to: NSApp.mainMenu)
        keyMonitor?.update(commands: commands)
    }
}
