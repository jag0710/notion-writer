import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BookmarkPreview: Sendable {
    let title: String
    let summary: String?
    let thumbnail: Data?

    struct Metadata: Sendable {
        let title: String
        let summary: String?
        let image: URL?

        static func fetch(_ url: URL) async -> Self? {
            guard let document = try? await WebDocument.load(url) else { return nil }
            let title = document.title() ?? document.base?.host ?? url.host ?? url.absoluteString
            let summary = document.meta("og:description") ?? document.meta("description")
            let image = WebResource.url(document.meta("og:image") ?? document.meta("twitter:image"), relativeTo: document.base)
            return Self(title: String(title.prefix(300)), summary: summary.map { String($0.prefix(400)) }, image: image)
        }

        func preview() async -> BookmarkPreview {
            let thumbnail: Data?
            if let image, let (data, _) = try? await WebResource.read(image, limit: 5 * 1024 * 1024) {
                thumbnail = BookmarkPreview.jpegThumbnail(data)
            } else {
                thumbnail = nil
            }
            return BookmarkPreview(title: title, summary: summary, thumbnail: thumbnail)
        }
    }

    static func jpegThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? buffer as Data : nil
    }
}

actor BookmarkPreviews {
    static let shared = BookmarkPreviews()
    private struct Entry {
        let url: URL
        let metadata: Task<BookmarkPreview.Metadata?, Never>
        let preview: Task<BookmarkPreview?, Never>
        var expiresAt: Date
    }
    private var entries: [Entry] = []

    func metadata(_ url: URL) async -> BookmarkPreview.Metadata? {
        await entry(for: url).metadata.value
    }

    func load(_ url: URL) async -> BookmarkPreview? {
        let entry = entry(for: url)
        let preview = await entry.preview.value
        if preview?.thumbnail == nil, let index = entries.firstIndex(where: { $0.preview == entry.preview }) {
            entries[index].expiresAt = min(entries[index].expiresAt, Date().addingTimeInterval(60))
        }
        return preview
    }

    private func entry(for url: URL) -> Entry {
        let now = Date()
        entries.removeAll { $0.expiresAt <= now }
        if let existing = entries.first(where: { $0.url == url }) { return existing }
        let metadata = Task { await BookmarkPreview.Metadata.fetch(url) }
        let preview = Task { await metadata.value?.preview() }
        let entry = Entry(url: url, metadata: metadata, preview: preview, expiresAt: now.addingTimeInterval(900))
        entries.append(entry)
        if entries.count > 32 { entries.removeFirst() }
        return entry
    }
}
