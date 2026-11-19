import Foundation

public struct TagOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public init(id: String, name: String, color: String = "default") { self.id = id; self.name = name; self.color = color }
}
public struct WriterProperty: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var options: [TagOption]
    public init(id: String, name: String, type: String, options: [TagOption] = []) {
        self.id = id; self.name = name; self.type = type; self.options = options
    }
}
public struct Schema: Codable, Equatable, Sendable {
    public var databaseID: String
    public var dataSourceID: String
    public var databaseName: String
    public var properties: [WriterProperty]
    public var syncedAt: Date
    public var viewID: String?
    public var viewName: String?
    public init(databaseID: String, dataSourceID: String, databaseName: String, properties: [WriterProperty], syncedAt: Date = Date()) {
        self.databaseID = databaseID; self.dataSourceID = dataSourceID; self.databaseName = databaseName
        self.properties = properties; self.syncedAt = syncedAt
        self.viewID = nil; self.viewName = nil
    }
    public var tags: [WriterProperty] { properties.filter { $0.type == "multi_select" } }
    public var urls: [WriterProperty] { properties.filter { $0.type == "url" } }
    public func needsRefresh(now: Date = Date()) -> Bool { now.timeIntervalSince(syncedAt) >= 600 }
    public static let demo = Schema(databaseID: "demo", dataSourceID: "demo", databaseName: "操作プレビュー", properties: [
        .init(id: "title", name: "名前", type: "title"),
        .init(id: "tags", name: "タグ", type: "multi_select", options: [
            .init(id: "idea", name: "アイデア", color: "yellow"), .init(id: "writing", name: "創作メモ", color: "purple"),
            .init(id: "thought", name: "感想", color: "blue"), .init(id: "reference", name: "資料", color: "green")]),
        .init(id: "kind", name: "分野", type: "multi_select", options: [
            .init(id: "music", name: "音楽", color: "pink"), .init(id: "life", name: "日々のこと", color: "orange")])])
}
public enum BodyFormat: String, Codable, Sendable { case plainText, markdown }

public struct Draft: Codable, Equatable, Sendable {
    public var title = ""
    public var tags: [String: [String]] = [:]
    public var urls: [String: String] = [:]
    public var body = ""
    public var bodyFormat: BodyFormat = .markdown
    public var formattedBody: Data?
    // Persisted before POST. A crash or lost response must never silently resubmit.
    public var submissionPending = false
    public var pendingPageID: String?
    public var submissionID: UUID?
    public var images: [DraftImage] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case title, tags, urls, body, bodyFormat, formattedBody, submissionPending, pendingPageID, submissionID, images }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        tags = try values.decode([String: [String]].self, forKey: .tags)
        urls = try values.decode([String: String].self, forKey: .urls)
        body = try values.decode(String.self, forKey: .body)
        bodyFormat = try values.decodeIfPresent(BodyFormat.self, forKey: .bodyFormat) ?? (body.isEmpty ? .markdown : .plainText)
        formattedBody = try values.decodeIfPresent(Data.self, forKey: .formattedBody)
        submissionPending = try values.decode(Bool.self, forKey: .submissionPending)
        pendingPageID = try values.decodeIfPresent(String.self, forKey: .pendingPageID)
        submissionID = try values.decodeIfPresent(UUID.self, forKey: .submissionID)
        images = try values.decodeIfPresent([DraftImage].self, forKey: .images) ?? []
    }
    public var isEmpty: Bool { title.isEmpty && body.isEmpty && images.isEmpty && tags.values.allSatisfy(\.isEmpty) && urls.values.allSatisfy(\.isEmpty) }
}
public struct Connection: Codable, Equatable, Sendable {
    public var databaseID: String
    public var dataSourceID: String
    public init(databaseID: String, dataSourceID: String = "") { self.databaseID = databaseID; self.dataSourceID = dataSourceID }
    public static func parseID(_ input: String) throws -> String {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32}"
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = URL(string: source).flatMap { $0.host == nil ? nil : $0.path } ?? source
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.matches(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)).last,
              let range = Range(match.range, in: candidate) else { throw WriterError.validation("データベースのURLまたはIDを入力してください。") }
        let raw = String(candidate[range]).replacingOccurrences(of: "-", with: "")
        guard let uuid = UUID(uuidString: "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))") else {
            throw WriterError.validation("IDを読み取れませんでした。")
        }
        return uuid.uuidString.lowercased()
    }
}
public enum WriterError: LocalizedError {
    case validation(String)
    case api(Int, String, Int?)
    case uncertain
    public var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        case .api(let status, let message, let retry):
            return "Notionエラー (\(status)): \(message)" + (retry.map { "\n\($0)秒後にもう一度お試しください。" } ?? "")
        case .uncertain: return "保存結果を確認できません。Notionでページの有無を確認してください。下書きは保持しています。重複を避けるため、自動再送はしません。"
        }
    }
}

