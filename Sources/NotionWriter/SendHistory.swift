import Foundation
import NotionWriterCore

struct SendRecord: Codable, Equatable, Identifiable {
    static let filename = "send-history"
    static let defaultLimit = 5
    static let limits = [5, 10, 20, 50, 100]

    enum Result: String, Codable {
        case failed, uncertain, sent

        var label: String {
            switch self {
            case .failed: return "未送信"
            case .uncertain: return "結果を要確認"
            case .sent: return "送信済み"
            }
        }
    }

    let id: UUID
    let destination: NotionDestination
    var attemptedAt: Date
    var draft: Draft
    var result: Result
    var pageID: String?

    var notionURL: URL? {
        guard let pageID, let uuid = UUID(uuidString: pageID) else { return nil }
        return URL(string: "https://www.notion.so/" + uuid.uuidString.replacingOccurrences(of: "-", with: ""))
    }

    static func load(from store: LocalStore, destination: NotionDestination?) throws -> [Self] {
        if let records = try store.read([Self].self, name: filename) { return records }
        guard let destination,
              let receipt = try? store.read(LegacyReceipt.self, name: "last-save-receipt"),
              receipt.dataSourceID == destination.dataSourceID,
              var draft = try? store.read(Draft.self, name: "last-saved-draft"),
              draft.pendingPageID == receipt.pageID else { return [] }
        let id = UUID()
        draft.submissionID = id
        draft.submissionPending = false
        draft.pendingPageID = nil
        return [Self(id: id, destination: destination, attemptedAt: receipt.savedAt, draft: draft,
                     result: .sent, pageID: receipt.pageID)]
    }

    private struct LegacyReceipt: Codable {
        let pageID: String
        let dataSourceID: String
        let savedAt: Date
    }
}
