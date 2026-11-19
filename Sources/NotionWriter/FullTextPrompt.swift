import AppKit

@MainActor final class FullTextPrompt {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 484, height: 305),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let scroll = NSTextView.scrollableTextView()
    private var input: NSTextView { scroll.documentView as! NSTextView }

    init() {
        panel.title = "全文を取り込む"
        let instruction = NSTextField(labelWithString: "コピーした内容を貼り付けてください。")
        instruction.textColor = .secondaryLabelColor
        scroll.borderType = .bezelBorder
        input.isRichText = false
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.font = .systemFont(ofSize: 14)
        input.textContainerInset = NSSize(width: 7, height: 7)
        input.setAccessibilityLabel("コピーした内容")

        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelImport))
        cancel.keyEquivalent = "\u{1B}"
        let confirm = NSButton(title: "取り込む", target: self, action: #selector(confirmImport))
        confirm.keyEquivalent = "\r"
        confirm.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.spacing = 8
        let stack = NSStackView(views: [instruction, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let view = panel.contentView else { return }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            instruction.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        panel.initialFirstResponder = input
    }

    func show(in window: NSWindow, onImport: @escaping (String) -> Void) {
        input.string = ""
        window.beginSheet(panel) { [weak self] result in
            guard let self else { return }
            let pasted = self.input.string
            self.input.string = ""
            if result == .OK { onImport(pasted) }
        }
        panel.makeFirstResponder(input)
    }

    @objc private func cancelImport() { panel.sheetParent?.endSheet(panel, returnCode: .cancel) }
    @objc private func confirmImport() { panel.sheetParent?.endSheet(panel, returnCode: .OK) }
}
