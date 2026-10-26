import AppKit
import PlainCore
import SwiftUI

/// How tall each shown section is (docs/navigation-spec.md, Heights).
public enum SidebarLayout {
    public static let pinnedRows = 10
    public static let recentRows = 6

    public struct Placed: Equatable, Sendable {
        public var kind: SidebarSectionKind
        /// The section's rows, below its header; 0 while folded.
        public var body: CGFloat
    }

    /// The sections that show, in order, with their heights. `present` are the sections that have something to
    /// show (Files needs a folder, Pinned and Recent need rows). Pinned and Recent take their rows' height; Files
    /// and Outline share what is left.
    public static func place(_ sections: [SidebarSection], present: Set<SidebarSectionKind>, pinned: Int, recent: Int,
                             height: CGFloat) -> [Placed] {
        let shown = sections.filter { !$0.hidden && present.contains($0.kind) }
        var bodies: [SidebarSectionKind: CGFloat] = [:]
        for section in shown where !section.folded {
            switch section.kind {
            case .pinned: bodies[.pinned] = CGFloat(min(pinned, pinnedRows)) * Tokens.line
            case .recent: bodies[.recent] = CGFloat(min(recent, recentRows)) * Tokens.line
            case .files, .outline: break
            }
        }
        let headers = CGFloat(shown.count) * Tokens.line + CGFloat(max(shown.count - 1, 0)) * Tokens.sidebarSectionGap
        let flexible = shown.filter { !$0.folded && ($0.kind == .files || $0.kind == .outline) }
        let left = max(height - headers - bodies.values.reduce(0, +), 0)
        for section in flexible { bodies[section.kind] = (left / CGFloat(flexible.count)).rounded(.down) }
        return shown.map { Placed(kind: $0.kind, body: $0.folded ? 0 : bodies[$0.kind] ?? 0) }
    }
}

/// What the sidebar asks the shell to do.
public struct SidebarActions {
    public var toggleFold: (SidebarSectionKind) -> Void
    public var setHidden: (SidebarSectionKind, Bool) -> Void
    public var move: (SidebarSectionKind, _ before: SidebarSectionKind) -> Void
    /// The edge dragged to this width; the shell clamps it or closes the sidebar.
    public var resize: (CGFloat) -> Void
    public var resizeEnded: () -> Void
    /// Double-click on the edge.
    public var resetWidth: () -> Void

    public init(
        toggleFold: @escaping (SidebarSectionKind) -> Void, setHidden: @escaping (SidebarSectionKind, Bool) -> Void,
        move: @escaping (SidebarSectionKind, SidebarSectionKind) -> Void, resize: @escaping (CGFloat) -> Void,
        resizeEnded: @escaping () -> Void, resetWidth: @escaping () -> Void
    ) {
        self.toggleFold = toggleFold
        self.setHidden = setHidden
        self.move = move
        self.resize = resize
        self.resizeEnded = resizeEnded
        self.resetWidth = resetWidth
    }
}

/// The sidebar: stacked sections, each a header row that folds it and the section's own rows, with a draggable
/// right edge. `titles` holds a header for every section that has something to show.
public struct Sidebar<Section: View>: View {
    let sections: [SidebarSection]
    let titles: [SidebarSectionKind: String]
    let pinnedCount: Int
    let recentCount: Int
    let width: CGFloat
    /// Draws the 1 pt right edge (compact or narrow window).
    let compact: Bool
    let actions: SidebarActions
    let section: (SidebarSectionKind) -> Section

    @State private var dragStartWidth: CGFloat?
    @State private var dropTarget: SidebarSectionKind?

    static var dragPrefix: String { "plain-sidebar-section:" }

    public init(
        sections: [SidebarSection], titles: [SidebarSectionKind: String], pinnedCount: Int, recentCount: Int,
        width: CGFloat, compact: Bool, actions: SidebarActions, @ViewBuilder section: @escaping (SidebarSectionKind) -> Section
    ) {
        self.sections = sections
        self.titles = titles
        self.pinnedCount = pinnedCount
        self.recentCount = recentCount
        self.width = width
        self.compact = compact
        self.actions = actions
        self.section = section
    }

    public var body: some View {
        GeometryReader { proxy in
            let placed = SidebarLayout.place(
                sections, present: Set(titles.keys), pinned: pinnedCount, recent: recentCount, height: proxy.size.height)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(placed.enumerated()), id: \.element.kind) { index, item in
                    let folded = sections.first { $0.kind == item.kind }?.folded ?? false
                    header(item.kind, folded: folded, first: index == 0)
                    if !folded {
                        section(item.kind)
                            .frame(maxWidth: .infinity)
                            .frame(height: item.body)
                            .clipped()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: width)
        .background(Color.material)
        .overlay(alignment: .trailing) {
            if compact { Rectangle().fill(Color.materialLine).frame(width: 1) }
        }
        .overlay(alignment: .trailing) { resizeEdge }
    }

    private func header(_ kind: SidebarSectionKind, folded: Bool, first: Bool) -> some View {
        let title = titles[kind] ?? kind.title
        return Text(title)
            .font(uiFont)
            .foregroundStyle(folded ? Color.tertiaryText : Color.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Tokens.rowPadding)
            .frame(maxWidth: .infinity, minHeight: Tokens.line, maxHeight: Tokens.line, alignment: .leading)
            .overlay(alignment: .top) {
                if dropTarget == kind { Rectangle().fill(Color.materialLine).frame(height: 1) }
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.toggleFold(kind) }
            .draggable(Self.dragPrefix + kind.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, raw.hasPrefix(Self.dragPrefix),
                      let dragged = SidebarSectionKind(rawValue: String(raw.dropFirst(Self.dragPrefix.count))) else { return false }
                actions.move(dragged, kind)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = kind } else if dropTarget == kind { dropTarget = nil }
            }
            .contextMenu {
                ForEach(SidebarSectionKind.allCases, id: \.self) { other in
                    let shown = !(sections.first { $0.kind == other }?.hidden ?? false)
                    Toggle(other.title, isOn: Binding(get: { shown }, set: { actions.setHidden(other, !$0) }))
                }
            }
            .padding(.top, first ? 0 : Tokens.sidebarSectionGap)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(folded ? "collapsed" : "expanded")
            .accessibilityAddTraits([.isHeader, .isButton])
            .accessibilityAction { actions.toggleFold(kind) }
    }

    /// A 4 pt strip on the right edge: drag to resize, double-click for the default width.
    private var resizeEdge: some View {
        Color.clear
            .frame(width: 4)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        actions.resize(start + value.translation.width)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        actions.resizeEnded()
                    }
            )
            .onTapGesture(count: 2) { actions.resetWidth() }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: actions.resize(width + 20)
                case .decrement: actions.resize(width - 20)
                @unknown default: return
                }
                actions.resizeEnded()
            }
    }
}
