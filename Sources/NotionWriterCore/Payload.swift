import Foundation

public enum PagePayload {
    // Count UTF-16 conservatively, never split Unicode scalars (including emoji surrogate pairs).
    public static func chunks(_ text: String, limit: Int = 2000) -> [String] {
        precondition(limit >= 2)
        var result: [String] = []; var chunk = ""; var count = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf16.count
            if count + length > limit { result.append(chunk); chunk = ""; count = 0 }
            chunk.unicodeScalars.append(scalar); count += length
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
    private static func richText(_ text: String) throws -> [[String: Any]] {
        let pieces = chunks(text)
        guard pieces.count <= 100 else { throw WriterError.validation("文章がNotion APIの上限を超えています。内容を短くしてください。下書きは保持します。") }
        return pieces.map { ["type": "text", "text": ["content": $0]] }
    }
    private static let bodyBlockTypes: Set<String> = [
        "paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item", "numbered_list_item",
        "quote", "to_do", "code", "divider", "table", "bookmark", "draft_image"
    ]

    private static func validText(_ value: Any?) -> Bool {
        guard let runs = value as? [[String: Any]] else { return false }
        return runs.allSatisfy { run in
            run["type"] as? String == "text" && (run["text"] as? [String: Any])?["content"] is String
        }
    }

    private static func validStoredBlock(_ block: [String: Any]) -> Bool {
        guard let type = block["type"] as? String, bodyBlockTypes.contains(type),
              let content = block[type] as? [String: Any] else { return false }
        switch type {
        case "divider", "draft_image":
            return content["children"] == nil
        case "bookmark":
            return content["children"] == nil && bookmarkURL(in: block) != nil
                && (content["caption"] == nil || validText(content["caption"]))
        case "table":
            guard let columns = content["table_width"] as? Int, columns > 0,
                  let rows = content["children"] as? [[String: Any]], !rows.isEmpty else { return false }
            return rows.allSatisfy { row in
                guard row["type"] as? String == "table_row",
                      let rowContent = row["table_row"] as? [String: Any], rowContent["children"] == nil,
                      let cells = rowContent["cells"] as? [[[String: Any]]] else { return false }
                return cells.count == columns && cells.allSatisfy { validText($0) }
            }
        default:
            return content["children"] == nil && validText(content["rich_text"])
        }
    }

    public static func bodyBlocks(_ draft: Draft) throws -> [[String: Any]] {
        if let stored = draft.formattedBody {
            guard let blocks = try JSONSerialization.jsonObject(with: stored) as? [[String: Any]] else {
                throw WriterError.validation("本文の書式データを読み取れません。下書きは保持します。")
            }
            if draft.bodyFormat == .markdown || blocks.contains(where: { imageReferenceID($0) != nil }) {
                guard blocks.allSatisfy(validStoredBlock) else {
                    throw WriterError.validation("本文に読み取れないブロックがあります。下書きは保持します。")
                }
                return blocks
            }
        }
        if draft.bodyFormat == .markdown { return try MarkdownBody.blocks(draft.body) }
        guard !draft.body.isEmpty else { return [] }
        let pieces = chunks(draft.body)
        return try pieces.map { text in ["object": "block", "type": "paragraph", "paragraph": ["rich_text": try richText(text)]] }
    }
    public static func bookmarkURL(_ source: String) -> URL? {
        guard source.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.absoluteString.utf16.count <= 2000 else { return nil }
        return url
    }

    public static func bookmarkURL(in block: [String: Any]) -> URL? {
        guard block["type"] as? String == "bookmark",
              let content = block["bookmark"] as? [String: Any],
              let source = content["url"] as? String else { return nil }
        return bookmarkURL(source)
    }

    public static func urlText(_ url: URL) -> [String: Any] {
        let text: [String: Any] = ["type": "text", "text": ["content": url.absoluteString, "link": ["url": url.absoluteString]]]
        return ["object": "block", "type": "paragraph", "paragraph": ["rich_text": [text]]]
    }

    private static let webURLDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func linkingBodyURLs(_ block: [String: Any]) -> [String: Any] {
        guard let type = block["type"] as? String, type != "code",
              var content = block[type] as? [String: Any] else { return block }

        func linkRuns(_ runs: [[String: Any]]) -> [[String: Any]] {
            var result: [[String: Any]] = []
            for (index, run) in runs.enumerated() {
                let remaining = runs.count - index - 1
                guard result.count + 1 + remaining <= 100, var text = run["text"] as? [String: Any],
                      text["link"] == nil || text["link"] is NSNull,
                      (run["annotations"] as? [String: Any])?["code"] as? Bool != true,
                      let raw = text["content"] as? String, raw.range(of: "http", options: .caseInsensitive) != nil else {
                    result.append(run)
                    continue
                }
                let source = raw as NSString
                var pieces: [[String: Any]] = []
                var offset = 0
                func append(_ range: NSRange, url: URL? = nil) {
                    guard range.length != 0 else { return }
                    var part = run
                    text["content"] = source.substring(with: range)
                    if let url { text["link"] = ["url": url.absoluteString] }
                    else { text.removeValue(forKey: "link") }
                    part["text"] = text
                    pieces.append(part)
                }
                for match in webURLDetector.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
                    guard let url = bookmarkURL(source.substring(with: match.range)) else { continue }
                    append(NSRange(location: offset, length: match.range.location - offset))
                    append(match.range, url: url)
                    offset = NSMaxRange(match.range)
                }
                if offset == 0 {
                    result.append(run)
                    continue
                }
                append(NSRange(location: offset, length: source.length - offset))
                result += result.count + pieces.count + remaining <= 100 ? pieces : [run]
            }
            return result
        }
        if let runs = content["rich_text"] as? [[String: Any]] {
            content["rich_text"] = linkRuns(runs)
        } else if type == "table", let rows = content["children"] as? [[String: Any]] {
            content["children"] = rows.map { row -> [String: Any] in
                guard var rowContent = row["table_row"] as? [String: Any],
                      let cells = rowContent["cells"] as? [[[String: Any]]] else { return row }
                var linked = row
                rowContent["cells"] = cells.map(linkRuns)
                linked["table_row"] = rowContent
                return linked
            }
        } else {
            return block
        }
        var linked = block
        linked[type] = content
        return linked
    }

