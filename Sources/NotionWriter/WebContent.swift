import Foundation
import NotionWriterCore

enum WebResource {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    static func url(_ value: String?, relativeTo base: URL? = nil) -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: value, relativeTo: base)?.absoluteURL else { return nil }
        return PagePayload.bookmarkURL(url.absoluteString)
    }

    static func read(_ url: URL, limit: Int, using session: URLSession = session) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) NotionWriter", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = self.url(http.url?.absoluteString), response.expectedContentLength <= Int64(limit) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, finalURL)
    }
}

struct WebDocument {
    let root: XMLElement
    let base: URL?

    init?(html: String, base: URL?) {
        guard !html.isEmpty, html.utf8.count <= 6 * 1024 * 1024 else { return nil }
        let source = html
            .replacingOccurrences(of: #"(?i)<article(?=[\s>])"#, with: #"<div data-writer-article="1""#, options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</article\s*>"#, with: "</div>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<(/?)figure(?=[\s>])"#, with: "<$1div", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<(/?)figcaption(?=[\s>])"#, with: "<$1p", options: .regularExpression)
        guard let xml = try? XMLDocument(xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = xml.rootElement() else { return nil }
        self.root = root
        self.base = base
    }

    static func load(_ url: URL) async throws -> WebDocument {
        let (data, finalURL) = try await WebResource.read(url, limit: 6 * 1024 * 1024)
        guard let html = String(data: data, encoding: .utf8), let document = WebDocument(html: html, base: finalURL) else {
            throw WriterError.validation("記事のHTMLを読み取れませんでした。")
        }
        return document
    }

    func title() -> String? {
        meta("og:title") ?? root.firstElement(where: { $0.name == "title" })?.stringValue?.webText
    }

    func meta(_ key: String) -> String? {
        root.firstElement { node in
            node.name == "meta" && (node.value("property") ?? node.value("name"))?.lowercased() == key
        }?.value("content")?.webText
    }
}

extension XMLElement {
    func value(_ name: String) -> String? { attribute(forName: name)?.stringValue }

    func firstElement(where includes: (XMLElement) -> Bool) -> XMLElement? {
        if includes(self) { return self }
        for case let element as XMLElement in children ?? [] {
            if let found = element.firstElement(where: includes) { return found }
        }
        return nil
    }
}

extension String {
    var webText: String? {
        let value = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}
