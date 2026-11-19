import Foundation
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

final class WriterTests: XCTestCase {
    func schema() -> Schema {
        Schema(databaseID: TestDestination.databaseID, dataSourceID: TestDestination.dataSourceID, databaseName: "Test Notes", properties: [
            .init(id: "title", name: "名前", type: "title"),
            .init(id: "tag-id", name: "創作", type: "multi_select", options: [.init(id: "option-id", name: "メモ", color: "purple")]),
            .init(id: "url-id", name: "URL", type: "url")])
    }
    func testLongJapaneseAndEmojiPreserveEveryCharacterAndBlankLine() throws {
        let text = "\n\n" + String(repeating: "日本語👨‍👩‍👧‍👦e\u{301}\n\n", count: 500) + "\n終わり\n"
        var draft = Draft(); draft.title = text
        let data = try PagePayload.make(draft: draft, schema: schema(), destination: TestDestination.target)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = try XCTUnwrap(json["properties"] as? [String: [String: Any]])
        let rich = try XCTUnwrap(props["title"]?["title"] as? [[String: Any]])
        let values = rich.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }
        XCTAssertEqual(values.joined(), text)
        XCTAssertTrue(values.allSatisfy { $0.utf16.count <= 2000 })
    }
    func testPayloadUsesIDsAndDoesNotInterpretTitleMarkdown() throws {
        var draft = Draft(); draft.title = "# 普通の文章\n\n**そのまま**"; draft.tags = ["tag-id": ["option-id"]]; draft.urls = ["url-id": "https://example.com/a?b=c"]; draft.body = "本文\n\n空行\n"; draft.bodyFormat = .plainText
        let json = try JSONSerialization.jsonObject(with: PagePayload.make(draft: draft, schema: schema(), destination: TestDestination.target)) as! [String: Any]
        let props = json["properties"] as! [String: [String: Any]]
        XCTAssertEqual((json["parent"] as? [String: String])?["data_source_id"], TestDestination.dataSourceID)
        XCTAssertEqual((props["tag-id"]?["multi_select"] as? [[String: String]])?.first?["id"], "option-id")
        XCTAssertEqual(props["url-id"]?["url"] as? String, "https://example.com/a?b=c")
        let rich = props["title"]?["title"] as! [[String: Any]]
        XCTAssertEqual((rich[0]["text"] as? [String: String])?["content"], draft.title)
        let blocks = json["children"] as! [[String: Any]]
        let paragraph = blocks[0]["paragraph"] as! [String: Any]
        XCTAssertEqual((((paragraph["rich_text"] as! [[String: Any]])[0]["text"]) as! [String: String])["content"], draft.body)
    }
    func testProductionAndDemoAreRejected() throws {
        var draft = Draft(); draft.title = "test"
        var prod = schema(); prod.databaseName = "Other Notes"
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: prod, destination: TestDestination.target))
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: .demo, destination: TestDestination.target))
        var unrelated = schema(); unrelated.databaseID = "some-other-database"
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: unrelated, destination: TestDestination.target))
        XCTAssertThrowsError(try TestDestination.target.validate(.init(databaseID: "main")))
        XCTAssertThrowsError(try TestDestination.target.validate(.init(databaseID: TestDestination.databaseID, dataSourceID: "wrong-source")))
        try TestDestination.target.validate(.init(databaseID: TestDestination.databaseID))
    }
    func testRemovedTagsAndPropertiesNeverSilentlyDisappear() {
        var draft = Draft(); draft.title = "test"; draft.tags = ["tag-id": ["deleted-option"]]
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: schema(), destination: TestDestination.target))
        draft.tags = ["deleted-property": ["option-id"]]
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: schema(), destination: TestDestination.target))
    }
    func testOversizedTitleRejectedWithoutMutation() {
        var draft = Draft(); draft.title = String(repeating: "あ", count: 200_001)
        let original = draft
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: schema(), destination: TestDestination.target))
        XCTAssertEqual(draft, original)
    }
    func testDatabaseURLIgnoresViewQuery() throws {
        let id = try Connection.parseID("https://www.notion.so/work/Test Notes-0123456789abcdef0123456789abcdef?v=ffffffffffffffffffffffffffffffff")
        XCTAssertEqual(id, "01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertThrowsError(try Connection.parseID("not a database"))
    }
    func testCacheRefreshBoundary() {
        var value = schema(); value.syncedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(value.needsRefresh(now: Date(timeIntervalSince1970: 1599)))
        XCTAssertTrue(value.needsRefresh(now: Date(timeIntervalSince1970: 1600)))
    }
    func testDraftRoundTripAndSourceIsolationAndCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        var draft = Draft(); draft.title = "\n日本語\n\n"; draft.submissionPending = true; draft.tags = ["a": ["b"]]
        let first = store.draftName(for: .init(databaseID: "a", dataSourceID: "b"))
        let second = store.draftName(for: .init(databaseID: "a", dataSourceID: "c"))
        XCTAssertNotEqual(first, second)
        try store.write(draft, name: first)
        XCTAssertEqual(try store.read(Draft.self, name: first), draft)
        XCTAssertNil(try store.read(Draft.self, name: second))
        let url = root.appendingPathComponent("broken.json"); try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.read(Draft.self, name: "broken"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}
final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class APITests: XCTestCase {
    func client() -> NotionClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        return NotionClient(token: "test-only", session: URLSession(configuration: config))
    }
    func testMetadataSyncNeverQueriesCardsAndPreservesColors() async throws {
        var paths: [String] = []
        MockProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2025-09-03")
            let json: [String: Any]
            if request.url!.path.contains("databases") {
                json = TestDestination.database()
            } else {
                json = TestDestination.source(properties: [
                    "名前": ["id": "title", "name": "名前", "type": "title"],
                    "タグ": ["id": "tag", "name": "タグ", "type": "multi_select",
                           "multi_select": ["options": [["id": "a", "name": "創作", "color": "purple"]]]]
                ])
            }
            return (200, [:], try JSONSerialization.data(withJSONObject: json))
        }
        let schema = try await client().fetchSchema(destination: TestDestination.target)
        XCTAssertEqual(schema.tags.first?.options.first?.color, "purple")
        XCTAssertEqual(paths, ["/v1/databases/" + TestDestination.databaseID, "/v1/data_sources/" + TestDestination.dataSourceID])
    }
    func testWrongDatabaseStopsBeforeAnyFurtherRequest() async {
        var count = 0
        MockProtocol.handler = { request in
            count += 1
            XCTAssertEqual(request.httpMethod, "GET")
            var db = TestDestination.database()
            db["id"] = UUID().uuidString
            return (200, [:], try JSONSerialization.data(withJSONObject: db))
        }
        do { _ = try await client().fetchSchema(destination: TestDestination.target); XCTFail("Must reject a foreign database") }
        catch WriterError.validation {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(count, 1)
    }
    private func pageRequest(source: String = TestDestination.dataSourceID) -> Data {
        try! JSONSerialization.data(withJSONObject: ["parent": ["type": "data_source_id", "data_source_id": source]])
    }
    func testWrongCreateParentStopsBeforeNetwork() async {
        var requests = 0
        MockProtocol.handler = { _ in requests += 1; return (500, [:], Data()) }
        do {
            _ = try await client().createPage(payload: pageRequest(source: UUID().uuidString), destination: TestDestination.target)
            XCTFail("Unexpected request to the wrong data source")
        } catch WriterError.validation {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(requests, 0)
    }
    func testAmbiguousWriteIsNeverAutomaticallyRetried() async {
        for status in [500, 503, 504] {
            var count = 0
            MockProtocol.handler = { _ in count += 1; return (status, [:], Data()) }
            do { _ = try await client().createPage(payload: pageRequest(), destination: TestDestination.target); XCTFail("Must flag uncertain") }
            catch WriterError.uncertain {} catch { XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(count, 1)
        }
        MockProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await client().createPage(payload: pageRequest(), destination: TestDestination.target); XCTFail("Must flag timeout") }
        catch WriterError.uncertain {} catch { XCTFail("Wrong error") }
    }
    func testRateLimitExposesRetryAfter() async {
        MockProtocol.handler = { _ in (429, ["Retry-After": "45"], Data(#"{"message":"rate limited"}"#.utf8)) }
        do { _ = try await client().createPage(payload: pageRequest(), destination: TestDestination.target); XCTFail("Must fail") }
        catch WriterError.api(let status, _, let retry) { XCTAssertEqual(status, 429); XCTAssertEqual(retry, 45) }
        catch { XCTFail("Wrong error") }
    }
    func testMultipleSourcesRequireExplicitChoice() async {
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/v1/databases/" + TestDestination.databaseID)
            let db = TestDestination.database(sources: [TestDestination.dataSourceID, UUID().uuidString.lowercased()])
            return (200, [:], try JSONSerialization.data(withJSONObject: db))
        }
        do {
            _ = try await client().discoverDestination(databaseID: UUID(uuidString: TestDestination.databaseID)!, viewID: nil)
            XCTFail("Must require choice")
        } catch WriterError.validation {} catch { XCTFail("Wrong error: \(error)") }
    }
}

extension WriterTests {
    func testLegacyDraftAndImageUploadExpiry() throws {
        let json = #"{"title":"前の下書き\n\n","tags":{},"urls":{},"body":"本文","submissionPending":false}"#
        let draft = try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
        XCTAssertEqual(draft.title, "前の下書き\n\n"); XCTAssertTrue(draft.images.isEmpty)
        var image = DraftImage(name: "写真.png", localFile: "owned.png", contentType: "image/png", byteCount: 10)
        image.uploadID = UUID().uuidString; image.uploadExpiresAt = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(image.reusableUploadID(now: Date(timeIntervalSince1970: 100)), image.uploadID)
        XCTAssertNil(image.reusableUploadID(now: Date(timeIntervalSince1970: 950)))
        var withImage = draft; withImage.images = [image]
        XCTAssertEqual(try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(withImage)), withImage)
    }
    func testViewOrderUsesPropertyIDsAndRejectsForeignDatabase() throws {
        let schema = schema()
        let view: [String: Any] = ["id": "view", "name": "閲覧", "parent": ["database_id": schema.databaseID], "data_source_id": schema.dataSourceID,
            "configuration": ["properties": [["property_id":"url-id"],["property_id":"tag-id"],["property_id":"tag-id"]]]]
        let result = try ViewPropertyOrder.apply(view, to: schema)
        XCTAssertEqual(result.properties.map(\.id), ["url-id", "tag-id", "title"])
        XCTAssertEqual(result.viewName, "閲覧")
        var foreign = view; foreign["data_source_id"] = "other"
        XCTAssertThrowsError(try ViewPropertyOrder.apply(foreign, to: schema))
    }
    func testMultipleImagesFollowBodyAndMissingUploadsAreRejected() throws {
        var draft = Draft(); draft.title = "# そのまま"; draft.body = "本文\n\n"; draft.bodyFormat = .plainText
        let a = DraftImage(name: "a.png", localFile: "a.png", contentType: "image/png", byteCount: 10)
        let b = DraftImage(name: "b.jpg", localFile: "b.jpg", contentType: "image/jpeg", byteCount: 10)
        draft.images = [a,b]
        XCTAssertThrowsError(try PagePayload.make(draft: draft, schema: schema(), destination: TestDestination.target))
        let first = UUID().uuidString; let second = UUID().uuidString
        let payload = try PagePayload.make(draft: draft, schema: schema(), uploadedImages: [a.id:first,b.id:second], destination: TestDestination.target)
        let json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let children = json["children"] as! [[String: Any]]
        XCTAssertEqual(children.map { $0["type"] as! String }, ["paragraph","image","image"])
        XCTAssertEqual(((children[1]["image"] as! [String: Any])["file_upload"] as! [String: String])["id"], first)
        XCTAssertEqual(((children[2]["image"] as! [String: Any])["file_upload"] as! [String: String])["id"], second)
        XCTAssertEqual(draft.images, [a,b])
    }
}
extension APITests {
    func testViewMetadataSyncReadsNoCards() async throws {
        var paths: [String] = []
        MockProtocol.handler = { request in
            paths.append(request.url!.path); XCTAssertEqual(request.httpMethod, "GET")
            let json: [String: Any]
            if request.url!.path.contains("databases") {
                json = TestDestination.database()
            } else if request.url!.path.contains("data_sources") {
                json = TestDestination.source(properties: ["Name":["id":"title","name":"Name","type":"title"],"A":["id":"a","name":"A","type":"multi_select"],"B":["id":"b","name":"B","type":"multi_select"]])
            } else {
                json = ["id":TestDestination.viewID,"name":"閲覧","parent":["database_id":TestDestination.databaseID],"data_source_id":TestDestination.dataSourceID,"configuration":["properties":[["property_id":"title"],["property_id":"b"],["property_id":"a"]]]]
            }
            return (200,[:],try JSONSerialization.data(withJSONObject: json))
        }
        let result = try await client().fetchSchema(destination: TestDestination.withView)
        XCTAssertEqual(result.tags.map(\.id), ["b","a"])
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths[1], "/v1/views/" + TestDestination.viewID)
    }
    func testImageUploadUsesBinaryMultipartAndNeverCreatesAPage() async throws {
        let id = UUID().uuidString
        let binary = Data([0,1,13,10,255,128,64])
        var paths: [String] = []
        MockProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/send") {
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
                let body = request.httpBody ?? readBody(request.httpBodyStream)
                XCTAssertTrue(body.range(of: binary) != nil)
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("name=\"file\"; filename=\"image.png\""))
                return (200,[:],try JSONSerialization.data(withJSONObject: ["id":id,"status":"uploaded"]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200,[:],try JSONSerialization.data(withJSONObject: ["id":id,"status":"pending"]))
        }
        let result = try await client().uploadImage(data: binary, filename: "image.png", contentType: "image/png")
        XCTAssertEqual(result,id)
        XCTAssertEqual(paths,["/v1/file_uploads","/v1/file_uploads/" + id + "/send"])
    }
    func testImageUploadFailureDoesNotBecomeAnAmbiguousPageWrite() async {
        var count = 0
        MockProtocol.handler = { _ in count += 1; throw URLError(.timedOut) }
        do { _ = try await client().uploadImage(data: Data([1]), filename: "a.png", contentType: "image/png"); XCTFail("Must fail") }
        catch WriterError.uncertain { XCTFail("No page was submitted") } catch {}
        XCTAssertEqual(count,1)
    }
}
private func readBody(_ stream: InputStream?) -> Data {
    guard let stream else { return Data() }; stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while true { let count = stream.read(&buffer,maxLength: buffer.count); if count <= 0 { break }; data.append(buffer,count: count) }
    return data
}
