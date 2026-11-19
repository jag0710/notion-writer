import AppKit

struct TagMenuLayout {
    let frame: NSRect
    init(screen: NSRect, width: CGFloat, height: CGFloat) {
        let margin: CGFloat = 20
        let actualWidth = min(width, screen.width - 2 * margin)
        let actualHeight = min(height, screen.height - 2 * margin)
        frame = NSRect(x: screen.midX - actualWidth / 2, y: screen.midY - actualHeight / 2,
                       width: actualWidth, height: actualHeight)
    }
}

final class TagOptionsPanel: NSPanel {
    var saveRequested: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 && event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return true }
            saveRequested?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