    public static func replacingLegacyBookmark(_ block: [String: Any]) -> [String: Any] {
        guard let url = bookmarkURL(in: block) else { return block }
        let plain = urlText(url)
        let bookmark = block["bookmark"] as? [String: Any]
        guard let caption = bookmark?["caption"] as? [[String: Any]], !caption.isEmpty,
              let paragraph = plain["paragraph"] as? [String: Any],
              let address = paragraph["rich_text"] as? [[String: Any]] else { return plain }
        let newline: [String: Any] = ["type": "text", "text": ["content": "\n"]]
        return ["object": "block", "type": "paragraph", "paragraph": ["rich_text": address + [newline] + caption]]
    }

    public static func imageReference(_ id: String) -> [String: Any] {
        ["type": "draft_image", "draft_image": ["id": id]]
    }

    public static func imageReferenceID(_ block: [String: Any]) -> String? {
        guard block["type"] as? String == "draft_image" else { return nil }
        return (block["draft_image"] as? [String: String])?["id"]
    }

    public static func bodyWithImages(_ draft: Draft) throws -> [[String: Any]] {
        var blocks = try bodyBlocks(draft)
        let knownImages = Set(draft.images.map(\.id))
        let references = blocks.filter { $0["type"] as? String == "draft_image" }
        let placed = Set(references.compactMap(imageReferenceID))
        guard placed.count == references.count, placed.isSubset(of: knownImages) else {
            throw WriterError.validation("本文と画像の情報が一致しません。下書きは保持します。")
        }
        blocks += draft.images.filter { !placed.contains($0.id) }.map { imageReference($0.id) }
        return blocks
    }

    public static func make(draft: Draft, schema: Schema, uploadedImages: [String: String] = [:], destination: NotionDestination) throws -> Data {
        let delivery = try prepare(draft: draft, schema: schema, uploadedImages: uploadedImages, destination: destination)
        guard delivery.continuation.isEmpty else {
            throw WriterError.validation("本文を分割して送信してください。下書きは保持します。")
        }
        return delivery.create
    }

