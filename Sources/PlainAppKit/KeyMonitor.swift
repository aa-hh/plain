import AppKit
import EditorTextView
import PlainCore

/// One local `keyDown` monitor for the app (Decision 15): every command-table shortcut, Cmd+1…9, the Ctrl+Tab
/// switcher and the Esc rules. Menu key equivalents only show the shortcut; the monitor runs it first.
@MainActor
public final class KeyMonitor {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var mouseMonitor: Any?
    private(set) var table: [Shortcut: String] = [:]
    /// The window model for an event's window; nil for windows Plain does not own (panels, alerts).
    private let modelFor: (NSWindow?) -> WindowModel?
    private let run: (String, WindowModel) -> Void

    public init(commands: [Command], modelFor: @escaping (NSWindow?) -> WindowModel?, run: @escaping (String, WindowModel) -> Void) {
        self.modelFor = modelFor
        self.run = run
        update(commands: commands)
    }

    /// Rebuilds the shortcut table; the first command to claim a shortcut keeps it.
    public func update(commands: [Command]) {
        var table: [Shortcut: String] = [:]
        for command in commands where command.id != "application:about" {
            for shortcut in command.shortcuts where table[shortcut] == nil { table[shortcut] = command.id }
        }
        self.table = table
    }

    public func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { self?.handle(event) == nil }
            return used ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.modelFor(event.window)?.modifierFlags.send(event.modifierFlags) }
            return event
        }
        // The mouse's back and forward buttons (docs/navigation-spec.md, Back and forward).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, let id = Self.mouseCommands[event.buttonNumber], let model = self.modelFor(event.window) else { return false }
                self.run(id, model)
                return true
            }
            return used ? nil : event
        }
    }

    static let mouseCommands: [Int: String] = [3: "window:go-back", 4: "window:go-forward"]

    public func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        mouseMonitor = nil
    }

    /// Returns nil when the event was used up.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let model = modelFor(event.window), let shortcut = Self.shortcut(for: event) else { return event }
        let mods = shortcut.modifiers

        // Ctrl+Tab switcher (spec 969–978): Tab or Down moves on, Shift+Tab or Up moves back, Ctrl+Esc cancels.
        if model.popup.active == .tabSwitcher {
            switch shortcut.key {
            case "Tab": model.moveTabSwitcher(by: mods.contains(.shift) ? -1 : 1); return nil
            case "Down": model.moveTabSwitcher(by: 1); return nil
            case "Up": model.moveTabSwitcher(by: -1); return nil
            case "Esc": model.closePopup(); return nil
            default: break
            }
        }
        if shortcut.key == "Tab", mods.contains(.ctrl), !mods.contains(.cmd), !mods.contains(.alt) {
            model.openTabSwitcher()
            return nil
        }
        if mods == [.cmd], let number = Int(shortcut.key), (1...9).contains(number) {
            model.selectTab(number: number)
            return nil
        }
        if shortcut.key == "Esc", mods.isEmpty {
            return model.escape(editorFocused: Self.editorFocused(event.window)) ? nil : event
        }
        guard let id = table[shortcut] else { return event }
        if id.hasPrefix("editor:"), !Self.editorFocused(event.window) { return event }
        run(id, model)
        return nil
    }

    static func editorFocused(_ window: NSWindow?) -> Bool {
        window?.firstResponder is EditorTextView
    }

    /// The shortcut an event types, with the key read without Shift so `Cmd Shift ]` matches.
    static func shortcut(for event: NSEvent) -> Shortcut? {
        var modifiers = Set<Modifier>()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.cmd) }
        if flags.contains(.control) { modifiers.insert(.ctrl) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let named: [UInt16: String] = [
            126: "Up", 125: "Down", 123: "Left", 124: "Right", 36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete",
            53: "Esc", 48: "Tab", 49: "Space", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 24: "Plus", 27: "Minus",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        if let key = named[event.keyCode] { return Shortcut(modifiers: modifiers, key: key) }
        guard let characters = event.characters(byApplyingModifiers: []), characters.count == 1 else { return nil }
        return Shortcut(modifiers: modifiers, key: characters.uppercased())
    }
}
