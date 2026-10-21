import AppKit
import Observation
import PlainCore
import Spellcheck

/// Spelling underlines and autocorrect from a `SpellcheckController` (spec 315–323, 1507).
extension EditorTextView {
    public func bind(spellcheck controller: SpellcheckController) {
        spellcheck = controller
        spellingExcluded = snapshot?.codeRanges() ?? []
        let length = nsText.length
        controller.textChanged(text: document.textStorage.string, changedRange: NSRange(location: 0, length: length),
                               excludedRanges: spellingExcluded, typedCharacter: nil)
        observeMisspellings()
    }

    /// Called for every character edit: code ranges move with the edit, then the controller hears about it.
    func spellingTextEdited(_ edited: NSRange, delta: Int) {
        guard let spellcheck else { return }
        let old = NSRange(location: edited.location, length: edited.length - delta)
        spellingExcluded = spellingExcluded.map { Self.map($0, location: old.location, oldLength: old.length, newLength: edited.length) }
        let typed = helperDepth == 0 ? lastTypedCharacter : nil
        spellcheck.textChanged(text: document.textStorage.string, changedRange: edited, excludedRanges: spellingExcluded, typedCharacter: typed)
    }

    /// A current snapshot gives exact code ranges for the next check.
    func spellingSnapshotArrived() {
        guard spellcheck?.enabled == true, let snapshot else { return }
        spellingExcluded = snapshot.codeRanges()
    }

    private func observeMisspellings() {
        guard let spellcheck else { return }
        withObservationTracking {
            _ = spellcheck.misspellings
            _ = spellcheck.enabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.drawMisspellings()
                self?.observeMisspellings()
            }
        }
        drawMisspellings()
    }

    /// A thick underline in `--highlight-error` under each misspelled word.
    func drawMisspellings() {
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.removeRenderingAttribute(.underlineStyle, for: layoutManager.documentRange)
        layoutManager.removeRenderingAttribute(.underlineColor, for: layoutManager.documentRange)
        guard let spellcheck, spellcheck.enabled else { return }
        for word in spellcheck.misspellings where NSMaxRange(word) <= nsText.length {
            guard let range = textRange(for: word) else { continue }
            layoutManager.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, for: range)
            layoutManager.addRenderingAttribute(.underlineColor, value: Tokens.highlightError, for: range)
        }
    }

    /// After a typed space at `offset`: replaces the word before it with the best correction, in its own undo step,
    /// and flashes it grey for 1 second (spec 323).
    func autocorrectAfterSpace(at offset: Int) {
        guard let spellcheck, spellcheck.autocorrect else { return }
        let text = document.textStorage.string
        Task { [weak self] in
            guard let correction = await spellcheck.didTypeSpace(at: offset, in: text), let self else { return }
            let range = correction.range
            guard NSMaxRange(range) <= self.nsText.length, self.nsText.substring(with: range) == (text as NSString).substring(with: range) else { return }
            let caretShift = (correction.replacement as NSString).length - range.length
            let carets = self.allSelections.map { $0.location >= NSMaxRange(range) ? NSRange(location: $0.location + caretShift, length: $0.length) : $0 }
            self.perform([(range, correction.replacement)], select: carets)
            self.flash(NSRange(location: range.location, length: (correction.replacement as NSString).length))
        }
    }

    /// A grey background over `range` that fades out over 1 second.
    private func flash(_ range: NSRange) {
        guard let layoutManager = textLayoutManager, let textRange = textRange(for: range) else { return }
        let steps = 10
        for step in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(step * 100)) { [weak self] in
                MainActor.assumeIsolated {
                    guard self != nil else { return }
                    layoutManager.removeRenderingAttribute(.backgroundColor, for: textRange)
                    if step < steps {
                        let alpha = 0.25 * CGFloat(steps - step) / CGFloat(steps)
                        layoutManager.addRenderingAttribute(.backgroundColor, value: NSColor.gray.withAlphaComponent(alpha), for: textRange)
                    }
                }
            }
        }
    }

    func performSpellingCommand(_ id: String) -> Bool {
        switch id {
        case "editor:toggle-spellcheck": spellcheck?.enabled.toggle()
        case "editor:toggle-autocorrect": spellcheck?.autocorrect.toggle()
        default: return false
        }
        return true
    }
}
