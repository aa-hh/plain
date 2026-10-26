import AppKit
import PlainCore
import PlainShell
import SwiftUI

/// The card the page's editing tools sit on: menu background, radius 6, a 1 pt border ring and the page shadow.
struct PageMenuCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let page = Tokens.page
        content
            .background(Color(nsColor: page.menuBackground))
            .clipShape(RoundedRectangle(cornerRadius: page.radius))
            .overlay(RoundedRectangle(cornerRadius: page.radius).strokeBorder(Color(nsColor: page.border), lineWidth: 1))
            .shadow(color: Color(nsColor: page.shadow), radius: page.shadowRadius, x: 0, y: page.shadowY)
    }
}

/// A 32 pt menu row: a 16 pt Lucide icon, a 14 pt label and an optional tick or chevron.
struct PageMenuRow: View {
    enum Trailing { case none, tick, chevron }

    let icon: String
    let title: String
    var trailing: Trailing = .none
    var highlighted = false

    var body: some View {
        let page = Tokens.page
        HStack(spacing: 8) {
            LucideIcon(name: icon, size: page.menuIcon, colour: Color(nsColor: page.textSecondary))
            Text(title)
                .font(.system(size: page.menuLabel))
                .foregroundStyle(Color(nsColor: page.text))
            Spacer(minLength: 0)
            switch trailing {
            case .none: EmptyView()
            case .tick: LucideIcon(name: "check", size: page.menuIcon, colour: Color(nsColor: page.textSecondary))
            case .chevron: LucideIcon(name: "chevron-right", size: page.menuIcon, colour: Color(nsColor: page.textSecondary))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: page.menuRow)
        .background(highlighted ? Color(nsColor: page.hover) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: page.handleBoxRadius))
        .contentShape(Rectangle())
    }
}

/// The "Turn into" list: the kinds a block can become, the current one ticked.
struct TurnIntoList: View {
    let current: PageBlockKind?
    let onPick: (PageBlockKind) -> Void
    @State private var hovered: Int?

    var body: some View {
        PageMenuCard {
            VStack(spacing: 0) {
                ForEach(Array(PageBlockKind.turnIntoKinds.enumerated()), id: \.offset) { index, kind in
                    PageMenuRow(icon: kind.icon, title: kind.title, trailing: Self.same(kind, current) ? .tick : .none, highlighted: hovered == index)
                        .onHover { inside in
                            if inside { hovered = index } else if hovered == index { hovered = nil }
                        }
                        .onTapGesture { onPick(kind) }
                }
            }
            .padding(4)
        }
        .frame(width: Tokens.page.menuWidth)
    }

    /// Kinds match ignoring a task's tick.
    static func same(_ a: PageBlockKind, _ b: PageBlockKind?) -> Bool {
        guard let b else { return false }
        if case .task = a, case .task = b { return true }
        return a == b
    }
}

extension EditorTextView {
    /// Adds `view` in an `NSHostingView` of `size`, just under `below`, or just over `above` when there is no room
    /// below, kept inside the visible rect. Rects are in this view's coordinates.
    @discardableResult
    func showPageTool<V: View>(_ view: V, size: NSSize, below: NSRect, above: NSRect) -> NSView {
        let host = NSHostingView(rootView: view)
        let visible = visibleRect
        var y = below.maxY
        if y + size.height > visible.maxY { y = above.minY - size.height }
        let x = min(max(below.minX, visible.minX), max(visible.maxX - size.width, visible.minX))
        y = min(max(y, visible.minY), max(visible.maxY - size.height, visible.minY))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        addSubview(host)
        return host
    }
}
