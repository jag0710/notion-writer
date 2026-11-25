import AppKit
import NotionWriterCore

@MainActor
func verifyVideoAndPropertyRecall(root: URL) async throws {
    let location = root.appendingPathComponent("video-and-property-recall")
    OfflineProtocol.propertyRecallSchema = true
    OfflineProtocol.pageStatus = 200
    defer { OfflineProtocol.propertyRecallSchema = false }
    let state = try AppVerification.state(root: location)
    await state.sync()

    let shortLink = URL(string: "https://youtu.be/jNQXAC9IVRw?t=4")!
    for address in [
        shortLink.absoluteString,
        "https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PL123",
        "https://youtube.com/shorts/jNQXAC9IVRw",
        "https://m.youtube.com/live/jNQXAC9IVRw",
        "https://www.youtube.com/embed/jNQXAC9IVRw"
    ] {
        let video = try YouTubeVideo(url: URL(string: address)!)
        try require(video.id == "jNQXAC9IVRw" && video.sourceURL.absoluteString == address,
                    "The YouTube video ID or original URL changed")
    }
    for address in [
        "https://www.youtube.com.evil.example/watch?v=jNQXAC9IVRw",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/watch?v=short"
    ] {
        try require((try? YouTubeVideo(url: URL(string: address)!)) == nil, "A non-video URL passed validation")
    }
    state.draft.title = "前のタイトル"
    state.draft.urls["url"] = "https://example.com/old"
    state.draft.body = "既存の本文"
    state.draft.tags = ["reference": ["character"], "notes": ["idea"]]
    let original = state.draft
    await state.addVideo(shortLink, loadTitle: { _ in throw URLError(.resourceUnavailable) }, canReplaceTitle: { true })
    try require(state.draft == original, "A failed video import altered the draft")
    await state.addVideo(shortLink, loadTitle: { _ in
        state.draft.title = "取得中に編集したタイトル"
        return "取得した動画タイトル"
    }, canReplaceTitle: { true })
    try require(state.draft.title == "取得中に編集したタイトル" && state.draft.urls == original.urls && state.draft.tags == original.tags,
                "An import overwrote a pending title edit")
    await state.addVideo(shortLink, loadTitle: { _ in "取得した動画タイトル" }, canReplaceTitle: { false })
    try require(state.draft.title == "取得中に編集したタイトル" && state.draft.urls == original.urls,
                "An import overwrote marked text")
    await state.addVideo(shortLink, loadTitle: { _ in "取得した動画タイトル" }, canReplaceTitle: { true })
    await state.addVideo(shortLink, loadTitle: { _ in "取得した動画タイトル" }, canReplaceTitle: { true })
    try require(state.draft.title == "取得した動画タイトル" && state.draft.urls["url"] == shortLink.absoluteString &&
                state.draft.tags == ["reference": ["character", "web"], "notes": ["idea"]] &&
                state.draft.body == original.body, "Video import did not update just the requested fields")
    let imported = state.draft
    try require(try AppVerification.state(root: location).draft == imported, "Video fields were not persisted")
    await state.submit()
    guard let payload = try OfflineProtocol.pagePayload.flatMap({ try JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
          let properties = payload["properties"] as? [String: [String: Any]] else {
        throw CheckFailure.failed("No page payload after sending imported video")
    }
    try require(properties["url"]?["url"] as? String == shortLink.absoluteString &&
                (properties["reference"]?["multi_select"] as? [[String: String]])?.compactMap { $0["id"] } == ["character", "web"],
                "Notion payload lost the URL or existing tag IDs")

    for index in 1...11 {
        state.draft.title = "送信 \(index)"
        state.draft.tags = ["reference": [index % 2 == 0 ? "web" : "character"], "notes": ["idea"]]
        state.draft.urls["url"] = "https://example.com/\(index)"
        await state.submit()
    }
    let reopened = try AppVerification.state(root: location)
    try require(reopened.recentSends.count == 5 && reopened.recentPropertyInputs.count == 10 &&
                reopened.recentPropertyInputs[0].urls["url"] == "https://example.com/11" &&
                reopened.recentPropertyInputs[9].urls["url"] == "https://example.com/2",
                "Recent property inputs did not persist in order independently of send history")
    let other = NotionDestination(name: "別の保存先", databaseID: UUID(), dataSourceID: UUID())
    try require(try AppVerification.state(root: location, destination: other).recentPropertyInputs.isEmpty,
                "Recent properties leaked across destinations")

    reopened.draft.title = "残すタイトル"
    reopened.draft.body = "残す本文"
    reopened.draft.tags = ["reference": ["web", "character"]]
    reopened.draft.urls = ["url": "https://example.com/draft"]
    let writer = WriterWindow(state: reopened)
    let row = writer.tagRows.first!
    row.filter()
    try require(row.table.selectedRow == 1, "The first recent input was not selected below its heading")
    let editor = NSTextView()
    try require(row.control(row.search, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))) &&
                row.table.selectedRow == row.table.numberOfRows - 1, "Up did not wrap to the last candidate")
    try require(row.control(row.search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))) &&
                row.table.selectedRow == 1, "Down did not wrap to the first selectable row")
    _ = row.control(row.search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    try require(reopened.draft.tags == ["reference": ["character"], "notes": ["idea"]] &&
                reopened.draft.urls == ["url": "https://example.com/11"] &&
                reopened.draft.title == "残すタイトル" && reopened.draft.body == "残す本文",
                "Recall through Enter did not replace all properties alone")
    row.filter()
    (row.tableView(row.table, viewFor: row.table.tableColumns.first, row: 2) as? NSButton)?.performClick(nil)
    try require(reopened.draft.tags["reference"] == ["web"] &&
                reopened.draft.urls["url"] == "https://example.com/10", "Click did not restore the second property set")
    for direction in [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:))] {
        writer.focusProperty(0)
        _ = row.control(row.search, textView: editor, doCommandBy: direction)
        try require(!row.optionsPanel.isVisible && writer.window?.firstResponder === writer.titleEditor,
                    "Horizontal arrows did not return title focus")
    }
    writer.window?.orderOut(nil)
    print("PASS: YouTube fields and failure safety, recent inputs across restart, keyboard wrap and Enter/click recall")
}
