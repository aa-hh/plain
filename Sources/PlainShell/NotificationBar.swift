import PlainCore
import SwiftUI

/// One message for the notification bar.
public struct ShellNotification: Identifiable, Sendable {
    public struct Button: Sendable {
        public var label: String
        public var action: @MainActor @Sendable () -> Void

        public init(label: String, action: @escaping @MainActor @Sendable () -> Void) {
            self.label = label
            self.action = action
        }
    }

    public let id = UUID()
    public var message: String
    public var isError: Bool
    public var buttons: [Button]

    public init(message: String, isError: Bool = false, buttons: [Button] = []) {
        self.message = message
        self.isError = isError
        self.buttons = buttons
    }
}

/// The bar at the bottom of the editor column: centred blue text (red for errors), buttons written
/// `[ Label ]` 13 pt apart, a `[ × ]` close button, and a 1 pt top border in the text colour.
public struct NotificationBar: View {
    let notification: ShellNotification
    let onClose: () -> Void

    public init(notification: ShellNotification, onClose: @escaping () -> Void) {
        self.notification = notification
        self.onClose = onClose
    }

    public var body: some View {
        let colour = notification.isError ? Color.redText : Color.blueText
        HStack(spacing: 13) {
            Text(notification.message)
            ForEach(Array(notification.buttons.enumerated()), id: \.offset) { _, button in
                SwiftUI.Button("[ \(button.label) ]") { button.action() }.buttonStyle(.plain)
            }
            SwiftUI.Button("[ × ]", action: onClose).buttonStyle(.plain)
        }
        .font(uiFont)
        .foregroundStyle(colour)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(13)
        .background(Color.material)
        .overlay(alignment: .top) { Rectangle().fill(colour).frame(height: 1) }
    }
}
