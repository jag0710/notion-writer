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
    var submissionStarted: (() -> Void)?
    var saved: (() -> Void)?
    var submissionFailed: (() -> Void)?
    private let bookmarkPreview: @Sendable (URL) async -> BookmarkPreview?
    private(set) var recentSends: [SendRecord]
    private(set) var sendingID: UUID?
    private(set) var historyFeedback: String?
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
    init(qa: Bool, dataRoot: URL? = nil, exclusiveStore: Bool = false, clientOverride: (() throws -> NotionClient)? = nil,
         bookmarkPreview: @escaping @Sendable (URL) async -> BookmarkPreview? = { await BookmarkPreviews.shared.load($0) }) throws {
        self.clientOverride = clientOverride
        self.bookmarkPreview = bookmarkPreview
        self.qa = qa
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
        schema = try local.read(Schema.self, name: cacheName(storedConnection))
        draft = try local.read(Draft.self, name: local.draftName(for: storedConnection)) ?? Draft()
        recentSends = try SendRecord.load(from: local, destination: destination)
        if draft.submissionPending { status = pendingSaveMessage }
        else if let target = activeDestination { status = target.name + " · キャッシュを表示中" }
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
        let next = Array(([record] + otherRecords).sorted { $0.attemptedAt > $1.attemptedAt }.prefix(SendRecord.limit))
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
            let blocks = try PagePayload.bodyWithImages(record.draft)
            guard !record.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WriterError.validation("文章を入力してください。")
            }
            let api = try client()
            record.attemptedAt = Date()
            record.draft.submissionPending = false
            record.draft.pendingPageID = nil
            record.result = .failed
            record.pageID = nil
            try saveRecord(record)
            if tracksEditor { try writeEditor(record.draft) }
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
            _ = try PagePayload.prepare(draft: record.draft, schema: fresh, uploadedImages: placeholders, destination: target)

            let bookmarkURLs = blocks.compactMap(PagePayload.bookmarkURL(in:))
            let previews = try await prepareBookmarks(bookmarkURLs, using: api)
            var uploadedImages: [String: String] = [:]
            var uploadedDuringSave = previews.values.contains { $0.thumbnailUploadID != nil }
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
                                                   bookmarkPreviews: previews, destination: target)
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

    private func prepareBookmarks(_ urls: [URL], using api: NotionClient) async throws -> [URL: PagePayload.BookmarkPreview] {
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        var results: [URL: PagePayload.BookmarkPreview] = [:]
        guard !unique.isEmpty else { return results }
        status = "ブックマークを準備中…"
        updated?()
        let load = bookmarkPreview
        for start in stride(from: 0, to: unique.count, by: 4) {
            let batch = unique[start..<min(start + 4, unique.count)]
            let previews = await withTaskGroup(of: (URL, BookmarkPreview?).self) { group in
                for url in batch { group.addTask { (url, await load(url)) } }
                var previews: [URL: BookmarkPreview] = [:]
                for await (url, preview) in group { previews[url] = preview }
                return previews
            }
            for url in batch {
                guard let preview = previews[url] else { continue }
                var uploadID: String?
                if let thumbnail = preview.thumbnail {
                    do {
                        uploadID = try await api.uploadImage(data: thumbnail, filename: "bookmark-thumbnail.jpg", contentType: "image/jpeg")
                    } catch {
                        if case WriterError.api(429, _, let retry) = error {
                            // A thumbnail is optional. Honor Retry-After before sending the page.
                            guard let retry, (0...10).contains(retry) else { throw error }
                            try await Task.sleep(for: .seconds(retry))
                        }
                    }
                }
                results[url] = .init(title: preview.title, summary: preview.summary, thumbnailUploadID: uploadID)
            }
        }
        return results
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
