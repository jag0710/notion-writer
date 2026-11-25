import AppKit
import NotionWriterCore

extension NSAttributedString.Key {
    static let bodyKind = Self("NotionWriter.BlockKind")
    static let bodyLanguage = Self("NotionWriter.CodeLanguage")
    static let bodyColor = Self("NotionWriter.BlockColor")
    static let bodyMarks = Self("NotionWriter.InlineMarks")
    static let bodyTableHeader = Self("NotionWriter.TableHeader")
}

enum BodyBlockColor {
    static func supports(_ kind: String) -> Bool {
        ["paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item",
         "numbered_list_item", "to_do", "quote"].contains(kind)
    }

    static func foreground(_ color: String?) -> NSColor {
        guard let color, color != "default", !color.hasSuffix("_background") else { return WriterStyle.ink }
        return color == "gray" ? NSColor(calibratedWhite: 0.46, alpha: 1) : NotionTagColors.named(color).foreground
    }

    static func background(_ color: String?) -> NSColor? {
        guard let color, color.hasSuffix("_background") else { return nil }
        return NotionTagColors.named(String(color.dropLast("_background".count))).background.withAlphaComponent(0.56)
    }
}

enum MarkdownPreview {
    static func render(_ source: String, font: NSFont) -> NSAttributedString {
        guard let blocks = try? MarkdownBody.blocks(source) else {
            return NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: WriterStyle.ink])
        }
        return render(blocks, font: font)
    }

    static func render(_ blocks: [[String: Any]], font: NSFont, transcript: Bool = false, image: ((String) -> NSAttributedString?)? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var listNumber = 0
        for original in blocks {
            let block = PagePayload.replacingLegacyBookmark(original)
            if let id = PagePayload.imageReferenceID(block) {
                if let attachment = image?(id) { result.append(attachment) }
                listNumber = 0
                continue
            }
            guard let type = block["type"] as? String, let content = block[type] as? [String: Any] else { continue }
            if type == "numbered_list_item" { listNumber += 1 } else { listNumber = 0 }
            if type == "table" {
                appendTable(content, to: result, font: font)
                continue
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = font.pointSize * 0.4
            let size = font.pointSize
            let blockFont: NSFont
            switch type {
            case "heading_1", "heading_2", "heading_3":
                let factor: CGFloat = type == "heading_1" ? 1.55 : (type == "heading_2" ? 1.3 : 1.15)
                style.paragraphSpacingBefore = size * 0.45
                blockFont = NSFont.systemFont(ofSize: size * factor, weight: .semibold)
            case "code":
                blockFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                blockFont = font
            }
            if transcript { TranscriptFormatting.stylePreview(style, kind: type, pointSize: size) }
            let line = NSMutableAttributedString()
            let prefix: String
            switch type {
            case "bulleted_list_item": prefix = "•  "
            case "numbered_list_item": prefix = "\(listNumber).  "
            case "to_do": prefix = content["checked"] as? Bool == true ? "☑  " : "☐  "
            case "quote": prefix = "│  "
            case "divider": prefix = "────────────────"
            default: prefix = ""
            }
            line.append(NSAttributedString(string: prefix, attributes: [.font: blockFont, .foregroundColor: WriterStyle.muted]))
            let runs = content["rich_text"] as? [[String: Any]] ?? []
            line.append(renderRuns(runs, font: blockFont, softLineBreaks: type != "code"))
            line.append(NSAttributedString(string: "\n", attributes: [.font: blockFont]))
            let range = NSRange(location: 0, length: line.length)
            line.addAttribute(.paragraphStyle, value: style, range: range)
            line.addAttribute(.bodyKind, value: type, range: range)
            if let color = content["color"] as? String, color != "default", BodyBlockColor.supports(type) {
                line.addAttribute(.bodyColor, value: color, range: range)
                line.addAttribute(.foregroundColor, value: BodyBlockColor.foreground(color), range: range)
            }
            if let language = content["language"] as? String {
                line.addAttribute(.bodyLanguage, value: language, range: range)
            }
            if type == "code" { line.addAttribute(.backgroundColor, value: NSColor(white: 0.94, alpha: 1), range: range) }
            result.append(line)
        }
        return result
    }

    static func renderRuns(_ runs: [[String: Any]], font: NSFont, softLineBreaks: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            guard let text = run["text"] as? [String: Any], let content = text["content"] as? String else { continue }
            let annotations = run["annotations"] as? [String: Bool] ?? [:]
            var runFont = font
            if annotations["code"] == true { runFont = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
            if annotations["bold"] == true { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if annotations["italic"] == true { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: WriterStyle.ink]
            if !annotations.isEmpty { attributes[.bodyMarks] = annotations as NSDictionary }
            if annotations["code"] == true { attributes[.backgroundColor] = NSColor(white: 0.94, alpha: 1) }
            if annotations["strikethrough"] == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = (text["link"] as? [String: String])?["url"], let url = URL(string: link) {
                attributes[.link] = url
            }
            // Keep explicit line breaks inside a single AppKit paragraph and Notion block.
            let visible = softLineBreaks ? content.replacingOccurrences(of: "\n", with: "\u{2028}") : content
            result.append(NSAttributedString(string: visible, attributes: attributes))
        }
        return result
    }

    private static func appendTable(_ content: [String: Any], to result: NSMutableAttributedString, font: NSFont) {
        guard let columns = content["table_width"] as? Int,
              let rows = content["children"] as? [[String: Any]] else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        for (row, block) in rows.enumerated() {
            guard let cells = (block["table_row"] as? [String: Any])?["cells"] as? [[[String: Any]]] else { continue }
            let header = row == 0 && content["has_column_header"] as? Bool == true
            let cellFont = header ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            for (column, runs) in cells.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor(white: 0.85, alpha: 1))
                if header { cell.backgroundColor = NSColor(white: 0.95, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                let value = NSMutableAttributedString(attributedString: renderRuns(runs, font: cellFont))
                value.append(NSAttributedString(string: "\n", attributes: [.font: cellFont]))
                let range = NSRange(location: 0, length: value.length)
                value.addAttribute(.paragraphStyle, value: style, range: range)
                value.addAttribute(.bodyTableHeader, value: header, range: range)
                result.append(value)
            }
        }

    }
}
