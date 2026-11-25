import Foundation
import NotionWriterCore

enum ChatShare {
    private static let payloadMarker = "window.__reactRouterContext.streamController.enqueue("
    private static let maximumBytes = 10 * 1024 * 1024
    private static let unreadable = WriterError.validation("ChatGPTのページから対話を読み取れませんでした。ブラウザで開き、内容をコピーして「全文を取り込む」に貼り付けてください。")

    static func load(_ link: ConversationLink) async throws -> Transcript {
        guard case .chatGPTShared(let id) = link else {
            throw WriterError.validation("非公開の対話はブラウザで開き、コピーした内容を「全文を取り込む」に貼り付けてください。")
        }
        let url = URL(string: "https://chatgpt.com/share/" + id)!
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: SameConversationRedirect(link), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        // Request the rendered conversation page, which embeds its visible timeline.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= Int64(maximumBytes), let final = http.url,
                  (try? ConversationLink(final)) == link else { throw unreadable }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw WriterError.validation("共有ページが大きすぎます。内容を分けて「全文を取り込む」に貼り付けてください。")
                }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8) else { throw unreadable }
            return try parse(html)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? WriterError { throw error }
            throw WriterError.validation("ChatGPTの共有ページに接続できませんでした。共有URLをブラウザで確認するか、「全文を取り込む」を使ってください。")
        }
    }

    static func parse(_ html: String, routePrefix: String = "routes/share.") throws -> Transcript {
        var cursor = html.startIndex
        while let marker = html.range(of: payloadMarker, range: cursor..<html.endIndex) {
            let suffix = html[marker.upperBound...].drop(while: \.isWhitespace)
            cursor = marker.upperBound
            guard suffix.first == "\"" else { continue }
            var escaped = false
            guard let end = suffix.indices.dropFirst().first(where: { index in
                if escaped { escaped = false; return false }
                if suffix[index] == "\\" { escaped = true; return false }
                return suffix[index] == "\""
            }) else { continue }
            cursor = html.index(after: end)
            guard let stream = try? JSONDecoder().decode(String.self, from: Data(suffix[...end].utf8)),
                  let table = try? JSONSerialization.jsonObject(with: Data(stream.utf8)) as? [Any],
                  let transcript = decode(table, routePrefix: routePrefix) else { continue }
            return transcript
        }
        throw unreadable
    }

    private static func decode(_ table: [Any], routePrefix: String) -> Transcript? {
        func value(_ reference: Any?) -> Any? {
            guard let index = reference as? Int, table.indices.contains(index) else { return nil }
            return table[index]
        }
        func record(_ reference: Any?) -> [String: Any] {
            guard let encoded = value(reference) as? [String: Any] else { return [:] }
            return encoded.reduce(into: [:]) { fields, item in
                guard item.key.hasPrefix("_"), let index = Int(item.key.dropFirst()),
                      let key = value(index) as? String else { return }
                fields[key] = item.value
            }
        }
        func visible(_ reference: Any?, depth: Int = 0) -> [String] {
            guard depth < 6 else { return [] }
            if let text = value(reference) as? String { return [text] }
            if let list = value(reference) as? [Any] { return list.flatMap { visible($0, depth: depth + 1) } }
            let fields = record(reference)
            return TranscriptFormatting.widgetFields.flatMap { visible(fields[$0], depth: depth + 1) }
        }

        let loader = record(record(0)["loaderData"])
        guard let route = loader.first(where: { $0.key.hasPrefix(routePrefix) })?.value else { return nil }
        let response = record(record(route)["serverResponse"])
        let conversation = record(response["data"])
        guard let timeline = value(conversation["linear_conversation"]) as? [Any] else { return nil }

        var citations: [String: String] = [:]
        for entry in timeline {
            let metadata = record(record(record(entry)["message"])["metadata"])
            for group in value(metadata["search_result_groups"]) as? [Any] ?? [] {
                for source in value(record(group)["entries"]) as? [Any] ?? [] {
                    let result = record(source)
                    let reference = record(result["ref_id"])
                    guard let turn = value(reference["turn_index"]) as? Int,
                          let kind = value(reference["ref_type"]) as? String,
                          let index = value(reference["ref_index"]) as? Int,
                          let address = value(result["url"]) as? String,
                          let url = PagePayload.bookmarkURL(address),
                          let label = (value(result["source_name"]) as? String)?.webText ?? url.host else { continue }
                    let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    citations["turn\(turn)\(kind)\(index)"] = "[\(escaped)](<\(url.absoluteString)>)"
                }
            }
        }

        let turns: [Transcript.Turn] = timeline.compactMap { entry in
            let message = record(record(entry)["message"])
            let author = record(message["author"])
            let metadata = record(message["metadata"])
            let content = record(message["content"])
            guard let role = value(author["role"]) as? String, role == "user" || role == "assistant",
                  value(metadata["is_visually_hidden_from_conversation"]) as? Bool != true,
                  value(message["channel"]) as? String != "analysis",
                  (value(message["recipient"]) as? String ?? "all") == "all" else { return nil }
            let parts = value(content["parts"]) as? [Any] ?? []
            let strings = parts.flatMap { visible($0) }
            let text = (strings.isEmpty ? TranscriptFormatting.widgetFields.flatMap { visible(content[$0]) } : strings)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : Transcript.Turn(speaker: role, markdown: text, citations: citations)
        }
        guard !turns.isEmpty else { return nil }
        return Transcript(turns: turns, title: value(conversation["title"]) as? String)
    }
}

private final class SameConversationRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    let link: ConversationLink

    init(_ link: ConversationLink) { self.link = link }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? ConversationLink(url)) == link else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
