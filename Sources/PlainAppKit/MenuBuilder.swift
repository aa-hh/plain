import AppKit
import PlainCore
import PreviewRenderer

/// Builds the application menu from the command table (Decision 15). Items carry their command id; picking one calls
/// `run`, and every item's check mark comes from `state` each time a menu opens.
@MainActor
public final class MenuBuilder: NSObject, NSMenuItemValidation {
    public private(set) var commands: [Command]
    public var themes: [ThemeFile]
    /// Runs a command id in the key window (or the app for `application:` ids).
    public var run: (String) -> Void
    /// Whether a checkbox or radio command is on.
    public var state: (String) -> Bool

    /// Commands whose menu items use the standard responder-chain action, so text fields get them too.
    static let standardActions: [String: Selector] = [
        "editor:undo": Selector(("undo:")), "editor:redo": Selector(("redo:")),
        "editor:cut": #selector(NSText.cut(_:)), "editor:copy": #selector(NSText.copy(_:)),
        "editor:paste": #selector(NSText.paste(_:)), "editor:select-all": #selector(NSText.selectAll(_:)),
    ]

    static let menuTitles: [(MenuGroup, String)] = [
        (.file, "File"), (.edit, "Edit"), (.selection, "Selection"), (.format, "Format"), (.go, "Go"), (.view, "View"),
    ]

    public init(commands: [Command], themes: [ThemeFile] = [], run: @escaping (String) -> Void = { _ in },
                state: @escaping (String) -> Bool = { _ in false }) {
        self.commands = commands
        self.themes = themes
        self.run = run
        self.state = state
    }

    public func build() -> NSMenu {
        let main = NSMenu(title: "Main")

        let appMenu = NSMenu(title: "Plain")
        for command in commands where command.menu == .plain {
            appMenu.addItem(item(for: command))
            if command.id == "application:about" { appMenu.addItem(.separator()) }
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Plain", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Plain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        for (group, title) in Self.menuTitles {
            let menu = NSMenu(title: title)
            for command in commands where command.menu == group {
                if command.id == "application:add-custom-theme" {
                    menu.addItem(themeItem())
                    continue
                }
                menu.addItem(item(for: command))
            }
            add(menu, to: main)
        }

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp?.windowsMenu = window

        let help = NSMenu(title: "Help")
        for command in commands where command.menu == .help { help.addItem(item(for: command)) }
        add(help, to: main)
        NSApp?.helpMenu = help
        return main
    }

    /// View > Preview Theme: one checkbox per theme file, then Add Theme… (spec 548).
    private func themeItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Preview Theme")
        for theme in themes {
            let item = NSMenuItem(title: theme.name, action: #selector(runItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.commandID
            submenu.addItem(item)
        }
        if let add = commands.first(where: { $0.id == "application:add-custom-theme" }) {
            if !themes.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(item(for: add))
        }
        let parent = NSMenuItem(title: "Preview Theme", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    private func item(for command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(runItem(_:)), keyEquivalent: "")
        if command.id == "application:about" {
            item.action = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        } else if let standard = Self.standardActions[command.id] {
            item.action = standard
        } else {
            item.target = self
        }
        item.representedObject = command.id
        item.isHidden = command.hiddenFromMenu
        if let first = command.shortcuts.first, let equivalent = Self.keyEquivalent(for: first) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    /// Rebinds key equivalents after the Keyboard Shortcuts file is saved (spec 1079).
    public func applyShortcuts(_ commands: [Command], to menu: NSMenu?) {
        self.commands = commands
        guard let menu else { return }
        let byID = Dictionary(commands.filter { $0.menu != .tabContext }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard let id = item.representedObject as? String, let command = byID[id] else { continue }
                if let first = command.shortcuts.first, let equivalent = Self.keyEquivalent(for: first) {
                    item.keyEquivalent = equivalent.key
                    item.keyEquivalentModifierMask = equivalent.modifiers
                } else {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }
        }
        walk(menu)
    }

    @objc func runItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        run(id)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let id = item.representedObject as? String { item.state = state(id) ? .on : .off }
        return true
    }

    /// The menu form of a shortcut: a key equivalent string and modifier mask.
    static func keyEquivalent(for shortcut: Shortcut) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let special: [String: Int] = [
            "Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey, "Left": NSLeftArrowFunctionKey,
            "Right": NSRightArrowFunctionKey, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey,
            "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey, "Delete": NSDeleteFunctionKey,
        ]
        let plain: [String: String] = ["Enter": "\r", "Backspace": "\u{8}", "Esc": "\u{1b}", "Tab": "\t", "Space": " ", "Plus": "=", "Minus": "-"]
        let key: String
        if let code = special[shortcut.key] {
            key = String(Character(UnicodeScalar(code)!))
        } else if let text = plain[shortcut.key] {
            key = text
        } else if shortcut.key.count > 1, shortcut.key.hasPrefix("F"), let number = Int(shortcut.key.dropFirst()), (1...12).contains(number) {
            key = String(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!))
        } else if shortcut.key.count == 1 {
            key = shortcut.key.lowercased()
        } else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.cmd) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.ctrl) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.alt) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return (key, modifiers)
    }
}
