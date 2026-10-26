import Foundation
import MarkdownDocument
import Observation

/// Renders blocks off the main thread.
actor RenderQueue {
    func render(_ blocks: [Block], in snapshot: Snapshot, with renderer: HTMLRenderer)
        -> (blocks: [BlockID: String], footnotes: String) {
        renderer.html(for: blocks, in: snapshot)
    }
}

/// Keeps the preview page in step with a `MarkdownDocument`. Snapshots arriving within 16 ms are merged, only the
/// blocks they changed are rendered, and the page gets one message per merge: patches for changed blocks, or a full
/// replace when the order of unchanged blocks moved, reference definitions changed, or footnotes were renumbered.
@MainActor
@Observable
public final class PreviewController {
    @ObservationIgnored public let page: any PreviewPage
    /// Opens a clicked link's target: a path for local files, the URL otherwise.
    @ObservationIgnored public var openPath: (String) -> Void = { _ in }
    /// Applies a task checkbox toggle to the editor's text, which passes it on to the `MarkdownDocument` (spec 507).
    @ObservationIgnored public var applyEdit: (TextEdit) -> Void = { _ in }
    /// The latest snapshot shown in the page.
    public private(set) var snapshot: Snapshot?
    public private(set) var fileURL: URL?
    public var projectRoot: URL?
    public private(set) var themeURL: URL?

    @ObservationIgnored var renderer: HTMLRenderer
    @ObservationIgnored private let queue = RenderQueue()
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pending: Snapshot?
    @ObservationIgnored private var pendingChanged: Set<BlockID> = []
    /// The newest snapshot received, shown or not; task toggles are located in it.
    @ObservationIgnored private var latest: Snapshot?
    /// `data-block` values in the page, in order.
    @ObservationIgnored private(set) var pageOrder: [String] = []
    @ObservationIgnored private var footnotesHTML = ""
    @ObservationIgnored private var generation = 0

    /// `page` defaults to a `WebPreviewPage` showing `themeURL`.
    public init(page: (any PreviewPage)? = nil, math: any MathRenderer = KaTeXJSRenderer(), themeURL: URL? = nil) {
        self.page = page ?? WebPreviewPage(themeURL: themeURL)
        self.themeURL = themeURL
        renderer = HTMLRenderer(math: math)
        // The preview is the one consumer that draws a block provisionally; export reads the settled kinds.
        renderer.usesProvisionalKinds = true
        self.page.onTask = { [weak self] index in self?.toggleTask(index) }
        self.page.onLink = { [weak self] href in self?.openLink(href) }
    }

    /// The web view, when the page is a `WebPreviewPage`.
    public var webPage: WebPreviewPage? { page as? WebPreviewPage }

    /// Shows a tab's document: renders it whole, scrolls to the top, then follows its snapshots.
    public func show(document: MarkdownDocument, fileURL: URL?) async {
        listener?.cancel()
        flushTask?.cancel()
        flushTask = nil
        pending = nil
        pendingChanged = []
        generation += 1
        let current = generation
        self.fileURL = fileURL
        let resolver = LinkResolver(projectRoot: projectRoot, currentFile: fileURL)
        renderer.resolveURL = { value in
            let resolved = resolver.resolve(value)
            return resolved.hasPrefix("/") ? URL(fileURLWithPath: resolved).absoluteString : resolved
        }
        let stream = document.snapshots
        let first = await document.currentSnapshot()
        guard current == generation else { return }
        latest = first
        await replaceAll(with: first)
        guard current == generation else { return }
        page.send(.scrollToTop)
        listener = Task { [weak self] in
            for await snapshot in stream {
                guard let self, current == self.generation else { return }
                self.received(snapshot)
            }
        }
    }

    /// Stops following the document; the page keeps what it shows.
    public func stop() {
        listener?.cancel()
        listener = nil
        flushTask?.cancel()
        flushTask = nil
        generation += 1
    }

    public func setTheme(_ url: URL) {
        themeURL = url
        page.send(.setTheme(url))
    }

    /// Scrolls the page so `fraction` of the block (or the next block the page shows) is at the top.
    public func scrollToBlock(_ id: BlockID, fraction: Double) {
        guard let snapshot, let start = snapshot.blocks.firstIndex(where: { $0.id == id }) else { return }
        let shown = Set(pageOrder)
        for (offset, block) in snapshot.blocks[start...].enumerated() where shown.contains(String(block.id.rawValue)) {
            page.send(.scrollToBlock(id: String(block.id.rawValue), fraction: offset == 0 ? fraction : 0))
            return
        }
    }

    public func scrollToTop() { page.send(.scrollToTop) }
    public func scrollToBottom() { page.send(.scrollToBottom) }

    // MARK: Updates

