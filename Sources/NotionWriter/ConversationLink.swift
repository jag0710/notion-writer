import Foundation
import NotionWriterCore

enum ConversationLink: Equatable, Sendable {
    case chatGPTShared(String)
    case chatGPTPrivate(String)
    case aiStudio(String)

    init(_ url: URL) throws {
        let invalid = WriterError.validation("ChatGPTの会話・共有URL、またはGoogle AI Studioの対話URLを貼り付けてください。")
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil, parts.port == nil else {
            throw invalid
        }
        let path = parts.path.split(separator: "/")
        switch parts.host?.lowercased() {
        case "chatgpt.com", "chat.openai.com":
            guard path.count == 2, let uuid = UUID(uuidString: String(path[1])) else { throw invalid }
            let id = uuid.uuidString.lowercased()
            switch path[0] {
            case "share": self = .chatGPTShared(id)
            case "c": self = .chatGPTPrivate(id)
            default: throw invalid
            }
        case "aistudio.google.com":
            let id: String?
            if path.count == 2, path[0] == "prompts" {
                id = String(path[1])
            } else if path == ["app", "prompts"],
                      let state = parts.queryItems?.first(where: { $0.name == "state" })?.value,
                      let object = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any],
                      let ids = object["ids"] as? [String], ids.count == 1 {
                id = ids.first
            } else {
                id = nil
            }
            guard let id, (10...160).contains(id.utf8.count),
                  id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw invalid }
            self = .aiStudio(id)
        default:
            throw invalid
        }
    }
}
