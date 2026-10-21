import Foundation
import PlainCore

/// Routes a command id: `editor:` ids to the window's editor, app-wide ids to the app, the rest to the window model.
/// Remembers the 3 commands most recently run from the Commands popup in `state/commands.json` (spec 962).
@MainActor
public final class CommandDispatcher {
    public static let historyName = "commands"
    public static let historyLimit = 3

    private let context: AppContext
    /// Runs an app-wide command (`application:`, `windows:`, New Window); returns false for ids it does not know.
    var app: (String, WindowModel?) -> Bool

    public init(context: AppContext, app: @escaping (String, WindowModel?) -> Bool = { _, _ in false }) {
        self.context = context
        self.app = app
    }

    public func run(_ id: String, in model: WindowModel?) {
        if id.hasPrefix("editor:") {
            model?.performEditorCommand(id)
        } else if !app(id, model) {
            model?.perform(id)
        }
    }

    /// The Commands popup: focus the editor, run, and remember the command (spec 963).
    public func runFromPopup(_ id: String, in model: WindowModel?) {
        model?.closePopup()
        record(id)
        run(id, in: model)
    }

    func record(_ id: String) {
        context.commandHistory = Self.updatedHistory(context.commandHistory, adding: id)
        let history = context.commandHistory
        let store = context.store
        Task { try? await store.save(Self.historyName, history) }
    }

    static func updatedHistory(_ history: [String], adding id: String) -> [String] {
        Array(([id] + history.filter { $0 != id }).prefix(historyLimit))
    }
}
