import Foundation
import NotionWriterCore

enum FullTextImport {
    private static let skipNavigation = "メイン コンテンツにスキップユーザー補助ヘルプ"
    private static let navigation = [skipNavigation, "AI モード", "すべて", "画像", "ニュース", "動画", "もっと見る"]
    private static let answerFooters = [
        "AI は不正確な情報を表示することがあるため、生成された回答を再確認するようにしてください",
        "パーソナライズなしで試す"
    ]
    private static let pageFooters = ["前のプロンプトにスキップする", "AI モードの回答が作成されました", "質問する"]
    private static let headingPattern = #"^([0-9]+)\\?\. (?=\S)"#
    private static let sourceCountPattern = #"^\+[0-9]+$"#

    static func transcript(_ text: String, assistantRole: String = "ai") throws -> Transcript {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == skipNavigation + "\\", lines.contains("\\") {
            lines = lines.map { $0.hasSuffix("\\") ? String($0.dropLast()) : $0 }
        }
        let isFullPage = lines.lazy.map(trim).filter { !$0.isEmpty }.prefix(navigation.count).elementsEqual(navigation)
        if isFullPage, let navEnd = lines.firstIndex(where: { trim($0) == navigation.last }) {
            lines.removeFirst(navEnd + 1)
        }

        let prose = proseFlags(lines)
        let hasGoogleFooter = lines.indices.contains { prose[$0] && trim(lines[$0]) == answerFooters[0] }
        if !isFullPage && !hasGoogleFooter {
            let turns = labeledTurns(lines, prose: prose, assistantRole: assistantRole) ?? [
                .init(speaker: "text", markdown: lines.joined(separator: "\n"))
            ]
            guard turns.contains(where: { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw WriterError.validation("取り込むテキストを貼り付けてください。")
            }
            return Transcript(turns: turns)
        }
        let trailingChrome = isFullPage ? pageFooters : ["質問する"]
        while let last = lines.indices.last, prose[last],
              trailingChrome.contains(trim(lines[last])) || trim(lines[last]).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { throw WriterError.validation("取り込むテキストを貼り付けてください。") }

        var turns: [Transcript.Turn] = []
        var answerStart: Int?
        var index = 0
        while index < lines.count {
            let label = trim(lines[index])
            if answerStart == nil, !label.isEmpty {
                if prose[index], isQuestion(at: index, in: lines, allowAdjacentAnswer: isFullPage) {
                    turns.append(.init(speaker: "user", markdown: label))
                    index += 1
                }
                answerStart = index
                continue
            }
            if let start = answerStart, prose[index], answerFooters.contains(label) {
                if let sources = readSources(from: index + 1, in: lines, prose: prose, isFullPage: isFullPage) {
                    let body = formatAnswer(lines[start..<index], prose: prose, isFullPage: isFullPage,
                                            sourceNames: Set(sources.cards.map { $0[0] }))
                    appendResponse(body, sourceCards: sources.cards, to: &turns)
                    index = sources.end
                    answerStart = nil
                    continue
                }
                if lines[(index + 1)...].allSatisfy({ trim($0).isEmpty }) {
                    appendResponse(formatAnswer(lines[start..<index], prose: prose, isFullPage: isFullPage, sourceNames: []), to: &turns)
                    answerStart = nil
                    break
                }
            }
            index += 1
        }
        if let start = answerStart {
            appendResponse(formatAnswer(lines[start...], prose: prose, isFullPage: isFullPage, sourceNames: []), to: &turns)
        }
        guard !turns.isEmpty else { throw WriterError.validation("取り込めるテキストが見つかりませんでした。") }
        return Transcript(turns: turns)
    }

    private static func trim(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespaces)
    }

    private static func appendResponse(_ markdown: String, sourceCards: [[String]] = [], to turns: inout [Transcript.Turn]) {
        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sourceCards.isEmpty {
            turns.append(.init(speaker: "ai", markdown: markdown, sourceCards: sourceCards))
        }
    }

    private static func isQuestion(at index: Int, in lines: [String], allowAdjacentAnswer: Bool) -> Bool {
        let candidate = trim(lines[index])
        guard candidate.count <= 72, let first = candidate.first, first.isLetter || first.isNumber,
              !candidate.hasSuffix("。"), index + 1 < lines.count,
              allowAdjacentAnswer || trim(lines[index + 1]).isEmpty,
              let next = lines[(index + 1)...].lazy.map(trim).first(where: { !$0.isEmpty }) else { return false }
        guard next.count >= max(30, candidate.count + 8) else { return false }
        return candidate.hasSuffix("？") || candidate.hasSuffix("?") || next.hasPrefix(candidate)
    }

