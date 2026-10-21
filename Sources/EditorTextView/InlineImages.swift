import AppKit
import MarkdownDocument
import PlainCore
import UniformTypeIdentifiers

/// A line holding nothing but an image.
struct ImageLine {
    /// The line without its line break.
    var line: NSRange
    var url: URL
}

/// Pictures in place of image lines (spec 226–237). The source text stays in the file; it is coloured clear and the
/// layout fragment draws the picture over it.
extension EditorTextView {
    static let imageSpacing: CGFloat = 6
    static let imageMaxHeight: CGFloat = 200

    /// Image lines among the top-level paragraphs that meet `range`.
    func imageLines(in range: NSRange) -> [ImageLine] {
        guard let snapshot else { return [] }
        var result: [ImageLine] = []
        var index = MarkdownStyler.firstBlockIndex(at: range.location, in: snapshot.blocks)
        while index < snapshot.blocks.count, snapshot.blocks[index].range.location <= NSMaxRange(range) {
            let block = snapshot.blocks[index]
            index += 1
            guard block.kind == .paragraph, block.lineRange.count == 1, block.inlines.count == 1,
                  case .image(let destination, _) = block.inlines[0].kind,
                  case .file(let url)? = resolve(destination) else { continue }
            let line = lineContents(at: block.range.location)
            guard nsText.substring(with: line).trimmingCharacters(in: .whitespaces) == nsText.substring(with: block.inlines[0].range) else { continue }
            result.append(ImageLine(line: line, url: url))
        }
        return result
    }

    func imageLine(at offset: Int) -> ImageLine? {
        let line = lineContents(at: offset)
        return imageLines(in: line).first { $0.line.location == line.location }
    }

    /// Whether the line at `offset` shows its picture now.
    func isRenderedImageLine(_ line: ImageLine) -> Bool {
        guard expandedImageLine != line.line.location, let cached = imageCache[line.url] else { return false }
        return cached != nil
    }

    func applyImageOverlays(in range: NSRange) {
        let storage = document.textStorage
        for image in imageLines(in: range) {
            guard expandedImageLine != image.line.location else { continue }
            guard let cached = imageCache[image.url] else {
                load(image.url)
                continue
            }
            guard let picture = cached else { continue }
            let indentText = nsText.substring(with: image.line).prefix { $0 == " " || $0 == "\t" }
            let indent = storage.attributedSubstring(from: NSRange(location: image.line.location, length: (String(indentText) as NSString).length)).size().width
            let available = max((textContainer?.size.width ?? 562) - indent, 20)
            var size = picture.size
            if size.width > available { size = NSSize(width: available, height: size.height * available / size.width) }
            if size.height > Self.imageMaxHeight { size = NSSize(width: size.width * Self.imageMaxHeight / size.height, height: Self.imageMaxHeight) }
            size = NSSize(width: size.width.rounded(), height: size.height.rounded())
            let selected = caret == image.line.location
            let overlay = OverlayImage(image: picture, size: size, topSpacing: Self.imageSpacing, left: indent, selected: selected)
            let style = styler.paragraphStyle(lineHeight: size.height + 2 * Self.imageSpacing, font: styler.proseFont)
            storage.beginEditing()
            storage.addAttributes([.foregroundColor: NSColor.clear, .paragraphStyle: style], range: image.line)
            storage.addAttribute(.plainOverlay, value: overlay, range: image.line)
            storage.endEditing()
        }
    }

    /// Reads the picture off the main thread, then draws it where its lines are.
    private func load(_ url: URL) {
        guard pendingImageLoads.insert(url).inserted else { return }
        Task { [weak self] in
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            guard let self else { return }
            self.pendingImageLoads.remove(url)
            self.imageCache[url] = data.flatMap { NSImage(data: $0) }
            self.applyImageOverlays(in: NSRange(location: 0, length: self.nsText.length))
        }
    }

    /// Restyles one image line so its source text shows again (or its picture returns).
    private func refreshImageLine(_ lineStart: Int) {
        guard let snapshot, lineStart <= nsText.length else { return }
        styler.restyle(snapshot: snapshot, range: lineContents(at: lineStart))
    }

    // MARK: Caret (spec 230–231)

    func imageSelectionMoved(from previous: [NSRange]) {
        guard helperDepth == 0, !adjustingImageSelection else { return }
        let ranges = allSelections
        guard ranges.count == 1, let range = ranges.first else { return }
        // Leaving an expanded image line shows its picture again.
        if let expanded = expandedImageLine, expanded <= nsText.length, !NSLocationInRange(range.location, NSRange(location: expanded, length: lineContents(at: expanded).length + 1)) {
            expandedImageLine = nil
            refreshImageLine(expanded)
        }
        guard let image = imageLine(at: range.location), isRenderedImageLine(image) else {
            refreshSelectedImages(previous: previous)
            return
        }
        adjustingImageSelection = true
        defer { adjustingImageSelection = false }
        let start = image.line.location, end = NSMaxRange(image.line)
        if range.length == 0 {
            if range.location != start && range.location != end {
                let old = previous.first?.location ?? range.location
                setSelectedRange(NSRange(location: old > range.location ? start : end, length: 0))
            }
        } else if NSMaxRange(range) > start, NSMaxRange(range) < end {
            setSelectedRange(NSRange(location: range.location, length: end - range.location))
        }
        refreshSelectedImages(previous: previous)
    }

