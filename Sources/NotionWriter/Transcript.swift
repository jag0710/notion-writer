import Foundation
import NotionWriterCore

struct Transcript: Sendable {
    struct Turn: Sendable {
        let speaker: String
        let markdown: String

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

    func blocks() throws -> [[String: Any]] {
        try turns.flatMap { turn in
            let body = try MarkdownBody.blocks(turn.markdown)
            guard let heading = turn.heading, !body.isEmpty else { return body }
            return try MarkdownBody.blocks("## " + heading) + body
        }
    }
}