    private func received(_ snapshot: Snapshot) {
        if let latest, snapshot.version <= latest.version { return }
        latest = snapshot
        pending = snapshot
        pendingChanged.formUnion(snapshot.changedBlockIDs)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard let next = pending, let previous = snapshot else { return }
        pending = nil
        let current = generation
        var render = pendingChanged
        pendingChanged = []
        if next.referenceDefinitions != previous.referenceDefinitions || next.footnotes.order != previous.footnotes.order {
            await replaceAll(with: next)
            return
        }

        // Blocks whose own text did not change but whose output did: headings whose slug moved, and the tables of
        // contents when any heading changed.
        var oldSlugs: [BlockID: String] = [:]
        for heading in previous.headings { oldSlugs[heading.blockID] = heading.slug }
        for heading in next.headings where oldSlugs[heading.blockID].map({ $0 != heading.slug }) == true {
            if let block = next.block(at: heading.range.location) { render.insert(block.id) }
        }
        let headingKey = { (headings: [Heading]) in headings.map { "\($0.level) \($0.slug) \($0.text)" } }
        if headingKey(previous.headings) != headingKey(next.headings) {
            for block in next.blocks where block.kind == .toc { render.insert(block.id) }
        }

        let blocks = next.blocks.filter { render.contains($0.id) }
        let result = await queue.render(blocks, in: next, with: renderer)
        guard current == generation else { return }

        let shown = Set(pageOrder)
        var html: [String: String] = [:]
        var newOrder: [String] = []
        for block in next.blocks {
            let id = String(block.id.rawValue)
            if let rendered = result.blocks[block.id] {
                if !rendered.isEmpty {
                    html[id] = rendered
                    newOrder.append(id)
                }
            } else if shown.contains(id) {
                newOrder.append(id)
            }
        }
        if !result.footnotes.isEmpty {
            newOrder.append(HTMLRenderer.footnotesID)
            if result.footnotes != footnotesHTML { html[HTMLRenderer.footnotesID] = result.footnotes }
        }

        // Unchanged blocks must keep their order; otherwise replace everything.
        let stable = Set(newOrder.filter { html[$0] == nil && shown.contains($0) })
        guard pageOrder.filter({ stable.contains($0) }) == newOrder.filter({ stable.contains($0) }) else {
            await replaceAll(with: next)
            return
        }

        // Between each pair of stable blocks, changed blocks replace the old ones there in order; extra new ones are
        // inserted before their successor and extra old ones removed.
        var patches: [PreviewPatch] = []
        var removals: [String] = []
        var oldIndex = 0
        var newIndex = 0
        while newIndex < newOrder.count || oldIndex < pageOrder.count {
            var oldRun: [String] = []
            while oldIndex < pageOrder.count && !stable.contains(pageOrder[oldIndex]) {
                oldRun.append(pageOrder[oldIndex])
                oldIndex += 1
            }
            var newRun: [String] = []
            while newIndex < newOrder.count && !stable.contains(newOrder[newIndex]) {
                newRun.append(newOrder[newIndex])
                newIndex += 1
            }
            let successor = newIndex < newOrder.count ? newOrder[newIndex] : nil
            for (index, id) in newRun.enumerated() {
                if index < oldRun.count {
                    patches.append(PreviewPatch(id: oldRun[index], html: html[id] ?? ""))
                } else {
                    let before = index + 1 < newRun.count ? newRun[index + 1] : successor
                    patches.append(PreviewPatch(id: id, html: html[id] ?? "", before: before))
                }
            }
            if oldRun.count > newRun.count { removals += oldRun[newRun.count...] }
            oldIndex += 1
            newIndex += 1
        }

        snapshot = next
        pageOrder = newOrder
        footnotesHTML = result.footnotes
        if !patches.isEmpty || !removals.isEmpty { page.send(.update(patches: patches, removals: removals)) }
    }

    private func replaceAll(with snapshot: Snapshot) async {
        let current = generation
        let result = await queue.render(snapshot.blocks, in: snapshot, with: renderer)
        guard current == generation else { return }
        var order: [String] = []
        var html = ""
        for block in snapshot.blocks {
            guard let rendered = result.blocks[block.id], !rendered.isEmpty else { continue }
            order.append(String(block.id.rawValue))
            html += rendered
        }
        if !result.footnotes.isEmpty {
            order.append(HTMLRenderer.footnotesID)
            html += result.footnotes
        }
        self.snapshot = snapshot
        pageOrder = order
        footnotesHTML = result.footnotes
        page.send(.replaceAll(html))
    }

    // MARK: Page events

    /// Ticks or unticks the Nth task item of the newest snapshot by rewriting the character inside its `[ ]`.
    func toggleTask(_ index: Int) {
        guard let snapshot = latest else { return }
        let tasks = snapshot.blocks(where: { if case .listItem(task: .some, _) = $0.kind { true } else { false } })
        guard index < tasks.count, case .listItem(_, let checked) = tasks[index].kind, tasks[index].markerRanges.count >= 2 else { return }
        let box = tasks[index].markerRanges[1]
        applyEdit(TextEdit(range: NSRange(location: box.location + 1, length: 1), replacement: checked ? " " : "x"))
    }

    func openLink(_ href: String) {
        if href.hasPrefix("#") {
            page.send(.scrollToAnchor(String(href.dropFirst())))
        } else if let url = URL(string: href), url.isFileURL {
            openPath(url.path)
        } else {
            openPath(href)
        }
    }
}
