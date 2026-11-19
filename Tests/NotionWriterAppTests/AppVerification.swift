import AppKit
import NotionWriterCore

enum TestDestination {
    static let databaseID = "aaaaaaaa-0000-4000-8000-000000000001"
    static let dataSourceID = "aaaaaaaa-0000-4000-8000-000000000002"
    static let viewID = "aaaaaaaa-0000-4000-8000-000000000003"
    static let target = NotionDestination(name: "Test Notes", databaseID: UUID(uuidString: databaseID)!,
                                          dataSourceID: UUID(uuidString: dataSourceID)!)
    static let withView = NotionDestination(name: target.name, databaseID: UUID(uuidString: databaseID)!,
                                           dataSourceID: UUID(uuidString: dataSourceID)!, viewID: UUID(uuidString: viewID)!)

    static func database(_ target: NotionDestination = target, sources: [String]? = nil) -> [String: Any] {
        ["object": "database", "id": target.databaseID, "title": [["plain_text": target.name]],
         "data_sources": (sources ?? [target.dataSourceID]).map { ["id": $0] }]
    }

    static func source(_ target: NotionDestination = target, properties: [String: [String: Any]]) -> [String: Any] {
        ["object": "data_source", "id": target.dataSourceID, "parent": ["type": "database_id", "database_id": target.databaseID],
         "properties": properties]
    }
}

