import AppKit
import NotionWriterCore

@MainActor final class SettingsWindow: NSWindowController, NSTabViewDelegate {
    let state: AppState
    let database = NSTextField()
    let openDatabaseButton = NSButton()
    let token = NSSecureTextField()
    let connectButton = NSButton(title: "接続を確認して保存", target: nil, action: nil)
    let syncButton = NSButton(title: "プロパティを再同期", target: nil, action: nil)
    let connectionTitle = label("", size: 14)
    let connectionDetail = label("", size: 11, color: .secondaryLabelColor)
    let syncDetail = label("", size: 11, color: .secondaryLabelColor)
    let setupButton = NSButton(title: "接続の設定・変更…", target: nil, action: nil)
    let setup = stack(.vertical, spacing: 8)
    var connectionFeedback: String?
    var connecting = false
    let message = label("", size: 11, color: .secondaryLabelColor)
    let shortcutMessage = label("", size: 11, color: .secondaryLabelColor)
    let fixedPosition = NSButton(checkboxWithTitle: "表示位置を固定", target: nil, action: nil)
    let overallSize = NSSlider(value: 100, minValue: 75, maxValue: 150, target: nil, action: nil)
    let overallSizeValue = label("100％")
    let fontButton = NSButton()
    let preview = label("思いついたことを、すぐに書く。")
    var sizeSliders: [String: NSSlider] = [:]
    var sizeLabels: [String: NSTextField] = [:]
    var shortcutChanged: ((Shortcut) -> String?)?
    private let tabs = NSTabView()
    private let bookmarkModeButton = NSPopUpButton()
    private let historyLimitButton = NSPopUpButton()
    private let historyRows = stack(.vertical, spacing: 14)
    private let aiStudioDetail = label("", size: 12, color: .secondaryLabelColor)
    private let disconnectAIStudioButton = NSButton(title: "ファイル接続を解除", target: nil, action: nil)
    private let historyMessage = label("", size: 11, color: .secondaryLabelColor)
    private var renderedHistory: [SendRecord] = []
    private var historyButtons: [(SendRecord, NSButton)] = []
    private let historyDates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(state: AppState) {
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Notion Writer"
        window.title = appName + " 設定"; window.level = .floating; window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white; window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            window.contentView!.widthAnchor.constraint(greaterThanOrEqualToConstant: 580),
            window.contentView!.heightAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])
        buildConnectionTab(addTab("Notionへの接続", to: tabs, scrollable: true))
        buildDisplayTab(addTab("表示", to: tabs))
        buildGeneralTab(addTab("一般", to: tabs))
        buildHistoryTab(addTab("履歴", to: tabs, scrollable: true))
        buildConversationTab(addTab("対話取り込み", to: tabs))
        tabs.delegate = self
        window.setContentSize(NSSize(width: 580, height: 560)); window.center(); update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func addTab(_ title: String, to tabs: NSTabView, scrollable: Bool = false) -> NSStackView {
        let item = NSTabViewItem(identifier: title); item.label = title
        let container = NSView(); let root = stack(.vertical, spacing: 12); root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
        ])
        if scrollable {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            let document = SettingsDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
            root.removeFromSuperview(); document.addSubview(root)
            scroll.documentView = document
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
                root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
                root.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
                root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
            ])
            item.view = scroll
        } else { item.view = container }
        tabs.addTabViewItem(item); return root
    }
    private func explain(_ text: String, in root: NSStackView, size: CGFloat = 11) {
        let field = label(text, size: size, color: .secondaryLabelColor)
        field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping; field.preferredMaxLayoutWidth = 490
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }
    private func buildConversationTab(_ root: NSStackView) {
        root.addArrangedSubview(label("Google AI Studio", size: 16))
        root.addArrangedSubview(aiStudioDetail)
        explain("アプリでは、最初に対話URLを入力したときに選んだGoogle Driveの対話ファイルを読み取ります。Googleアカウントのログインはブラウザで行います。", in: root)
        disconnectAIStudioButton.target = self
        disconnectAIStudioButton.action = #selector(disconnectAIStudio)
        root.addArrangedSubview(disconnectAIStudioButton)
    }

    @objc private func disconnectAIStudio() {
        do { try state.disconnectAIStudioFiles(); update() }
        catch { NSAlert(error: error).runModal() }
    }

    private func buildHistoryTab(_ root: NSStackView) {
        for limit in SendRecord.limits {
            historyLimitButton.addItem(withTitle: "\(limit)件まで保存")
            historyLimitButton.lastItem?.tag = limit
        }
        historyLimitButton.setAccessibilityLabel("履歴の保存上限")
        historyLimitButton.target = self
        historyLimitButton.action = #selector(historyLimitChanged(_:))
        root.addArrangedSubview(historyLimitButton)
        explain("送信内容はこのMacに保存します。未送信の内容は元の保存先へ再送できます。", in: root)
        historyMessage.maximumNumberOfLines = 0
        historyMessage.lineBreakMode = .byWordWrapping
        historyMessage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(historyMessage)
        root.addArrangedSubview(historyRows)
        NSLayoutConstraint.activate([
            historyMessage.widthAnchor.constraint(equalTo: root.widthAnchor),
            historyRows.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        explain("送信先を変更した場合は、元の保存先に接続すると再送できます。", in: root)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.identifier as? String == "履歴" { updateHistory() }
    }

    @objc private func historyLimitChanged(_ sender: NSPopUpButton) {
        guard let limit = sender.selectedItem?.tag, limit != state.historyLimit else { return }
        defer { updateHistory() }
        let removed = state.recentSends.count - limit
        if removed > 0 {
            let alert = NSAlert()
            alert.messageText = "履歴の上限を\(limit)件に変更しますか？"
            alert.informativeText = "このMacに保存した古い履歴\(removed)件を削除します。"
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "変更して削除")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do { try state.setHistoryLimit(limit) }
        catch { NSAlert(error: error).runModal() }
    }

    private func updateHistory() {
        historyLimitButton.selectItem(withTag: state.historyLimit)
        historyLimitButton.isEnabled = !state.busy
        let records = state.recentSends
        if renderedHistory != records {
            for view in historyRows.arrangedSubviews {
                historyRows.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            historyButtons = []
            for record in records {
                let row = stack(.vertical, spacing: 5)
                let heading = record.draft.title.split(whereSeparator: \.isNewline).first
                let title = label(heading.map(String.init) ?? record.draft.title, size: 13)
                title.maximumNumberOfLines = 1
                title.lineBreakMode = .byTruncatingTail
                title.toolTip = String(record.draft.title.prefix(500))
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(title)
                let detail = label(historyDates.string(from: record.attemptedAt) + "  ·  " + record.destination.name,
                                   size: 11, color: .secondaryLabelColor)
                detail.lineBreakMode = .byTruncatingTail
                detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(detail)

                let actions = stack(.horizontal, spacing: 8)
                let preview = NSButton(title: "内容を表示…", target: self, action: #selector(showHistoryContent(_:)))
                preview.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
                actions.addArrangedSubview(preview)
                if record.result != .sent || record.notionURL != nil {
                    let button = NSButton(title: "", target: self, action: #selector(historyAction(_:)))
                    button.identifier = preview.identifier
                    actions.addArrangedSubview(button)
                    historyButtons.append((record, button))
                } else {
                    actions.addArrangedSubview(label("送信済み", size: 11, color: .secondaryLabelColor))
                }
                row.addArrangedSubview(actions)
                historyRows.addArrangedSubview(row)
                NSLayoutConstraint.activate([
                    row.widthAnchor.constraint(equalTo: historyRows.widthAnchor),
                    title.widthAnchor.constraint(equalTo: row.widthAnchor),
                    detail.widthAnchor.constraint(equalTo: row.widthAnchor),
                ])
            }
            renderedHistory = records
        }
        historyMessage.stringValue = state.historyFeedback ?? (records.isEmpty ? "送信履歴はまだありません。" : "")
        historyMessage.isHidden = historyMessage.stringValue.isEmpty
        for (record, button) in historyButtons {
            let sending = state.sendingID == record.id
            if sending {
                button.title = "送信中…"
            } else {
                switch record.result {
                case .sent: button.title = "送信済み · Notionで開く"
                case .failed: button.title = "未送信 · 再送…"
                case .uncertain: button.title = "結果を要確認…"
                }
            }
            button.isEnabled = !sending && (record.result == .sent || state.canRetry(record) || record.notionURL != nil)
        }
    }

    private func historyRecord(for sender: NSButton) -> SendRecord? {
        guard let key = sender.identifier?.rawValue, let id = UUID(uuidString: key) else { return nil }
        return state.recentSends.first { $0.id == id }
    }

    @objc private func showHistoryContent(_ sender: NSButton) {
        guard let record = historyRecord(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "送信内容"
        alert.informativeText = record.destination.name + "  ·  " + record.result.label
        alert.addButton(withTitle: "閉じる")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let body = NSTextView(frame: scroll.bounds)
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = false
        body.font = .systemFont(ofSize: 13)
        body.textContainerInset = NSSize(width: 8, height: 8)
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        body.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        body.textContainer?.widthTracksTextView = true
        let draft = record.draft
        let links = (try? PagePayload.bodyBlocks(draft))?.compactMap(PagePayload.bookmarkURL(in:)).map(\.absoluteString) ?? []
        let contents = draft.body.replacingOccurrences(of: "\u{fffc}", with: "")
        let images = draft.images.isEmpty ? [] : ["添付画像（\(draft.images.count)枚）\n" + draft.images.map(\.name).joined(separator: "\n")]
        body.string = ([draft.title, contents] + draft.urls.values.sorted() + links + images)
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        scroll.documentView = body
        alert.accessoryView = scroll
        alert.runModal()
    }

    @objc private func historyAction(_ sender: NSButton) {
        guard let record = historyRecord(for: sender) else { return }
        if record.result == .sent {
            if let url = record.notionURL { NSWorkspace.shared.open(url) }
            return
        }
        let uncertain = record.result == .uncertain
        let retry = state.canRetry(record)
        let alert = NSAlert()
        alert.messageText = uncertain ? "Notionで保存結果を確認してください" : "元の保存先へ再送しますか？"
        alert.informativeText = record.destination.name
        if uncertain {
            alert.informativeText += "\n\nNotionに同じページがあるか確認してください。途中まで保存されたページがある場合は、内容を確認して整理してから再送してください。"
        }
        alert.addButton(withTitle: "キャンセル")
        if retry { alert.addButton(withTitle: uncertain ? "未保存を確認・再送" : "再送") }
        if record.notionURL != nil { alert.addButton(withTitle: "Notionで確認") }
        let result = alert.runModal()
        if retry && result == .alertSecondButtonReturn {
            Task { await state.retry(record.id, confirmedMissing: uncertain) }
        } else if let url = record.notionURL,
                  result == (retry ? .alertThirdButtonReturn : .alertSecondButtonReturn) {
            NSWorkspace.shared.open(url)
        }
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false; button.contentTintColor = .linkColor; button.alignment = .left
        return button
    }
    private func buildConnectionTab(_ root: NSStackView) {
        root.addArrangedSubview(label("Notionへの接続", size: 16))
        root.addArrangedSubview(connectionTitle)
        connectionDetail.maximumNumberOfLines = 0; connectionDetail.lineBreakMode = .byWordWrapping; connectionDetail.preferredMaxLayoutWidth = 490
        connectionDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(connectionDetail); connectionDetail.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(syncDetail)
        let controls = stack(.horizontal)
        syncButton.target = self; syncButton.action = #selector(sync); syncButton.bezelStyle = .rounded
        controls.addArrangedSubview(syncButton)
        openDatabaseButton.title = "保存先をNotionで開く"
        openDatabaseButton.target = self
        openDatabaseButton.action = #selector(openDatabase)
        openDatabaseButton.isBordered = false
        openDatabaseButton.contentTintColor = .linkColor
        controls.addArrangedSubview(openDatabaseButton)
        root.addArrangedSubview(controls)
        message.maximumNumberOfLines = 0; message.lineBreakMode = .byWordWrapping; message.preferredMaxLayoutWidth = 490
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(message); message.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let divider = NSBox(); divider.boxType = .separator; root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        setupButton.target = self; setupButton.action = #selector(toggleSetup); setupButton.bezelStyle = .rounded
        root.addArrangedSubview(setupButton)
        root.addArrangedSubview(setup); setup.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        setup.isHidden = state.connection != nil
        setupButton.title = setup.isHidden ? "接続の設定・変更…" : "接続の設定を閉じる"

        setup.addArrangedSubview(label("① Notionで接続を用意する", size: 13))
        explain("Notionで内部接続を作成します。新規メモを保存するには「コンテンツを読み取る」と「コンテンツを挿入」をオンにします。「コンテンツを更新」はオフで使えます。APIトークンは接続の「設定」からコピーします。", in: setup)
        setup.addArrangedSubview(linkButton("Notionの接続管理を開く ↗", action: #selector(openConnections)))
        setup.addArrangedSubview(label("② 接続に保存先のデータベースを追加する", size: 13))
        explain("接続管理で①の接続を開き、「コンテンツへのアクセス」→「アクセス権限を編集」へ進みます。「ページを検索する」に保存先のデータベース名を入力し、検索結果からデータベース本体を選んで保存します。", in: setup)
        setup.addArrangedSubview(label("③ 保存先とトークンを登録する", size: 13))
        explain("Notionで保存先のデータベースを開き、右上の「•••」→「リンクをコピー」で取得したリンクとAPIトークンを入力します。2台目のMacでは、同じリンクと既存のトークンを使います。", in: setup)
        setup.addArrangedSubview(label("保存先データベースのリンク", size: 12))
        database.placeholderString = "Notionでコピーしたデータベースのリンク"
        updateConnectionFields()
        database.setAccessibilityLabel("保存先データベースのリンク"); setup.addArrangedSubview(database)
        setup.addArrangedSubview(label("APIトークン", size: 12))
        token.setAccessibilityLabel("Notion接続のAPIトークン"); setup.addArrangedSubview(token)
        explain("トークンはMacのキーチェーンに保存します。保存済みの値はこの画面に表示しません。", in: setup)
        connectButton.target = self; connectButton.action = #selector(connect); connectButton.bezelStyle = .rounded
        setup.addArrangedSubview(connectButton)
        explain("接続確認で表示されたデータベース名を確認し、「保存先に設定」を押します。同期したプロパティとタグは入力画面で使えます。", in: setup)
        setup.addArrangedSubview(linkButton("Notion公式の接続ガイド ↗", action: #selector(openConnectionHelp)))
        for view in [database, token] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.widthAnchor.constraint(equalTo: setup.widthAnchor).isActive = true
        }
    }
    private func updateConnectionFields() {
        database.stringValue = state.activeDestination.map { notionURL(for: $0).absoluteString } ?? ""
        token.placeholderString = state.activeDestination == nil
            ? "①でコピーしたAPIトークン"
            : "変更時のみ入力（同じDBなら空欄で登録済みトークンを使用）"
    }

    @objc func toggleSetup() {
        setup.isHidden.toggle()
        setupButton.title = setup.isHidden ? "接続の設定・変更…" : "接続の設定を閉じる"
        window?.contentView?.layoutSubtreeIfNeeded()
        setupButton.scrollToVisible(setupButton.bounds)
    }
    private func buildDisplayTab(_ root: NSStackView) {
        root.addArrangedSubview(label("入力ウィンドウの表示", size: 16))
        root.addArrangedSubview(label("アプリ内の表示に適用します。Notionへ送る文字は変わりません。", size: 11, color: .secondaryLabelColor))
        let overallRow = stack(.horizontal, spacing: 10)
        let overallLabel = label("全体サイズ"); overallLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        overallRow.addArrangedSubview(overallLabel)
        overallSize.target = self; overallSize.action = #selector(overallSizeChanged); overallSize.isContinuous = true
        overallSize.numberOfTickMarks = 16; overallSize.allowsTickMarkValuesOnly = true
        overallSize.setAccessibilityLabel("全体サイズ（％）"); overallRow.addArrangedSubview(overallSize)
        overallSizeValue.widthAnchor.constraint(equalToConstant: 46).isActive = true; overallSizeValue.alignment = .right
        overallRow.addArrangedSubview(overallSizeValue); root.addArrangedSubview(overallRow)
        overallRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(label("文字・余白・ウィンドウ幅をまとめて拡大します。標準は100％。", size: 11, color: .secondaryLabelColor))
        fixedPosition.target = self; fixedPosition.action = #selector(fixedPositionChanged); root.addArrangedSubview(fixedPosition)
        root.addArrangedSubview(label("オン：中央より少し上に表示　オフ：自由に移動（位置を記憶）", size: 11, color: .secondaryLabelColor))
        let fontRow = stack(.horizontal); fontRow.addArrangedSubview(label("フォント"))
        fontButton.bezelStyle = .rounded; fontButton.target = self; fontButton.action = #selector(chooseFont)
        fontButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontRow.addArrangedSubview(fontButton); root.addArrangedSubview(fontRow)
        addSize("タイトル", id: "title", maximum: 36, root: root)
        addSize("本文", id: "body", maximum: 30, root: root)
        addSize("プロパティ・タグ", id: "property", maximum: 24, root: root)
        let separator = NSBox(); separator.boxType = .separator; root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(label("タイトルのプレビュー", size: 11, color: .secondaryLabelColor))
        preview.maximumNumberOfLines = 3; preview.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(preview); preview.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let reset = NSButton(title: "表示を標準に戻す", target: self, action: #selector(resetDisplay)); reset.bezelStyle = .rounded; root.addArrangedSubview(reset)
    }
    private func addSize(_ title: String, id: String, maximum: Double, root: NSStackView) {
        let row = stack(.horizontal, spacing: 10)
        let name = label(title); name.widthAnchor.constraint(equalToConstant: 120).isActive = true; row.addArrangedSubview(name)
        let slider = NSSlider(value: 18, minValue: 10, maxValue: maximum, target: self, action: #selector(sizeChanged(_:)))
        slider.identifier = .init(id); slider.isContinuous = true
        slider.numberOfTickMarks = Int(maximum - 10 + 1); slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel(title + "の文字サイズ"); row.addArrangedSubview(slider)
        let value = label(""); value.widthAnchor.constraint(equalToConstant: 46).isActive = true; value.alignment = .right; row.addArrangedSubview(value)
        root.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        sizeSliders[id] = slider; sizeLabels[id] = value
    }
    private func buildGeneralTab(_ root: NSStackView) {
        root.addArrangedSubview(label("Notionに送るブックマーク", size: 16))
        for mode in PagePayload.BookmarkMode.allCases {
            let title = mode == .urlOnly ? "URLだけ貼る" : "サムネイル付きカード"
            bookmarkModeButton.addItem(withTitle: title)
            bookmarkModeButton.lastItem?.representedObject = mode.rawValue
        }
        bookmarkModeButton.setAccessibilityLabel("Notionに送るブックマーク")
        bookmarkModeButton.target = self
        bookmarkModeButton.action = #selector(bookmarkModeChanged(_:))
        root.addArrangedSubview(bookmarkModeButton)
        explain("本文に入れたブックマークに、Notionへの送信時に適用します。", in: root)

        root.addArrangedSubview(label("キーボードショートカット", size: 16))
        let openRecorder = ShortcutRecorder(shortcut: .load())
        let clearRecorder = ShortcutRecorder(shortcut: state.clearShortcut)
        addShortcutRow("入力画面の呼び出し", detail: "他のアプリを使用中でも開けます。", recorder: openRecorder, to: root)
        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        addShortcutRow("入力をクリア", detail: "入力画面のタイトル、プロパティ、画像、本文を消去します。", recorder: clearRecorder, to: root)

        openRecorder.validate = { [weak self] value in
            if value == self?.state.clearShortcut { return "「入力をクリア」と異なるキーを選んでください。" }
            if value == .send || (value.flags == .command && [UInt32(12), 13, 48].contains(value.keyCode)) {
                return "アプリで使用中の操作と異なるキーを選んでください。"
            }
            return nil
        }
        clearRecorder.validate = { value in
            if value == Shortcut.load() { return "「入力画面の呼び出し」と異なるキーを選んでください。" }
            if value == .send || (value.flags == .command && [UInt32(0), 6, 7, 8, 9, 12, 13, 48, 43].contains(value.keyCode)) {
                return "アプリで使用中の操作と異なるキーを選んでください。"
            }
            return nil
        }
        openRecorder.rejected = { [weak self] in self?.setShortcutMessage($0) }
        clearRecorder.rejected = openRecorder.rejected
        openRecorder.changed = { [weak self] value in
            guard let self else { return }
            self.setShortcutMessage(self.shortcutChanged?(value))
        }
        clearRecorder.changed = { [weak self] value in
            self?.state.setClearShortcut(value)
            self?.setShortcutMessage(nil)
        }
        shortcutMessage.maximumNumberOfLines = 4
        shortcutMessage.isHidden = true
        root.addArrangedSubview(shortcutMessage)
        shortcutMessage.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func addShortcutRow(_ title: String, detail: String, recorder: ShortcutRecorder, to root: NSStackView) {
        let row = stack(.horizontal, spacing: 16)
        let description = stack(.vertical, spacing: 4)
        description.addArrangedSubview(label(title))
        description.addArrangedSubview(label(detail, size: 11, color: .secondaryLabelColor))
        let space = NSView()
        row.addArrangedSubview(description)
        row.addArrangedSubview(space)
        row.addArrangedSubview(recorder)
        recorder.setAccessibilityLabel(title + "のショートカット")
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        root.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    func setShortcutMessage(_ warning: String?) {
        shortcutMessage.stringValue = warning ?? ""
        shortcutMessage.isHidden = warning == nil
    }
    func show() { update(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    @objc private func bookmarkModeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String,
              let mode = PagePayload.BookmarkMode(rawValue: value) else { return }
        state.setBookmarkMode(mode)
    }

    func update() {
        if tabs.selectedTabViewItem?.identifier as? String == "履歴" { updateHistory() }
        let bookmarkModeIndex = bookmarkModeButton.itemArray.firstIndex {
            $0.representedObject as? String == state.bookmarkMode.rawValue
        }
        if let bookmarkModeIndex { bookmarkModeButton.selectItem(at: bookmarkModeIndex) }
        let fileCount = state.aiStudioFileCount
        aiStudioDetail.stringValue = fileCount == 0 ? "接続しているファイルはありません。" : "接続済みの対話ファイル  \(fileCount)件"
        disconnectAIStudioButton.isEnabled = fileCount > 0 && !state.importingImages
        connectButton.isEnabled = !state.busy && !state.syncing && !state.importingImages && !connecting
        database.isEnabled = connectButton.isEnabled
        token.isEnabled = connectButton.isEnabled
        openDatabaseButton.isEnabled = state.activeDestination != nil
        syncButton.isEnabled = state.connection != nil && !state.busy && !state.syncing && !connecting
        connectionTitle.stringValue = state.activeDestination.map { "設定済み · " + $0.name } ?? "未接続"
        connectionDetail.stringValue = state.connection == nil ? "初めて接続する場合は①から、別のMacで設定済みの保存先を使う場合は③から進めます。" : "保存先が登録されています。通常は設定し直す必要はありません。"
        if let schema = state.schema {
            let date = DateFormatter(); date.dateStyle = .short; date.timeStyle = .short
            syncDetail.stringValue = "プロパティの最終同期：" + date.string(from: schema.syncedAt)
        } else { syncDetail.stringValue = "プロパティは接続確認後に取得します。" }
        message.stringValue = connecting ? "Notionへの接続を確認しています…" : (state.syncing ? "プロパティとタグを取得しています…" : connectionFeedback ?? "")
        message.isHidden = message.stringValue.isEmpty
        fontButton.title = state.display.fontLabel + "…"
        for (id, value) in [("title", state.display.titleSize), ("body", state.display.bodySize), ("property", state.display.propertySize)] {
            sizeSliders[id]?.doubleValue = value; sizeLabels[id]?.stringValue = String(format: "%.0f pt", value)
        }
        overallSize.doubleValue = state.display.overallPercent
        overallSizeValue.stringValue = String(format: "%.0f％", state.display.overallPercent)
        fixedPosition.state = state.display.fixedPosition ? .on : .off
        preview.font = state.display.scaledFont(size: state.display.titleSize)
    }
    @objc func overallSizeChanged() {
        var value = state.display; value.overallPercent = overallSize.doubleValue.rounded()
        state.setDisplay(value)
    }
    @objc func fixedPositionChanged() {
        var value = state.display; value.fixedPosition = fixedPosition.state == .on
        state.setDisplay(value)
    }
    @objc func chooseFont() {
        let manager = NSFontManager.shared; manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(state.display.font(size: state.display.titleSize), isMultiple: false)
        if let panel = manager.fontPanel(true) {
            panel.level = .floating
            panel.makeKeyAndOrderFront(self)
        }
    }
    @objc func changeFont(_ sender: NSFontManager) {
        let font = sender.convert(state.display.font(size: state.display.titleSize))
        var value = state.display; value.fontName = font.fontName; value.titleSize = Double(font.pointSize)
        state.setDisplay(value)
    }
    @objc func sizeChanged(_ sender: NSSlider) {
        var value = state.display; let size = sender.doubleValue.rounded()
        switch sender.identifier?.rawValue { case "title": value.titleSize = size; case "body": value.bodySize = size; default: value.propertySize = size }
        state.setDisplay(value)
    }
    @objc func resetDisplay() { state.setDisplay(DisplayPreferences()) }
    @objc func connect() {
        let databaseText = database.stringValue; let secret = token.stringValue
        connecting = true; connectionFeedback = nil; update()
        Task {
            do {
                try await state.connect(database: databaseText, token: secret) { target in
                    let alert = NSAlert()
                    alert.messageText = "このデータベースを保存先にしますか？"
                    alert.informativeText = (target.name.isEmpty ? "無題" : target.name) + "\n" + self.notionURL(for: target).absoluteString
                    alert.addButton(withTitle: "保存先に設定")
                    alert.addButton(withTitle: "キャンセル")
                    return alert.runModal() == .alertFirstButtonReturn
                }
                token.stringValue = ""
                updateConnectionFields()
                connectionFeedback = "接続を確認し、プロパティとタグを同期しました。"
                setup.isHidden = true; setupButton.title = "接続の設定・変更…"
            } catch is CancellationError { connectionFeedback = nil }
            catch { connectionFeedback = connectionError(error) }
            connecting = false; update()
            window?.contentView?.layoutSubtreeIfNeeded()
            message.scrollToVisible(message.bounds)
        }
    }
    private func connectionError(_ error: Error) -> String {
        if case WriterError.api(let status, _, _) = error {
            switch status {
            case 401: return "APIトークンを確認できませんでした。①の接続管理画面からコピーし直して、③に貼り付けてください。"
            case 403, 404: return "保存先にアクセスできませんでした。①で「コンテンツを読み取る」がオンか、②で保存先のデータベースを選んで保存したか確認してください。"
            case 429: return "Notionのリクエスト上限に達しました。少し待ってから、もう一度お試しください。"
            default: break
            }
        }
        return error.localizedDescription
    }
    @objc func sync() {
        connectionFeedback = nil
        Task {
            await state.sync()
            let synced = state.activeDestination.map { state.status.hasPrefix($0.name + " · ") } ?? false
            connectionFeedback = synced ? "プロパティとタグを更新しました。" : connectionErrorMessage(state.status)
            update()
            window?.contentView?.layoutSubtreeIfNeeded()
            message.scrollToVisible(message.bounds)
        }
    }
    private func connectionErrorMessage(_ status: String) -> String {
        status + "\n接続できない場合は「接続の設定・変更」の①・②を確認してください。"
    }
    @objc func openConnections() { NSWorkspace.shared.open(URL(string: "https://app.notion.com/developers/connections")!) }
    @objc func openConnectionHelp() { NSWorkspace.shared.open(URL(string: "https://www.notion.com/help/add-and-manage-connections-with-the-api")!) }
    @objc func openDatabase() {
        if let target = state.activeDestination { NSWorkspace.shared.open(notionURL(for: target)) }
    }
    private func notionURL(for destination: NotionDestination) -> URL {
        let path = destination.databaseID.replacingOccurrences(of: "-", with: "")
        let view = destination.viewID.map { "?v=" + $0.replacingOccurrences(of: "-", with: "") } ?? ""
        return URL(string: "https://www.notion.so/" + path + view)!
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
