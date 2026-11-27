import AppKit
import NotionWriterCore

func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size); field.textColor = color
    return field
}
func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat = 8) -> NSStackView {
    let view = NSStackView(); view.orientation = orientation; view.alignment = orientation == .vertical ? .leading : .centerY; view.spacing = spacing
    return view
}
final class CandidateRow: NSTableRowView {
    private let selectable: Bool
    private var hoverTracking: NSTrackingArea?
    private(set) var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(selectable: Bool) {
        self.selectable = selectable
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard selectable else { return }
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        isHovered = window.map {
            $0.isKeyWindow && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
    }

    override func mouseEntered(with event: NSEvent) { if selectable { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    private var highlightPath: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            highlightPath.fill()
        }
    }

    // The custom selection stays light, so controls should keep their normal text colors.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        highlightPath.fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: 2, height: bounds.height - 10), xRadius: 1, yRadius: 1).fill()
    }
}
final class TagSearchField: NSTextField {
    var saveRequested: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 && event.modifierFlags.intersection([.command,.option,.shift,.control]) == .command {
            if (currentEditor() as? NSTextView)?.hasMarkedText() != true { saveRequested?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
final class TagRow: NSStackView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Source {
        case tags(WriterProperty)
        case recent(() -> [(input: RecentPropertyInput, summary: RecentPropertyInput.Summary)])
    }

    private let source: Source
    private let name: String
    private let tagOptions: [TagOption]
    let propertyButton = QuietButton()
    var display: DisplayPreferences
    let search = TagSearchField()
    let chips = NSStackView()
    let table = NSTableView()
    let scroll = NSScrollView()
    let optionsPanel = TagOptionsPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private var outsideClickMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private let panelHeading = label("")
    private let selectedScroll = NSScrollView()
    private let selectedDocument = FlippedDocumentView()
    private var selectedHeight: NSLayoutConstraint!
    var chipsHeight: NSLayoutConstraint!
    private enum Candidate: Equatable {
        case empty(String)
        case recent(RecentPropertyInput, RecentPropertyInput.Summary)
        case tag(TagOption)

        var selectable: Bool {
            switch self {
            case .recent, .tag: return true
            default: return false
            }
        }
    }

    private var candidates: [Candidate] = []
    var recall: ((RecentPropertyInput) -> Void)?
    var exitToTitle: (() -> Void)?
    var selection: [String]
    var changed: (([String]) -> Void)?
    var move: ((Bool) -> Void)?
    var layoutChanged: (() -> Void)?
    var activated: (() -> Void)?
    var saveRequested: (() -> Void)? { didSet { search.saveRequested = saveRequested } }
    var emptyWidth: NSLayoutConstraint!
    private var rowTracking: NSTrackingArea?
    private var rowHovered = false
    private var minimumHeight: NSLayoutConstraint!
    private var measuredCandidateWidth: CGFloat?
    convenience init(property: WriterProperty, selection: [String], display: DisplayPreferences) {
        self.init(source: .tags(property), selection: selection, display: display)
    }

    init(source: Source, selection: [String] = [], display: DisplayPreferences) {
        self.source = source
        self.selection = selection
        self.display = display
        let symbol: String
        switch source {
        case .tags(let property):
            name = property.name
            tagOptions = property.options
            switch name {
            case "アイディア": symbol = "lightbulb.fill"
            case "作者or作品": symbol = "person.fill"
            default: symbol = "tag.fill"
            }
        case .recent:
            name = "最近の項目"
            tagOptions = []
            symbol = "clock.arrow.circlepath"
        }
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8 * display.scale
        let title = propertyButton
        title.isBordered = false; title.alignment = .left; title.font = display.scaledFont(size: display.propertySize); title.contentTintColor = WriterStyle.muted
        title.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(display.propertySize) * display.scale, weight: .regular))
        title.imagePosition = .imageLeading; title.imageHugsTitle = true
        title.target = self; title.action = #selector(openSearch); addArrangedSubview(title)
        emptyWidth = title.widthAnchor.constraint(equalTo: widthAnchor)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: max(26, CGFloat(display.propertySize + 10)) * display.scale); minimumHeight.isActive = true
        title.heightAnchor.constraint(equalTo: heightAnchor).isActive = true
        wantsLayer = true; layer?.cornerRadius = 5
        chips.orientation = .horizontal; chips.spacing = 5 * display.scale; chips.alignment = .centerY
        let chipsScroll = NSScrollView(); chipsScroll.drawsBackground = false; chipsScroll.hasHorizontalScroller = true; chipsScroll.autohidesScrollers = true
        chipsScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chipsScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chipsScroll.documentView = chips; chipsHeight = chipsScroll.heightAnchor.constraint(equalToConstant: CGFloat(display.propertySize + 8) * display.scale); chipsHeight.isActive = true
        addArrangedSubview(chipsScroll);
        search.font = display.scaledFont(size: display.propertySize)
        if case .recent = source { search.placeholderString = "最近の項目を検索する…" }
        else { search.placeholderString = "オプションを検索する…" }
        search.isBordered = false; search.focusRingType = .none; search.delegate = self
        let column = NSTableColumn(identifier: .init("tag")); table.addTableColumn(column); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.rowHeight = max(28, CGFloat(display.propertySize + 14)) * display.scale; table.target = self; table.action = #selector(clicked)
        table.style = .plain; table.intercellSpacing = .zero; table.backgroundColor = .white; table.focusRingType = .none; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let content = NSViewController(); content.view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        let root = stack(.vertical, spacing: 10 * display.scale); root.translatesAutoresizingMaskIntoConstraints = false
        let inset = 16 * display.scale
        panelHeading.stringValue = name
        panelHeading.font = .systemFont(ofSize: CGFloat(display.propertySize + 2) * display.scale, weight: .semibold)
        panelHeading.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(panelHeading)
        selectedScroll.documentView = selectedDocument
        selectedScroll.drawsBackground = false
        selectedScroll.hasVerticalScroller = true
        selectedScroll.scrollerStyle = .overlay
        selectedScroll.autohidesScrollers = true
        selectedHeight = selectedScroll.heightAnchor.constraint(equalToConstant: 0)
        selectedHeight.isActive = true
        selectedScroll.isHidden = true
        root.addArrangedSubview(selectedScroll)
        root.addArrangedSubview(search)
        let divider = NSBox(); divider.boxType = .separator; root.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(scroll); content.view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: inset),
            root.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -inset),
            root.topAnchor.constraint(equalTo: content.view.topAnchor, constant: inset),
            root.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: -inset),
            panelHeading.widthAnchor.constraint(equalTo: root.widthAnchor),
            selectedScroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            search.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            search.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(display.propertySize + 12) * display.scale)
        ])
        content.view.wantsLayer = true; content.view.layer?.backgroundColor = NSColor.white.cgColor; content.view.layer?.cornerRadius = 8; content.view.layer?.borderWidth = 1; content.view.layer?.borderColor = NSColor(white: 0.89, alpha: 1).cgColor; content.view.layer?.masksToBounds = true
        optionsPanel.contentViewController = content
        optionsPanel.title = name + "の選択"
        optionsPanel.backgroundColor = .clear; optionsPanel.isOpaque = false; optionsPanel.hasShadow = true
        optionsPanel.isReleasedWhenClosed = false; optionsPanel.isFloatingPanel = true; optionsPanel.level = .floating
        optionsPanel.appearance = NSAppearance(named: .aqua); optionsPanel.hidesOnDeactivate = true
        optionsPanel.animationBehavior = .none; optionsPanel.isMovable = false
        optionsPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        optionsPanel.saveRequested = { [weak self] in self?.saveRequested?() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Both the chip buttons and the empty space around them open this group.
        var target: NSView? = hit
        while let view = target, view !== self {
            if view is NSControl { return hit }
            target = view.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        if propertyButton.isEnabled { openSearch() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rowTracking { removeTrackingArea(rowTracking) }
        rowTracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(rowTracking!)
        rowHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateHover()
    }
    override func mouseEntered(with event: NSEvent) { rowHovered = true; updateHover() }
    override func mouseExited(with event: NSEvent) { rowHovered = false; updateHover() }
    private func updateHover() {
        layer?.backgroundColor = (rowHovered && propertyButton.isEnabled ? WriterStyle.hover : NSColor.clear).cgColor
    }
    @objc func openSearch() {
        if optionsPanel.isVisible { collapse(); return }
        if let activated { activated() } else { focus() }
    }
    func applyDisplay(_ value: DisplayPreferences) {
        guard display != value else { return }
        measuredCandidateWidth = nil
        minimumHeight.constant = max(26, CGFloat(value.propertySize + 10)) * value.scale
        display = value; propertyButton.font = value.scaledFont(size: value.propertySize); search.font = value.scaledFont(size: value.propertySize)
        panelHeading.font = .systemFont(ofSize: CGFloat(value.propertySize + 2) * value.scale, weight: .semibold)
        chipsHeight.constant = CGFloat(value.propertySize + 8) * value.scale; table.rowHeight = max(28, CGFloat(value.propertySize + 14)) * value.scale; refresh()
    }
    func focus() {
        guard let parent = window else { return }
        search.stringValue = ""; filter(); layoutOptionsPanel()
        parent.addChildWindow(optionsPanel, ordered: .above)
        optionsPanel.makeKeyAndOrderFront(nil); optionsPanel.makeFirstResponder(search)
        propertyButton.contentTintColor = WriterStyle.ink
        installDismissalHandlers()
    }
    func collapse(restoreFocus: Bool = true) {
        let wasKey = optionsPanel.isKeyWindow
        optionsPanel.parent?.removeChildWindow(optionsPanel); optionsPanel.orderOut(nil)
        removeDismissalHandlers(); propertyButton.contentTintColor = WriterStyle.muted
        if restoreFocus && wasKey { window?.makeKeyAndOrderFront(nil) }
    }
    private func layoutOptionsPanel() {
        guard let parent = window else { return }
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let baseWidth = 560 * display.scale
        if measuredCandidateWidth == nil {
            let font = display.scaledFont(size: display.propertySize)
            let widest = tagOptions.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            measuredCandidateWidth = max(baseWidth, ceil(widest + 76 * display.scale + 15))
        }
        let visibleRows = min(14, max(7, candidates.count))
        let preferredHeight = table.rowHeight * CGFloat(visibleRows) + 110 * display.scale
        let geometry = TagMenuLayout(screen: screen, width: measuredCandidateWidth ?? baseWidth,
                                     height: min(preferredHeight, screen.height * 0.72))
        optionsPanel.setFrame(geometry.frame, display: optionsPanel.isVisible)
        layoutSelectedTags(width: geometry.frame.width - 32 * display.scale, panelHeight: geometry.frame.height)
        optionsPanel.contentView?.layoutSubtreeIfNeeded()
    }

    private func layoutSelectedTags(width: CGFloat, panelHeight: CGFloat) {
        let origin = selectedScroll.contentView.bounds.origin
        selectedDocument.subviews.forEach { $0.removeFromSuperview() }
        let gap = 6 * display.scale
        let chipHeight = CGFloat(display.propertySize + 12) * display.scale
        var x: CGFloat = 0
        var y: CGFloat = 0
        for id in selection {
            let option = tagOptions.first { $0.id == id }
            let name = option?.name ?? "削除されたタグ"
            let colors = NotionTagColors.named(option?.color ?? "default")
            let title = label(name, size: CGFloat(display.propertySize) * display.scale, color: colors.foreground)
            title.font = display.scaledFont(size: display.propertySize)
            title.lineBreakMode = .byTruncatingTail
            title.toolTip = name
            let remove = QuietButton(title: "×", target: self, action: #selector(removeSelectedTag(_:)))
            remove.font = title.font
            remove.contentTintColor = colors.foreground
            remove.identifier = .init(id)
            remove.setAccessibilityLabel(name + "を解除")
            remove.toolTip = name + "を解除"

            let inset = 7 * display.scale
            let buttonWidth = 24 * display.scale
            let textWidth = (name as NSString).size(withAttributes: [.font: title.font!]).width
            let chipWidth = min(width, ceil(textWidth + 2 * inset + buttonWidth))
            if x > 0 && x + chipWidth > width { x = 0; y += chipHeight + gap }
            let chip = NSView(frame: NSRect(x: x, y: y, width: chipWidth, height: chipHeight))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = colors.background.cgColor
            chip.layer?.cornerRadius = 5
            let labelHeight = title.intrinsicContentSize.height
            title.frame = NSRect(x: inset, y: (chipHeight - labelHeight) / 2,
                                 width: max(0, chipWidth - inset - buttonWidth), height: labelHeight)
            remove.frame = NSRect(x: chipWidth - buttonWidth, y: 0, width: buttonWidth, height: chipHeight)
            chip.addSubview(title)
            chip.addSubview(remove)
            selectedDocument.addSubview(chip)
            x += chipWidth + gap
        }
        let height = selection.isEmpty ? 0 : y + chipHeight
        selectedScroll.isHidden = selection.isEmpty
        selectedHeight.constant = min(height, max(chipHeight, panelHeight * 0.27))
        selectedDocument.frame.size = NSSize(width: width, height: height)
        let clip = selectedScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, height - selectedHeight.constant))))
        selectedScroll.reflectScrolledClipView(clip)
    }

    @objc private func removeSelectedTag(_ button: NSButton) {
        guard let id = button.identifier?.rawValue else { return }
        selection.removeAll { $0 == id }
        selectionChanged()
    }

    private func installDismissalHandlers() {
        removeDismissalHandlers()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.optionsPanel.isVisible, event.window !== self.optionsPanel else { return event }
            // Let this row and its selected tags toggle their own menu.
            if event.window === self.window && self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { return event }
            self.collapse(restoreFocus: false)
            return event
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.collapse(restoreFocus: false)
        }
    }
    private func removeDismissalHandlers() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
    }
    deinit {
        removeDismissalHandlers()
        optionsPanel.parent?.removeChildWindow(optionsPanel); optionsPanel.orderOut(nil)
    }
    func refresh(preserveNavigation: Bool = false) {
        if case .tags = source {
            propertyButton.title = name + (selection.isEmpty ? "を追加" : "")
        } else {
            propertyButton.title = name
        }
        emptyWidth.isActive = selection.isEmpty
        for view in chips.arrangedSubviews { chips.removeArrangedSubview(view); view.removeFromSuperview() }
        for id in selection {
            let option = tagOptions.first { $0.id == id }
            let button = QuietButton(title: option?.name ?? "削除されたタグ", target: self, action: #selector(openSearch))
            button.font = display.scaledFont(size: display.propertySize); button.identifier = .init(id); button.isBordered = false; button.contentTintColor = WriterStyle.ink; button.wantsLayer = true
            let colors = NotionTagColors.named(option?.color ?? "default")
            button.contentTintColor = colors.foreground
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: display.scaledFont(size: display.propertySize), .foregroundColor: colors.foreground])
            // Keep each label at its full text width. Overflow scrolls the group instead
            // of letting NSStackView compress individual buttons into ellipses.
            let textWidth = button.attributedTitle.size().width
            button.widthAnchor.constraint(equalToConstant: ceil(textWidth + 12 * display.scale)).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.cell?.lineBreakMode = .byClipping
            button.layer?.backgroundColor = colors.background.cgColor; button.layer?.cornerRadius = 4
            button.toolTip = name + "の選択を開く"
            chips.addArrangedSubview(button)
        }
        chips.frame.size = chips.fittingSize
        if let parent = chips.superview?.superview as? NSScrollView { parent.isHidden = selection.isEmpty }
        if optionsPanel.isVisible { layoutOptionsPanel() }
        filter(preserveNavigation: preserveNavigation); layoutChanged?()
    }
    func filter(preserveNavigation: Bool = false) {
        let selected = candidates.indices.contains(table.selectedRow) ? candidates[table.selectedRow] : nil
        let previousOrigin = scroll.contentView.bounds.origin
        let query = search.stringValue
        let emptyMessage: String
        switch source {
        case .tags:
            candidates = tagOptions.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.map(Candidate.tag)
            emptyMessage = "一致するタグがありません"
        case .recent(let inputs):
            candidates = inputs().filter { query.isEmpty || $0.summary.text.localizedStandardContains(query) }
                .map { .recent($0.input, $0.summary) }
            emptyMessage = query.isEmpty ? "履歴なし" : "一致する項目がありません"
        }
        if candidates.isEmpty { candidates = [.empty(emptyMessage)] }
        table.reloadData()
        let preserved = preserveNavigation ? selected.flatMap { candidates.firstIndex(of: $0) } : nil
        if let row = preserved ?? candidates.firstIndex(where: \.selectable) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        if preserveNavigation {
            let clip = scroll.contentView
            let bounds = clip.constrainBoundsRect(NSRect(origin: previousOrigin, size: clip.bounds.size))
            clip.scroll(to: bounds.origin); scroll.reflectScrolledClipView(clip)
        } else {
            table.scrollRowToVisible(0)
        }
    }
    @objc func clickedCandidate(_ sender: NSButton) { choose(sender.tag) }
    func tableViewSelectionDidChange(_ notification: Notification) {
        table.needsDisplay = true
    }
    @objc func clicked() { if table.clickedRow >= 0 { choose(table.clickedRow) } }
    func choose(_ row: Int) {
        guard candidates.indices.contains(row), candidates[row].selectable else { NSSound.beep(); return }
        switch candidates[row] {
        case .recent(let input, _):
            recall?(input)
        case .tag(let tag):
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if selection.contains(tag.id) { selection.removeAll { $0 == tag.id } } else { selection.append(tag.id) }
            selectionChanged()
        default:
            break
        }
    }
    private func selectionChanged() {
        refresh(preserveNavigation: true)
        changed?(selection)
        optionsPanel.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let rows = candidates.indices.filter { candidates[$0].selectable }
            guard !rows.isEmpty else { return true }
            let forward = selector == #selector(NSResponder.moveDown(_:))
            let offset = rows.firstIndex(of: table.selectedRow) ?? (forward ? -1 : rows.count)
            let row = rows[(offset + (forward ? 1 : -1) + rows.count) % rows.count]
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveBackward(_:)), #selector(NSResponder.moveForward(_:)):
            collapse()
            exitToTitle?()
            return true
        case #selector(NSResponder.insertNewline(_:)): choose(table.selectedRow); return true
        case #selector(NSResponder.insertTab(_:)): collapse(); move?(false); return true
        case #selector(NSResponder.insertBacktab(_:)): collapse(); move?(true); return true
        case #selector(NSResponder.cancelOperation(_:)): collapse(); window?.makeFirstResponder(propertyButton); return true
        default: return false
        }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CandidateRow(selectable: candidates[row].selectable)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { candidates[row].selectable }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch candidates[row] {
        case .empty(let message):
            return label(message, size: 12 * display.scale, color: .secondaryLabelColor)
        case .recent(_, let summary):
            let button = QuietButton(title: summary.text, target: self, action: #selector(clickedCandidate(_:)))
            button.highlightsOnHover = false
            button.alignment = .left
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let normal: [NSAttributedString.Key: Any] = [
                .foregroundColor: WriterStyle.ink,
                .font: display.scaledFont(size: display.propertySize),
                .paragraphStyle: paragraph
            ]
            let title = NSMutableAttributedString(string: "  ", attributes: normal)
            for option in summary.tags {
                let colors = NotionTagColors.named(option.color)
                var badge = normal
                badge[.foregroundColor] = colors.foreground
                badge[.backgroundColor] = colors.background
                title.append(NSAttributedString(string: "\u{00a0}" + option.name + "\u{00a0}", attributes: badge))
                title.append(NSAttributedString(string: "  ", attributes: normal))
            }
            let separator = "  ·  "
            let details = summary.tags.isEmpty && summary.urls.isEmpty ? summary.text : summary.urls.joined(separator: separator)
            title.append(NSAttributedString(string: details, attributes: normal))
            button.attributedTitle = title
            button.cell?.lineBreakMode = .byTruncatingTail
            button.tag = row
            button.toolTip = summary.text
            button.setAccessibilityLabel(summary.text)
            return button
        case .tag(let option):
            let button = TagCandidateButton(title: option.name, target: self, action: #selector(clickedCandidate(_:)))
            button.chosen = selection.contains(option.id); button.scale = display.scale; button.tagColor = option.color
            button.tag = row; button.font = display.scaledFont(size: display.propertySize); button.toolTip = option.name
            button.setAccessibilityLabel(option.name + (button.chosen ? " 選択済み" : ""))
            return button
        }
    }
}

final class TagCandidateButton: QuietButton {
    var chosen = false
    var scale: CGFloat = 1
    var tagColor = "default"
    override func draw(_ dirtyRect: NSRect) {
        let colors = NotionTagColors.named(tagColor)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: colors.foreground]
        let size = (title as NSString).size(withAttributes: attributes)
        let leading = 4 * scale
        let trailing = (chosen ? 32 : 8) * scale
        let pill = NSRect(x: leading, y: (bounds.height - size.height - 4 * scale) / 2, width: max(0, min(bounds.width - leading - trailing, size.width + 12 * scale)), height: size.height + 4 * scale)
        colors.background.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        (title as NSString).draw(in: pill.insetBy(dx: 6 * scale, dy: 2 * scale), withAttributes: attributes)
        if chosen { ("✓" as NSString).draw(at: NSPoint(x: bounds.width - 20 * scale, y: (bounds.height - size.height) / 2), withAttributes: attributes) }
    }
}
