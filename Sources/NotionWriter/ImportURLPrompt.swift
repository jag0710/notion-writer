import AppKit
import NotionWriterCore

@MainActor final class ImportURLPrompt: NSObject, NSTextFieldDelegate {
    private let alert = NSAlert()
    private let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    private let importButton: NSButton
    private var submittedURL: URL?

    init(title: String, instruction: String, fieldLabel: String) {
        importButton = alert.addButton(withTitle: "取り込む")
        super.init()
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1B}"
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = instruction
        field.placeholderString = "https://"
        field.setAccessibilityLabel(fieldLabel)
        field.delegate = self
        field.isAutomaticTextCompletionEnabled = false
        alert.accessoryView = field
        importButton.target = self
        importButton.action = #selector(confirmImport)
    }

    private var url: URL? {
        let value = field.currentEditor()?.string ?? field.stringValue
        return PagePayload.bookmarkURL(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func show(in window: NSWindow, onImport: @escaping (URL) -> Void) {
        submittedURL = nil
        field.stringValue = ""
        importButton.isEnabled = false
        alert.layout()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let url = self?.submittedURL else { return }
            DispatchQueue.main.async { onImport(url) }
        }
        alert.window.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        importButton.isEnabled = url != nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        confirmImport()
        return true
    }

    @objc private func confirmImport() {
        guard let url, let parent = alert.window.sheetParent else {
            NSSound.beep()
            return
        }
        submittedURL = url
        parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
    }
}
