import AppKit
import GitStatus
import PlainCore

/// Git change marks right of the text column (spec 373–381, 1511).
extension EditorTextView {
    /// Binds the window's `GitStatus`; nil clears the marks (no repository).
    public func bind(gitStatus status: GitStatus?) {
        gitStatus = status
        guard status != nil else { return clearGitMarks() }
        scheduleGitMarks(after: .zero)
    }

    public func clearGitMarks() {
        gitRefreshTask?.cancel()
        gitMarks = [:]
        needsDisplay = true
    }

    /// Compares with the committed text 50 ms after the call; a newer call replaces an older one.
    func scheduleGitMarks(after delay: Duration = .milliseconds(50)) {
        guard let status = gitStatus, let url = document.url else { return clearGitMarks() }
        gitRefreshTask?.cancel()
        let text = document.textStorage.string
        gitRefreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, status.repositoryRoot != nil, let committed = await status.committedText(of: url) else {
                self?.gitMarks = [:]
                self?.needsDisplay = true
                return
            }
            let found = await Task.detached { marks(for: text, committed: committed) }.value
            guard !Task.isCancelled, let self else { return }
            var lineStarts = [0]
            for (index, unit) in text.utf16.enumerated() where unit == 10 { lineStarts.append(index + 1) }
            self.gitLineStarts = lineStarts
            self.gitMarks = Dictionary(found.map { ($0.line, $0.kind) }, uniquingKeysWith: { first, _ in first })
            self.needsDisplay = true
        }
    }

    /// Zero-based line holding `offset`, from the line starts of the compared text.
    func gitLine(at offset: Int) -> Int {
        var low = 0, high = gitLineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if gitLineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    /// `+`, `~` or `D` in the tertiary colour 30 pt right of the column, on every wrapped row of a changed line and on
    /// one row for a deletion.
    func drawGitMarks(in rect: NSRect) {
        guard !gitMarks.isEmpty, let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage else { return }
        let font = EditorFonts.code(configuration.codeFontSize)
        let origin = textContainerOrigin
        enumerateFragments(in: rect) { fragment in
            let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            guard let kind = gitMarks[gitLine(at: offset)] else { return }
            let glyph: String
            switch kind {
            case .added: glyph = "+"
            case .changed: glyph = "~"
            case .deleted: glyph = "D"
            }
            let string = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: Tokens.colorTertiary])
            let size = string.size()
            let frame = fragment.layoutFragmentFrame
            let rows = kind == .deleted ? Array(fragment.textLineFragments.prefix(1)) : fragment.textLineFragments
            for line in rows {
                let bounds = line.typographicBounds
                string.draw(at: NSPoint(x: columnRight + 30, y: origin.y + frame.minY + bounds.minY + (bounds.height - size.height) / 2))
            }
        }
    }
}