private enum CheckFailure: Error { case failed(String) }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure.failed(message) }
}
private final class OfflineProtocol: URLProtocol {
    static var alternateDestination: NotionDestination?
    static var pageStatus = 400
    static var pageRequests = 0
    static var schemaRequests = 0
    static var rejectUpload = false
    static var pagePayload: Data?
    static var pageParentOverride: [String: String]?
    static var moveAfterFirstAppend = false
    static var databaseChangesAfterUpload = false
    static let pageID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    static let uploadIDs = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]
    static var uploadCount = 0
    static var appendStatus = 200
    static var appendPaths: [String] = []
    static var delay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var value: [String: Any] = [:]
        var status = 200
        if path.contains("databases/") {
            Self.schemaRequests += 1
            let target = Self.alternateDestination.flatMap { path.hasSuffix($0.databaseID) ? $0 : nil } ?? TestDestination.target
            value = TestDestination.database(target)
            if Self.databaseChangesAfterUpload && Self.uploadCount > 0 {
                value["data_sources"] = [["id": UUID().uuidString]]
            }
        } else if path.contains("data_sources/") {
            let target = Self.alternateDestination.flatMap { path.hasSuffix($0.dataSourceID) ? $0 : nil } ?? TestDestination.target
            value = TestDestination.source(target, properties: ["名前": ["id": "title", "name": "名前", "type": "title"]])
        } else if path.contains("views/") {
            let target = Self.alternateDestination.flatMap { path.hasSuffix($0.viewID ?? "") ? $0 : nil } ?? TestDestination.withView
            value = ["id": target.viewID!, "name": "閲覧", "parent": ["database_id": target.databaseID],
                     "data_source_id": target.dataSourceID, "configuration": ["properties": [["property_id": "title"]]]]
        } else if path == "/v1/file_uploads", Self.rejectUpload {
            status = 403
            value = ["object": "error", "code": "restricted_resource", "status": 403]
        } else if path == "/v1/file_uploads", Self.uploadCount < Self.uploadIDs.count {
            value = ["id": Self.uploadIDs[Self.uploadCount]]
            Self.uploadCount += 1
        } else if path.hasPrefix("/v1/file_uploads/"), path.hasSuffix("/send") {
            value = ["id": request.url!.deletingLastPathComponent().lastPathComponent, "status": "uploaded"]
        } else if path == "/v1/pages" {
            Self.pageRequests += 1; Self.pagePayload = request.httpBody ?? readBody(request.httpBodyStream)
            status = Self.pageStatus
            let fields = Self.pagePayload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var parent = fields?["parent"] as? [String: String] ?? [:]
            let destination = Self.alternateDestination.flatMap { $0.dataSourceID == parent["data_source_id"] ? $0 : nil }
            parent["database_id"] = (destination ?? TestDestination.target).databaseID
            if let override = Self.pageParentOverride { parent = override }
            value = status == 200 ? ["object": "page", "id": Self.pageID, "parent": parent] :
                ["object": "error", "code": "validation_error", "status": status, "message": "offline verification rejection"]
        } else if path == "/v1/pages/" + Self.pageID, request.httpMethod == "GET" {
            var parent = ["type": "data_source_id", "data_source_id": TestDestination.dataSourceID,
                          "database_id": TestDestination.databaseID]
            if Self.moveAfterFirstAppend && !Self.appendPaths.isEmpty { parent["database_id"] = UUID().uuidString }
            value = ["object": "page", "id": Self.pageID, "parent": parent]
        } else if request.httpMethod == "PATCH" && path.hasSuffix("/children") {
            Self.appendPaths.append(path)
            status = Self.appendStatus
            let body = request.httpBody ?? readBody(request.httpBodyStream) ?? Data()
            let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            value = ["object": "list", "results": fields?["children"] ?? []]
        } else {
            status = 500; value = ["message": "Unexpected verification request"]
        }
        if Self.delay > 0 { Thread.sleep(forTimeInterval: Self.delay) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

@main struct AppVerification {
    @MainActor static func state(root: URL, destination: NotionDestination = TestDestination.target,
                                preview: @escaping @Sendable (URL) async -> BookmarkPreview? = { _ in nil }) throws -> AppState {
        let store = try LocalStore(root: root)
        try store.write(destination, name: "destination")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineProtocol.self]
        let api = NotionClient(token: "offline-test-only", session: URLSession(configuration: config))
        return try AppState(qa: false, dataRoot: root, clientOverride: { api }, bookmarkPreview: preview)
    }
    @MainActor static func main() async {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotionWriterVerification-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let state = try state(root: root)
            state.draft.title = "日本語\n\n絵文字🎷\n"
            state.draft.body = "## 見出し\n- **太字**"
            state.draft.bodyFormat = .markdown
            try state.flush()
            let original = state.draft
            let reloaded = try Self.state(root: root)
            try require(reloaded.draft == original, "Restart failed to restore draft or format")
            print("PASS: draft restart restores Japanese, blank lines, and Markdown source/format")

            OfflineProtocol.pageStatus = 400; OfflineProtocol.pageRequests = 0
            await state.submit()
            var rejected = state.draft
            rejected.submissionID = nil
            try require(rejected == original && !state.busy, "Rejected save changed draft")
            try require(state.recentSends.first?.result == .failed && state.recentSends.first?.draft == state.draft,
                        "Rejected save was not recoverable from history")
            try require(OfflineProtocol.pageRequests == 1 && !state.draft.submissionPending, "Rejected save state incorrect")
            try require(try Self.state(root: root).draft == state.draft, "Rejected save was not preserved on disk")
            print("PASS: failed save preserves draft in memory and on disk")

            OfflineProtocol.pageStatus = 503; OfflineProtocol.pageRequests = 0
            await state.submit()
            try require(state.draft.submissionPending && !state.busy, "Uncertain save not protected")
            let protected = state.draft
            await state.submit()
            try require(OfflineProtocol.pageRequests == 1 && state.draft == protected, "Uncertain save was resubmitted")
            try require(try Self.state(root: root).draft.submissionPending, "Uncertain save lost protection on restart")
            try state.resolvePending(discard: false)
            print("PASS: uncertain save blocks duplicate submission, including after restart")

            OfflineProtocol.pageStatus = 200; OfflineProtocol.pageRequests = 0; OfflineProtocol.delay = 0.01
            var savedCount = 0; state.saved = { savedCount += 1 }
            async let first: Void = state.submit()
            async let second: Void = state.submit()
            _ = await (first, second)
            OfflineProtocol.delay = 0
            try require(OfflineProtocol.pageRequests == 1 && savedCount == 1, "Concurrent save created duplicate pages")
            try require(state.draft.isEmpty && !state.draft.submissionPending, "Successful save did not clear draft")
            try require(state.recentSends.count == 1 && state.recentSends.first?.result == .sent &&
                        state.recentSends.first?.draft.body == original.body, "Save recovery draft missing or retry duplicated history")
            print("PASS: concurrent save submits once and retains the saved draft receipt")

            var source = original
            source.body = (0..<215).map { "- \($0)" }.joined(separator: "\n")
            state.draft = source; OfflineProtocol.pageRequests = 0
            await state.submit()
            let target = "/v1/blocks/" + OfflineProtocol.pageID + "/children"
            try require(OfflineProtocol.pageRequests == 1 && OfflineProtocol.appendPaths == [target, target], "Long body was not written in order to the same page")
            try require(state.draft.isEmpty, "Successful batched write left a draft")
            print("PASS: over 100 blocks are appended to the one newly created page")

            state.draft = source
            OfflineProtocol.pageRequests = 0; OfflineProtocol.appendPaths = []
            OfflineProtocol.moveAfterFirstAppend = true
            await state.submit()
            OfflineProtocol.moveAfterFirstAppend = false
            let moved = try Self.state(root: root).draft
            try require(OfflineProtocol.pageRequests == 1 && OfflineProtocol.appendPaths == [target],
                        "Writer patched a page after it moved to another database")
            try require(moved.body == source.body && moved.submissionPending && moved.pendingPageID == OfflineProtocol.pageID,
                        "Moving the page lost the draft or its recovery link")
            print("PASS: moving a page between continuation requests stops further writes")

            state.draft = source; OfflineProtocol.pageRequests = 0; OfflineProtocol.appendPaths = []
            OfflineProtocol.appendStatus = 503
            await state.submit()
            let pending = try Self.state(root: root).draft
            try require(pending.body == source.body && pending.submissionPending && pending.pendingPageID == OfflineProtocol.pageID, "Partial write lost data or receipt")
            await state.submit()
            try require(OfflineProtocol.pageRequests == 1 && OfflineProtocol.appendPaths == [target], "Partial write triggered a duplicate request")
            print("PASS: partial save retains the source and destination and blocks duplicate writes")

            state.draft = source
            OfflineProtocol.pageRequests = 0; OfflineProtocol.appendPaths = []; OfflineProtocol.appendStatus = 200
            OfflineProtocol.pageParentOverride = ["type": "data_source_id", "data_source_id": TestDestination.dataSourceID,
                                                  "database_id": UUID().uuidString]
            await state.submit()
            try require(OfflineProtocol.pageRequests == 1 && OfflineProtocol.appendPaths.isEmpty, "Writer appended to a page with a different parent")
            try require(state.draft.submissionPending && state.draft.body == source.body, "Unexpected page parent cleared the draft")
            await state.submit()
            try require(OfflineProtocol.pageRequests == 1, "Unexpected page parent triggered a retry")
            OfflineProtocol.pageParentOverride = nil
            print("PASS: unexpected returned parent stops continuation and retry")

            let damaged = try Self.state(root: root.appendingPathComponent("damaged"))
            damaged.draft = original
            damaged.draft.formattedBody = Data("unreadable".utf8)
            damaged.draft.images = [DraftImage(name: "lost.png", localFile: UUID().uuidString + ".png", contentType: "image/png", byteCount: 1)]
            let damagedSnapshot = damaged.draft
            let damagedWriter = WriterWindow(state: damaged)
            damagedWriter.toggleBody()
            try require(!damagedWriter.bodyEditor.isEditable && !damagedWriter.imageButton.isEnabled, "A damaged body can be edited")
            damagedWriter.bodyEditor.insertText("追記", replacementRange: NSRange(location: 0, length: 0))
            try require(damaged.draft == damagedSnapshot, "A damaged draft lost format or images")
            let requestsBefore = OfflineProtocol.pageRequests
            await damaged.submit()
            try require(damaged.draft == damagedSnapshot && OfflineProtocol.pageRequests == requestsBefore, "A damaged draft was sent")
            print("PASS: damaged formatted draft retains body and image references")


            if CommandLine.arguments.count > 1 {
                let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
                let body = try String(contentsOf: fixture, encoding: .utf8)
                let blocks = try MarkdownBody.blocks(body)
                try require(blocks.filter { $0["type"] as? String == "table" }.count == 2, "Fixture lost comparison tables")
                let preview = MarkdownPreview.render(body, font: .systemFont(ofSize: 16))
                try require(preview.string.contains("搭載メモリ容量の比較") && preview.string.contains("メモリ帯域幅") && !preview.string.contains("**"), "Fixture preview missing styled content")
                var sample = original
                sample.body = body
                let delivery = try PagePayload.prepare(draft: sample, schema: state.visibleSchema, destination: TestDestination.target)
                print("PASS: supplied AI-answer fixture yields \(blocks.count) blocks and \(delivery.continuation.count + 1) request(s)")
            }

            state.draft = Draft(); state.schema = .demo
            state.draft.body = "復元される本文"
            let writer = WriterWindow(state: state)
            try require(writer.bodyScroll.isHidden && writer.bodyEditor.string.isEmpty, "A body draft was prepared while collapsed")
            writer.toggleBody()
            try require(writer.bodyEditor.string.contains("復元される本文"), "The old body was not loaded on first use")
            writer.toggleBody()
            let literalTitle = "# 見出し\n**太字** /gray"
            writer.titleEditor.insertText(literalTitle, replacementRange: NSRange(location: 0, length: 0))
            try require(!writer.titleEditor.isRichText && state.draft.title == literalTitle, "Title handled Markdown or slash commands")
            state.draft.body = ""
            writer.update()
            writer.toggleBody()
            let editor = writer.bodyEditor
            try require(editor.isEditable && writer.bodyScroll.frame.height > 245, "Expanded body is not directly editable or large enough")
            let rich = "# 見出し\n\n**強調**と[リンク](https://example.com)\n\n| 項目 | 値 |\n| --- | --- |\n| 元のセル | 32GB |"
            try require(editor.pasteMarkdown(rich), "Markdown paste failed")
            try require(editor.string.contains("見出し") && !editor.string.contains("**"), "Markdown markers remained in display")
            let cell = (editor.string as NSString).range(of: "元のセル")
            editor.setSelectedRange(cell)
            editor.insertText("編集したセル", replacementRange: cell)
            let edited = try PagePayload.bodyBlocks(state.draft)
            try require(edited.compactMap { $0["type"] as? String } == ["heading_1", "paragraph", "table"], "Editing dropped a block")
            let data = try JSONSerialization.data(withJSONObject: edited)
            let json = String(decoding: data, as: UTF8.self)
            try require(json.contains("編集したセル") && json.contains("bold") && json.contains("example.com"), "Edit lost text, inline formatting or link")
            try state.flush()
            let restored = try Self.state(root: root).draft
            try require(restored.formattedBody == state.draft.formattedBody, "Edited formatting did not survive restart")

            let commandEditor = BodyEditor()
            commandEditor.isRichText = true
            for part in ["#", " ", "編", "集"] {
                commandEditor.insertText(part, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            commandEditor.insertNewline(nil)
            for part in ["*", "*", "太", "字", "*", "*"] {
                commandEditor.insertText(part, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            let shortcutBlocks = BodyDocument.read(commandEditor.textStorage!).blocks
            try require(shortcutBlocks.compactMap { $0["type"] as? String } == ["heading_1", "paragraph"], "Heading shortcut split or the next paragraph failed")
            let shortcutData = try JSONSerialization.data(withJSONObject: shortcutBlocks)
            try require(String(decoding: shortcutData, as: UTF8.self).contains("bold") && commandEditor.string == "編集\n太字", "Inline shortcut did not apply in place")
            print("PASS: native body editing preserves headings, inline styling, tables, links and the edited draft")

            let colorEditor = BodyEditor()
            colorEditor.isRichText = true
            func type(_ value: String) {
                colorEditor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            for value in ["-", " ", "普通の箇条書き"] { type(value) }
            let firstItem = (colorEditor.string as NSString).range(of: "普通の箇条書き")
            try require(colorEditor.textStorage?.attribute(.foregroundColor, at: firstItem.location, effectiveRange: nil) as? NSColor == WriterStyle.ink, "List marker colored the first item text")
            colorEditor.insertNewline(nil)
            type("次の項目")
            let nextItem = (colorEditor.string as NSString).range(of: "次の項目")
            try require(colorEditor.textStorage?.attribute(.foregroundColor, at: nextItem.location, effectiveRange: nil) as? NSColor == WriterStyle.ink, "List continuation text changed color")
            type(" /gray")
            colorEditor.applyColor("gray_background", replacing: (colorEditor.string as NSString).range(of: "/gray"))
            type("を編集")
            let colored = BodyDocument.read(colorEditor.textStorage!).blocks
            let firstBlock = colored.first?["bulleted_list_item"] as? [String: Any]
            let secondBlock = colored.last?["bulleted_list_item"] as? [String: Any]
            try require(firstBlock?["color"] == nil && secondBlock?["color"] as? String == "gray_background", "Block color was lost or affected another paragraph")
            try require(colorEditor.string.contains("次の項目を編集") && !colorEditor.string.contains("/gray"), "Applying the color altered the working text")
            let renderedColor = MarkdownPreview.render(colored, font: .systemFont(ofSize: 16))
            try require(BodyDocument.read(renderedColor).blocks.last?["bulleted_list_item"] as? NSDictionary == secondBlock as NSDictionary?, "Block color did not round trip")

            let paragraphEditor = BodyEditor()
            paragraphEditor.isRichText = true
            paragraphEditor.insertText("/gray", replacementRange: NSRange(location: 0, length: 0))
            paragraphEditor.applyColor("gray_background", replacing: NSRange(location: 0, length: 5))
            paragraphEditor.insertText("背景付き本文", replacementRange: NSRange(location: 0, length: 0))
            paragraphEditor.insertNewline(nil)
            paragraphEditor.insertText("標準色の次の段落", replacementRange: NSRange(location: NSNotFound, length: 0))
            let paragraphs = BodyDocument.read(paragraphEditor.textStorage!).blocks
            try require((paragraphs.first?["paragraph"] as? [String: Any])?["color"] as? String == "gray_background", "An empty colored paragraph lost its color on first input")
            try require((paragraphs.last?["paragraph"] as? [String: Any])?["color"] == nil, "New plain paragraph inherited the previous color")
            print("PASS: collapsed body draft, literal title and editable Notion block color")

            writer.window?.makeFirstResponder(writer.titleEditor)
            writer.titleEditor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try require(writer.titleEditor.hasMarkedText(), "IME fixture did not create marked text")
            let composing = writer.titleEditor.string
            state.draft.title = "同期結果で置き換えない"
            writer.update()
            try require(writer.titleEditor.string == composing, "Background update overwrote IME composition")
            OfflineProtocol.pageRequests = 0
            writer.submit()
            try require(OfflineProtocol.pageRequests == 0, "IME composition triggered save")
            writer.titleEditor.unmarkText()
            print("PASS: marked Japanese input survives update and prevents premature save")

            let displayFrame = NSRect(x: -1280, y: 160, width: 1280, height: 768)
            let centeredMenu = TagMenuLayout(screen: displayFrame, width: 560, height: 480).frame
            try require(centeredMenu.midX == displayFrame.midX && centeredMenu.midY == displayFrame.midY &&
                        centeredMenu.size == NSSize(width: 560, height: 480), "Property picker was not centered on the active display")
            let wideMenu = TagMenuLayout(screen: displayFrame, width: 2000, height: 1200).frame
            try require(displayFrame.insetBy(dx: 20, dy: 20).contains(wideMenu), "Property picker exceeded the visible screen")

            let property = WriterProperty(id: "tags", name: "確認", type: "multi_select", options: (0..<24).map { TagOption(id: "t\($0)", name: "候補 \($0)") })
            let row = TagRow(property: property, selection: ["t12"], display: DisplayPreferences())
            var opened = 0; row.activated = { opened += 1 }
            (row.chips.arrangedSubviews[0] as! NSButton).performClick(nil)
            try require(opened == 1 && row.selection == ["t12"], "Selected tag click removed it")
            row.scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            row.table.frame = NSRect(x: 0, y: 0, width: 380, height: row.table.rowHeight * 24)
            row.scroll.tile(); row.table.selectRowIndexes(IndexSet(integer: 12), byExtendingSelection: false)
            row.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
            let origin = row.scroll.contentView.bounds.origin
            row.choose(12)
            try require(row.table.selectedRow == 12 && row.scroll.contentView.bounds.origin == origin, "Enter reset selection or scroll")
            row.search.stringValue = "12"; row.filter(); row.choose(0)
            try require(row.search.stringValue == "12" && row.selection == ["t12"], "Search lost after tag selection")
            print("PASS: selected tag opens group; tag choice retains navigation and search")
            let imageRoot = root.appendingPathComponent("inline-images")
            let imageState = try Self.state(root: imageRoot)
            imageState.draft.title = "画像の順番"
            let imageWriter = WriterWindow(state: imageState)
            imageWriter.toggleBody()
            let imageEditor = imageWriter.bodyEditor
            try require(imageEditor.pasteMarkdown("## 前の文章\n\n**後ろの文章**"), "Image test body could not be created")
            let caret = (imageEditor.string as NSString).range(of: "前の文章")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide { bitmap.setColor(NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1), atX: x, y: y) }
            }
            let png = bitmap.representation(using: .png, properties: [:])!
            let firstImage = imageRoot.appendingPathComponent("first.png")
            let secondImage = imageRoot.appendingPathComponent("second.png")
            try png.write(to: firstImage)
            try png.write(to: secondImage)
            let previewSize = NSSize(width: 540, height: 360)
            await imageState.addImageFiles([firstImage, secondImage]) { images in
                try require(imageEditor.insertImages(images, at: NSMaxRange(caret), root: imageRoot, size: previewSize),
                            "Image insertion did not edit the body")
            }
            let document = BodyDocument.read(imageEditor.attributedString())
            let types = document.blocks.compactMap { $0["type"] as? String }
            try require(types == ["heading_2", "draft_image", "draft_image", "paragraph"], "Image insertion changed the block order")
            try require(document.images.map(\.name) == ["first.png", "second.png"], "Multiple image files changed order")
            try require((imageEditor.string as NSString).substring(from: imageEditor.selectedRange().location).hasPrefix("後ろの文章"),
                        "Caret did not land below the inserted images")

            // Confirm restart/legacy rendering as well as the save path through the real client with offline transport.
            let restoredState = try Self.state(root: imageRoot)
            let restoredWindow = WriterWindow(state: restoredState)
            let restoredEditor = restoredWindow.bodyEditor
            try require(restoredWindow.bodyScroll.isHidden && restoredEditor.string.isEmpty, "Restart loaded image previews before opening the body")
            restoredWindow.toggleBody()
            let reopened = BodyDocument.read(restoredEditor.attributedString())
            try require(reopened.images == document.images, "Restart lost inline images")
            try require(reopened.blocks.compactMap { $0["type"] as? String } == types, "Restart reordered the blocks")

            let inline = (restoredEditor.string as NSString).range(of: "\u{fffc}")
            restoredEditor.setSelectedRange(inline)
            restoredEditor.deleteBackward(nil)
            try require(restoredState.draft.images.map(\.name) == ["second.png"], "Deleting an inline image left it in the upload list")
            let remaining = try PagePayload.bodyWithImages(restoredState.draft)
            try require(remaining.compactMap(PagePayload.imageReferenceID) == [document.images[1].id], "Deleted image would be saved")

            var legacy = Draft()
            legacy.title = "旧下書き"
            legacy.body = "# 以前の本文\n\n**そのまま**"
            legacy.bodyFormat = .plainText
            legacy.images = document.images
            restoredState.draft = legacy
            restoredWindow.update()
            try require(restoredEditor.string.hasPrefix(legacy.body) && restoredState.draft == legacy,
                        "Opening an older plain-text draft changed its text or format")
            try require(BodyDocument.read(restoredEditor.attributedString()).images == document.images,
                        "Legacy attachments did not appear at the end of the body")
            restoredEditor.setSelectedRange(NSRange(location: (restoredEditor.string as NSString).length, length: 0))
            for part in ["#", " ", "追記"] {
                restoredEditor.insertText(part, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            let upgraded = try PagePayload.bodyWithImages(restoredState.draft)
            try require(restoredState.draft.bodyFormat == .markdown && upgraded.last?["type"] as? String == "heading_1",
                        "Markdown editing was unavailable after loading an old draft")
            try require(restoredEditor.string.hasPrefix(legacy.body) && upgraded.compactMap(PagePayload.imageReferenceID) == document.images.map(\.id),
                        "Editing converted old Markdown symbols or moved existing images")

            OfflineProtocol.uploadCount = 0
            OfflineProtocol.pageStatus = 200
            OfflineProtocol.pageRequests = 0
            OfflineProtocol.databaseChangesAfterUpload = true
            let beforeUpload = imageState.draft
            await imageState.submit()
            OfflineProtocol.databaseChangesAfterUpload = false
            try require(OfflineProtocol.uploadCount == 2 && OfflineProtocol.pageRequests == 0 &&
                        imageState.draft.formattedBody == beforeUpload.formattedBody && !imageState.draft.submissionPending,
                        "Writer created a page after the database changed during image upload")
            print("PASS: a data source change during image uploads stops page creation")
            await imageState.submit()
            try require(OfflineProtocol.pageRequests == 1 && imageState.draft.isEmpty, "Inline image save failed: \(imageState.status)")
            let sent = try JSONSerialization.jsonObject(with: OfflineProtocol.pagePayload ?? Data()) as? [String: Any]
            let sentBlocks = sent?["children"] as? [[String: Any]] ?? []
            let sentIDs = sentBlocks.compactMap { block in
                ((block["image"] as? [String: Any])?["file_upload"] as? [String: String])?["id"]
            }
            try require(sentBlocks.compactMap { $0["type"] as? String } == ["heading_2", "image", "image", "paragraph"] &&
                        sentIDs == OfflineProtocol.uploadIDs, "Saved Notion image blocks or upload IDs changed order")
            print("PASS: inline image insertion, draft reload, legacy attachments, deletion and Notion block order")
            let cleanupRoot = root.appendingPathComponent("image-cleanup")
            let cleanupStore = try LocalStore(root: cleanupRoot)
            let attachmentFolder = try ImageAttachments.directory(cleanupRoot)
            let today = Date()
            let old = today.addingTimeInterval(-8 * 24 * 60 * 60)
            let retainedNames = ["draft-offline", "draft-another-destination", "last-saved-draft", "confirmed-saved-draft"]
            for name in retainedNames {
                let file = UUID().uuidString + ".png"
                let url = attachmentFolder.appendingPathComponent(file)
                try png.write(to: url)
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
                var draft = Draft()
                draft.images = [DraftImage(name: "kept.png", localFile: file, contentType: "image/png", byteCount: png.count)]
                try cleanupStore.write(draft, name: name)
            }
            var archived = Draft()
            let archivedImage = try ImageAttachments.importData(png, name: "history.png", root: cleanupRoot)
            archived.images = [archivedImage]
            archived.submissionID = UUID()
            let archivedURL = try ImageAttachments.url(for: archivedImage, root: cleanupRoot)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: archivedURL.path)
            let history = SendRecord(id: archived.submissionID!, destination: TestDestination.target, attemptedAt: old,
                                     draft: archived, result: .failed)
            try cleanupStore.write([history], name: SendRecord.filename)
            let orphan = attachmentFolder.appendingPathComponent(UUID().uuidString + ".png")
            let recentlyAdded = attachmentFolder.appendingPathComponent(UUID().uuidString + ".png")
            let unrelated = attachmentFolder.appendingPathComponent("unrelated.png")
            for file in [orphan, recentlyAdded, unrelated] { try png.write(to: file) }
            for file in [orphan, unrelated] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            }
            var discarded: [URL] = []
            try ImageAttachments.tidyCache(root: cleanupRoot, now: today) { discarded.append($0) }
            try require(discarded.map(\.lastPathComponent) == [orphan.lastPathComponent], "Cache cleanup picked protected images")
            try Data("damaged draft".utf8).write(to: cleanupRoot.appendingPathComponent("draft-damaged.json"))
            discarded = []
            do { try ImageAttachments.tidyCache(root: cleanupRoot, now: today) { discarded.append($0) } }
            catch { }
            try require(discarded.isEmpty, "Cache cleanup ran despite an unreadable draft")
            print("PASS: cache cleanup protects drafts, send history, recovery files, recent copies and unknown files")
            let mainTarget = NotionDestination(name: "Other Notes", databaseID: UUID(), dataSourceID: UUID())
            OfflineProtocol.alternateDestination = mainTarget
            let pageRequestsBeforeSetup = OfflineProtocol.pageRequests
            var blocked = false
            do { try await state.connect(database: mainTarget.databaseID, token: "offline-test-only") { _ in false } }
            catch is CancellationError { blocked = true }
            try require(blocked && state.activeDestination == TestDestination.target, "Cancelled verification changed the destination")
            try require(OfflineProtocol.pageRequests == pageRequestsBeforeSetup, "Destination verification wrote a Notion page")
            let switchRoot = root.appendingPathComponent("isolated-destinations")
            let sharedState = try Self.state(root: switchRoot)
            sharedState.draft.title = "開発用だけの下書き"
            sharedState.draft.body = "OLD"
            sharedState.draft.bodyFormat = .plainText
            let switchingWriter = WriterWindow(state: sharedState)
            sharedState.updated = { [weak switchingWriter] in switchingWriter?.update() }
            switchingWriter.toggleBody()
            let switchingEditor = switchingWriter.bodyEditor
            guard let switchUndo = switchingEditor.undoManager else { throw CheckFailure.failed("Undo manager unavailable") }
            switchUndo.groupsByEvent = false
            switchUndo.beginUndoGrouping()
            switchingEditor.replace(NSRange(location: 0, length: 3), with: NSAttributedString(string: "MOD"))
            switchUndo.endUndoGrouping()
            try require(switchUndo.canUndo, "The test did not produce undo history")
            try await sharedState.connect(database: mainTarget.databaseID, token: "offline-test-only") { _ in true }
            try require(sharedState.activeDestination == mainTarget && sharedState.draft.isEmpty,
                        "Switching to the approved main database carried over a development draft")
            try require(!switchUndo.canUndo, "Undo can retrieve content from a different destination")
            sharedState.draft.title = "本番用だけの下書き"
            let mainPayload = try PagePayload.prepare(draft: sharedState.draft, schema: sharedState.visibleSchema, destination: mainTarget)
            let mainPage = try JSONSerialization.jsonObject(with: mainPayload.create) as? [String: Any]
            try require((mainPage?["parent"] as? [String: String])?["data_source_id"] == mainTarget.dataSourceID,
                        "Main destination used the wrong page parent")
            try await sharedState.connect(database: TestDestination.databaseID, token: "offline-test-only") { _ in true }
            try require(sharedState.draft.title == "開発用だけの下書き", "Switching back lost the development draft")
            try await sharedState.connect(database: mainTarget.databaseID, token: "offline-test-only") { _ in true }
            try require(sharedState.draft.title == "本番用だけの下書き", "Switching back lost the main draft")
            OfflineProtocol.alternateDestination = nil
            print("PASS: read-only destination verification, cancellation and isolated destination switching")
            let bookmarkRoot = root.appendingPathComponent("bookmarks", isDirectory: true)
            let bookmarkState = try Self.state(root: bookmarkRoot)
            let bookmarkWindow = WriterWindow(state: bookmarkState)
            bookmarkWindow.toggleBody()
            let bookmarkEditor = bookmarkWindow.bodyEditor
            let article = "https://note.com/kenhori2/n/nb1856e88a60d"
            let url = URL(string: article)!
            try require(!bookmarkEditor.pasteWebURL("参考 " + article) && !bookmarkEditor.pasteWebURL("file:///tmp/test"),
                        "Non-web text was handled as a bookmark URL")
            try require(bookmarkEditor.pasteMarkdown("前の文章\n\n後ろの文章"), "Failed to prepare surrounding text")
            let next = (bookmarkEditor.string as NSString).range(of: "後ろの文章").location
            bookmarkEditor.setSelectedRange(NSRange(location: next, length: 0))
            try require(bookmarkEditor.pasteWebURL(article), "A single web URL was not accepted")
            let range = NSRange(location: next, length: (article as NSString).length)
            let plain = try PagePayload.bodyBlocks(bookmarkState.draft)
            try require(plain.allSatisfy { PagePayload.bookmarkURL(in: $0) == nil }, "Pasting created a bookmark without a choice")
            try require(bookmarkEditor.makeBookmark(url, replacing: range), "Choosing a bookmark failed")
            bookmarkState.draft.title = "ブックマーク"
            try bookmarkState.flush()

            let reopenedBookmarks = try Self.state(root: bookmarkRoot)
            let restoredBookmarkWindow = WriterWindow(state: reopenedBookmarks)
            restoredBookmarkWindow.toggleBody()
            let restoredBookmarkEditor = restoredBookmarkWindow.bodyEditor
            let restoredBlocks = BodyDocument.read(restoredBookmarkEditor.attributedString()).blocks
            try require(restoredBlocks.compactMap { $0["type"] as? String } == ["paragraph", "bookmark", "paragraph"],
                        "Restoring the bookmark reordered or changed the surrounding blocks")
            try require(PagePayload.bookmarkURL(in: restoredBlocks[1]) == url, "The bookmark URL did not survive reopening")

            OfflineProtocol.pageStatus = 200
            await reopenedBookmarks.submit()
            let savedPage = try JSONSerialization.jsonObject(with: OfflineProtocol.pagePayload ?? Data()) as? [String: Any]
            let children = savedPage?["children"] as? [[String: Any]] ?? []
            try require(children.count == 3 && PagePayload.bookmarkURL(in: children[1]) == url,
                        "The create-page request lost the bookmark")

            let attachment = (restoredBookmarkEditor.string as NSString).range(of: "\u{fffc}")
            try require(attachment.location != NSNotFound, "The bookmark attachment was not rendered")
            restoredBookmarkEditor.setSelectedRange(attachment)
            restoredBookmarkEditor.deleteBackward(nil)
            try require(BodyDocument.read(restoredBookmarkEditor.attributedString()).blocks.count == 2,
                        "Deleting the bookmark removed surrounding text or left an empty block")
            print("PASS: web URL choice, bookmark restore, Notion payload and deletion")
            let clipRoot = root.appendingPathComponent("article", isDirectory: true)
            let clipState = try Self.state(root: clipRoot)
            let clipWindow = WriterWindow(state: clipState)
            clipWindow.toggleBody()
            let html = """
            <article><h2>記事の見出し</h2><p>先頭 <strong>強調</strong><br><br><a href="/source">出典</a></p><p><br></p>
              <figure><div class="external-article-widget"><a href="https://example.org/news">リンクカード</a></div></figure>
              <figure><img src="/one.png" alt="写真"><figcaption>説明</figcaption></figure>
              <p>後半</p><p><br></p><img src="/unavailable.png" alt="取得できない画像"><script>skip me</script></article>
            """
            let base = URL(string: "https://example.org/article")!
            let content = try await WebClip.prepare(.selection(html, base: base, fallback: nil),
                                                    root: clipRoot, availableImages: 100) { url in
                if url.lastPathComponent == "unavailable.png" { throw URLError(.resourceUnavailable) }
                return png
            }
            let clipEditor = clipWindow.bodyEditor
            let fragment = MarkdownPreview.render(content.blocks, font: clipEditor.baseFont) { id in
                content.images.first(where: { $0.id == id }).map {
                    clipEditor.imageFragment($0, root: clipRoot, size: NSSize(width: 480, height: 300))
                }
            }
            try require(content.images.count == 1 && content.skippedImages == 1, "Article images were lost or failures were hidden")
            try require(clipEditor.insertWebBlocks(fragment, replacing: NSRange(location: 0, length: 0)), "Could not paste article")
            let articleBlocks = try PagePayload.bodyWithImages(clipState.draft)
            try require(articleBlocks.compactMap { $0["type"] as? String } == ["heading_2", "paragraph", "paragraph", "bookmark", "draft_image", "paragraph", "paragraph", "paragraph", "paragraph"],
                        "Article paste lost the order or a supported block")
            let articleJSON = String(decoding: try JSONSerialization.data(withJSONObject: articleBlocks, options: [.withoutEscapingSlashes]), as: UTF8.self)
            try require(articleJSON.contains("https://example.org/source") && articleJSON.contains("https://example.org/unavailable.png")
                        && articleJSON.contains("bold") && !articleJSON.contains("skip me"), "Article formatting or links were not preserved")
            let paragraphRuns = (articleBlocks[1]["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? []
            let paragraph = paragraphRuns.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
            let blank = (articleBlocks[2]["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]]
            try require(paragraph == "先頭 強調\n\n出典" && blank?.isEmpty == true,
                        "Article line breaks were lost or converted to new paragraphs")
            try clipState.flush()
            let clipReopened = try Self.state(root: clipRoot)
            let reopenedWindow = WriterWindow(state: clipReopened)
            reopenedWindow.toggleBody()
            try require(clipReopened.draft.images == content.images &&
                        reopenedWindow.bodyEditor.string.contains("強調\u{2028}\u{2028}出典\n\n"),
                        "Article images or line breaks did not survive reopening")
            print("PASS: HTML article paste with ordered images, links, paragraphs and blank lines")

            clipState.draft.title = "クリアのテスト"
            clipState.draft.tags = ["tags": ["one"]]
            clipState.draft.urls = ["url": "https://example.org"]
            clipState.draft.submissionPending = true
            try clipState.clearDraft()
            try require(!clipState.draft.isEmpty, "Clearing discarded a pending submission")
            clipState.draft.submissionPending = false
            clipState.edited()
            try clipState.clearDraft()
            clipWindow.update()
            try require(clipState.draft == Draft() && clipState.activeDestination == TestDestination.target &&
                        clipWindow.titleEditor.string.isEmpty && clipWindow.bodyEditor.string.isEmpty,
                        "Clear left editor content behind or changed the destination")
            try require(try Self.state(root: clipRoot).draft == Draft(), "Cleared draft was restored on restart")
            print("PASS: clearing all inputs persists separately from destination and protects pending saves")
            try await verifyBackgroundSend(root: root)
            try await verifyHistoryRetries(root: root)
            try await verifyBookmarkThumbnails(root: root, png: png)
            print("PASS: app-level verification used isolated temporary data and offline transport")
        } catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor private static func verifyBackgroundSend(root: URL) async throws {
        let location = root.appendingPathComponent("background-send")
        let state = try Self.state(root: location)
        let writer = WriterWindow(state: state)
        let window = writer.window!
        state.draft.title = "バックグラウンドで送信"
        state.draft.body = "下書きに先に保存される本文"
        OfflineProtocol.pageStatus = 200
        OfflineProtocol.schemaRequests = 0
        let originalSchemaRequests = OfflineProtocol.schemaRequests
        let initialPageRequests = OfflineProtocol.pageRequests
        var acknowledged = false
        var wasHidden = false
        var preservedFirst = false
        var beforeNetwork = false
        var saved = false
        state.submissionStarted = {
            acknowledged = true
            wasHidden = !window.isVisible
            beforeNetwork = OfflineProtocol.schemaRequests == originalSchemaRequests && OfflineProtocol.pageRequests == initialPageRequests
            let backup = try? Self.state(root: location)
            preservedFirst = backup?.draft.body == state.draft.body && backup?.recentSends.first?.draft.body == state.draft.body
        }
        state.saved = { saved = true }
        window.orderFrontRegardless()
        try require(window.isVisible, "Composer was not open before sending")
        writer.submit()
        for _ in 0..<200 {
            if acknowledged && !state.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(acknowledged && beforeNetwork && wasHidden && preservedFirst,
                    "Composer did not hide after committing both local copies and before any Notion request")
        try require(saved && state.draft.isEmpty && !window.isVisible, "Confirmed save did not finish in the background")
        print("PASS: AppKit composer hides after local backup and before the first Notion request")
    }

    @MainActor private static func verifyHistoryRetries(root: URL) async throws {
        let location = root.appendingPathComponent("send-history")
        let initial = try Self.state(root: location)
        initial.draft.title = "以前の文章"
        initial.draft.body = "前の本文\n\n空行と絵文字📝"
        OfflineProtocol.pageStatus = 400
        await initial.submit()
        let first = initial.recentSends[0]

        initial.draft.title = "新しい編集中の文章"
        initial.draft.body = "編集メモ"
        initial.edited()
        try initial.flush()
        let editor = initial.draft
        let previousRequests = OfflineProtocol.pageRequests
        let other = NotionDestination(name: "別の保存先", databaseID: UUID(), dataSourceID: UUID())
        let differentDestination = try Self.state(root: location, destination: other)
        await differentDestination.retry(first.id, confirmedMissing: true)
        try require(OfflineProtocol.pageRequests == previousRequests, "History retry was redirected to another destination")

        let restarted = try Self.state(root: location)
        OfflineProtocol.pageStatus = 503
        await restarted.retry(first.id, confirmedMissing: false)
        let afterTimeout = try Self.state(root: location)
        try require(afterTimeout.draft == editor && afterTimeout.recentSends.first?.result == .uncertain,
                    "A historical retry replaced the active draft or lost its pending state")
        let timeoutRequests = OfflineProtocol.pageRequests
        await afterTimeout.retry(first.id, confirmedMissing: false)
        try require(OfflineProtocol.pageRequests == timeoutRequests, "A result-unknown history item was resent without confirmation")
        OfflineProtocol.pageStatus = 200
        await afterTimeout.retry(first.id, confirmedMissing: true)
        try require(OfflineProtocol.pageRequests == timeoutRequests + 1 && afterTimeout.draft == editor &&
                    afterTimeout.recentSends.count == 1 && afterTimeout.recentSends.first?.result == .sent &&
                    afterTimeout.recentSends.first?.draft.body == first.draft.body,
                    "Confirmed retry lost the original content or touched the unrelated draft")
        await afterTimeout.retry(first.id, confirmedMissing: true)
        try require(OfflineProtocol.pageRequests == timeoutRequests + 1, "A completed history item was resent")

        OfflineProtocol.pageStatus = 400
        afterTimeout.draft.title = "同じ下書きを履歴から再送"
        await afterTimeout.submit()
        let sameDraftID = afterTimeout.recentSends[0].id
        OfflineProtocol.pageStatus = 200
        await afterTimeout.retry(sameDraftID, confirmedMissing: false)
        try require(afterTimeout.draft.isEmpty, "Retry left an identical draft ready to send twice")

        for index in 1...6 {
            afterTimeout.draft.title = "送信\(index)"
            await afterTimeout.submit()
        }
        let newest = try Self.state(root: location)
        try require(newest.recentSends.map(\.draft.title) == ["送信6", "送信5", "送信4", "送信3", "送信2"],
                    "History exceeded five entries or lost newest-first order on restart")
        let settings = SettingsWindow(state: newest)
        let tabs = settings.window?.contentView?.subviews.compactMap { $0 as? NSTabView }.first
        try require(tabs?.tabViewItems.map(\.label).contains("直近5件") == true, "Settings lost the history tab")
        print("PASS: history retry is scoped, deduplicated, restart-safe and keeps only the five newest sends")
    }

    @MainActor private static func verifyBookmarkThumbnails(root: URL, png: Data) async throws {
        let thumbnailURL = URL(string: "https://example.org/preview")!
        let bareURL = URL(string: "https://example.org/no-preview")!
        guard let jpeg = BookmarkPreview.jpegThumbnail(png) else { throw CheckFailure.failed("Bookmark thumbnail did not convert") }
        let state = try Self.state(root: root.appendingPathComponent("thumbnail-send")) { url in
            url == thumbnailURL ? BookmarkPreview(title: "記事のタイトル", summary: "記事の説明", thumbnail: jpeg) : nil
        }
        let writer = WriterWindow(state: state)
        writer.toggleBody()
        try require(writer.bodyEditor.pasteMarkdown("リンクの前"), "Missing text to check block order")
        for url in [thumbnailURL, bareURL, thumbnailURL] {
            let end = NSRange(location: writer.bodyEditor.string.utf16.count, length: 0)
            try require(writer.bodyEditor.insertWebBlocks(BodyBookmarkAttachment.fragment(url, font: .systemFont(ofSize: 14)), replacing: end),
                        "Could not insert bookmark fixture")
        }
        state.draft.title = "サムネイル付きの送信"
        let draft = state.draft
        let expectedTypes = ["paragraph", "callout", "bookmark", "callout"]
        OfflineProtocol.uploadCount = 0
        OfflineProtocol.pageStatus = 200
        await state.submit()
        let page = try JSONSerialization.jsonObject(with: OfflineProtocol.pagePayload ?? Data()) as? [String: Any]
        let blocks = page?["children"] as? [[String: Any]] ?? []
        try require(state.draft.isEmpty && OfflineProtocol.uploadCount == 1 && blocks.compactMap { $0["type"] as? String } == expectedTypes,
                    "Bookmark callout lost block order, the fallback, or the shared upload")
        let callout = blocks[1]["callout"] as? [String: Any]
        let text = callout?["rich_text"] as? [[String: Any]]
        let title = text?.first?["text"] as? [String: Any]
        let summary = text?.last?["text"] as? [String: Any]
        let images = callout?["children"] as? [[String: Any]]
        let image = images?.first?["image"] as? [String: Any]
        try require(title?["content"] as? String == "記事のタイトル" &&
                    (title?["link"] as? [String: String])?["url"] == thumbnailURL.absoluteString &&
                    summary?["content"] as? String == "\n記事の説明" &&
                    (image?["file_upload"] as? [String: String])?["id"] == OfflineProtocol.uploadIDs[0] &&
                    PagePayload.bookmarkURL(in: blocks[2]) == bareURL,
                    "Notion payload lost the thumbnail, the click target or the text")
        let recordedBlocks = try PagePayload.bodyBlocks(state.recentSends[0].draft)
        try require(recordedBlocks.compactMap(PagePayload.bookmarkURL(in:)) == [thumbnailURL, bareURL, thumbnailURL],
                    "The history backup lost the source bookmarks")

        state.draft = draft
        OfflineProtocol.rejectUpload = true
        await state.submit()
        OfflineProtocol.rejectUpload = false
        let fallback = try JSONSerialization.jsonObject(with: OfflineProtocol.pagePayload ?? Data()) as? [String: Any]
        let fallbackBlocks = fallback?["children"] as? [[String: Any]] ?? []
        try require(state.draft.isEmpty && fallbackBlocks.compactMap(PagePayload.bookmarkURL(in:)) == [thumbnailURL, bareURL, thumbnailURL],
                    "An optional thumbnail upload blocked page creation or lost the bookmark")
        print("PASS: ordered bookmark callouts carry uploaded thumbnails, titles and original link targets with a bookmark fallback")
    }
}
