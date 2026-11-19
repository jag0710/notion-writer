import Foundation

public struct NotionClient {
    private let token: String
    private let session: URLSession
    public init(token: String, session: URLSession = .shared) { self.token = token; self.session = session }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", ambiguousWrite: Bool = false, version: String = "2025-09-03") async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if ambiguousWrite { throw WriterError.uncertain }; throw error }
        guard let http = response as? HTTPURLResponse else { throw WriterError.uncertain }
        guard (200..<300).contains(http.statusCode) else {
            if ambiguousWrite && (http.statusCode >= 500 || http.statusCode == 408) { throw WriterError.uncertain }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw WriterError.api(http.statusCode, json?["message"] as? String ?? "通信に失敗しました。", http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if ambiguousWrite { throw WriterError.uncertain }
            throw WriterError.validation("Notionの応答を読み取れませんでした。")
        }
        return json
    }
    public func discoverDestination(databaseID: UUID, viewID: UUID?) async throws -> (NotionDestination, Schema) {
        let id = databaseID.uuidString.lowercased()
        let database = try await fetchDatabase(id)
        let view: [String: Any]?
        if let viewID {
            view = try await request("views/" + viewID.uuidString.lowercased(), version: "2026-03-11")
        } else {
            view = nil
        }
        let sourceID: UUID?
        if let linkedSource = view?["data_source_id"] as? String {
            sourceID = UUID(uuidString: linkedSource)
        } else if database.sources.count == 1 {
            sourceID = UUID(uuidString: database.sources[0])
        } else {
            throw WriterError.validation("複数のデータソースがあります。保存したいビューのリンクをNotionからコピーしてください。")
        }
        guard let sourceID, database.sources.contains(sourceID.uuidString.lowercased()) else {
            throw WriterError.validation("ビューのデータソースが保存先に属していません。")
        }
        let target = NotionDestination(name: database.name, databaseID: databaseID, dataSourceID: sourceID, viewID: viewID)
        return (target, try await fetchProperties(for: target, view: view))
    }

    public func fetchSchema(destination: NotionDestination) async throws -> Schema {
        try destination.validateIDs()
        let database = try await fetchDatabase(destination.databaseID)
        guard database.name == destination.name, database.sources.contains(destination.dataSourceID) else {
            throw WriterError.validation("確認済みの保存先と一致しません。設定で接続を確認し直してください。")
        }
        let view: [String: Any]?
        if let viewID = destination.viewID {
            view = try await request("views/" + viewID, version: "2026-03-11")
        } else {
            view = nil
        }
        return try await fetchProperties(for: destination, view: view)
    }

    private func fetchDatabase(_ id: String) async throws -> (name: String, sources: [String]) {
        let db = try await request("databases/" + id)
        let name = (db["title"] as? [[String: Any]] ?? []).map { ($0["plain_text"] as? String) ?? (($0["text"] as? [String: Any])?["content"] as? String ?? "") }.joined()
        guard db["object"] as? String == "database", (db["id"] as? String)?.lowercased() == id,
              db["in_trash"] as? Bool != true, db["archived"] as? Bool != true,
              let sources = db["data_sources"] as? [[String: Any]] else {
            throw WriterError.validation("保存先データベースを確認できません。")
        }
        return (name, sources.compactMap { ($0["id"] as? String)?.lowercased() })
    }

    private func fetchProperties(for destination: NotionDestination, view: [String: Any]?) async throws -> Schema {
        let source = try await request("data_sources/" + destination.dataSourceID)
        guard source["object"] as? String == "data_source",
              (source["id"] as? String)?.lowercased() == destination.dataSourceID,
              let parent = source["parent"] as? [String: Any], parent["type"] as? String == "database_id",
              (parent["database_id"] as? String)?.lowercased() == destination.databaseID,
              source["in_trash"] as? Bool != true, source["archived"] as? Bool != true,
              let raw = source["properties"] as? [String: [String: Any]] else {
            throw WriterError.validation("保存先のデータソースを確認できません。")
        }
        let properties = raw.compactMap { key, value -> WriterProperty? in
            guard let id = value["id"] as? String, let type = value["type"] as? String else { return nil }
            let options = ((value["multi_select"] as? [String: Any])?["options"] as? [[String: Any]] ?? []).compactMap { option -> TagOption? in
                guard let id = option["id"] as? String, let name = option["name"] as? String else { return nil }
                return TagOption(id: id, name: name, color: option["color"] as? String ?? "default")
            }
            return WriterProperty(id: id, name: value["name"] as? String ?? key, type: type, options: options)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard properties.contains(where: { $0.type == "title" }) else { throw WriterError.validation("タイトルプロパティがありません。") }
        let schema = Schema(databaseID: destination.databaseID, dataSourceID: destination.dataSourceID,
                            databaseName: destination.name, properties: properties)
        if let view {
            guard (view["id"] as? String)?.lowercased() == destination.viewID else {
                throw WriterError.validation("保存先のビューが一致しません。")
            }
            return try ViewPropertyOrder.apply(view, to: schema)
        }
        return schema
    }
    public struct CreatedPage {
        public let id: String
        fileprivate init(id: String) { self.id = id }
    }

    public func createPage(payload: Data, destination: NotionDestination) async throws -> CreatedPage {
        try destination.validateIDs()
        guard let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              matchesParent(fields["parent"], destination: destination) else {
            throw WriterError.validation("作成リクエストの保存先が一致しません。送信を中止しました。")
        }
        let response = try await request("pages", method: "POST", body: payload, ambiguousWrite: true)
        guard response["object"] as? String == "page", let id = response["id"] as? String,
              UUID(uuidString: id) != nil, matchesParent(response["parent"], destination: destination) else {
            throw WriterError.uncertain
        }
        return CreatedPage(id: id)
    }

    private func matchesParent(_ value: Any?, destination: NotionDestination) -> Bool {
        guard let parent = value as? [String: String], parent["type"] == "data_source_id",
              parent["data_source_id"]?.lowercased() == destination.dataSourceID else { return false }
        return parent["database_id"].map { $0.lowercased() == destination.databaseID } ?? true
    }

    public func appendChildren(to page: CreatedPage, payload: Data) async throws {
        let response = try await request("blocks/" + page.id + "/children", method: "PATCH", body: payload, ambiguousWrite: true)
        guard response["object"] as? String == "list" else { throw WriterError.uncertain }
    }

    public func uploadImage(data: Data, filename: String, contentType: String) async throws -> String {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw WriterError.validation("画像は1枚20MBまでです。") }
        let metadata = try JSONSerialization.data(withJSONObject: ["mode": "single_part", "filename": filename, "content_type": contentType])
        let created = try await request("file_uploads", method: "POST", body: metadata)
        guard let id = created["id"] as? String, UUID(uuidString: id) != nil else { throw WriterError.validation("画像の送信先を作成できませんでした。") }
        let boundary = "NotionWriter-" + UUID().uuidString
        let safeName = filename.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: "\"", with: "_")
        var form = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n").utf8)
        form.append(data); form.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let uploaded = try await request("file_uploads/" + id + "/send", method: "POST", body: form, contentType: "multipart/form-data; boundary=" + boundary)
        guard uploaded["status"] as? String == "uploaded", uploaded["id"] as? String == id else { throw WriterError.validation("画像の送信が完了しませんでした。もう一度保存してください。") }
        return id
    }

}