/// The database and data source explicitly approved in settings.
public struct NotionDestination: Codable, Equatable, Sendable {
    public let name: String
    public let databaseID: String
    public let dataSourceID: String
    public let viewID: String?

    public init(name: String, databaseID: UUID, dataSourceID: UUID, viewID: UUID? = nil) {
        self.name = name
        self.databaseID = databaseID.uuidString.lowercased()
        self.dataSourceID = dataSourceID.uuidString.lowercased()
        self.viewID = viewID?.uuidString.lowercased()
    }

    public var connection: Connection { Connection(databaseID: databaseID, dataSourceID: dataSourceID) }

    public func validateIDs() throws {
        guard UUID(uuidString: databaseID)?.uuidString.lowercased() == databaseID,
              UUID(uuidString: dataSourceID)?.uuidString.lowercased() == dataSourceID,
              viewID == nil || viewID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() == viewID else {
            throw WriterError.validation("保存先の識別子を確認できません。")
        }
    }

    public func validate(_ connection: Connection) throws {
        guard connection.databaseID.lowercased() == databaseID,
              connection.dataSourceID.isEmpty || connection.dataSourceID.lowercased() == dataSourceID else {
            throw WriterError.validation("確認済みの保存先 \(name) と一致しません。")
        }
    }

    public func validate(_ schema: Schema) throws {
        try validateIDs()
        try validate(Connection(databaseID: schema.databaseID, dataSourceID: schema.dataSourceID))
        guard schema.dataSourceID.lowercased() == dataSourceID else {
            throw WriterError.validation("保存先のデータソースを確認できませんでした。")
        }
        guard schema.databaseName == name else {
            throw WriterError.validation("Notionのデータベース名が \(name) と一致しません。")
        }
    }
}

public struct DraftImage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var localFile: String
    public var contentType: String
    public var byteCount: Int
    public var uploadID: String?
    public var uploadExpiresAt: Date?
    public init(id: String = UUID().uuidString, name: String, localFile: String, contentType: String, byteCount: Int) {
        self.id = id; self.name = name; self.localFile = localFile; self.contentType = contentType; self.byteCount = byteCount
    }
    public func reusableUploadID(now: Date = Date()) -> String? {
        guard let uploadID, let uploadExpiresAt, uploadExpiresAt.timeIntervalSince(now) > 60 else { return nil }
        return uploadID
    }
}

public enum ViewPropertyOrder {
    public static func apply(_ view: [String: Any], to schema: Schema) throws -> Schema {
        guard let parent = view["parent"] as? [String: Any], parent["database_id"] as? String == schema.databaseID,
              view["data_source_id"] as? String == schema.dataSourceID,
              let configuration = view["configuration"] as? [String: Any],
              let entries = configuration["properties"] as? [[String: Any]], !entries.isEmpty else {
            throw WriterError.validation("Notionのビューの並び順を取得できませんでした。設定から再同期してください。")
        }
        var ordered: [WriterProperty] = []
        var seen = Set<String>()
        for entry in entries {
            guard let identifier = entry["property_id"] as? String,
                  let property = schema.properties.first(where: { ($0.id.removingPercentEncoding ?? $0.id) == (identifier.removingPercentEncoding ?? identifier) || $0.name == identifier }),
                  seen.insert(property.id).inserted else { continue }
            ordered.append(property)
        }
        guard !ordered.isEmpty else { throw WriterError.validation("ビューのプロパティとDBの定義が一致しません。") }
        ordered += schema.properties.filter { !seen.contains($0.id) }
        var result = schema; result.properties = ordered; result.viewID = view["id"] as? String; result.viewName = view["name"] as? String
        return result
    }
}