    private static func readSources(from start: Int, in lines: [String], prose: [Bool], isFullPage: Bool)
        -> (cards: [[String]], end: Int)? {
        if !isFullPage, lines[start...].lazy.map(trim).first(where: { !$0.isEmpty }) != "•" { return nil }
        var cards: [[String]] = []
        var card: [String] = []
        var hasExplicitEnd = false
        var index = start
        while index < lines.count, prose[index] {
            let label = trim(lines[index])
            if label == "すべて表示" {
                hasExplicitEnd = true
                index += 1
                break
            }
            if isFullPage, card.isEmpty, !cards.isEmpty,
               isQuestion(at: index, in: lines, allowAdjacentAnswer: true) { break }
            if label == "•" || (isFullPage && label.isEmpty && card.count >= 3) {
                if !card.isEmpty { cards.append(card); card = [] }
            } else if !label.isEmpty {
                card.append(label)
            }
            index += 1
        }
        if !card.isEmpty { cards.append(card) }
        let minimum = isFullPage ? 3 : 2
        guard isFullPage || hasExplicitEnd, !cards.isEmpty, cards.allSatisfy({ entry in
            entry.count >= minimum && entry[0].count <= 45 && !entry[0].hasSuffix("。") && !entry[0].contains("？") &&
                (!isFullPage || entry[2...].contains { $0.hasSuffix("...") || $0.hasSuffix("…") })
        }) else { return nil }
        return (cards, index)
    }

    private static func formatAnswer(_ lines: ArraySlice<String>, prose: [Bool], isFullPage: Bool, sourceNames: Set<String>) -> String {
        var output: [String] = []
        var remaining = lines
        while let line = remaining.popFirst() {
            let index = remaining.startIndex - 1
            let label = trim(line)
            guard prose[index] else { output.append(line); continue }
            let next = remaining.first.map(trim)
            let trimmedCount = next?.replacingOccurrences(of: #"^(?:&#x20;|&#32;|&nbsp;)\s*"#, with: "", options: .regularExpression)
            let count = trimmedCount.flatMap { $0.range(of: sourceCountPattern, options: .regularExpression) == nil ? nil : $0 }
            if isFullPage, !label.isEmpty, label.count <= 45,
               index > lines.startIndex, trim(lines[index - 1]).isEmpty,
               let previous = output.lastIndex(where: { !trim($0).isEmpty }),
               trim(output[previous]).hasSuffix("。"),
               (sourceNames.contains(label) || count != nil) {
                let suffix = count.map { " \($0)" } ?? ""
                output[previous] = trim(output[previous]) + "（出典　\(label)\(suffix)）"
                if count != nil { remaining.removeFirst() }
                if output.last?.isEmpty == false { output.append("") }
                continue
            }
            if let match = label.range(of: headingPattern, options: .regularExpression),
               let following = remaining.lazy.map(trim).first(where: { !$0.isEmpty }),
               following.hasPrefix("• ") || (isFullPage && label.count <= 60 && !label.hasSuffix("。") && following.count >= 45) {
                let ordinal = label[match].prefix(while: \.isNumber)
                output.append("### \(ordinal). " + label[match.upperBound...])
                if isFullPage && next?.isEmpty == false { output.append("") }
            } else if label.hasPrefix("• ") {
                output.append("- " + label.dropFirst(2))
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func labeledTurns(_ lines: [String], prose: [Bool], assistantRole: String) -> [Transcript.Turn]? {
        let userLabels = ["あなた", "ユーザー", "user", "you", "you said", "あなたの発言", "質問"]
        let aiLabels = ["assistant", "ai", "アシスタント", "回答", "chatgpt", "chatgpt said", "claude", "gemini", "model", "モデル", "google ai studio", "google ai モード"]
        var headings: [(index: Int, speaker: String, body: String)] = []
        for index in lines.indices where prose[index] {
            var label = trim(lines[index])
            if label.hasPrefix("#") {
                let marks = label.prefix(while: { $0 == "#" })
                if (1...6).contains(marks.count), label.dropFirst(marks.count).first == " " {
                    label = trim(String(label.dropFirst(marks.count)))
                }
            }
            if label.hasPrefix("**"), let end = label.dropFirst(2).range(of: "**") {
                label = String(label.dropFirst(2)[..<end.lowerBound]) + String(label[end.upperBound...])
            }
            let boundary = label.firstIndex { $0 == ":" || $0 == "：" } ?? label.endIndex
            let name = trim(String(label[..<boundary])).lowercased()
            guard userLabels.contains(name) || aiLabels.contains(name) else { continue }
            let speaker = userLabels.contains(name) ? "user" : assistantRole
            let body = boundary == label.endIndex ? "" : trim(String(label[label.index(after: boundary)...]))
            headings.append((index, speaker, body))
        }
        guard let first = headings.first, first.speaker == "user",
              headings.contains(where: { $0.speaker == assistantRole }) else { return nil }
        let preamble = lines[..<first.index].joined(separator: "\n").trimmingCharacters(in: .newlines)
        var turns: [Transcript.Turn] = preamble.isEmpty ? [] : [.init(speaker: "text", markdown: preamble)]
        for (offset, heading) in headings.enumerated() {
            let end = offset + 1 < headings.count ? headings[offset + 1].index : lines.endIndex
            let formatted = lines[(heading.index + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .newlines)
            let body = [heading.body, formatted].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            turns.append(.init(speaker: heading.speaker, markdown: body))
        }
        return turns
    }

    private static func proseFlags(_ lines: [String]) -> [Bool] {
        var fence: (character: Character, length: Int)?
        return lines.map { line in
            let label = trim(line)
            if let first = label.first, first == "\u{60}" || first == "~" {
                let run = label.prefix { $0 == first }.count
                if let open = fence {
                    if first == open.character, run >= open.length, run == label.count { fence = nil }
                    return false
                }
                if run >= 3 { fence = (first, run); return false }
            }
            return fence == nil
        }
    }
}