    /// Redraws the image lines the caret entered or left, so the blue cover follows the caret.
    private func refreshSelectedImages(previous: [NSRange]) {
        let now = allSelections
        let offsets = Set((previous + now).filter { $0.length == 0 }.map(\.location))
        for offset in offsets where offset <= nsText.length {
            if let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image) {
                applyImageOverlays(in: image.line)
            }
        }
    }

    func imageLineNewline(at offset: Int) -> Bool {
        guard let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image) else { return false }
        expandedImageLine = image.line.location
        refreshImageLine(image.line.location)
        return true
    }

    func imageLineBackspace(at offset: Int) -> Bool {
        guard let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image) else { return false }
        let whole = nsText.lineRange(for: image.line)
        perform(whole, "", caret: whole.location)
        return true
    }

    /// Space with the caret at the start of an image line zooms the picture.
    func imageLineSpace(at offset: Int) -> Bool {
        guard let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image),
              let picture = imageCache[image.url] ?? nil else { return false }
        actions.zoom(picture)
        return true
    }

    /// Clicking the picture while the caret is already on it zooms (spec 232).
    func clickedImage(_ event: NSEvent) -> Bool {
        guard let offset = caret, let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image),
              let picture = imageCache[image.url] ?? nil else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard rect(forCharacterRange: image.line).insetBy(dx: 0, dy: -2).contains(point) || lineContents(at: characterIndexForInsertion(at: point)).location == image.line.location else { return false }
        actions.zoom(picture)
        return true
    }

    /// A zoom-in pointer over the picture while its line is selected (spec 232).
    func imageHoverCursor(at windowPoint: NSPoint) {
        guard let offset = caret, let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image) else { return }
        let hit = characterIndexForInsertion(at: convert(windowPoint, from: nil))
        if lineContents(at: hit).location == image.line.location { NSCursor.zoomIn.set() }
    }

    // MARK: Arrows at the document's ends (spec 231)

    private func insertLineAroundImage(before: Bool) -> Bool {
        guard let offset = caret, let image = imageLine(at: offset), image.line.location == offset, isRenderedImageLine(image) else { return false }
        if before, image.line.location == 0 {
            perform(NSRange(location: 0, length: 0), "\n", caret: 0)
            return true
        }
        if !before, NSMaxRange(image.line) == nsText.length {
            perform(NSRange(location: nsText.length, length: 0), "\n", caret: nsText.length + 1)
            return true
        }
        return false
    }

    public override func moveUp(_ sender: Any?) {
        if moveAllCarets(by: -1, vertical: true) || insertLineAroundImage(before: true) { return }
        super.moveUp(sender)
    }
    public override func moveLeft(_ sender: Any?) {
        if moveAllCarets(by: -1, vertical: false) || insertLineAroundImage(before: true) { return }
        super.moveLeft(sender)
    }
    public override func moveDown(_ sender: Any?) {
        if moveAllCarets(by: 1, vertical: true) || insertLineAroundImage(before: false) { return }
        super.moveDown(sender)
    }
    public override func moveRight(_ sender: Any?) {
        if moveAllCarets(by: 1, vertical: false) || insertLineAroundImage(before: false) { return }
        super.moveRight(sender)
    }

    // MARK: Drops (spec 233)

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let offset = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            var links: [String] = []
            for file in files {
                if OpenableFiles.imageExtensions.contains(file.pathExtension.lowercased()) {
                    links.append("![" + file.deletingPathExtension().lastPathComponent + "](" + relativePath(to: file) + ")")
                } else if OpenableFiles.isOpenable(file) {
                    actions.openPath(file)
                }
            }
            if !links.isEmpty {
                let text = links.joined(separator: "\n")
                perform(NSRange(location: offset, length: 0), text, caret: offset + (text as NSString).length)
            }
            return true
        }
        if let html = board.string(forType: .html), let linked = Self.linkedImage(in: html) {
            perform(NSRange(location: offset, length: 0), linked, caret: offset + (linked as NSString).length)
            return true
        }
        if let url = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme?.hasPrefix("http") == true {
            let title = board.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? url.absoluteString
            let link = "[" + title + "](" + url.absoluteString + ")"
            perform(NSRange(location: offset, length: 0), link, caret: offset + (link as NSString).length)
            return true
        }
        if let html = board.string(forType: .html) {
            setSelectedRange(NSRange(location: offset, length: 0))
            paste(text: actions.htmlToMarkdown(html))
            return true
        }
        if let string = board.string(forType: .string) {
            setSelectedRange(NSRange(location: offset, length: 0))
            paste(text: string)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// `[![alt](src)](url)` for HTML holding an image inside a link.
    static func linkedImage(in html: String) -> String? {
        guard let anchor = html.range(of: #"<a\s[^>]*href="([^"]+)"[^>]*>\s*<img\s[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(html[anchor])
        func attribute(_ name: String, in text: String) -> String? {
            guard let range = text.range(of: name + #"="[^"]*""#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(text[range].dropFirst(name.count + 2).dropLast())
        }
        guard let href = attribute("href", in: tag), let imageStart = tag.range(of: "<img", options: .caseInsensitive) else { return nil }
        let image = String(tag[imageStart.lowerBound...])
        guard let src = attribute("src", in: image) else { return nil }
        return "[![" + (attribute("alt", in: image) ?? "") + "](" + src + ")](" + href + ")"
    }
}
