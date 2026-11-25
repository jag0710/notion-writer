import AppKit
import NotionWriterCore

extension AppVerification {
    @MainActor static func verifyConversationImport(root: URL) async throws {
        let location = root.appendingPathComponent("conversation-import")
        let state = try Self.state(root: location)
        OfflineProtocol.conversationSchema = true
        defer { OfflineProtocol.conversationSchema = false }
        await state.sync()
        let writer = WriterWindow(state: state)
        let window = writer.window!
        let buttons = ["本文を追加", "画像を追加", "記事を取り込む", "動画を取り込む", "対話を取り込む", "全文を取り込む"]
        func containsActionRow(_ view: NSView) -> Bool {
            if let row = view as? NSStackView, row.orientation == .horizontal {
                let labels = row.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
                if Array(labels.prefix(buttons.count)) == buttons { return true }
            }
            return view.subviews.contains(where: containsActionRow)
        }
        try require(window.contentView.map(containsActionRow) == true, "Import actions are not on the same toolbar")
        let settings = SettingsWindow(state: state)
        let tabs = settings.window?.contentView?.subviews.compactMap { $0 as? NSTabView }.first
        try require(tabs?.tabViewItems.prefix(2).map(\.label) == ["Notionへの接続", "取り込み全般"],
                    "The import settings are not next to the Notion connection tab")

        state.draft.title = "既存タイトル"
        state.draft.urls = ["other": "https://example.com/other", "url": "https://example.com/previous"]
        writer.toggleBody()
        try require(writer.bodyEditor.pasteMarkdown("既存メモ\n\n- 元の項目"), "Could not prepare the existing note")
        let beforeCancel = state.draft
        window.orderFrontRegardless()
        writer.addFullText()
        guard let sheet = window.attachedSheet else { throw CheckFailure.failed("Full text did not open a sheet") }
        window.endSheet(sheet, returnCode: .cancel)
        window.orderOut(nil)
        await Task.yield()
        try require(state.draft == beforeCancel, "Cancelling the paste sheet changed the draft")

        let id = "aaaaaaa1-0000-4000-8000-000000000001"
        let shared = URL(string: "https://chatgpt.com/share/" + id + "?source=test")!
        let html = try sharedConversationFixture()
        let imported = await writer.importConversation(.url(shared)) { link in
            guard link == .chatGPTShared(id) else { throw CheckFailure.failed("Parsed wrong link") }
            return try ChatShare.parse(html)
        }
        try require(imported && state.draft.title == "既存タイトル" &&
                    state.draft.urls == ["other": "https://example.com/other", "url": shared.absoluteString], "Import changed title or the unrelated URL")
        let current = writer.bodyEditor.string
        func headingsHavePrototypeSpacing(_ editor: NSTextView) -> Bool {
            let range = (editor.string as NSString).range(of: "ChatGPT")
            guard range.location != NSNotFound,
                  let style = editor.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else { return false }
            return abs(style.paragraphSpacingBefore - 17 * writer.bodyEditor.baseFont.pointSize / 15) < 0.01
        }
        try require(headingsHavePrototypeSpacing(writer.bodyEditor) && state.draft.usesTranscriptLayout,
                    "The imported headings lost the prototype spacing")
        let reopened = try Self.state(root: location)
        let reopenedWriter = WriterWindow(state: reopened)
        reopenedWriter.toggleBody()
        try require(headingsHavePrototypeSpacing(reopenedWriter.bodyEditor), "Reopening the draft lost the transcript layout")
        let order = ["既存メモ", "元の項目", "あなた", "質問の本文", "ChatGPT", "元の見出し", "一番目", "二番目"]
        try require(containsInOrder(current, order), "Preview order or Markdown structure was lost")
        try require(current.contains("画像の説明") && current.contains("投票の質問") && current.contains("選択肢A") &&
                    !current.contains("INTERNAL_ONLY") && !current.contains("\u{E200}") && !current.contains("{\""),
                    "Widget text is missing, or internal content leaked into the editor")

        let beforeFailure = state.draft
        let failing = await writer.importConversation(.url(shared)) { _ in throw URLError(.notConnectedToInternet) }
        try require(!failing && state.draft == beforeFailure && writer.bodyEditor.string == current, "Failed fetch changed the editor")
        let cancelled = await writer.importConversation(.url(shared)) { _ in throw CancellationError() }
        try require(!cancelled && state.draft == beforeFailure && state.status.contains("キャンセル"),
                    "Cancelled fetch did not return the cancelled state or changed the draft")
        let pasted = await writer.importConversation(.fullText("前書き\n\n**User:** 行を残す\n\nAssistant: 別サービスの答え\n- [根拠](https://example.com/source)"))
        let plain = await writer.importConversation(.fullText("普通の記録\n改行を保持する\n\n最後の段落"))
        try require(pasted && plain && state.draft.urls["url"] == shared.absoluteString &&
                    containsInOrder(writer.bodyEditor.string, ["前書き", "あなた", "行を残す", "AI", "別サービスの答え", "普通の記録", "最後の段落"]),
                    "Full text import lost a preface, dialogue or ordinary text")

        OfflineProtocol.pageStatus = 200
        await state.submit()
        let payload = try conversationJSON(OfflineProtocol.pagePayload ?? Data())
        let blocks = payload["children"] as? [[String: Any]] ?? []
        let document = conversationText(blocks)
        let properties = payload["properties"] as? [String: [String: Any]]
        let links = conversationLinks(blocks)
        try require(state.draft.isEmpty && containsInOrder(document, order) &&
                    containsInOrder(document, ["動画の補足", "前書き", "別サービスの答え", "普通の記録\n改行を保持する", "最後の段落"]) &&
                    blocks.contains { $0["type"] as? String == "heading_3" } &&
                    blocks.contains { $0["type"] as? String == "bulleted_list_item" } &&
                    properties?["url"]?["url"] as? String == shared.absoluteString &&
                    properties?["other"]?["url"] as? String == "https://example.com/other" &&
                    links.contains("https://example.com/source"),
                    "Notion request lost the bookmark-free URL, paragraph breaks, links, or ordered content")
        let privateURL = URL(string: "https://chatgpt.com/c/" + id)!
        let aiURL = URL(string: "https://aistudio.google.com/prompts/abcdef12345")!
        let privateBrowser = await writer.importConversation(.fullText("You said: 質問\nChatGPT said: 回答", sourceURL: privateURL))
        try require(privateBrowser && state.draft.urls["url"] == privateURL.absoluteString &&
                    containsInOrder(writer.bodyEditor.string, ["あなた", "質問", "ChatGPT", "回答"]),
                    "Browser copy lost the private ChatGPT link or speaker")
        let aiBrowser = await writer.importConversation(.fullText("User:\n問い\nModel:\n答え", sourceURL: aiURL))
        try require(aiBrowser && state.draft.urls["url"] == aiURL.absoluteString &&
                    containsInOrder(writer.bodyEditor.string, ["あなた", "問い", "Google AI Studio", "答え"]),
                    "The file-free AI Studio flow lost the origin or speaker")
        print("PASS: AppKit import, preview spacing, browser copy, URL preservation and cancellation")
    }

