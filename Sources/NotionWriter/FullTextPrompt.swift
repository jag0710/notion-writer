import AppKit

@MainActor final class FullTextPrompt {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 484, height: 305),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let scroll = NSTextView.scrollableTextView()
    private let instruction = NSTextField(labelWithString: "")
    private let browserButton = NSButton()
    private let fileButton = NSButton()
    private let sourceActions = NSStackView()
    private var browserURL: URL?
    private var fileSelection: (() -> Void)?
    private var input: NSTextView { scroll.documentView as! NSTextView }

    init() {
        panel.title = "全文を取り込む"
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
        browserButton.title = "ブラウザで開く"
        browserButton.target = self
        browserButton.action = #selector(openBrowser)
        fileButton.title = "保存ファイルを選ぶ"
        fileButton.target = self
        fileButton.action = #selector(chooseFile)
        sourceActions.orientation = .horizontal
        sourceActions.addArrangedSubview(browserButton)
        sourceActions.addArrangedSubview(fileButton)
        sourceActions.spacing = 8
        let stack = NSStackView(views: [instruction, sourceActions, scroll, buttons])
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
            sourceActions.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        panel.initialFirstResponder = input
    }

    func show(in window: NSWindow, url: URL? = nil, chooseFile: (() -> Void)? = nil,
              onImport: @escaping (String) -> Void) {
        input.string = ""
        browserURL = url
        fileSelection = chooseFile
        instruction.stringValue = url == nil ? "コピーした内容を貼り付けてください。"
            : "ブラウザで対話をコピーし、ここに貼り付けてください。"
        sourceActions.isHidden = url == nil
        fileButton.isHidden = chooseFile == nil
        window.beginSheet(panel) { [weak self] result in
            guard let self else { return }
            let pasted = self.input.string
            self.input.string = ""
            let selectFile = self.fileSelection
            self.fileSelection = nil
            self.browserURL = nil
            if result == .OK { onImport(pasted) }
            if result == .continue { selectFile?() }
        }
        panel.makeFirstResponder(input)
    }

    @objc private func openBrowser() {
        if let browserURL { NSWorkspace.shared.open(browserURL) }
    }
    @objc private func chooseFile() { panel.sheetParent?.endSheet(panel, returnCode: .continue) }
    @objc private func cancelImport() { panel.sheetParent?.endSheet(panel, returnCode: .cancel) }
    @objc private func confirmImport() { panel.sheetParent?.endSheet(panel, returnCode: .OK) }
}
