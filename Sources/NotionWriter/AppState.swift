import AppKit
import NotionWriterCore

@MainActor final class AppState {
    let store: LocalStore
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
    var saved: (() -> Void)?
    private var pendingSave: DispatchWorkItem?
    private var generation = 0
    private let clientOverride: (() throws -> NotionClient)?
    private var retryNotBefore = Date.distantPast
    var display = DisplayPreferences.load()
    let qa: Bool
    var visibleSchema: Schema { schema ?? .demo }
    init(qa: Bool, dataRoot: URL? = nil, clientOverride: (() throws -> NotionClient)? = nil) throws {
        self.clientOverride = clientOverride
        self.qa = qa
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent(qa ? "Notion Writer Preview" : "Notion Writer", isDirectory: true)
        store = try LocalStore(root: dataRoot ?? base)
        activeDestination = qa ? nil : try store.read(NotionDestination.self, name: "destination")
        try activeDestination?.validateIDs()
        let storedConnection = activeDestination?.connection
        schema = try store.read(Schema.self, name: cacheName(storedConnection))
        draft = try store.read(Draft.self, name: store.draftName(for: storedConnection)) ?? Draft()
        if draft.submissionPending { status = pendingSaveMessage }
        else if let target = activeDestination { status = target.name + " · キャッシュを表示中" }
    }
    func setDisplay(_ value: DisplayPreferences) {
        display = value.normalized(); display.save(); updated?()
    }
    func edited() {
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
            status = target.name + " · " + (result.viewName.map { $0 + "の順序で同期済み" } ?? "同期済み")
        } catch { applyError(error) }
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
    func submit() async {
        guard !busy, !importingImages, !changingDestination else { return }
        guard !draft.submissionPending else { status = pendingSaveMessage; updated?(); return }
        guard Date() >= retryNotBefore else { status = "Notionの待機時間が終わってから保存してください。"; updated?(); return }
        guard let connection, let target = activeDestination else { status = "設定でNotionに接続してください。プレビューのタグは送信されません。"; updated?(); return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "文章を入力してください。"; updated?(); return }
        busy = true; status = "保存中…"; updated?()
        defer { busy = false; updated?() }
        do {
            let api = try client()
            // Only metadata is fetched. Never read or query existing cards.
            let fresh = try await api.fetchSchema(destination: target)
            // Validate the entire save before opening uploads or creating a page.
            let placeholder = "00000000-0000-0000-0000-000000000000"
            if !draft.images.isEmpty {
                let placeholders = Dictionary(draft.images.map { ($0.id, placeholder) }, uniquingKeysWith: { first, _ in first })
                _ = try PagePayload.prepare(draft: draft, schema: fresh, uploadedImages: placeholders, destination: target)
            }
            var uploadedImages: [String: String] = [:]
            for index in draft.images.indices {
                if let id = draft.images[index].reusableUploadID() { uploadedImages[draft.images[index].id] = id; continue }
                status = "画像を送信中 \(index + 1)/\(draft.images.count)…"; updated?()
                let image = draft.images[index]
                let data = try Data(contentsOf: ImageAttachments.url(for: image, root: store.root), options: .mappedIfSafe)
                let id = try await api.uploadImage(data: data, filename: image.localFile, contentType: image.contentType)
                draft.images[index].uploadID = id; draft.images[index].uploadExpiresAt = Date().addingTimeInterval(50 * 60)
                uploadedImages[image.id] = id; try flush()
            }
            let delivery = try PagePayload.prepare(draft: draft, schema: fresh, uploadedImages: uploadedImages, destination: target)
            status = "ページを保存中…"; updated?()
            try store.write(fresh, name: cacheName(connection)); schema = fresh
            draft.submissionPending = true
            do { try flush() } catch { draft.submissionPending = false; throw error }
            let page: NotionClient.CreatedPage
            do { page = try await api.createPage(payload: delivery.create, destination: target) }
            catch {
                if case WriterError.uncertain = error { throw error }
                draft.submissionPending = false; try flush(); throw error
            }
            if !delivery.continuation.isEmpty {
                draft.pendingPageID = page.id
                try flush()
                for (index, payload) in delivery.continuation.enumerated() {
                    status = "本文を送信中 \(index + 2)/\(delivery.continuation.count + 1)…"
                    updated?()
                    try await api.appendChildren(to: page, payload: payload)
                }
            }
            // Keep a local receipt with the original draft if clearing fails.
            try store.write(draft, name: "last-saved-draft")
            try store.write(SaveReceipt(pageID: page.id, dataSourceID: fresh.dataSourceID, savedAt: Date()), name: "last-save-receipt")
            let empty = Draft()
            try store.write(empty, name: store.draftName(for: connection))
            draftRevision += 1; draft = empty; status = "Notionに保存しました"; saved?()
        } catch {
            applyError(error)
            if draft.pendingPageID != nil { status = pendingSaveMessage + "\n" + status }
        }
    }
    var pendingSaveMessage: String {
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
    private func applyError(_ error: Error) {
        if case WriterError.api(_, _, let retry) = error, let retry { retryNotBefore = Date().addingTimeInterval(TimeInterval(max(0, retry))) }
        status = error.localizedDescription
    }
    func resolvePending(discard: Bool) throws {
        guard !busy, !changingDestination else { return }
        var next = draft
        if discard {
            try store.write(draft, name: "confirmed-saved-draft")
            next = Draft()
        } else {
            next.submissionPending = false
            next.pendingPageID = nil
        }
        try store.write(next, name: store.draftName(for: connection))
        pendingSave?.cancel(); pendingSave = nil
        if discard { draftRevision += 1 }
        draft = next
        status = "保存結果を確認しました"; updated?()
    }
}
private func cacheName(_ connection: Connection?) -> String {
    "schema-" + (connection.map { $0.databaseID + "-" + $0.dataSourceID } ?? "offline")
}

private struct SaveReceipt: Codable {
    let pageID: String
    let dataSourceID: String
    let savedAt: Date
}
