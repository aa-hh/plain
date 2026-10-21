import AppKit
import Observation

/// Saves one document 500 ms after its edits settle. Never touches untitled, preferences or backup tabs.
@MainActor @Observable
public final class AutosaveController {
    public var enabled: Bool
    public let delay: Duration
    public private(set) var lastError: (any Error)?
    /// Called after each successful save, so the shell can record the file's history as saved.
    @ObservationIgnored public var onSaved: () -> Void = {}

    private let document: Document
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init(document: Document, enabled: Bool = true, delay: Duration = .milliseconds(500)) {
        self.document = document
        self.enabled = enabled
        self.delay = delay
        observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: document.textStorage, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSave() }
        }
    }

    isolated deinit {
        timer?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private var isAutosavable: Bool {
        document.url != nil && !document.isPreferencesFile && !document.isBackupTab
    }

    /// False while autosave is on for a normal file; preferences and untitled files still show it.
    public var showsEditedMark: Bool { document.isEdited && !(enabled && isAutosavable) }

    private var isDue: Bool { enabled && isAutosavable && document.isEdited }

    private func scheduleSave() {
        timer?.cancel()
        guard isDue else { return }
        timer = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    /// Saves now if due. Called when the window loses focus.
    public func flush() async {
        timer?.cancel()
        guard isDue else { return }
        do { try await document.save(); lastError = nil; onSaved() } catch { lastError = error }
    }

    /// Saves now and returns when done. Called before a tab switch or close.
    public func flushSync() {
        timer?.cancel()
        guard isDue else { return }
        do { try document.saveSync(); lastError = nil; onSaved() } catch { lastError = error }
    }
}