    @MainActor static func verifyConversationSamples(_ args: [String], root: URL) async throws {
        guard (5...6).contains(args.count), let share = URL(string: args[0]), let personal = URL(string: args[1]),
              let aiStudio = URL(string: args[2]) else {
            throw CheckFailure.failed("Supply a shared URL, private URL, AI Studio URL, AI Studio file and full-page text")
        }
        OfflineProtocol.conversationSchema = true
        defer { OfflineProtocol.conversationSchema = false }

        func context(_ name: String) async throws -> (AppState, WriterWindow) {
            let state = try Self.state(root: root.appendingPathComponent(name, isDirectory: true))
            await state.sync()
            state.draft.title = "テスト用の既存タイトル"
            state.draft.body = "残す本文"
            return (state, WriterWindow(state: state))
        }

        func outgoing(_ state: AppState, expectedURL: URL?) throws -> [[String: Any]] {
            let delivery = try PagePayload.prepare(draft: state.draft, schema: state.visibleSchema, destination: TestDestination.target)
            let request = try conversationJSON(delivery.create)
            let properties = request["properties"] as? [String: [String: Any]]
            try require(properties?["url"]?["url"] as? String == expectedURL?.absoluteString, "URL property changed")
            return try ([delivery.create] + delivery.continuation).flatMap {
                try conversationJSON($0)["children"] as? [[String: Any]] ?? []
            }
        }

        let (chatState, chatWriter) = try await context("live-chat")
        let shared = await chatWriter.importConversation(.url(share))
        try require(shared, "Live shared page import: " + chatState.status)
        let shareBlocks = try outgoing(chatState, expectedURL: share)
        let shareText = conversationText(shareBlocks)
        try require(containsInOrder(shareText, ["残す本文", "あなた", "ChatGPT"]) &&
                    containsInOrder(chatWriter.bodyEditor.string, ["残す本文", "あなた", "ChatGPT"]) &&
                    chatState.draft.title == "テスト用の既存タイトル", "Live share lost author order or appended data")
        print("PASS: live ChatGPT shared URL through AppKit preview and outgoing URL/body (\(shareBlocks.count) blocks)")

        let beforePrivate = chatState.draft
        let privateOpened = await chatWriter.importConversation(.url(personal))
        if privateOpened {
            let privateBlocks = try outgoing(chatState, expectedURL: personal)
            try require(conversationText(privateBlocks).contains("ChatGPT"), "Private URL lost the transcript")
            print("PASS: private URL also returned a readable transcript")
        } else {
            try require(chatState.draft == beforePrivate && chatState.status.contains("全文を取り込む"),
                        "Private link failure did not preserve the draft or give instructions")
            print("PASS: app session could not read the private URL; the draft survived and fallback was offered")
        }

        let (aiState, aiWriter) = try await context("live-ai-studio")
        let file = URL(fileURLWithPath: args[3])
        let aiImported = await aiWriter.importConversation(.aiStudio(url: aiStudio, file: file, remember: true))
        try require(aiImported, "AI Studio file import: " + aiState.status)
        let aiBlocks = try outgoing(aiState, expectedURL: aiStudio)
        let aiSpeakers = aiBlocks.filter { $0["type"] as? String == "heading_2" }.map { conversationText([$0]) }
            .filter { ["あなた", "Google AI Studio"].contains($0) }
        try require(aiSpeakers == ["あなた", "Google AI Studio", "あなた", "Google AI Studio"] &&
                    containsInOrder(aiWriter.bodyEditor.string, ["あなた", "Google AI Studio", "あなた", "Google AI Studio"]),
                    "AI Studio failed to preserve the two exchanges")
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let chunked = source?["chunkedPrompt"] as? [String: Any]
        let chunks = chunked?["chunks"] as? [[String: Any]] ?? []
        let thoughts = chunks.filter { $0["isThought"] as? Bool == true }.compactMap { $0["text"] as? String }
        let edited = conversationText(aiBlocks)
        try require(!thoughts.isEmpty && thoughts.allSatisfy { text in
            let prefix = String(text.split(separator: "\n").first?.prefix(50) ?? "")
            return prefix.isEmpty || !edited.contains(prefix)
        }, "AI Studio included a thought chunk")

        if case .aiStudio(let promptID) = try ConversationLink(aiStudio) {
            let reloaded = try Self.state(root: aiState.store.root)
            try require(reloaded.aiStudioFileCount == 1 && reloaded.aiStudioFile(for: promptID)?.path == file.path,
                        "AI Studio file link was not restored")
            try reloaded.disconnectAIStudioFiles()
            try require(reloaded.aiStudioFile(for: promptID) == nil && FileManager.default.fileExists(atPath: file.path),
                        "Disconnect deleted the original or kept the file connection")
        } else {
            throw CheckFailure.failed("AI Studio file pairing used an unsupported URL")
        }
        print("PASS: specified AI Studio file through preview and outgoing data; two exchanges; thoughts excluded; link restored and disconnected")

        let (searchState, searchWriter) = try await context("live-search-copy")
        let text = try String(contentsOfFile: args[4], encoding: .utf8)
        let searchImported = await searchWriter.importConversation(.fullText(text))
        try require(searchImported, "Google Search full-page text import: " + searchState.status)
        let searchBlocks = try outgoing(searchState, expectedURL: nil)
        let searchText = conversationText(searchBlocks)
        let preview = searchWriter.bodyEditor.string
        let sourceCards = searchBlocks.filter { $0["type"] as? String == "bulleted_list_item" && conversationText([$0]).contains(" — ") }
        let speakers = searchBlocks.filter { $0["type"] as? String == "heading_2" }.map { conversationText([$0]) }
            .filter { ["あなた", "AI"].contains($0) }
        try require(speakers == ["あなた", "AI", "あなた", "AI"] && sourceCards.count == 6 &&
                    searchText.components(separatedBy: "（出典").count - 1 == 13 &&
                    preview.components(separatedBy: "（出典").count - 1 == 13 &&
                    containsInOrder(preview, ["あなた", "AI", "あなた", "AI", "BBCニュース"]) &&
                    !searchText.contains("メイン コンテンツにスキップ") && !searchText.contains("AI モードの回答が作成されました"),
                    "Google Search copy lost turns, inline sources, source cards or removed the wrong lines")
        try require(sourceCards.allSatisfy { block in conversationText([block]).contains("\n") },
                    "A source card lost its excerpt or the excerpt was separated from its title")
        if args.count == 6 {
            let approved = try String(contentsOfFile: args[5], encoding: .utf8)
            let prototypeText = conversationText(try MarkdownBody.blocks(approved))
            func words(_ value: String) -> [Substring] { value.split(whereSeparator: \.isWhitespace) }
            try require(words(conversationText(Array(searchBlocks.dropFirst()))) == words(prototypeText),
                        "The full sample changed text or order compared with the approved prototype")
        }
        print("PASS: full Google Search sample matches the prototype text; two exchanges, 13 inline citations and six grouped source cards")
    }

