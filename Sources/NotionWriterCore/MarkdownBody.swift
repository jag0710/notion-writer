import Foundation

/// A deliberately small block syntax, with Foundation handling inline CommonMark.
/// Unrecognized blocks remain text; parsing never changes the source stored in Draft.
public enum MarkdownBody {
    public static func blocks(_ source: String) throws -> [[String: Any]] {
        guard !source.isEmpty else { return [] }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [[String: Any]] = [], paragraph: [String] = []
        func append(_ type: String, _ text: String, extra: [String: Any] = [:], literal: Bool = false) throws {
            var content = extra
            content["rich_text"] = try richText(text, literal: literal)
            result.append(["object": "block", "type": type, type: content])
        }
        func flush() throws {
            guard !paragraph.isEmpty else { return }
            try append("paragraph", paragraph.joined(separator: "\n")); paragraph = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                try flush()
                let start = index
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                // A single separator already becomes the gap between two blocks.
                let first = start > 0 && index < lines.count && lines[start].isEmpty ? start + 1 : start
                for blank in lines[first..<index] { try append("paragraph", blank, literal: true) }
                continue
            }
            if line.hasPrefix("  ") || line.hasPrefix("\t") {
                // Nested/indented structures are outside this first format set.
                // Keep their source visibly intact rather than flattening the hierarchy.
                try flush(); try append("paragraph", line, literal: true)
                index += 1; continue
            }
            if let fence = captures(#"^ {0,3}(`{3,}|~{3,})([^\r\n]*)$"#, line) {
                let marker = fence[0], hint = fence[1].trimmingCharacters(in: .whitespaces)
                var end = index + 1
                while end < lines.count {
                    let closing = lines[end].trimmingCharacters(in: .whitespaces)
                    if closing.count >= marker.count && closing.allSatisfy({ $0 == marker.first! }) { break }
                    end += 1
                }
                // An unfinished fence is still being edited: preserve it literally.
                if end == lines.count {
                    try flush(); try append("paragraph", lines[index...].joined(separator: "\n"), literal: true)
                    index = lines.count; continue
                }
                try flush()
                let code = lines[(index + 1)..<end].joined(separator: "\n")
                try append("code", code, extra: ["language": language(hint)], literal: true)
                index = end + 1; continue
            }
            if index + 1 < lines.count,
               let header = tableCells(line), let rule = tableCells(lines[index + 1]),
               header.count == rule.count, header.count <= 100,
               rule.allSatisfy({ captures(#"^(:?-{1,}:?)$"#, $0) != nil }) {
                try flush()
                var rows = [header]
                index += 2
                while index < lines.count, let row = tableCells(lines[index]), row.count == header.count {
                    rows.append(row)
                    index += 1
                }
                for offset in stride(from: 0, to: rows.count, by: 100) {
                    let children = try rows[offset..<min(rows.count, offset + 100)].map { row in
                        ["object": "block", "type": "table_row", "table_row": [
                            "cells": try row.map { try richText($0, literal: false) }
                        ]] as [String: Any]
                    }
                    result.append(["object": "block", "type": "table", "table": [
                        "table_width": header.count, "has_column_header": offset == 0,
                        "has_row_header": false, "children": children
                    ]])
                }
                continue
            }
            if let heading = captures(#"^ {0,3}(#{1,6})[ \t]+(.*)$"#, line) {
                try flush()
                let text = heading[1].replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                try append("heading_\(min(3, heading[0].count))", text)
            } else if captures(#"^ {0,3}((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$"#, line) != nil {
                try flush(); result.append(["object": "block", "type": "divider", "divider": [:]])
            } else if let item = captures(#"^ {0,3}[-+*][ \t]+\[([ xX])\][ \t]+(.*)$"#, line) {
                try flush(); try append("to_do", item[1], extra: ["checked": item[0].lowercased() == "x"])
            } else if let item = captures(#"^ {0,3}[-+*][ \t]+(.*)$"#, line) {
                try flush(); try append("bulleted_list_item", item[0])
            } else if let item = captures(#"^ {0,3}[0-9]{1,9}[.)][ \t]+(.*)$"#, line) {
                try flush(); try append("numbered_list_item", item[0])
            } else if let quote = captures(#"^ {0,3}>[ \t]?(.*)$"#, line) {
                try flush()
                var quoted = [quote[0]]
                while index + 1 < lines.count, let next = captures(#"^ {0,3}>[ \t]?(.*)$"#, lines[index + 1]) {
                    index += 1; quoted.append(next[0])
                }
                try append("quote", quoted.joined(separator: "\n"))
            } else if index + 1 < lines.count, let underline = captures(#"^ {0,3}(=+|-+)[ \t]*$"#, lines[index + 1]) {
                try flush(); try append(underline[0].first == "=" ? "heading_1" : "heading_2", line)
                index += 1
            } else { paragraph.append(line) }
            index += 1
        }
        try flush()
        return result
    }

    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in text {
            if character == "|" && !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                if character == "|" && escaped { cell.removeLast() }
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        guard !cells.isEmpty else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { cells.removeFirst() }
        if text.hasSuffix("|") && cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { number in
            Range(match.range(at: number), in: text).map { String(text[$0]) } ?? ""
        }
    }
    private static func richText(_ text: String, literal: Bool) throws -> [[String: Any]] {
        // Remote Markdown images are not fetched. Keep their complete source instead
        // of Foundation reducing them to alt text and losing the URL.
        if literal || text.contains("![") { return try runs(text) }
        let parsed: AttributedString
        do { parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) }
        catch { return try runs(text) }
        var result: [[String: Any]] = []
        for run in parsed.runs {
            let content = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent
            var annotations: [String: Any] = [:]
            if intent?.contains(.stronglyEmphasized) == true { annotations["bold"] = true }
            if intent?.contains(.emphasized) == true { annotations["italic"] = true }
            if intent?.contains(.strikethrough) == true { annotations["strikethrough"] = true }
            if intent?.contains(.code) == true { annotations["code"] = true }
            if let url = run.link, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                return try runs(text)
            }
            result += try runs(content, annotations: annotations, link: run.link)
        }
        guard result.count <= 100 else { throw WriterError.validation("本文の1ブロック内の書式が多すぎます。段落を分けてください。下書きは保持します。") }
        return result
    }
    private static func runs(_ text: String, annotations: [String: Any] = [:], link: URL? = nil) throws -> [[String: Any]] {
        if let link, link.absoluteString.utf16.count > 2000 { throw WriterError.validation("本文のリンクが長すぎます。下書きは保持します。") }
        let pieces = PagePayload.chunks(text)
        guard pieces.count <= 100 else { throw WriterError.validation("本文の1ブロックが長すぎます。段落を分けてください。下書きは保持します。") }
        return pieces.map { piece in
            var value: [String: Any] = ["content": piece]
            if let link { value["link"] = ["url": link.absoluteString] }
            var run: [String: Any] = ["type": "text", "text": value]
            if !annotations.isEmpty { run["annotations"] = annotations }
            return run
        }
    }
    private static func language(_ hint: String) -> String {
        let aliases = ["js": "javascript", "ts": "typescript", "py": "python", "sh": "shell", "bash": "shell", "yml": "yaml", "md": "markdown", "txt": "plain text", "text": "plain text", "c++": "c++", "cs": "c#"]
        let name = hint.lowercased()
        let value = aliases[name] ?? name
        let supported: Set<String> = ["plain text", "swift", "javascript", "typescript", "python", "shell", "json", "yaml", "markdown", "html", "css", "sql", "c", "c++", "c#", "java", "kotlin", "ruby", "go", "rust", "xml", "r", "php"]
        return supported.contains(value) ? value : "plain text"
    }
}
