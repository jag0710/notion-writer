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

    static func assistantMarkdown(_ source: String) -> String {
        var fence: (character: Character, length: Int)?
        return source.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let character = trimmed.first, character == "\u{0060}" || character == "~" {
                let length = trimmed.prefix { $0 == character }.count
                if let opened = fence {
                    if opened.character == character, length >= opened.length, trimmed.count == length { fence = nil }
                } else if length >= 3 {
                    fence = (character, length)
                    return line
                }
                if length >= 3 { return line }
            }
            guard fence == nil else { return line }
            let range = NSRange(line.startIndex..., in: line)
            let matches = widgets.matches(in: line, range: range)
            guard !matches.isEmpty else { return line }
            let cleaned = NSMutableString(string: line)
            for match in matches.reversed() {
                let type = (line as NSString).substring(with: match.range(at: 1))
                let data = (line as NSString).substring(with: match.range(at: 2))
                let label = type == "entity" ? entityLabel(data) : widgetLabel(data)
                cleaned.replaceCharacters(in: match.range, with: label ?? "")
            }
            let text = cleaned as String
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }.joined(separator: "\n")
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
