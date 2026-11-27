import AppKit

enum WriterStyle {
    static let muted = NSColor(calibratedWhite: 0.55, alpha: 1)
    static let ink = NSColor(calibratedWhite: 0.22, alpha: 1)
    static let hover = NSColor(calibratedWhite: 0.955, alpha: 1)
}

// Flat controls keep the writing surface quiet; the entire row remains clickable.
class QuietButton: NSButton {
    private var tracking: NSTrackingArea?
    var hovered = false
    var highlightsOnHover = true
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; focusRingType = .none; contentTintColor = WriterStyle.muted }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && ((highlightsOnHover && hovered) || isHighlighted) {
            WriterStyle.hover.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

final class WriterCardView: ImageDropView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let window, window.isMovable { window.performDrag(with: event) }
    }
}

struct NotionTagColors {
    let background: NSColor
    let foreground: NSColor
    private init(_ background: UInt32, _ foreground: UInt32) {
        func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        self.background = color(background); self.foreground = color(foreground)
    }
    private static let palette: [String: NotionTagColors] = [
        "default": .init(0xF1F0EE, 0x37352F),
        "gray": .init(0xE3E2E0, 0x37352F),
        "brown": .init(0xEEE0DA, 0x64473A),
        "orange": .init(0xFADEC9, 0x854C1D),
        "yellow": .init(0xFDECC8, 0x89632A),
        "green": .init(0xDBEDDB, 0x305843),
        "blue": .init(0xD3E5EF, 0x254F70),
        "purple": .init(0xE8DEEE, 0x553B69),
        "pink": .init(0xF5E0E9, 0x683B52),
        "red": .init(0xFFE2DD, 0x5D1715)
    ]
    static func named(_ value: String) -> NotionTagColors { palette[value] ?? palette["default"]! }
}
