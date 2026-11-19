import AppKit
import ImageIO
import UniformTypeIdentifiers
import NotionWriterCore

// Copies are owned by the draft, so moving a Finder original never breaks a pending note.
enum ImageAttachments {
    static let maximumBytes = 20 * 1024 * 1024
    static func directory(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func url(for image: DraftImage, root: URL) throws -> URL {
        guard image.localFile == (image.localFile as NSString).lastPathComponent, !image.localFile.hasPrefix(".") else {
            throw WriterError.validation("下書きの画像パスを読み取れませんでした。")
        }
        return try directory(root).appendingPathComponent(image.localFile)
    }
    static func importFile(_ url: URL, root: URL) throws -> DraftImage {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try importData(Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent, root: root)
    }
    static func importData(_ original: Data, name: String, root: URL) throws -> DraftImage {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil), let typeID = CGImageSourceGetType(source) else {
            throw WriterError.validation("「\(name)」を画像として読み取れませんでした。")
        }
        let type = UTType(typeID as String)
        let supported: [UTType: (String, String)] = [.png: ("png", "image/png"), .jpeg: ("jpg", "image/jpeg"), .gif: ("gif", "image/gif"), .webP: ("webp", "image/webp")]
        let data: Data; let ext: String; let mime: String
        if let format = type.flatMap({ supported[$0] }) { data = original; ext = format.0; mime = format.1 }
        else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WriterError.validation("画像を変換できませんでした。") }
            let converted = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(converted, UTType.png.identifier as CFString, 1, nil) else { throw WriterError.validation("画像を変換できませんでした。") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw WriterError.validation("画像を変換できませんでした。") }
            data = converted as Data; ext = "png"; mime = "image/png"
        }
        guard !data.isEmpty, data.count <= maximumBytes else { throw WriterError.validation("「\(name)」は20MBを超えています。1枚20MBまで追加できます。") }
        let id = UUID().uuidString; let filename = id + "." + ext
        let file = try directory(root).appendingPathComponent(filename)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return DraftImage(id: id, name: name, localFile: filename, contentType: mime, byteCount: data.count)
    }
    static func tidyCache(root: URL, now: Date = Date(), trash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("attachments", isDirectory: true)
        guard manager.fileExists(atPath: folder.path) else { return }
        let folderInfo = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderInfo.isDirectory == true, folderInfo.isSymbolicLink != true else { return }

        let draftFiles = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { file in
            let name = file.lastPathComponent
            return file.pathExtension == "json" && (name.hasPrefix("draft-") ||
                name == "last-saved-draft.json" || name == "confirmed-saved-draft.json")
        }
        var retained = Set<String>()
        for file in draftFiles {
            let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: file))
            retained.formUnion(draft.images.map(\.localFile))
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            guard !retained.contains(file.lastPathComponent), ["png", "jpg", "gif", "webp"].contains(file.pathExtension),
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            let info = try file.resourceValues(forKeys: keys)
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let modified = info.contentModificationDate, modified < cutoff else { continue }
            try trash(file)
        }
    }

    static func thumbnail(_ image: DraftImage, root: URL, maximumPixels: Int) -> NSImage? {
        guard let url = try? url(for: image, root: root), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

final class BodyImageAttachment: NSTextAttachment {
    let draftImage: DraftImage

    init(_ image: DraftImage, root: URL, width: CGFloat, height: CGFloat) {
        draftImage = image
        super.init(data: nil, ofType: nil)
        let preview = ImageAttachments.thumbnail(image, root: root, maximumPixels: 960)
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: image.name)
            ?? NSImage(size: NSSize(width: 24, height: 24))
        let size = preview.size
        let scale = min(1, width / max(1, size.width), height / max(1, size.height))
        preview.size = NSSize(width: size.width * scale, height: size.height * scale)
        preview.accessibilityDescription = image.name
        attachmentCell = NSTextAttachmentCell(imageCell: preview)
    }

    required init?(coder: NSCoder) { nil }
}

enum ImageTransfer {
    static func files(_ pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }.filter { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) == true
        }
    }
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        !files(pasteboard).isEmpty || pasteboard.availableType(from: [.png, .tiff]) != nil
    }
    static func accept(_ pasteboard: NSPasteboard, files: (([URL]) -> Void)?, data: ((Data) -> Void)?) -> Bool {
        let urls = self.files(pasteboard)
        if !urls.isEmpty, let files { files(urls); return true }
        if let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let data { data(bytes); return true }
        return false
    }
}
class ImageDropView: NSView {
    var importFiles: (([URL]) -> Void)?
    var importData: ((Data) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL,.png,.tiff]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { ImageTransfer.canRead(sender.draggingPasteboard) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { ImageTransfer.accept(sender.draggingPasteboard, files: importFiles, data: importData) }
}
