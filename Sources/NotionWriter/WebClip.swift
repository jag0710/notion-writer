import Foundation
import NotionWriterCore

enum WebClip {
    enum Source {
        case selection(String, base: URL?, fallback: String?)
        case article(URL)
    }

    enum Part {
        case block([String: Any])
        case image(URL, alt: String)
    }

    struct Prepared {
        var title: String?
        var blocks: [[String: Any]] = []
        var images: [DraftImage] = []
        var skippedImages = 0
    }

    static func read(_ source: Source, loadArticle: (URL) async throws -> WebDocument = WebDocument.load)
        async throws -> (title: String?, parts: [Part]) {
        switch source {
        case let .selection(html, base, fallback):
            if let document = WebDocument(html: html, base: base),
               let body = document.root.firstElement(where: { $0.name == "body" }) {
                let content = parts(in: body, base: document.base)
                if !content.isEmpty { return (nil, content) }
            }
            if let fallback { return (nil, try MarkdownBody.blocks(fallback).map(Part.block)) }
            throw WriterError.validation("コピーした記事の書式を読み取れませんでした。")
        case .article(let url):
            let document = try await loadArticle(url)
            let noteBody = document.root.firstElement {
                $0.value("class")?.split(separator: " ").contains("note-common-styles__textnote-body") == true
            }
            let body = noteBody ?? document.root.firstElement {
                $0.value("data-writer-article") == "1" || $0.value("role") == "main"
            }
            guard let body else { throw WriterError.validation("記事本文を見つけられませんでした。ブラウザで本文を選択してコピーしてください。") }
            let content = parts(in: body, base: document.base)
            guard !content.isEmpty else { throw WriterError.validation("公開されている記事本文を読み取れませんでした。") }
            let heading = noteBody == nil ? nil : document.root.firstElement { $0.name == "h1" }
            let title = heading?.stringValue?.webText ?? document.title()
            return (title.map(bracketedTitle), content)
        }
    }

    private static func bracketedTitle(_ title: String) -> String {
        if title.hasPrefix("【"), title.hasSuffix("】") { return title }
        return "【" + title + "】"
    }

    static func parts(in body: XMLElement, base: URL?) -> [Part] {
        var reader = Reader(base: base)
        reader.walk(body, style: .init())
        reader.flush()
        return reader.parts
    }

    static func prepare(_ source: Source, root: URL, availableImages: Int,
                        imageData: (URL) async throws -> Data = remoteImage) async throws -> Prepared {
        let clip = try await read(source)
        var result = Prepared(title: clip.title)
        let deadline = Date().addingTimeInterval(45)
        for part in clip.parts {
            switch part {
            case .block(let block):
                result.blocks.append(block)
            case .image(let url, let alt):
                do {
                    guard result.images.count < availableImages, Date() < deadline else { throw URLError(.timedOut) }
                    let data = try await imageData(url)
                    let image = try ImageAttachments.importData(data, name: url.lastPathComponent, root: root)
                    result.images.append(image)
                    result.blocks.append(PagePayload.imageReference(image.id))
                } catch {
                    result.skippedImages += 1
                    result.blocks.append(block("paragraph", runs: textRuns(alt.isEmpty ? url.absoluteString : alt, link: url)))
                }
            }
        }
        return result
    }

    private static func remoteImage(_ url: URL) async throws -> Data {
        try await WebResource.read(url, limit: ImageAttachments.maximumBytes).0
    }

    fileprivate static func block(_ kind: String, runs: [[String: Any]]) -> [String: Any] {
        ["object": "block", "type": kind, kind: ["rich_text": runs]]
    }

    fileprivate static func textRuns(_ text: String, link: URL?, marks: [String: Bool] = [:]) -> [[String: Any]] {
        PagePayload.chunks(text).map { chunk in
            var content: [String: Any] = ["content": chunk]
            if let link { content["link"] = ["url": link.absoluteString] }
            var run: [String: Any] = ["type": "text", "text": content]
            if !marks.isEmpty { run["annotations"] = marks }
            return run
        }
    }
}

private struct Reader {
    struct Style {
        var link: URL?
        var marks: [String: Bool] = [:]
    }

    let base: URL?
    var parts: [WebClip.Part] = []
    private var kind = "paragraph"
    private var runs: [[String: Any]] = []
    private var endsInSpace = false

