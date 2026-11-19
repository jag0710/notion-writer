import AppKit

final class BodyCommandMenu: NSObject {
    enum Action: Equatable {
        case block(String)
        case color(String)
        case bookmark
        case keepURL
        case clipArticle
    }

    private struct Command {
        let title: String
        let action: Action
        let keywords: String
    }

    private let blocks = [
        Command(title: "テキスト", action: .block("paragraph"), keywords: "text 本文"),
        Command(title: "見出し1", action: .block("heading_1"), keywords: "h1 heading"),
        Command(title: "見出し2", action: .block("heading_2"), keywords: "h2 heading"),
        Command(title: "見出し3", action: .block("heading_3"), keywords: "h3 heading"),
        Command(title: "箇条書き", action: .block("bulleted_list_item"), keywords: "bullet list リスト"),
        Command(title: "番号付きリスト", action: .block("numbered_list_item"), keywords: "number list"),
        Command(title: "チェックリスト", action: .block("to_do"), keywords: "todo check"),
        Command(title: "引用", action: .block("quote"), keywords: "quote"),
        Command(title: "コード", action: .block("code"), keywords: "code"),
        Command(title: "表", action: .block("table"), keywords: "table テーブル"),
        Command(title: "区切り線", action: .block("divider"), keywords: "divider")
    ]

    private static let grayBackground = Command(title: "グレーの背景", action: .color("gray_background"), keywords: "gray background")

    private let colors: [Command] = {
        let names = [
            ("gray", "グレー"), ("brown", "茶"), ("orange", "オレンジ"),
            ("yellow", "黄"), ("green", "緑"), ("blue", "青"),
            ("purple", "紫"), ("pink", "ピンク"), ("red", "赤")
        ]
        return names.flatMap { name, title in
            [
                name == "gray" ? grayBackground : Command(title: title + "の背景", action: .color(name + "_background"), keywords: name + " background"),
                Command(title: title + "の文字", action: .color(name), keywords: name + " text")
            ]
        } + [Command(title: "標準色に戻す", action: .color("default"), keywords: "default")]
    }()

    private let popover = NSPopover()
    private let anchor = NSView(frame: .zero)
    private var matches: [Command] = []
    private var buttons: [NSButton] = []
    private var selected = 0
    private var onChoose: ((Action) -> Void)?
    var isVisible: Bool { popover.isShown }

    func show(query: String, in editor: NSTextView, allowColor: Bool, onChoose: @escaping (Action) -> Void) {
        let available: [Command]
        if !allowColor { available = blocks }
        else if query.isEmpty { available = blocks + [Self.grayBackground] }
        else { available = blocks + colors }
        let results = Array(available.filter {
            query.isEmpty || ($0.title + " " + $0.keywords).localizedStandardContains(query)
        }.prefix(12))
        show(results, in: editor, onChoose: onChoose)
    }

    func showURLPaste(in editor: NSTextView, onChoose: @escaping (Action) -> Void) {
        show([
            Command(title: "ブックマークを作成", action: .bookmark, keywords: ""),
            Command(title: "URLのまま", action: .keepURL, keywords: ""),
            Command(title: "記事を取り込む", action: .clipArticle, keywords: ""),
        ], in: editor, onChoose: onChoose)
    }

    private func show(_ results: [Command], in editor: NSTextView, onChoose: @escaping (Action) -> Void) {
        guard !results.isEmpty, let window = editor.window else { close(); return }
        self.onChoose = onChoose
        if !isVisible || matches.map(\.action) != results.map(\.action) {
            matches = results
            selected = 0
            let content = NSViewController()
            let width: CGFloat = 200
            let rowHeight: CGFloat = 24
            let size = NSSize(width: width, height: CGFloat(matches.count) * rowHeight + 12)
            content.view = NSView(frame: NSRect(origin: .zero, size: size))
            buttons = matches.enumerated().map { index, command in
                let button = NSButton(title: command.title, target: self, action: #selector(clicked(_:)))
                button.tag = index
                button.isBordered = false
                button.alignment = .left
                button.setAccessibilityLabel(command.title)
                button.frame = NSRect(x: 10, y: size.height - 6 - CGFloat(index + 1) * rowHeight, width: width - 20, height: rowHeight)
                button.wantsLayer = true
                button.layer?.cornerRadius = 5
                content.view.addSubview(button)
                return button
            }
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = content
            popover.contentSize = size
            highlight()
        }
        let selected = editor.selectedRange()
        let screen = editor.firstRect(forCharacterRange: selected, actualRange: nil)
        let caret = editor.convert(window.convertFromScreen(screen), from: nil)
        if anchor.superview !== editor {
            anchor.removeFromSuperview()
            editor.addSubview(anchor)
        }
        anchor.frame = NSRect(x: caret.minX, y: caret.minY, width: 2, height: max(16, caret.height))
        if !isVisible { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
    }

    func close() {
        if popover.isShown { popover.close() }
        onChoose = nil
    }

    func move(by offset: Int) {
        guard !buttons.isEmpty else { return }
        selected = (selected + offset + buttons.count) % buttons.count
        highlight()
    }

    func choose() {
        guard matches.indices.contains(selected) else { return }
        let action = matches[selected].action
        let choose = onChoose
        close()
        choose?(action)
    }

    private func highlight() {
        for (index, button) in buttons.enumerated() {
            button.layer?.backgroundColor = (index == selected ? NSColor.controlAccentColor.withAlphaComponent(0.13) : .clear).cgColor
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        selected = sender.tag
        choose()
    }
}
