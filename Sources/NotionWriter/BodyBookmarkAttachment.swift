import AppKit
import ImageIO

final class BodyBookmarkAttachment: NSTextAttachment {
    let url: URL
    private let font: NSFont
    private var requestedPreview = false

    init(_ url: URL, font: NSFont) {
        self.url = url
        self.font = font
        super.init(data: nil, ofType: nil)
        attachmentCell = NSTextAttachmentCell(imageCell: card(title: url.host ?? url.absoluteString, description: url.absoluteString))
    }

    required init?(coder: NSCoder) { nil }

    @MainActor func loadPreview(in editor: NSTextView) {
        guard !requestedPreview, editor.window?.isVisible == true else { return }
        requestedPreview = true
        Task { [weak self, weak editor] in
            guard let url = self?.url, let document = try? await WebDocument.load(url),
                  let title = document.title() else { return }
            let description = document.meta("og:description") ?? document.meta("description")
            self?.show(title: title, description: description, thumbnail: nil, editor: editor)
            guard let image = WebResource.url(document.meta("og:image") ?? document.meta("twitter:image"), relativeTo: document.base),
                  let (data, _) = try? await WebResource.read(image, limit: 5 * 1024 * 1024),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, nil) ?? CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return }
            self?.show(title: title, description: description, thumbnail: NSImage(cgImage: thumbnail, size: .zero), editor: editor)
        }
    }

    private func show(title: String, description: String?, thumbnail: NSImage?, editor: NSTextView?) {
        (attachmentCell as? NSTextAttachmentCell)?.image = card(title: title, description: description, thumbnail: thumbnail)
        if let editor { editor.setNeedsDisplay(editor.visibleRect) }
    }

    private func card(title: String, description: String?, thumbnail: NSImage? = nil) -> NSImage {
        let point = font.pointSize
        let size = NSSize(width: min(430, max(300, point * 23)), height: max(88, ceil(point * 4.8 + 14)))
        let host = url.host ?? url.absoluteString
        let card = NSImage(size: size, flipped: false) { rect in
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            WriterStyle.hover.setFill()
            outline.fill()
            NSColor.separatorColor.setStroke()
            outline.stroke()
            let pad: CGFloat = 11
            let imageWidth = thumbnail == nil ? 0 : rect.height - pad * 2
            let textWidth = rect.width - pad * 2 - (imageWidth > 0 ? imageWidth + pad : 0)
            let header = NSRect(x: pad, y: rect.maxY - pad - point * 1.5, width: textWidth, height: point * 1.5)
            Self.draw(title, in: header, font: .systemFont(ofSize: point, weight: .semibold), color: WriterStyle.ink)
            if let description {
                let summary = NSRect(x: pad, y: pad + point * 1.35, width: textWidth, height: header.minY - pad - point * 1.55)
                Self.draw(description, in: summary, font: .systemFont(ofSize: point * 0.85), color: WriterStyle.ink, wraps: true)
            }
            Self.draw(host, in: NSRect(x: pad, y: pad, width: textWidth, height: point * 1.2),
                      font: .systemFont(ofSize: point * 0.77), color: WriterStyle.muted)
            if let thumbnail {
                let destination = NSRect(x: rect.maxX - pad - imageWidth, y: pad, width: imageWidth, height: imageWidth)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: destination, xRadius: 5, yRadius: 5).addClip()
                let scale = max(destination.width / thumbnail.size.width, destination.height / thumbnail.size.height)
                let w = thumbnail.size.width * scale, h = thumbnail.size.height * scale
                thumbnail.draw(in: NSRect(x: destination.midX - w / 2, y: destination.midY - h / 2, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        card.accessibilityDescription = title + " " + host
        return card
    }

    private static func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, wraps: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func fragment(_ url: URL, font: NSFont) -> NSAttributedString {
        let fragment = NSMutableAttributedString(attachment: BodyBookmarkAttachment(url, font: font))
        fragment.addAttribute(.font, value: font, range: NSRange(location: 0, length: fragment.length))
        fragment.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return fragment
    }
}
