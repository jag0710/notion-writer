import AppKit

enum TranscriptFormatting {
    static func stylePreview(_ style: NSMutableParagraphStyle, kind: String, pointSize: CGFloat) {
        let scale = pointSize / 15
        style.lineSpacing = 3 * scale
        switch kind {
        case "paragraph":
            style.paragraphSpacing = 11 * scale
        case "bulleted_list_item", "numbered_list_item", "to_do":
            style.firstLineHeadIndent = 2 * scale
            style.headIndent = 25 * scale
            style.paragraphSpacing = 5 * scale
        case "heading_1", "heading_2", "heading_3":
            style.paragraphSpacingBefore = 17 * scale
            style.paragraphSpacing = 8 * scale
        default:
            style.paragraphSpacing = 8 * scale
        }
    }

    private static let widgets = try! NSRegularExpression(pattern: #"\uE200([a-z][a-z_0-9]*)\uE202([^\uE200\uE201]*)\uE201"#)

    static let widgetFields = [
        "title", "question", "caption", "alt", "alt_text", "description", "label", "text", "options", "choices", "cards", "items", "images"
    ]

    private static let layoutTags = try! NSRegularExpression(
        pattern: #"\x60+[^\x60\n]*\x60+|<(/?)([A-Za-z][A-Za-z0-9-]*)(?=[\s/>])((?:[^<>"']|"[^"]*"|'[^']*')*)>"#)
    private static let referenceIDs = try! NSRegularExpression(pattern: #""([A-Za-z0-9_]+)""#)
    private static let containers: Set<String> = ["grid", "grid-item", "card", "box", "row", "column", "stack", "panel"]
    private static let fields: Set<String> = [
        "caption", "title", "label", "value", "text", "paragraph", "heading", "badge", "icon", "divider", "spacer"
    ]

    static func assistantMarkdown(_ source: String, citations: [String: String] = [:]) -> String {
        guard source.contains("<") || source.contains("\u{E200}") else { return source }
        let withoutMarkers = removingPrivateMarkers(source)
        let explicitlyClosed = Set(["grid", "card"].filter { withoutMarkers.contains("</" + $0 + ">") })
        var layout: [String] = []
        var pendingCaption: String?
        var lines: [String] = []

        func flushCaption() {
            if let caption = pendingCaption { lines.append("- " + caption) }
            pendingCaption = nil
        }

        visitProseLines(withoutMarkers) { line, isProse in
            guard isProse, line.contains("<") else {
                flushCaption()
                lines.append(line)
                return
            }
            let wasInLayout = !layout.isEmpty
            let source = line as NSString
            var offset = 0
            var text = ""
            var removedLayout = false
            var caption = false
            var title = false
            var closedGroup = false
            for match in layoutTags.matches(in: line, range: NSRange(location: 0, length: source.length)) {
                guard match.range(at: 2).location != NSNotFound else { continue } // Inline code.
                let closing = source.substring(with: match.range(at: 1)) == "/"
                let name = source.substring(with: match.range(at: 2)).lowercased()
                let attributes = source.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                var replacement = ""
                if name == "cite", !closing, attributes.hasPrefix("refs="), attributes.hasSuffix("/") {
                    let quoted = attributes as NSString
                    let references = referenceIDs.matches(in: attributes, range: NSRange(location: 0, length: quoted.length))
                        .compactMap { citations[quoted.substring(with: $0.range(at: 1))] }
                    if !references.isEmpty { replacement = "（" + references.joined(separator: " / ") + "）" }
                } else if containers.contains(name) {
                    if closing {
                        guard let index = layout.lastIndex(of: name) else { continue }
                        layout.removeSubrange(index...)
                        closedGroup = closedGroup || name == "card" || layout.isEmpty
                    } else {
                        guard !layout.isEmpty || attributes.contains("=") ||
                              explicitlyClosed.contains(name) else { continue }
                        if !attributes.hasSuffix("/") { layout.append(name) }
                    }
                    removedLayout = true
                } else if !layout.isEmpty, fields.contains(name) {
                    caption = caption || name == "caption" || name == "label"
                    title = title || name == "title" || name == "value"
                    if closing && (name == "caption" || name == "label") { replacement = " — " }
                    removedLayout = true
                } else {
                    continue
                }
                text += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
                text += replacement
                offset = NSMaxRange(match.range)
            }
            guard offset > 0 else {
                flushCaption()
                lines.append(wasInLayout ? line.trimmingCharacters(in: .whitespaces) : line)
                return
            }
            text += source.substring(from: offset)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if removedLayout || wasInLayout {
                if caption && !title && trimmed.hasSuffix(" —") {
                    flushCaption()
                    pendingCaption = String(trimmed.dropLast(2))
                } else if title, let label = pendingCaption, !trimmed.isEmpty {
                    lines.append("- " + label + " — " + trimmed)
                    pendingCaption = nil
                } else if !trimmed.isEmpty {
                    flushCaption()
                    lines.append(caption && title ? "- " + trimmed : trimmed)
                }
                if closedGroup { flushCaption() }
            } else if !trimmed.isEmpty {
                flushCaption()
                lines.append(text)
            }
        }
        flushCaption()
        return lines.joined(separator: "\n")
    }

    private static func removingPrivateMarkers(_ source: String) -> String {
        var lines: [String] = []
        visitProseLines(source) { line, isProse in
            guard isProse else { lines.append(line); return }
            let range = NSRange(line.startIndex..., in: line)
            let matches = widgets.matches(in: line, range: range)
            guard !matches.isEmpty else { lines.append(line); return }
            let cleaned = NSMutableString(string: line)
            for match in matches.reversed() {
                let type = (line as NSString).substring(with: match.range(at: 1))
                let data = (line as NSString).substring(with: match.range(at: 2))
                let label = type == "entity" ? entityLabel(data) : widgetLabel(data)
                cleaned.replaceCharacters(in: match.range, with: label ?? "")
            }
            let text = cleaned as String
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }

    private static func visitProseLines(_ source: String, visit: (String, Bool) -> Void) {
        var fence: (marker: Character, count: Int)?
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "\u{0060}" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if let opened = fence, opened.marker == marker, count >= opened.count, trimmed.count == count {
                    fence = nil
                    visit(line, false)
                    continue
                }
                if fence == nil, count >= 3 { fence = (marker, count) }
            }
            visit(line, fence == nil)
        }
    }

    private static func widgetLabel(_ source: String) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(source.utf8)),
              value is [String: Any] || value is [[String: Any]] else { return nil }
        func labels(_ value: Any, depth: Int) -> [String] {
            guard depth < 6 else { return [] }
            if let text = value as? String { return [text] }
            if let list = value as? [Any] { return list.flatMap { labels($0, depth: depth + 1) } }
            guard let fields = value as? [String: Any] else { return [] }
            return widgetFields.compactMap { fields[$0] }.flatMap { labels($0, depth: depth + 1) }
        }
        return labels(value, depth: 0).joined(separator: " / ")
    }

    private static func entityLabel(_ source: String) -> String? {
        guard let values = try? JSONDecoder().decode([String].self, from: Data(source.utf8)),
              values.count > 1 else { return nil }
        return values[1]
    }
}
