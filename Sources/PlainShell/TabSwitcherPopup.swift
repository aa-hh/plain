import AppKit
import Combine
import PlainCore
import SwiftUI

/// The Ctrl+Tab switcher: popup "Tabs" without a filter field, listing open tabs most recently used first.
/// The shell's key handler moves `selection` while Ctrl is held; releasing Ctrl picks the selected tab.
public struct TabSwitcherPopup: View {
    let tabs: [TabItem]
    @Binding var selection: Int
    let modifierFlags: AnyPublisher<NSEvent.ModifierFlags, Never>
    let onPick: (TabItem) -> Void
    let onCancel: () -> Void

    public init(
        tabs: [TabItem], selection: Binding<Int>, modifierFlags: AnyPublisher<NSEvent.ModifierFlags, Never>,
        onPick: @escaping (TabItem) -> Void, onCancel: @escaping () -> Void
    ) {
        self.tabs = tabs
        self._selection = selection
        self.modifierFlags = modifierFlags
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// The row selected on opening: the second entry when the first is the current tab.
    public static func initialSelection(tabs: [TabItem], currentID: TabItem.ID?) -> Int {
        tabs.count > 1 && tabs.first?.id == currentID ? 1 : 0
    }

    public var body: some View {
        PopupCard(
            placeholder: "Tabs", filter: nil, selection: $selection, rowCount: tabs.count,
            emptyText: "no tabs opened", onPick: { onPick(tabs[$0]) }, onCancel: onCancel
        ) { index in
            HStack(spacing: 0) {
                FileIcon(kind: .text)
                Text(tabs[index].document.displayName)
                if tabs[index].document.isEdited { Text(" •") }
            }
        }
        .onReceive(modifierFlags) { flags in
            guard !flags.contains(.control) else { return }
            if tabs.indices.contains(selection) { onPick(tabs[selection]) } else { onCancel() }
        }
    }
}
