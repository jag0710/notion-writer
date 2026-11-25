import AppKit
import NotionWriterCore

@MainActor final class AppState {
    private static let historyLimitKey = "sendHistoryLimit"

    let store: LocalStore
    private let preferences: UserDefaults
    private(set) var historyLimit: Int
    private(set) var activeDestination: NotionDestination?
    var connection: Connection? { activeDestination?.connection }
    var schema: Schema?
    var draft: Draft
    var status = "未接続 · サンプルタグを表示中 · 下書きはローカル保存"
    var busy = false
    var syncing = false
    private(set) var changingDestination = false
    private(set) var draftRevision = 0
    var importingImages = false
    var updated: (() -> Void)?
    var submissionStarted: (() -> Void)?
    var saved: (() -> Void)?
    var submissionFailed: (() -> Void)?
    private(set) var recentSends: [SendRecord]
    private var recentPropertiesByDestination: [String: [RecentPropertyInput]]

    var recentPropertyInputs: [RecentPropertyInput] {
        guard let connection else { return [] }
        let key = store.draftName(for: connection)
        if let inputs = recentPropertiesByDestination[key] { return inputs }
        return recentSends.lazy.filter { $0.destination.connection == connection }
            .prefix(RecentPropertyInput.limit).map { RecentPropertyInput(draft: $0.draft) }
    }
    private(set) var sendingID: UUID?
    private(set) var historyFeedback: String?
    private var aiStudioFiles: [String: Data]
    var aiStudioFileCount: Int { aiStudioFiles.count }
    private var pendingSave: DispatchWorkItem?
    private var generation = 0
    private let clientOverride: (() throws -> NotionClient)?
    private var retryNotBefore = Date.distantPast
    var display = DisplayPreferences.load()
    private(set) var clearShortcut = Shortcut.loadClear()
    var canClearDraft: Bool {
        !busy && !importingImages && !changingDestination && !draft.submissionPending && !draft.isEmpty
    }
    let qa: Bool
    var visibleSchema: Schema { schema ?? .demo }
    var sourceURLProperty: WriterProperty? {
        let properties = visibleSchema.urls
        return properties.first { $0.name.caseInsensitiveCompare("URL") == .orderedSame }
            ?? (properties.count == 1 ? properties.first : nil)
    }
    init(qa: Bool, dataRoot: URL? = nil, exclusiveStore: Bool = false, clientOverride: (() throws -> NotionClient)? = nil,
         preferences: UserDefaults = .standard) throws {
        self.clientOverride = clientOverride
        self.qa = qa
        self.preferences = preferences
        let savedLimit = preferences.integer(forKey: Self.historyLimitKey)
        historyLimit = SendRecord.limits.contains(savedLimit) ? savedLimit : SendRecord.defaultLimit
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Notion Writer"
        let base = if let dataRoot {
            dataRoot
        } else {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
                .appendingPathComponent(qa ? name + " Preview" : name, isDirectory: true)
        }
        let local = try LocalStore(root: base, exclusive: exclusiveStore)
        let destination = qa ? nil : try local.read(NotionDestination.self, name: "destination")
        try destination?.validateIDs()
        let storedConnection = destination?.connection
        store = local
        activeDestination = destination
        aiStudioFiles = (try? local.read([String: Data].self, name: AIStudioAccess.storeName)) ?? [:]
        schema = try local.read(Schema.self, name: cacheName(storedConnection))
        draft = try local.read(Draft.self, name: local.draftName(for: storedConnection)) ?? Draft()
        recentSends = Array(try SendRecord.load(from: local, destination: destination).prefix(historyLimit))
        recentPropertiesByDestination = (try? local.read([String: [RecentPropertyInput]].self,
                                                         name: RecentPropertyInput.filename)) ?? [:]
        if draft.submissionPending { status = pendingSaveMessage }
        else if let target = activeDestination { status = target.name + " · キャッシュを表示中" }
    }
    func setHistoryLimit(_ limit: Int) throws {
        guard !busy, SendRecord.limits.contains(limit), limit != historyLimit else { return }
        if recentSends.count > limit {
            let retained = Array(recentSends.prefix(limit))
            try store.write(retained, name: SendRecord.filename)
            recentSends = retained
        }
        historyLimit = limit
        preferences.set(limit, forKey: Self.historyLimitKey)
        updated?()
    }

