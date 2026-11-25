import Foundation
import NotionWriterCore

struct Transcript: Sendable {
    struct Turn: Sendable {
        let speaker: String
        let markdown: String
        let sourceCards: [[String]]

        init(speaker: String, markdown: String, sourceCards: [[String]] = []) {
            self.speaker = speaker
            self.markdown = markdown
            self.sourceCards = sourceCards
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
            var body = try MarkdownBody.blocks(turn.markdown)
            if !turn.sourceCards.isEmpty {
                body += try MarkdownBody.blocks("### 出典")
                body += turn.sourceCards.map(Self.sourceBlock)
            }
            guard let heading = turn.heading, !body.isEmpty else { return body }
            return try MarkdownBody.blocks("## " + heading) + body
        }
    }
}