    init(base: URL?) { self.base = base }

    mutating func flush(keepEmpty: Bool = false) {
        if endsInSpace, var run = runs.last, var text = run["text"] as? [String: Any],
           var content = text["content"] as? String, content.hasSuffix(" ") {
            content.removeLast()
            if content.isEmpty {
                runs.removeLast()
            } else {
                text["content"] = content
                run["text"] = text
                runs[runs.count - 1] = run
            }
        }
        if !runs.isEmpty || keepEmpty {
            parts.append(.block(PagePayload.linkingBodyURLs(WebClip.block(kind, runs: runs))))
            runs.removeAll(keepingCapacity: true)
        }
        endsInSpace = false
    }

    private mutating func add(_ value: String, style: Style) {
        var text = value.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
        if (runs.isEmpty || endsInSpace) && text.hasPrefix(" ") { text.removeFirst() }
        guard !text.isEmpty else { return }
        endsInSpace = text.hasSuffix(" ")
        runs += WebClip.textRuns(text, link: style.link, marks: style.marks)
    }

    mutating func walk(_ node: XMLNode, style parent: Style, depth: Int = 0) {
        guard depth < 128 else { return }
        guard let element = node as? XMLElement else {
            if node.kind == .text, let value = node.stringValue { add(value, style: parent) }
            return
        }
        let tag = element.name?.lowercased() ?? ""
        let classes = element.value("class")?.split(whereSeparator: \.isWhitespace) ?? []
        guard element.attribute(forName: "hidden") == nil,
              !["head", "script", "style", "noscript", "template", "nav", "button"].contains(tag) else { return }
        if classes.contains("external-article-widget"),
           let link = element.firstElement(where: { $0.name == "a" }),
           let url = WebResource.url(link.value("href"), relativeTo: base) {
            flush()
            parts.append(.block(PagePayload.urlText(url)))
            return
        }
        if tag == "img" {
            let alt = element.value("alt") ?? ""
            if let url = WebResource.url(element.value("src"), relativeTo: base)
                ?? WebResource.url(element.value("data-src"), relativeTo: base) {
                flush()
                parts.append(.image(url, alt: alt))
            } else {
                add(alt, style: parent)
            }
            return
        }
        if tag == "iframe" || tag == "video" {
            if let url = WebResource.url(element.value("src"), relativeTo: base) {
                flush()
                parts.append(.block(PagePayload.urlText(url)))
            }
            return
        }
        if tag == "br" {
            runs += WebClip.textRuns("\n", link: parent.link, marks: parent.marks)
            endsInSpace = true
            return
        }
        if tag == "pre", let value = element.stringValue, !value.isEmpty {
            flush()
            let code: [String: Any] = ["rich_text": WebClip.textRuns(value, link: nil), "language": "plain text"]
            parts.append(.block(["object": "block", "type": "code", "code": code]))
            return
        }
        var style = parent
        switch tag {
        case "a": style.link = WebResource.url(element.value("href"), relativeTo: base)
        case "b", "strong": style.marks["bold"] = true
        case "i", "em": style.marks["italic"] = true
        case "s", "del": style.marks["strikethrough"] = true
        case "code": style.marks["code"] = true
        default: break
        }
        let nextKind: String?
        switch tag {
        case "h1": nextKind = "heading_1"
        case "h2": nextKind = "heading_2"
        case "h3", "h4", "h5", "h6": nextKind = "heading_3"
        case "blockquote": nextKind = "quote"
        case "li": nextKind = element.parent?.name == "ol" ? "numbered_list_item" : "bulleted_list_item"
        case "p", "div", "section", "article", "figure", "figcaption", "pre": nextKind = kind
        default: nextKind = nil
        }
        let before = kind
        if let nextKind { flush(); kind = nextKind }
        let beforeChildren = parts.count
        for child in element.children ?? [] { walk(child, style: style, depth: depth + 1) }
        if nextKind != nil {
            if tag == "p", beforeChildren == parts.count {
                let contents = runs.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
                if contents.filter({ $0 == "\n" }).count <= 1 &&
                    contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    runs.removeAll(keepingCapacity: true)
                }
                flush(keepEmpty: true)
            } else {
                flush()
            }
            kind = before
        }
    }
}
