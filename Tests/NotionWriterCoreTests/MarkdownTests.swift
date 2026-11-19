import Foundation
import NotionWriterCore

final class MarkdownTests: XCTestCase {
    func type(_ block: [String: Any]) -> String { block["type"] as! String }
    func rich(_ block: [String: Any]) -> [[String: Any]] { (block[type(block)] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? [] }
    func text(_ block: [String: Any]) -> String { rich(block).map { ($0["text"] as! [String: Any])["content"] as! String }.joined() }
    func testHeadingsListsAndParagraphs() throws {
        let blocks = try MarkdownBody.blocks("# 見出し\n## 小見出し\n### 三段目\n- 箇条書き\n1. 手順\n普通の文章\n続き")
        XCTAssertEqual(blocks.map(type), ["heading_1","heading_2","heading_3","bulleted_list_item","numbered_list_item","paragraph"])
        XCTAssertEqual(blocks.map(text), ["見出し","小見出し","三段目","箇条書き","手順","普通の文章\n続き"])
        XCTAssertEqual(try MarkdownBody.blocks("見出し\n===").map(type), ["heading_1"])
    }
    func testInlineStylesAndLinks() throws {
        let blocks = try MarkdownBody.blocks("**太字** *斜体* ~~取消~~ `a < b` [リンク](https://example.com/path?q=1)")
        let runs = rich(blocks[0])
        XCTAssertEqual(text(blocks[0]), "太字 斜体 取消 a < b リンク")
        for (word, annotation) in [("太字","bold"),("斜体","italic"),("取消","strikethrough"),("a < b","code")] {
            let run = try XCTUnwrap(runs.first { ($0["text"] as? [String: String])?["content"] == word })
            XCTAssertEqual((run["annotations"] as? [String: Bool])?[annotation], true)
        }
        let linked = try XCTUnwrap(runs.last?["text"] as? [String: Any])
        XCTAssertEqual((linked["link"] as? [String: String])?["url"], "https://example.com/path?q=1")
    }
    func testFencedCodeAndUnfinishedSource() throws {
        let blocks = try MarkdownBody.blocks("```swift\nlet a = \"**そのまま**\"\n\nprint(a)\n```\n後ろ")
        XCTAssertEqual(blocks.map(type), ["code","paragraph"])
        XCTAssertEqual(text(blocks[0]), "let a = \"**そのまま**\"\n\nprint(a)")
        XCTAssertEqual((blocks[0]["code"] as? [String: Any])?["language"] as? String, "swift")
        XCTAssertTrue(rich(blocks[0]).allSatisfy { $0["annotations"] == nil })
        let unfinished = "```swift\n**未完のコード**\n"
        XCTAssertEqual(text(try MarkdownBody.blocks(unfinished)[0]), unfinished)
        XCTAssertEqual((try MarkdownBody.blocks("```mystery\ncode\n```")[0]["code"] as? [String: Any])?["language"] as? String, "plain text")
    }
    func testUnsupportedSyntaxNeverDropsSource() throws {
        for source in ["![図](https://example.com/image.png)", "[リンク](../local)", "[リンク](javascript:alert)", "<div>原文</div>", "  - 子リスト **原文**", "**未完"] {
            XCTAssertEqual(try MarkdownBody.blocks(source).map(text).joined(), source)
        }
    }
    func testBlankLinesUnicodeAndLimits() throws {
        let blocks = try MarkdownBody.blocks("本文\n\n\n末尾\n")
        XCTAssertEqual(blocks.map(text), ["本文","","末尾",""])
        let long = String(repeating: "日本語👨‍👩‍👧‍👦e\u{301}", count: 400)
        let styled = try MarkdownBody.blocks("**" + long + "**")[0]
        XCTAssertEqual(text(styled), long)
        XCTAssertTrue(rich(styled).allSatisfy { (($0["text"] as! [String: Any])["content"] as! String).utf16.count <= 2000 })
        XCTAssertEqual(try MarkdownBody.blocks((0..<101).map { "- \($0)" }.joined(separator: "\n")).count, 101)
        XCTAssertThrowsError(try MarkdownBody.blocks(String(repeating: "**a** plain ", count: 60)))
        XCTAssertThrowsError(try MarkdownBody.blocks("[x](https://example.com/" + String(repeating: "a",count: 2001) + ")"))
    }
    func testTasksQuotesAndDivider() throws {
        let blocks = try MarkdownBody.blocks("- [x] 済み\n- [ ] 未完\n> 引用\n> 続き\n---")
        XCTAssertEqual(blocks.map(type), ["to_do","to_do","quote","divider"])
        XCTAssertEqual((blocks[0]["to_do"] as? [String: Any])?["checked"] as? Bool, true)
        XCTAssertEqual((blocks[1]["to_do"] as? [String: Any])?["checked"] as? Bool, false)
        XCTAssertEqual(text(blocks[2]), "引用\n続き")
    }
    func testLegacyFormatAndDraftRoundTrip() throws {
        let old = ##"{"title":"# 原文","tags":{},"urls":{},"body":"**原文**","submissionPending":false}"##
        let legacy = try JSONDecoder().decode(Draft.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.bodyFormat, .plainText)
        XCTAssertEqual(legacy.body, "**原文**")
        XCTAssertEqual(Draft().bodyFormat, .markdown)
        var draft = Draft(); draft.body = "# 見出し"; draft.title = "# 原文\n\n**そのまま**"
        XCTAssertEqual(try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(draft)), draft)
        let value = try JSONSerialization.jsonObject(with: PagePayload.make(draft: draft, schema: WriterTests().schema(), destination: TestDestination.target)) as! [String: Any]
        let props = value["properties"] as! [String: [String: Any]]
        let title = props["title"]!["title"] as! [[String: Any]]
        XCTAssertEqual((title[0]["text"] as? [String: String])?["content"], draft.title)
        XCTAssertEqual(((value["children"] as! [[String: Any]])[0]["type"] as? String), "heading_1")
        XCTAssertEqual(draft.body, "# 見出し")
    }
    func testBodyAndImageBatches() throws {
        var draft = Draft(); draft.title = "確認"; draft.body = (0..<200).map { "- \($0)" }.joined(separator: "\n")
        let image = DraftImage(name: "a", localFile: "a.png", contentType: "image/png", byteCount: 1)
        draft.images = [image]
        let original = draft
        let delivery = try PagePayload.prepare(draft: draft, schema: WriterTests().schema(), uploadedImages: [image.id: UUID().uuidString], destination: TestDestination.target)
        let requests = try ([delivery.create] + delivery.continuation).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        let blocks = requests.map { $0["children"] as! [[String: Any]] }
        XCTAssertEqual(blocks.map(\.count), [100, 100, 1])
        XCTAssertEqual(blocks.flatMap { $0 }.dropLast().map(text), (0..<200).map(String.init))
        XCTAssertEqual(blocks.last?.first.map(type), "image")
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0["parent"] == nil && $0["properties"] == nil })
        XCTAssertEqual(draft, original)
    }

    func testPastedComparisonTables() throws {
        let source = """
        はじめに **日本語** 🎷

        ## 比較

        | 条件 | 結果 |
        | --- | :---: |
        | A \\| B | **太字** |
        | メモ | [出典](https://example.com/a) |

        おわり
        """
        let blocks = try MarkdownBody.blocks(source)
        XCTAssertEqual(blocks.map(type), ["paragraph", "heading_2", "table", "paragraph"])
        let table = try XCTUnwrap(blocks[2]["table"] as? [String: Any])
        XCTAssertEqual(table["table_width"] as? Int, 2)
        let rows = try XCTUnwrap(table["children"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        let cells = try XCTUnwrap((rows[1]["table_row"] as? [String: Any])?["cells"] as? [[[String: Any]]])
        XCTAssertEqual((cells[0][0]["text"] as? [String: String])?["content"], "A | B")
        XCTAssertEqual((cells[1][0]["annotations"] as? [String: Bool])?["bold"], true)
    }
}
