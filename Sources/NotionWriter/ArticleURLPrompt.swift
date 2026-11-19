import AppKit
import NotionWriterCore

@MainActor final class ArticleURLPrompt: NSObject, NSTextFieldDelegate {
    private let alert = NSAlert()
    private let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    private let importButton: NSButton

    override init() {
        importButton = alert.addButton(withTitle: "取り込む")
        super.init()
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1B}"
        alert.alertStyle = .informational
        alert.messageText = "記事を取り込む"
        alert.informativeText = "公開記事のURLを入力してください。"
        field.placeholderString = "https://"
        field.setAccessibilityLabel("記事のURL")
        field.delegate = self
        field.isAutomaticTextCompletionEnabled = false
        alert.accessoryView = field
    }

    private var url: URL? {
        PagePayload.bookmarkURL(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func show(in window: NSWindow, onImport: @escaping (URL) -> Void) {
        field.stringValue = ""
        importButton.isEnabled = false
        alert.layout()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertFirstButtonReturn, let url = self?.url { onImport(url) }
        }
        alert.window.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        importButton.isEnabled = url != nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        if importButton.isEnabled { importButton.performClick(nil) } else { NSSound.beep() }
        return true
    }
}