    func setDisplay(_ value: DisplayPreferences) {
        display = value.normalized(); display.save(); updated?()
    }
    func edited() {
        if !draft.submissionPending { draft.submissionID = nil }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.flush() } catch { self.status = "下書き保存に失敗: " + error.localizedDescription; self.updated?() }
            }
        }
        pendingSave = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
    func flush() throws {
        pendingSave?.cancel(); pendingSave = nil
        try store.write(draft, name: store.draftName(for: connection))
    }
    func setClearShortcut(_ value: Shortcut) {
        clearShortcut = value
        value.saveClear()
    }
    func clearDraft() throws {
        guard canClearDraft else { return }
        let empty = Draft()
        try store.write(empty, name: store.draftName(for: connection))
        pendingSave?.cancel()
        pendingSave = nil
        draft = empty
        draftRevision += 1
        status = "入力をクリアしました"
        updated?()
    }
    func opened() {
        guard connection != nil, schema?.needsRefresh() ?? true else { return }
        Task { await sync() }
    }
    func client() throws -> NotionClient {
        guard let connection, let target = activeDestination else { throw WriterError.validation("接続先がありません。") }
        try target.validate(connection)
        if let clientOverride { return try clientOverride() }
        guard let token = try Keychain.read(target.databaseID), !token.isEmpty else {
            throw WriterError.validation("メニューバーの「設定」でNotionに接続してください。")
        }
        return NotionClient(token: token)
    }
    func sync() async {
        guard !busy, !syncing, let connection, let target = activeDestination, Date() >= retryNotBefore else { return }
        syncing = true; let current = generation
        status = "プロパティを同期中…"; updated?()
        do {
            let result = try await client().fetchSchema(destination: target)
            guard current == generation else { syncing = false; updated?(); return }
            try store.write(result, name: cacheName(connection)); schema = result
            if !busy { status = target.name + " · " + (result.viewName.map { $0 + "の順序で同期済み" } ?? "同期済み") }
        } catch {
            if !busy { applyError(error) }
        }
        syncing = false; updated?()
    }
    func connect(database: String, token: String, confirm: (NotionDestination) -> Bool) async throws {
        guard !busy, !syncing, !importingImages else { throw WriterError.validation("処理が終わってから接続を変更してください。") }
        let id = try Connection.parseID(database)
        guard let uuid = UUID(uuidString: id) else { throw WriterError.validation("保存先を確認できません。") }
        let view = URLComponents(string: database.trimmingCharacters(in: .whitespacesAndNewlines))?
            .queryItems?.first(where: { $0.name == "v" })?.value
        let viewID = try view.map { value in
            guard let id = UUID(uuidString: try Connection.parseID(value)) else {
                throw WriterError.validation("ビューのリンクを確認してください。")
            }
            return id
        }
        if qa { throw WriterError.validation("プレビューではNotionに接続できません。") }
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: String
        if secret.isEmpty { credential = try Keychain.read(id) ?? "" } else { credential = secret }
        guard !credential.isEmpty else { throw WriterError.validation("この保存先の接続トークンを入力してください。") }
        syncing = true; changingDestination = true; updated?()
        defer { syncing = false; changingDestination = false; updated?() }
        let api = try clientOverride?() ?? NotionClient(token: credential)
        let (target, result) = try await api.discoverDestination(databaseID: uuid, viewID: viewID)
        guard confirm(target) else { throw CancellationError() }
        let candidate = target.connection
        let sameSource = connection == candidate
        try flush()
        let destinationDraftName = store.draftName(for: candidate)
        var nextDraft: Draft
        if sameSource {
            nextDraft = draft
        } else if let existing = try store.read(Draft.self, name: destinationDraftName) {
            nextDraft = existing
        } else if connection == nil && !draft.submissionPending {
            nextDraft = draft
            nextDraft.tags = [:]
            nextDraft.urls = [:]
        } else {
            nextDraft = Draft()
        }
        if clientOverride == nil { try Keychain.save(credential, databaseID: id) }
        try store.write(result, name: cacheName(candidate))
        try store.write(nextDraft, name: destinationDraftName)
        try store.write(target, name: "destination")
        if !sameSource { draftRevision += 1 }
        generation += 1; activeDestination = target; schema = result; draft = nextDraft
        status = target.name + " · 接続済み"
    }
    func submit(onAccepted: (() -> Void)? = nil) async {
        guard !busy, !importingImages, !changingDestination else { return }
        guard !draft.submissionPending else { status = pendingSaveMessage; updated?(); return }
        guard let target = activeDestination else {
            status = "設定でNotionに接続してください。プレビューのタグは送信されません。"
            updated?()
            return
        }

        let id = draft.submissionID ?? UUID()
        if let result = recentSends.first(where: { $0.id == id })?.result, result != .failed {
            status = result == .sent ? "この入力はすでにNotionに保存されています。" : pendingSaveMessage
            updated?()
            return
        }
        var snapshot = draft
        snapshot.submissionID = id
        let record = SendRecord(id: id, destination: target, attemptedAt: Date(), draft: snapshot, result: .failed)
        await deliver(record, to: target, tracksEditor: true, onAccepted: onAccepted)
    }

    func canRetry(_ record: SendRecord) -> Bool {
        !busy && !importingImages && !changingDestination && record.result != .sent && connection == record.destination.connection
    }

    func retry(_ id: UUID, confirmedMissing: Bool) async {
        guard let record = recentSends.first(where: { $0.id == id }), canRetry(record), let target = activeDestination,
              record.result != .uncertain || confirmedMissing else { return }
        await deliver(record, to: target, tracksEditor: draft.submissionID == id, fromHistory: true)
    }

    private func saveRecord(_ record: SendRecord) throws {
        let otherRecords = recentSends.filter { $0.id != record.id }
        let next = Array(([record] + otherRecords).sorted { $0.attemptedAt > $1.attemptedAt }.prefix(historyLimit))
        try store.write(next, name: SendRecord.filename)
        recentSends = next
    }

    private func writeEditor(_ value: Draft) throws {
        try store.write(value, name: store.draftName(for: connection))
        pendingSave?.cancel()
        pendingSave = nil
        draft = value
    }

    private func deliver(_ source: SendRecord, to target: NotionDestination, tracksEditor: Bool,
                         fromHistory: Bool = false, onAccepted: (() -> Void)? = nil) async {
        var record = source
        var accepted = false
        defer {
            if accepted {
                sendingID = nil
                busy = false
            }
            updated?()
        }
        do {
            guard Date() >= retryNotBefore else { throw WriterError.validation("Notionの待機時間が終わってから送信してください。") }
            _ = try PagePayload.bodyWithImages(record.draft)
            guard !record.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WriterError.validation("文章を入力してください。")
            }
            let api = try client()
            record.attemptedAt = Date()
            record.draft.submissionPending = false
            record.draft.pendingPageID = nil
            record.result = .failed
            record.pageID = nil
            let previousInputs = recentPropertyInputs
            try saveRecord(record)
            if tracksEditor { try writeEditor(record.draft) }
            if !fromHistory {
                let input = RecentPropertyInput(draft: record.draft)
                var next = recentPropertiesByDestination
                next[store.draftName(for: target.connection)] = Array(([input] + previousInputs).prefix(RecentPropertyInput.limit))
                try store.write(next, name: RecentPropertyInput.filename)
                recentPropertiesByDestination = next
            }
            busy = true
            accepted = true
            sendingID = record.id
            historyFeedback = nil
            status = "保存中…"
            onAccepted?()
            submissionStarted?()
            updated?()

            var fresh = try await api.fetchSchema(destination: target)
            let placeholder = "00000000-0000-0000-0000-000000000000"
            let placeholders = Dictionary(record.draft.images.map { ($0.id, placeholder) }, uniquingKeysWith: { first, _ in first })
            _ = try PagePayload.prepare(draft: record.draft, schema: fresh, uploadedImages: placeholders,
                                        destination: target)

            var uploadedImages: [String: String] = [:]
            var uploadedDuringSave = false
            for index in record.draft.images.indices {
                let image = record.draft.images[index]
                if let id = image.reusableUploadID() {
                    uploadedImages[image.id] = id
                    continue
                }
                status = "画像を送信中 \(index + 1)/\(record.draft.images.count)…"
                updated?()
                let data = try Data(contentsOf: ImageAttachments.url(for: image, root: store.root), options: .mappedIfSafe)
                let id = try await api.uploadImage(data: data, filename: image.localFile, contentType: image.contentType)
                uploadedDuringSave = true
                record.draft.images[index].uploadID = id
                record.draft.images[index].uploadExpiresAt = Date().addingTimeInterval(50 * 60)
                uploadedImages[image.id] = id
                try saveRecord(record)
                if tracksEditor { try writeEditor(record.draft) }
            }
            if uploadedDuringSave { fresh = try await api.fetchSchema(destination: target) }
            let delivery = try PagePayload.prepare(draft: record.draft, schema: fresh, uploadedImages: uploadedImages,
                                                   destination: target)
            status = "ページを保存中…"
            updated?()
            try store.write(fresh, name: cacheName(connection))
            schema = fresh
            if tracksEditor {
                var pending = record.draft
                pending.submissionPending = true
                try writeEditor(pending)
            }
            record.result = .uncertain
            try saveRecord(record)
            let page: NotionClient.CreatedPage
            do {
                page = try await api.createPage(payload: delivery.create, destination: target)
            } catch {
                if case WriterError.uncertain = error { throw error }
                record.result = .failed
                try saveRecord(record)
                if tracksEditor { try writeEditor(record.draft) }
                throw error
            }

            record.pageID = page.id
            try saveRecord(record)
            if tracksEditor {
                var pending = draft
                pending.pendingPageID = page.id
                try writeEditor(pending)
            }
            for (index, payload) in delivery.continuation.enumerated() {
                status = "本文を送信中 \(index + 2)/\(delivery.continuation.count + 1)…"
                updated?()
                try await api.appendChildren(to: page, payload: payload)
            }
            record.result = .sent
            try saveRecord(record)
            if tracksEditor {
                try writeEditor(Draft())
                draftRevision += 1
            }
            status = "Notionに保存しました"
            saved?()
        } catch {
            applyError(error)
            if tracksEditor, draft.pendingPageID != nil { status = pendingSaveMessage + "\n" + status }
            if fromHistory { historyFeedback = status }
            if accepted { submissionFailed?() }
        }
    }

    var pendingSaveMessage: String {
        if recentSends.contains(where: { $0.id == draft.submissionID && $0.result == .sent }) {
            return "Notionへの送信は完了しています。「保存結果を確認…」から下書きを閉じられます。"
        }
        if draft.pendingPageID != nil {
            return "Notionにページは作成済みです。本文が途中まで保存されている可能性があります。下書きは保持しています。"
        }
        return WriterError.uncertain.localizedDescription
    }
    func addImageFiles(_ urls: [URL], insert: ([DraftImage]) throws -> Void) async {
        await importImages(count: urls.count, insert: insert) { root in
            var images: [DraftImage] = []
            for url in urls { images.append(try ImageAttachments.importFile(url, root: root)) }
            return images
        }
    }
    func addImageData(_ data: Data, insert: ([DraftImage]) throws -> Void) async {
        await importImages(count: 1, insert: insert) { root in [try ImageAttachments.importData(data, name: "貼り付けた画像.png", root: root)] }
    }
    private func importImages(count: Int, insert: ([DraftImage]) throws -> Void,
                              _ importer: @escaping @Sendable (URL) throws -> [DraftImage]) async {
        guard count > 0, !busy, !importingImages, !changingDestination, !draft.submissionPending else { return }
        guard draft.images.count + count <= 100 else { status = "画像は100枚までです。"; updated?(); return }
        importingImages = true; status = "画像を追加中…"; updated?()
        defer { importingImages = false; updated?() }
        do {
            let root = store.root
            let draftGeneration = generation
            let images = try await Task.detached(priority: .userInitiated) { try importer(root) }.value
            guard generation == draftGeneration else {
                throw WriterError.validation("接続先が変わりました。画像をもう一度追加してください。")
            }
            try insert(images)
            try flush()
            status = "画像を\(images.count)枚追加しました"
        } catch { status = error.localizedDescription }
    }
    func addWebContent(_ source: WebClip.Source, insert: (WebClip.Prepared) throws -> Void) async {
        guard !busy, !importingImages, !changingDestination, !draft.submissionPending else { return }
        importingImages = true
        status = "Webの内容を取り込み中…"
        updated?()
        defer { importingImages = false; updated?() }
        do {
            let root = store.root
            let availableImages = 100 - draft.images.count
            let content = try await Task.detached(priority: .userInitiated) {
                try await WebClip.prepare(source, root: root, availableImages: availableImages)
            }.value
            guard !content.blocks.isEmpty else { throw WriterError.validation("貼り付ける本文がありません。") }
            try insert(content)
            try flush()
            status = content.skippedImages == 0 ? "Webの内容を取り込みました"
                : "Webの内容を取り込みました。取得できなかった画像\(content.skippedImages)枚はリンクで残しています。"
        } catch {
            status = "Webの内容を取り込めませんでした。 " + error.localizedDescription
        }
    }

    func addVideo(_ url: URL, loadTitle: (YouTubeVideo) async throws -> String = { try await $0.loadTitle() },
                  canReplaceTitle: () -> Bool) async {
        guard !busy, !importingImages, !changingDestination, !draft.submissionPending else { return }
        let originalTitle = draft.title
        let originalURLProperty = sourceURLProperty?.id
        let originalURL = originalURLProperty.flatMap { draft.urls[$0] }
        importingImages = true
        status = "動画を取り込み中…"
        updated?()
        defer { importingImages = false; updated?() }

        do {
            let video = try YouTubeVideo(url: url)
            let title = try await loadTitle(video)
            try Task.checkCancellation()
            let urlProperty = sourceURLProperty?.id
            let currentURL = urlProperty.flatMap { draft.urls[$0] }
            guard canReplaceTitle(), draft.title == originalTitle, currentURL == originalURL,
                  (originalURLProperty == nil || originalURLProperty == urlProperty) else {
                throw WriterError.validation("タイトルまたはURLが編集中に変わりました。動画をもう一度取り込んでください。")
            }
            var next = draft
            next.title = title
            var missing: [String] = []
            if let urlProperty {
                next.urls[urlProperty] = video.sourceURL.absoluteString
            } else {
                missing.append("URL")
            }
            let matches = visibleSchema.tags.flatMap { property in
                property.options.filter { $0.name == "ネット収集情報" }.map { (property.id, $0.id) }
            }
            if matches.count == 1, let (propertyID, optionID) = matches.first {
                if !(next.tags[propertyID] ?? []).contains(optionID) {
                    next.tags[propertyID, default: []].append(optionID)
                }
            } else {
                missing.append("ネット収集情報")
            }
            next.submissionID = nil
            try writeEditor(next)
            status = missing.isEmpty ? "動画を取り込みました"
                : "動画を取り込みました。未入力: " + missing.joined(separator: "、")
        } catch {
            status = error.localizedDescription
        }
    }

    func aiStudioFile(for id: String) -> URL? {
        guard let bookmark = aiStudioFiles[id] else { return nil }
        return AIStudioAccess.resolve(bookmark)
    }

    func disconnectAIStudioFiles() throws {
        try store.write([String: Data](), name: AIStudioAccess.storeName)
        aiStudioFiles.removeAll()
        updated?()
    }

    func addConversation(_ source: ConversationImport.Source,
                         loadChat: @escaping @Sendable (ConversationLink) async throws -> Transcript,
                         insert: (ConversationImport.Prepared) throws -> Void) async -> Bool {
        guard !busy, !importingImages, !changingDestination, !draft.submissionPending else { return false }
        importingImages = true
        status = "内容を取り込み中…"
        updated?()
        defer { importingImages = false; updated?() }

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await ConversationImport.prepare(source, loadChat: loadChat)
            }.value
            try Task.checkCancellation()
            try insert(prepared)
            try flush()
            status = "本文に取り込みました"
            if let bookmark = prepared.aiStudioBookmark {
                var next = aiStudioFiles
                next[bookmark.id] = bookmark.data
                do {
                    try store.write(next, name: AIStudioAccess.storeName)
                    aiStudioFiles = next
                } catch {
                    status = "本文に取り込みました。ファイルへの接続は保存できませんでした。"
                }
            }
            return true
        } catch is CancellationError {
            status = "取り込みをキャンセルしました。"
            return false
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func applyError(_ error: Error) {
        if case WriterError.api(_, _, let retry) = error, let retry { retryNotBefore = Date().addingTimeInterval(TimeInterval(max(0, retry))) }
        status = error.localizedDescription
    }
    func resolvePending(discard: Bool) throws {
        guard !busy, !changingDestination else { return }
        guard draft.submissionPending else { return }
        var next = draft
        if var record = recentSends.first(where: { $0.id == draft.submissionID }) {
            guard discard || record.result != .sent else {
                throw WriterError.validation("この送信は完了しています。下書きを閉じる操作を選んでください。")
            }
            record.result = discard ? .sent : .failed
            if !discard { record.pageID = nil }
            try saveRecord(record)
        } else if discard {
            try store.write(draft, name: "confirmed-saved-draft")
        }
        if discard {
            next = Draft()
        } else {
            next.submissionPending = false
            next.pendingPageID = nil
        }
        try writeEditor(next)
        if discard { draftRevision += 1 }
        status = "保存結果を確認しました"; updated?()
    }
}
private func cacheName(_ connection: Connection?) -> String {
    "schema-" + (connection.map { $0.databaseID + "-" + $0.dataSourceID } ?? "offline")
}
