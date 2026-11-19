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
    @MainActor static func state(root: URL) throws -> AppState {
        let store = try LocalStore(root: root)
        try store.write(TestDestination.target, name: "destination")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineProtocol.self]
        let api = NotionClient(token: "offline-test-only", session: URLSession(configuration: config))
        return try AppState(qa: false, dataRoot: root, clientOverride: { api })
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
            try require(state.draft == original && !state.busy, "Rejected save changed draft")
            try require(OfflineProtocol.pageRequests == 1 && !state.draft.submissionPending, "Rejected save state incorrect")
            try require(try Self.state(root: root).draft == original, "Rejected save was not preserved on disk")
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
            try require(try state.store.read(Draft.self, name: "last-saved-draft")?.body == original.body, "Save recovery draft missing")
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
            print("PASS: cache cleanup protects drafts, recovery files, recent copies and unknown files")
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
            print("PASS: 17 app-level scenarios (isolated temporary data; no Keychain or real Notion requests)")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
