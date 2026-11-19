import AppKit
import NotionWriterCore

final class BodyEditor: WriterTextView {
    var baseFont = NSFont.systemFont(ofSize: 16)
    private let commands = BodyCommandMenu()
    private var applyingFormat = false
    private var searchingCommands = false

    var normalAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: WriterStyle.ink, .paragraphStyle: NSParagraphStyle.default]
    }

    override func draw(_ rect: NSRect) {
        drawBlockBackgrounds(in: rect)
        super.draw(rect)
    }

    private func drawBlockBackgrounds(in rect: NSRect) {
        guard let layoutManager, let textContainer, let textStorage else { return }
        let origin = textContainerOrigin
        let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, range, _ in
            let character = layoutManager.characterIndexForGlyph(at: range.location)
            guard character < textStorage.length,
                  let color = BodyBlockColor.background(textStorage.attribute(.bodyColor, at: character, effectiveRange: nil) as? String) else { return }
            color.setFill()
            NSRect(x: origin.x, y: origin.y + line.minY, width: textContainer.size.width, height: line.height).fill()
        }
        if selectedRange().location == textStorage.length, string.isEmpty || string.hasSuffix("\n"),
           let color = BodyBlockColor.background(typingAttributes[.bodyColor] as? String) {
            let extra = layoutManager.extraLineFragmentRect
            color.setFill()
            NSRect(x: origin.x, y: origin.y + extra.minY, width: textContainer.size.width,
                   height: max(extra.height, baseFont.ascender - baseFont.descender)).fill()
        }
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if ImageTransfer.accept(.general, files: importImageFiles, data: importImageData) { return }
        if let source = NSPasteboard.general.string(forType: .string), pasteMarkdown(source) { return }
        super.pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if ImageTransfer.canRead(sender.draggingPasteboard) {
            let point = convert(sender.draggingLocation, from: nil)
            let offset = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: min(offset, (string as NSString).length), length: 0))
        }
        return super.performDragOperation(sender)
    }

    func imageFragment(_ image: DraftImage, root: URL, size: NSSize) -> NSAttributedString {
        let attachment = BodyImageAttachment(image, root: root, width: size.width, height: size.height)
        let fragment = NSMutableAttributedString(attachment: attachment)
        fragment.addAttributes(normalAttributes, range: NSRange(location: 0, length: fragment.length))
        fragment.append(NSAttributedString(string: "\n", attributes: normalAttributes))
        return fragment
    }

    func insertImages(_ images: [DraftImage], at caret: Int, root: URL, size: NSSize) -> Bool {
        dismissCommands()
        guard let storage = textStorage, !images.isEmpty else { return false }
        let text = storage.string as NSString
        let position = imageInsertionPoint(min(caret, text.length), in: storage)
        var replacement = NSRange(location: position, length: 0)
        let fragment = NSMutableAttributedString()
        if position > 0 && text.character(at: position - 1) != 10 {
            let attributes = storage.attributes(at: position - 1, effectiveRange: nil).filter { $0.key != .attachment }
            fragment.append(NSAttributedString(string: "\n", attributes: attributes))
            if position < text.length, text.character(at: position) == 10 { replacement.length = 1 }
        }
        for image in images { fragment.append(imageFragment(image, root: root, size: size)) }
        guard replace(replacement, with: fragment) else { return false }
        typingAttributes = normalAttributes
        return true
    }

    private func imageInsertionPoint(_ caret: Int, in storage: NSAttributedString) -> Int {
        let text = storage.string as NSString
        guard text.length > 0, caret < text.length || text.character(at: caret - 1) != 10 else { return caret }
        let attributes = storage.attributes(at: min(caret, text.length - 1), effectiveRange: nil)
        let table = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
        let code = attributes[.bodyKind] as? String == "code"
        guard table != nil || code else { return caret }

        var position = NSMaxRange(text.paragraphRange(for: NSRange(location: min(caret, text.length - 1), length: 0)))
        while position < text.length {
            let next = storage.attributes(at: position, effectiveRange: nil)
            let nextTable = (next[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
            if let table {
                guard nextTable?.table === table.table else { break }
            } else if next[.bodyKind] as? String != "code" { break }
            position = NSMaxRange(text.paragraphRange(for: NSRange(location: position, length: 0)))
        }
        return position
    }

    @discardableResult
    func pasteMarkdown(_ source: String) -> Bool {
        guard let blocks = try? MarkdownBody.blocks(source), !blocks.isEmpty else { return false }
        dismissCommands()
        let range = selectedRange()
        if blocks.count == 1, blocks[0]["type"] as? String == "paragraph",
           !source.contains("\n"), !source.contains("\r") {
            let runs = (blocks[0]["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? []
            let fragment = NSMutableAttributedString(attributedString: MarkdownPreview.renderRuns(runs, font: activeFont))
            let attrs = currentBlockAttributes()
            if fragment.length > 0 { fragment.addAttributes(attrs, range: NSRange(location: 0, length: fragment.length)) }
            replace(range, with: fragment)
            return true
        }
        // Paste complete blocks at block boundaries so a heading/list cannot restyle surrounding text.
        let fragment = NSMutableAttributedString(attributedString: MarkdownPreview.render(blocks, font: baseFont))
        let text = string as NSString
        if range.location > 0 && text.character(at: range.location - 1) != 10 {
            fragment.insert(NSAttributedString(string: "\n", attributes: typingAttributes), at: 0)
        }
        replace(range, with: fragment)
        typingAttributes = normalAttributes
        return true
    }

    override func keyDown(with event: NSEvent) {
        if commands.isVisible && !hasMarkedText() {
            switch event.keyCode {
            case 125: commands.move(by: 1); return
            case 126: commands.move(by: -1); return
            case 36, 76:
                if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                    commands.choose(); return
                }
            case 53: dismissCommands(); return
            default: break
            }
        }
        if [36, 48, 53, 76, 123, 124, 125, 126].contains(event.keyCode) { dismissCommands() }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { dismissCommands() }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        dismissCommands()
        if event.modifierFlags.intersection([.shift, .command, .option]).isEmpty,
           let storage = textStorage, let layoutManager {
            let point = convert(event.locationInWindow, from: nil)
            let caret = characterIndexForInsertion(at: point)
            for index in [caret, caret - 1] where index >= 0 && index < storage.length {
                guard storage.attribute(.attachment, at: index, effectiveRange: nil) is BodyImageAttachment,
                      let textContainer else { continue }
                let range = NSRange(location: index, length: 1)
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                if frame.contains(point) {
                    window?.makeFirstResponder(self)
                    setSelectedRange(range)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        if let selection = imageDeletionRange() {
            replace(selection, with: NSAttributedString())
            typingAttributes = normalAttributes
            return
        }
        super.deleteBackward(sender)
        if searchingCommands { updateCommands() }
    }

    override func deleteForward(_ sender: Any?) {
        if selectedRange().length > 0, let selection = imageDeletionRange() {
            replace(selection, with: NSAttributedString())
            typingAttributes = normalAttributes
        } else { super.deleteForward(sender) }
    }

    private func imageDeletionRange() -> NSRange? {
        guard !hasMarkedText(), let storage = textStorage else { return nil }
        let selection = selectedRange()
        let text = storage.string as NSString
        let position = selection.length == 1 ? selection.location : selection.location - 2
        guard selection.length <= 1, position >= 0, position + 1 < storage.length,
              storage.attribute(.attachment, at: position, effectiveRange: nil) is BodyImageAttachment,
              text.character(at: position + 1) == 10 else { return nil }
        return NSRange(location: position, length: 2)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        guard !hasMarkedText(), !applyingFormat else { return }
        let inserted = (insertString as? NSAttributedString)?.string ?? insertString as? String
        if inserted == " " { applyBlockShortcut() }
        if let inserted, ["*", "~", "`"].contains(inserted) { applyInlineShortcut() }
        if searchingCommands || (inserted?.hasPrefix("/") == true) { updateCommands() }
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { super.insertNewline(sender); return }
        let text = string as NSString
        let selection = selectedRange()
        let paragraph = text.paragraphRange(for: selection)
        let attrs = currentBlockAttributes()
        if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textBlocks.isEmpty {
            let next = NSMaxRange(paragraph)
            if next < text.length {
                setSelectedRange(NSRange(location: next, length: 0))
                scrollRangeToVisible(selectedRange())
            } else {
                if next > 0 && text.character(at: next - 1) == 10 {
                    setSelectedRange(NSRange(location: next, length: 0))
                } else {
                    replace(NSRange(location: next, length: 0), with: NSAttributedString(string: "\n", attributes: attrs))
                }
                typingAttributes = normalAttributes
            }
            return
        }
        let kind = attrs[.bodyKind] as? String ?? "paragraph"
        let value = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
        let marker: String
        switch kind {
        case "bulleted_list_item": marker = "•  "
        case "numbered_list_item":
            let current = value.prefix(while: { $0.isASCII && $0.isNumber })
            marker = "\((Int(current) ?? 0) + 1).  "
        case "to_do": marker = "☐  "
        default: marker = ""
        }
        let currentMarker = kind == "numbered_list_item" ? #"^[0-9]+\.  $"# : #"^[•☐☑]  $"#
        if !marker.isEmpty && value.range(of: currentMarker, options: .regularExpression) != nil {
            let contentRange = NSRange(location: paragraph.location, length: (value as NSString).length)
            replace(contentRange, with: NSAttributedString())
            if paragraph.location < (string as NSString).length {
                textStorage?.setAttributes(normalAttributes, range: NSRange(location: paragraph.location, length: 1))
                didChangeText()
            }
            typingAttributes = normalAttributes
            return
        }
        // Keep the style of the paragraph being split. New headings and quotes start as body text.
        if kind == "code" {
            super.insertNewline(sender)
        } else if !marker.isEmpty {
            let listAttributes = normalAttributes.merging(attrs) { _, new in new }
            replace(selection, with: NSAttributedString(string: "\n" + marker, attributes: listAttributes))
            typingAttributes = listAttributes
        } else {
            replace(selection, with: NSAttributedString(string: "\n", attributes: normalAttributes.merging(attrs) { _, new in new }))
            typingAttributes = normalAttributes
        }
    }

    private var activeFont: NSFont {
        let kind = currentBlockAttributes()[.bodyKind] as? String
        if let kind, kind.hasPrefix("heading_"), let level = kind.last.flatMap({ Int(String($0)) }) {
            let scale: CGFloat = level == 1 ? 1.55 : (level == 2 ? 1.3 : 1.15)
            return .systemFont(ofSize: baseFont.pointSize * scale, weight: .semibold)
        }
        if kind == "code" { return .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular) }
        return baseFont
    }

    private func currentBlockAttributes() -> [NSAttributedString.Key: Any] {
        let caret = selectedRange().location
        let text = string as NSString
        let attributes: [NSAttributedString.Key: Any]
        if caret < text.length {
            attributes = textStorage?.attributes(at: caret, effectiveRange: nil) ?? [:]
        } else {
            attributes = typingAttributes
        }
        var block = attributes.filter { [.paragraphStyle, .bodyKind, .bodyLanguage, .bodyTableHeader, .bodyColor].contains($0.key) }
        if let color = block[.bodyColor] as? String { block[.foregroundColor] = BodyBlockColor.foreground(color) }
        return block
    }

    @discardableResult
    func replace(_ range: NSRange, with fragment: NSAttributedString) -> Bool {
        guard isEditable, let storage = textStorage, NSMaxRange(range) <= storage.length else { return false }
        let manager = undoManager
        manager?.disableUndoRegistration()
        guard shouldChangeText(in: range, replacementString: fragment.string) else {
            manager?.enableUndoRegistration()
            return false
        }
        let previous = storage.attributedSubstring(from: range)
        let newRange = NSRange(location: range.location, length: fragment.length)
        storage.replaceCharacters(in: range, with: fragment)
        setSelectedRange(NSRange(location: NSMaxRange(newRange), length: 0))
        manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget: self) { editor in editor.replace(newRange, with: previous) }
        didChangeText()
        scrollRangeToVisible(selectedRange())
        return true
    }

    private func applyBlockShortcut() {
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = string as NSString
        let paragraph = text.paragraphRange(for: selection)
        let allowed = currentBlockAttributes()
        guard (allowed[.bodyKind] as? String ?? "paragraph") == "paragraph",
              (allowed[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty != false else { return }
        let range = NSRange(location: paragraph.location, length: selection.location - paragraph.location)
        let kind: String
        switch text.substring(with: range) {
        case "# ": kind = "heading_1"
        case "## ": kind = "heading_2"
        case "### ": kind = "heading_3"
        case "- ", "* ", "+ ": kind = "bulleted_list_item"
        case "1. ": kind = "numbered_list_item"
        case "[] ", "[ ] ": kind = "to_do"
        case "> ": kind = "quote"
        default: return
        }
        apply(kind, replacing: range)
    }

    private func applyInlineShortcut() {
        guard currentBlockAttributes()[.bodyKind] as? String != "code" else { return }
        let caret = selectedRange().location
        let text = string as NSString
        let line = text.paragraphRange(for: NSRange(location: caret, length: 0))
        guard caret > line.location else { return }
        let typed = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let suffix = #"(?<![\\*])\*\*[^*\n]+\*\*$|(?<![\\*])\*[^*\n]+\*(?<!\*\*)$|(?<![\\~])~~[^~\n]+~~$|(?<![\\`])`[^`\n]+`$"#
        let found = (typed as NSString).range(of: suffix, options: .regularExpression)
        guard found.location != NSNotFound,
              let block = try? MarkdownBody.blocks((typed as NSString).substring(with: found)).first,
              let runs = (block["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]],
              runs.contains(where: { $0["annotations"] != nil }) else { return }
        let range = NSRange(location: line.location + found.location, length: found.length)
        let fragment = NSMutableAttributedString(attributedString: MarkdownPreview.renderRuns(runs, font: activeFont))
        let blockAttributes = currentBlockAttributes()
        fragment.addAttributes(blockAttributes, range: NSRange(location: 0, length: fragment.length))
        applyingFormat = true
        replace(range, with: fragment)
        applyingFormat = false
        typingAttributes = normalAttributes.merging(blockAttributes) { _, new in new }
        typingAttributes[.font] = activeFont
    }

    private func dismissCommands() {
        searchingCommands = false
        commands.close()
    }

    private func updateCommands() {
        guard isEditable, window?.isKeyWindow == true,
              currentBlockAttributes()[.bodyKind] as? String != "code",
              (currentBlockAttributes()[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty != false else {
            dismissCommands()
            return
        }
        let caret = selectedRange().location
        let text = string as NSString
        let line = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let found = (before as NSString).range(of: #"(?<!\S)/[^\s/]*(?: [^\s/]*)?$"#, options: .regularExpression)
        guard found.location != NSNotFound else { dismissCommands(); return }
        searchingCommands = true
        let range = NSRange(location: line.location + found.location, length: found.length)
        let query = text.substring(with: range).dropFirst()
        let canColor = BodyBlockColor.supports(currentBlockAttributes()[.bodyKind] as? String ?? "paragraph")
        commands.show(query: String(query), in: self, allowColor: canColor) { [weak self] action in
            switch action {
            case .block(let kind): self?.apply(kind, replacing: range)
            case .color(let color): self?.applyColor(color, replacing: range)
            }
        }
    }

    private func apply(_ kind: String, replacing command: NSRange) {
        dismissCommands()
        let text = string as NSString
        let paragraph = text.paragraphRange(for: command)
        let hasContentBefore = command.location > paragraph.location
        let language = kind == "code" ? ["language": "plain text"] : [:]
        var content: [String: Any] = ["rich_text": [] as [[String: Any]]]
        content.merge(language) { _, new in new }
        if BodyBlockColor.supports(kind) { content["color"] = currentBlockAttributes()[.bodyColor] }
        var blocks = [["type": kind, kind: content]]
        if kind == "table", let table = try? MarkdownBody.blocks("| 列1 | 列2 |\n| --- | --- |\n| | |") { blocks = table }
        let rendered = MarkdownPreview.render(blocks, font: baseFont)
        guard rendered.length > 0 else { return }
        let fragment = NSMutableAttributedString(attributedString: rendered)
        let standalone = kind == "divider" || kind == "table"
        if fragment.length > 0 && !standalone { fragment.deleteCharacters(in: NSRange(location: fragment.length - 1, length: 1)) }
        let attributes = rendered.attributes(at: 0, effectiveRange: nil)
        if hasContentBefore {
            fragment.insert(NSAttributedString(string: "\n", attributes: currentBlockAttributes()), at: 0)
        }
        replace(command, with: fragment)
        if standalone {
            typingAttributes = normalAttributes
            if kind == "table" { setSelectedRange(NSRange(location: command.location + (hasContentBefore ? 1 : 0), length: 0)) }
        } else {
            // If a newline already terminates this block, it needs the same semantic style.
            let next = selectedRange().location
            if next < (string as NSString).length && (string as NSString).character(at: next) == 10 {
                textStorage?.addAttributes(attributes, range: NSRange(location: next, length: 1))
                didChangeText()
            }
            typingAttributes = attributes.merging([.foregroundColor: BodyBlockColor.foreground(attributes[.bodyColor] as? String)]) { _, new in new }
        }
    }

    func applyColor(_ color: String, replacing command: NSRange) {
        dismissCommands()
        guard let storage = textStorage else { return }
        let text = string as NSString
        let paragraph = text.paragraphRange(for: command)
        let colored = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
        var removing = NSRange(location: command.location - paragraph.location, length: command.length)
        let line = colored.string as NSString
        if removing.location > 0, line.character(at: removing.location - 1) == 32,
           NSMaxRange(removing) == line.length || line.character(at: NSMaxRange(removing)) == 10 {
            removing.location -= 1
            removing.length += 1
        }
        colored.deleteCharacters(in: removing)
        let all = NSRange(location: 0, length: colored.length)
        let foreground = BodyBlockColor.foreground(color)
        colored.addAttribute(.foregroundColor, value: foreground, range: all)
        if color == "default" { colored.removeAttribute(.bodyColor, range: all) }
        else { colored.addAttribute(.bodyColor, value: color, range: all) }

        let block = currentBlockAttributes()
        replace(paragraph, with: colored)
        setSelectedRange(NSRange(location: paragraph.location + removing.location, length: 0))
        typingAttributes = normalAttributes.merging(block) { _, new in new }
        typingAttributes[.foregroundColor] = foreground
        typingAttributes[.font] = activeFont
        typingAttributes[.bodyColor] = color == "default" ? nil : color
        needsDisplay = true
    }
}
