import Foundation
import NotionWriterCore

struct Transcript: Sendable {
    struct Turn: Sendable {
        let speaker: String
        let markdown: String
        let sourceCards: [[String]]
        let citations: [String: String]

        init(speaker: String, markdown: String, sourceCards: [[String]] = [], citations: [String: String] = [:]) {
            self.speaker = speaker
            self.markdown = markdown
            self.sourceCards = sourceCards
            self.citations = citations
        }

        var formattedMarkdown: String {
            speaker == "user" ? markdown : TranscriptFormatting.assistantMarkdown(markdown, citations: citations)
        }

        var heading: String? {
            switch speaker {
            case "text": return nil
            case "user": return "あなた"
            case "assistant": return "ChatGPT"
            case "model": return "Google AI Studio"
            default: return "AI"
            }
        }

    }

    let turns: [Turn]
    let title: String?

    init(turns: [Turn], title: String? = nil) {
        self.turns = turns
        self.title = title
    }

    func suggestedTitle(from blocks: [[String: Any]]) -> String {
        if let title = title?.webText { return Self.limitTitle(title) }
        let speakerLabels = Set(turns.compactMap(\.heading))
        for block in blocks {
            guard let type = block["type"] as? String, type != "code",
                  let content = block[type] as? [String: Any],
                  let runs = content["rich_text"] as? [[String: Any]] else { continue }
            let text = runs.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
            for line in text.split(whereSeparator: \.isNewline) {
                if let lead = String(line).webText, !speakerLabels.contains(lead) {
                    return Self.limitTitle(lead)
                }
            }
        }
        return "取り込んだ文章"
    }

    private static func limitTitle(_ text: String) -> String {
        let prefix = String(text.prefix(80))
        return prefix == text ? prefix : prefix + "…"
    }

    private static func sourceBlock(_ card: [String]) -> [String: Any] {
        let title = card.prefix(2).joined(separator: " — ")
        var runs: [[String: Any]] = PagePayload.chunks(title).map {
            ["type": "text", "text": ["content": $0], "annotations": ["bold": true]]
        }
        if card.count > 2 {
            runs += PagePayload.chunks("\n" + card.dropFirst(2).joined(separator: "\n")).map {
                ["type": "text", "text": ["content": $0]]
            }
        }
        return ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": runs]]
    }

    func blocks() throws -> [[String: Any]] {
        try turns.flatMap { turn in
            var body = try MarkdownBody.blocks(turn.formattedMarkdown)
            if !turn.sourceCards.isEmpty {
                body += try MarkdownBody.blocks("### 出典")
                body += turn.sourceCards.map(Self.sourceBlock)
            }
            guard let heading = turn.heading, !body.isEmpty else { return body }
            return try MarkdownBody.blocks("## " + heading) + body
        }
    }
}
