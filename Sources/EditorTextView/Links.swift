import AppKit
import MarkdownDocument

/// Where a link points.
enum LinkTarget: Equatable {
    case anchor(String)
    case web(URL)
    case file(URL)
}

/// The link, image or footnote reference at an offset.
struct LinkAtCaret {
    var inline: Inline
    var destination: String?
    var target: LinkTarget
    var isReference: Bool
    /// The definition line of a reference link or footnote.
    var definition: NSRange?
}

/// Clicking links (spec 214–224).
extension EditorTextView {
    func linkTarget(at offset: Int) -> LinkAtCaret? {
        guard let snapshot else { return nil }
        for inline in inlines(at: offset).reversed() {
            switch inline.kind {
            case .link(let destination), .image(let destination, _), .autolink(let destination), .bareURL(let destination):
                guard let target = resolve(destination) else { return nil }
                return LinkAtCaret(inline: inline, destination: destination, target: target, isReference: false)
            case .referenceLink(let label), .referenceImage(let label):
                let destination = snapshot.referenceDefinitions[label]
                guard let target = destination.flatMap(resolve) else {
                    return LinkAtCaret(inline: inline, destination: destination, target: .anchor(""), isReference: true,
                                       definition: definitionRange(label: label, footnote: false))
                }
                return LinkAtCaret(inline: inline, destination: destination, target: target, isReference: true,
                                   definition: definitionRange(label: label, footnote: false))
            case .footnoteReference(let label):
                return LinkAtCaret(inline: inline, destination: nil, target: .anchor("fn-" + label), isReference: true,
                                   definition: definitionRange(label: label, footnote: true))
            default:
                continue
            }
        }
        return nil
    }

    /// `#slug` → anchor; a URL with a scheme → web; anything else → a file relative to the document's folder.
    func resolve(_ destination: String) -> LinkTarget? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return .anchor(String(trimmed.dropFirst())) }
        if trimmed.contains("@"), !trimmed.contains("/"), !trimmed.contains(":"), let url = URL(string: "mailto:" + trimmed) { return .web(url) }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            return scheme == "file" ? .file(url) : .web(url)
        }
        let path = (trimmed.removingPercentEncoding ?? trimmed).components(separatedBy: "#")[0]
        if path.hasPrefix("~/") { return .file(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))) }
        if path.hasPrefix("/") {
            if let folder = actions.folderURL() {
                let inFolder = folder.appendingPathComponent(String(path.dropFirst()))
                if FileManager.default.fileExists(atPath: inFolder.path) { return .file(inFolder) }
            }
            return .file(URL(fileURLWithPath: path))
        }
        guard let base = document.url?.deletingLastPathComponent() ?? actions.folderURL() else { return nil }
        return .file(base.appendingPathComponent(path).standardizedFileURL)
    }

    private func definitionRange(label: String, footnote: Bool) -> NSRange? {
        guard let snapshot else { return nil }
        let blocks = snapshot.blocks(where: {
            switch $0.kind {
            case .referenceDefinition: return !footnote
            case .footnoteDefinition(let l): return footnote && l == label
            default: return false
            }
        })
        if footnote { return blocks.first.map { lineContents(at: $0.range.location) } }
        for block in blocks {
            let text = nsText.substring(with: block.range)
            guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") , open < close else { continue }
            let name = text[text.index(after: open)..<close].lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if name == label { return lineContents(at: block.range.location) }
        }
        return nil
    }

    func open(_ link: LinkAtCaret, newTab: Bool = false) {
        switch link.target {
        case .anchor(let slug):
            if let definition = link.definition, slug.hasPrefix("fn-") {
                setSelectedRange(definition)
                scrollRangeToVisible(definition)
            } else {
                goToAnchor(slug)
            }
        case .web(let url): actions.visitURL(url)
        case .file(let url): actions.openPath(url, newTab)
        }
    }

    /// Selects the heading whose slug matches and scrolls it to about 3 lines from the top (spec 220).
    func goToAnchor(_ slug: String) {
        guard let heading = snapshot?.headings.first(where: { $0.slug == slug }) else { return }
        var text = lineContents(at: heading.range.location)
        if let marker = headingMarker(at: heading.range.location) {
            text = NSRange(location: marker.end, length: NSMaxRange(text) - marker.end)
        }
        setSelectedRange(text)
        let rect = rect(forCharacterRange: NSRange(location: text.location, length: 0))
        if let clip = enclosingScrollView?.contentView {
            let y = max(rect.minY - 3 * configuration.linePoints, 0)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    // MARK: Cmd held (spec 217–219)

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        linkMode = event.modifierFlags.contains(.command)
        updateLinkCursor(at: window?.mouseLocationOutsideOfEventStream)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateLinkCursor(at: event.locationInWindow)
        imageHoverCursor(at: event.locationInWindow)
        if isPage {
            blockHandleMouseMoved(event)
            tableGridMouseMoved(event)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if isPage {
            blockHandleMouseMoved(event)
            tableGridMouseMoved(event)
        }
    }

    private func updateLinkCursor(at windowPoint: NSPoint?) {
        guard linkMode, let windowPoint else { return }
        let offset = characterIndexForInsertion(at: convert(windowPoint, from: nil))
        if linkTarget(at: offset) != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    /// Cmd+click opens the link under the pointer in place, Cmd+Option+click in a new tab
    /// (docs/navigation-spec.md); any other click places the caret.
    func clickedLink(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .option] else { return false }
        let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let link = linkTarget(at: offset) else { return false }
        open(link, newTab: flags.contains(.option))
        return true
    }
}
