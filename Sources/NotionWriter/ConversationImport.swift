import Foundation
import NotionWriterCore

enum ConversationImport {
    enum Source: Sendable {
        case url(URL)
        case fullText(String, sourceURL: URL? = nil)
        case aiStudio(url: URL, file: URL, remember: Bool)
    }

    struct Prepared: @unchecked Sendable {
        let blocks: [[String: Any]]
        let url: URL?
        let aiStudioBookmark: AIStudioAccess.Bookmark?
    }

    static func prepare(_ source: Source, loadChat: @Sendable (ConversationLink) async throws -> Transcript = { try await ChatShare.load($0) }) async throws -> Prepared {
        let transcript: Transcript
        let url: URL?
        var bookmark: AIStudioAccess.Bookmark?
        switch source {
        case .url(let original):
            let link = try ConversationLink(original)
            if case .aiStudio = link {
                throw WriterError.validation("ブラウザでGoogle AI Studioの対話を開き、「全文を取り込む」に貼り付けてください。")
            }
            transcript = try await loadChat(link)
            url = original
        case .fullText(let text, let sourceURL):
            guard text.utf8.count <= 10 * 1024 * 1024 else {
                throw WriterError.validation("貼り付ける内容を分けて、もう一度取り込んでください。")
            }
            let role: String
            switch sourceURL.flatMap({ try? ConversationLink($0) }) {
            case .chatGPTPrivate, .chatGPTShared: role = "assistant"
            case .aiStudio: role = "model"
            case nil: role = "ai"
            }
            transcript = try FullTextImport.transcript(text, assistantRole: role)
            url = sourceURL
        case .aiStudio(let original, let file, let remember):
            guard case .aiStudio(let id) = try ConversationLink(original) else {
                throw WriterError.validation("Google AI Studioの対話URLを確認してください。")
            }
            transcript = try AIStudioAccess.read(file: file)
            if remember, let data = AIStudioAccess.makeBookmark(for: file) {
                bookmark = AIStudioAccess.Bookmark(id: id, data: data)
            }
            url = original
        }
        try Task.checkCancellation()
        let blocks = try transcript.blocks()
        guard !blocks.isEmpty else { throw WriterError.validation("取り込める本文がありません。") }
        return Prepared(blocks: blocks, url: url, aiStudioBookmark: bookmark)
    }
}

enum AIStudioAccess {
    static let storeName = "ai-studio-files"

    struct Bookmark: Sendable {
        let id: String
        let data: Data
    }

    static func makeBookmark(for file: URL) -> Data? {
        (try? file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
            ?? (try? file.bookmarkData(options: .minimalBookmark))
    }

    static func resolve(_ data: Data) -> URL? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        let file = (try? URL(resolvingBookmarkData: data, options: options.union(.withSecurityScope),
                             relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: options,
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        return stale ? nil : file
    }

    static func read(file: URL) throws -> Transcript {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let invalid = WriterError.validation("Google AI Studioの対話データを読み取れませんでした。Google Driveに保存された対話ファイルを選び直すか、「全文を取り込む」を使ってください。")
        guard file.isFileURL, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { throw invalid }
        defer { try? handle.close() }
        let limit = 10 * 1024 * 1024
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = root["chunkedPrompt"] as? [String: Any],
              let chunks = prompt["chunks"] as? [[String: Any]] else { throw invalid }

        let turns = chunks.compactMap { chunk -> Transcript.Turn? in
            guard let role = chunk["role"] as? String, role == "user" || role == "model",
                  chunk["isThought"] as? Bool != true else { return nil }
            let parts = chunk["parts"] as? [[String: Any]] ?? []
            let plain = chunk["text"] as? String
            let text: String
            if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = plain
            } else {
                text = parts.filter { $0["isThought"] as? Bool != true && $0["thought"] as? Bool != true }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Transcript.Turn(speaker: role, markdown: text)
        }
        guard !turns.isEmpty else { throw invalid }
        return Transcript(turns: turns)
    }
}