    private static func uploadedImage(_ id: String) -> [String: Any] {
        ["object": "block", "type": "image", "image": ["type": "file_upload", "file_upload": ["id": id]]]
    }

    public struct Delivery {
        public let create: Data
        public let continuation: [Data]
    }

    public static func prepare(draft: Draft, schema: Schema, uploadedImages: [String: String] = [:],
                               destination: NotionDestination) throws -> Delivery {
        try destination.validate(schema)
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WriterError.validation("文章を入力してください。") }
        guard let title = schema.properties.first(where: { $0.type == "title" }) else { throw WriterError.validation("タイトルプロパティが見つかりません。再同期してください。") }
        var properties: [String: Any] = [title.id: ["title": try richText(draft.title)]]
        for (id, selection) in draft.tags where !selection.isEmpty {
            guard let prop = schema.tags.first(where: { $0.id == id }), selection.allSatisfy({ tag in prop.options.contains { $0.id == tag } }) else {
                throw WriterError.validation("選択したタグがNotion側で変更されています。再同期して選び直してください。")
            }
            guard selection.count <= 100 else { throw WriterError.validation("1つのプロパティで選べるタグは100個までです。") }
            properties[id] = ["multi_select": selection.map { ["id": $0] }]
        }
        for (id, text) in draft.urls where !text.isEmpty {
            guard schema.urls.contains(where: { $0.id == id }) else { throw WriterError.validation("URLプロパティが変更されています。再同期してください。") }
            guard text.utf16.count <= 2000, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw WriterError.validation("URLには有効な http / https のアドレスを入力してください。")
            }
            properties[id] = ["url": text]
        }
        let body: [String: Any] = ["parent": ["type": "data_source_id", "data_source_id": schema.dataSourceID], "properties": properties]
        let images = Set(draft.images.map(\.id))
        let children = try bodyWithImages(draft).map { block in
            guard let imageID = imageReferenceID(block) else { return linkingBodyURLs(replacingLegacyBookmark(block)) }
            guard images.contains(imageID), let uploadID = uploadedImages[imageID], UUID(uuidString: uploadID) != nil else {
                throw WriterError.validation("画像の送信が完了していません。下書きは保持しています。")
            }
            return uploadedImage(uploadID)
        }
        return try batch(page: body, blocks: children)
    }

    private static func batch(page: [String: Any], blocks: [[String: Any]]) throws -> Delivery {
        func encode(_ fields: [String: Any], _ children: [[String: Any]]) throws -> Data {
            var payload = fields
            if !children.isEmpty { payload["children"] = children }
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }
        func blockCount(_ block: [String: Any]) -> Int {
            let type = block["type"] as? String ?? ""
            let content = block[type] as? [String: Any]
            let children = content?["children"] as? [[String: Any]] ?? []
            return 1 + children.reduce(0) { $0 + blockCount($1) }
        }
        let initial = try encode(page, [])
        guard initial.count < 500_000 else {
            throw WriterError.validation("タイトルとプロパティがNotionの送信サイズ上限を超えています。")
        }
        var batches: [Data] = []
        var current: [[String: Any]] = []
        var currentBytes = initial.count
        var currentBlocks = 0
        for block in blocks {
            let bytes = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys]).count + 1
            let count = blockCount(block)
            if current.count == 100 || currentBytes + bytes + 20 >= 500_000 || currentBlocks + count > 1_000 {
                batches.append(try encode(batches.isEmpty ? page : [:], current))
                current.removeAll(keepingCapacity: true)
                currentBytes = 2
                currentBlocks = 0
            }
            guard currentBytes + bytes + 20 < 500_000 && count <= 1_000 else {
                throw WriterError.validation("本文の一部がNotionの送信サイズ上限を超えています。下書きは保持します。")
            }
            current.append(block)
            currentBytes += bytes
            currentBlocks += count
        }
        if !current.isEmpty || batches.isEmpty {
            batches.append(try encode(batches.isEmpty ? page : [:], current))
        }
        return Delivery(create: batches[0], continuation: Array(batches.dropFirst()))
    }
}