    private static func sharedConversationFixture() throws -> String {
        func message(_ role: String, _ parts: [Any], hidden: Bool = false) -> [String: Any] {
            ["message": ["author": ["role": role], "recipient": "all",
                         "metadata": ["is_visually_hidden_from_conversation": hidden], "content": ["parts": parts]]]
        }
        let widget = "\u{E200}poll\u{E202}{\"question\":\"投票の質問\",\"options\":[{\"label\":\"選択肢A\"}],\"internal\":\"INTERNAL_ONLY\"}\u{E201}"
        let timeline = [
            message("user", ["質問の本文"]),
            message("assistant", ["INTERNAL_ONLY"], hidden: true),
            message("assistant", ["### 元の見出し\n- 一番目\n- [二番目](https://example.com/second)", widget,
                                  ["alt_text": "画像の説明", "asset_pointer": "INTERNAL_ONLY"], "動画の補足"])
        ]
        var table: [Any] = []
        func reference(_ value: Any) -> Int {
            let index = table.count
            table.append(NSNull())
            if let fields = value as? [String: Any] {
                var record: [String: Int] = [:]
                for (key, entry) in fields { record["_" + String(reference(key))] = reference(entry) }
                table[index] = record
            } else if let items = value as? [Any] {
                table[index] = items.map(reference)
            } else {
                table[index] = value
            }
            return index
        }
        _ = reference(["loaderData": ["routes/share.fixture": ["serverResponse": ["data": ["linear_conversation": timeline]]]]])
        let data = try JSONSerialization.data(withJSONObject: table)
        let argument = try JSONEncoder().encode(String(decoding: data, as: UTF8.self))
        return "<script>window.__reactRouterContext.streamController.enqueue(\"[]\");</script>" +
            "<script>window.__reactRouterContext.streamController.enqueue(" + String(decoding: argument, as: UTF8.self) + ");</script>"
    }

    private static func containsInOrder(_ text: String, _ pieces: [String]) -> Bool {
        var suffix = text[...]
        for piece in pieces {
            guard let found = suffix.range(of: piece) else { return false }
            suffix = suffix[found.upperBound...]
        }
        return true
    }

    private static func conversationJSON(_ data: Data) throws -> [String: Any] {
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckFailure.failed("Conversation payload is not a JSON object")
        }
        return fields
    }

    private static func conversationRuns(_ block: [String: Any]) -> [[String: Any]] {
        let type = block["type"] as? String ?? ""
        let content = block[type] as? [String: Any]
        return (content?["rich_text"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? [String: Any] }
    }

    private static func conversationText(_ blocks: [[String: Any]]) -> String {
        blocks.map { conversationRuns($0).compactMap { $0["content"] as? String }.joined() }.joined(separator: "\n")
    }

    private static func conversationLinks(_ blocks: [[String: Any]]) -> [String] {
        blocks.flatMap(conversationRuns).compactMap { ($0["link"] as? [String: String])?["url"] }
    }
}
