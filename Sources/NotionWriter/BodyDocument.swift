import AppKit
import NotionWriterCore

enum BodyDocument {
    static func read(_ text: NSAttributedString) -> (blocks: [[String: Any]], images: [DraftImage]) {
        let source = text.string as NSString
        var blocks: [[String: Any]] = []
        var images: [DraftImage] = []
        var ids = Set<String>()
        var start = 0

        func appendText(until end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            blocks += readFormatted(range.length == text.length ? text : text.attributedSubstring(from: range))
        }

        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? BodyImageAttachment {
                appendText(until: range.location)
                let image = attachment.draftImage
                blocks.append(PagePayload.imageReference(image.id))
                if ids.insert(image.id).inserted { images.append(image) }
            } else {
                return
            }
            start = NSMaxRange(range)
            if start < source.length, source.character(at: start) == 10 { start += 1 }
        }
        appendText(until: text.length)
        return (blocks, images)
    }

    static func renderPlain(_ blocks: [[String: Any]], attributes: [NSAttributedString.Key: Any],
                            image: (String) -> NSAttributedString?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var hasText = false
        for block in blocks {
            if let id = PagePayload.imageReferenceID(block), let attachment = image(id) {
                if hasText { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
                result.append(attachment)
                hasText = false
            } else if let runs = (block["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]] {
                for run in runs {
                    guard let text = (run["text"] as? [String: Any])?["content"] as? String else { continue }
                    result.append(NSAttributedString(string: text, attributes: attributes))
                    hasText = hasText || !text.isEmpty
                }
            }
        }
        return result
    }

    private static func readFormatted(_ text: NSAttributedString) -> [[String: Any]] {
        let source = text.string as NSString
        var blocks: [[String: Any]] = []
        var offset = 0
        var table: NSTextTable?
        var tableRows: [Int: [Int: [[String: Any]]]] = [:]
        var hasHeader = false
        var code: [String] = []
        var codeLanguage = "plain text"

        func flushTable() {
            guard let table else { return }
            let rows = tableRows.sorted { $0.key < $1.key }.map { _, cells in
                block("table_row", ["cells": (0..<table.numberOfColumns).map { cells[$0] ?? [] }])
            }
            for start in stride(from: 0, to: rows.count, by: 100) {
                blocks.append(block("table", [
                    "table_width": table.numberOfColumns, "has_column_header": hasHeader && start == 0,
                    "has_row_header": false, "children": Array(rows[start..<min(start + 100, rows.count)])
                ]))
            }
            tableRows.removeAll()
            hasHeader = false
        }

        func flushCode() {
            guard !code.isEmpty else { return }
            blocks.append(block("code", ["language": codeLanguage, "rich_text": literal(code.joined(separator: "\n"))]))
            code.removeAll()
        }

        while offset < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: offset, length: 0))
            var range = paragraph
            if paragraph.length > 0 && source.character(at: NSMaxRange(paragraph) - 1) == 10 {
                range.length -= 1
            }
            // Paragraph metadata lives on the trailing newline as well as the visible text.
            let attrs = text.attributes(at: NSMaxRange(paragraph) - 1, effectiveRange: nil)
            let initial = text.attributes(at: offset, effectiveRange: nil)
            let style = (attrs[.paragraphStyle] ?? initial[.paragraphStyle]) as? NSParagraphStyle
            let cell = style?.textBlocks.first as? NSTextTableBlock
            if let cell {
                flushCode()
                if table !== cell.table { flushTable(); table = cell.table }
                let value = runs(text, range)
                let existing = tableRows[cell.startingRow]?[cell.startingColumn] ?? []
                tableRows[cell.startingRow, default: [:]][cell.startingColumn] = existing.isEmpty ? value : existing + literal("\n") + value
                hasHeader = hasHeader || ((attrs[.bodyTableHeader] ?? initial[.bodyTableHeader]) as? Bool == true)
            } else {
                flushTable()
                table = nil
                let kind = (attrs[.bodyKind] ?? initial[.bodyKind]) as? String ?? "paragraph"
                if kind == "code" {
                    let language = (attrs[.bodyLanguage] ?? initial[.bodyLanguage]) as? String ?? "plain text"
                    if language != codeLanguage { flushCode() }
                    codeLanguage = language
                    code.append(source.substring(with: range))
                } else {
                    flushCode()
                    let value = source.substring(with: range)
                    let prefix: Int
                    switch kind {
                    case "bulleted_list_item": prefix = value.hasPrefix("•  ") ? 3 : 0
                    case "numbered_list_item":
                        prefix = (value as NSString).range(of: #"^[0-9]+\.  "#, options: .regularExpression).length
                    case "to_do": prefix = value.hasPrefix("☑  ") || value.hasPrefix("☐  ") ? 3 : 0
                    case "quote": prefix = value.hasPrefix("│  ") ? 3 : 0
                    default: prefix = 0
                    }
                    range.location += prefix
                    range.length -= prefix
                    var content: [String: Any] = ["rich_text": runs(text, range)]
                    if BodyBlockColor.supports(kind), let color = (attrs[.bodyColor] ?? initial[.bodyColor]) as? String {
                        content["color"] = color
                    }
                    if kind == "to_do" { content["checked"] = value.hasPrefix("☑") }
                    blocks.append(block(kind, kind == "divider" ? [:] : content))
                }
            }
            offset = NSMaxRange(paragraph)
        }
        flushTable()
        flushCode()
        return blocks
    }

    private static func block(_ kind: String, _ content: [String: Any]) -> [String: Any] {
        ["object": "block", "type": kind, kind: content]
    }

    private static func literal(_ text: String) -> [[String: Any]] {
        PagePayload.chunks(text).map { ["type": "text", "text": ["content": $0]] }
    }

    private static func runs(_ text: NSAttributedString, _ range: NSRange) -> [[String: Any]] {
        guard range.length > 0 else { return [] }
        var result: [[String: Any]] = []
        var buffered = ""
        var marks: [String: Bool] = [:]
        var link: String?
        func flush() {
            for piece in PagePayload.chunks(buffered) {
                var value: [String: Any] = ["content": piece]
                if let link { value["link"] = ["url": link] }
                var item: [String: Any] = ["type": "text", "text": value]
                if !marks.isEmpty { item["annotations"] = marks }
                result.append(item)
            }
            buffered = ""
        }
        text.enumerateAttributes(in: range) { attrs, range, _ in
            let next = (attrs[.bodyMarks] as? [String: Bool] ?? [:]).filter { $0.value }
            let nextLink = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
            if next != marks || nextLink != link { flush() }
            marks = next
            link = nextLink
            buffered += (text.string as NSString).substring(with: range).replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        flush()
        return result
    }
}
