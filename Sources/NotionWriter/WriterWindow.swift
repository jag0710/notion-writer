import AppKit
import UniformTypeIdentifiers
import NotionWriterCore

final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }
class WriterTextView: NSTextView {
    var placeholder = "タイトルを入力…"
    var importImageFiles: (([URL]) -> Void)?
    var importImageData: ((Data) -> Void)?
    var tab: ((Bool) -> Void)?
    var save: (() -> Void)?
    var dismiss: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor(white: 0.65, alpha: 1)])
        }
    }
    override func paste(_ sender: Any?) {
        guard !ImageTransfer.accept(.general, files: importImageFiles, data: importImageData) else { return }
        super.paste(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageTransfer.canRead(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ImageTransfer.accept(sender.draggingPasteboard, files: importImageFiles, data: importImageData) || super.performDragOperation(sender)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 48 { tab?(event.modifierFlags.contains(.shift)); return }
            if event.keyCode == 53 { dismiss?(); return }
        }
        super.keyDown(with: event)
    }
}
final class WriterPanel: NSPanel {
    var save: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 && event.modifierFlags.intersection([.command,.option,.shift,.control]) == .command {
            if let text = firstResponder as? NSTextView, text.hasMarkedText() { return true }
            save?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class WriterWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    let state: AppState
    let titleEditor = WriterTextView()
    let bodyEditor = BodyEditor()
    let properties = stack(.vertical, spacing: 0)
    let status = label("", size: 11, color: .secondaryLabelColor)
    let pendingButton = NSButton(title: "保存結果を確認…", target: nil, action: nil)
    let bodyButton = QuietButton(title: "▸ 本文を追加", target: nil, action: nil)
    let bodyScroll = NSScrollView()
    private var bodyExpanded = false
    private var bodyHeight: NSLayoutConstraint!
    private var loadedBody: String?
    private var loadedBlocks: Data?
    private var loadedFormat: BodyFormat?
    private var loadedFont: NSFont?
    private var loadedImages: [String] = []
    private var loadedDraftRevision = 0
    private var resettingDraft = false
    private var bodyLoadError: String?
    let imageButton = QuietButton(title: "画像を追加…", target: nil, action: nil)
    let imageCount = label("", size: 11, color: .secondaryLabelColor)
    var tagRows: [TagRow] = []
    var urlFields: [NSTextField] = []
    var renderedSchema: Schema?
    var renderedDisplay: DisplayPreferences?
    var previousApp: NSRunningApplication?
    let propertyScroll = NSScrollView()
    var titleHeight: NSLayoutConstraint!
    var propertyHeight: NSLayoutConstraint!
    var rootStack: NSStackView!
    private var fittingContent = false
    private var preferredWidth: CGFloat = 980
    private var minimumWidth: NSLayoutConstraint!
    private var scaledConstraints: [(NSLayoutConstraint, CGFloat)] = []
    private var scaledStacks: [(NSStackView, CGFloat)] = []
    init(state: AppState) {
        self.state = state
        preferredWidth = min(980 * state.display.scale, (NSScreen.main?.visibleFrame.width ?? 1200) - 48)
        let panel = WriterPanel(contentRect: NSRect(x: 0, y: 0, width: preferredWidth, height: 500), styleMask: [.borderless,.resizable], backing: .buffered, defer: false)
        panel.title = "Notion Writer"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.isMovableByWindowBackground = true; panel.appearance = NSAppearance(named: .aqua); panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        panel.minSize = NSSize(width: preferredWidth, height: 260)
        super.init(window: panel); panel.delegate = self
        panel.save = { [weak self] in self?.submit() }
        let root = scaledStack(stack(.vertical, spacing: 10)); rootStack = root; root.translatesAutoresizingMaskIntoConstraints = false
        let content = WriterCardView(); content.importFiles = { [weak self] urls in self?.importImages(urls) }
        content.importData = { [weak self] data in self?.importImageData(data) }; content.wantsLayer = true; content.layer?.backgroundColor = NSColor.white.cgColor; content.layer?.cornerRadius = 14; content.layer?.borderWidth = 1; content.layer?.borderColor = NSColor(white: 0.9, alpha: 1).cgColor; content.layer?.masksToBounds = true; panel.contentView = content; content.addSubview(root)
        minimumWidth = content.widthAnchor.constraint(greaterThanOrEqualToConstant: preferredWidth); minimumWidth.isActive = true
        NSLayoutConstraint.activate([scaledConstraint(root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)),scaledConstraint(root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)),scaledConstraint(root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24)),scaledConstraint(root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24))])
        let titleScroll = editorScroll(titleEditor); titleHeight = titleScroll.heightAnchor.constraint(equalToConstant: 80); titleHeight.isActive = true
        titleEditor.setAccessibilityLabel("文章（Notionのタイトル）"); titleEditor.string = state.draft.title
        titleEditor.tab = { [weak self] back in self?.focusProperty(back ? ((self?.tagRows.count ?? 0) + (self?.urlFields.count ?? 0) - 1) : 0) }
        titleEditor.dismiss = { [weak self] in self?.hide() }
        root.addArrangedSubview(titleScroll); titleScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        properties.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(properties)
        propertyScroll.documentView = document; propertyScroll.drawsBackground = false; propertyScroll.hasVerticalScroller = true; propertyScroll.autohidesScrollers = true
        propertyHeight = propertyScroll.heightAnchor.constraint(equalToConstant: 100 * state.display.scale); propertyHeight.isActive = true
        NSLayoutConstraint.activate([properties.leadingAnchor.constraint(equalTo: document.leadingAnchor),properties.trailingAnchor.constraint(equalTo: document.trailingAnchor),properties.topAnchor.constraint(equalTo: document.topAnchor),properties.bottomAnchor.constraint(equalTo: document.bottomAnchor),document.widthAnchor.constraint(equalTo: propertyScroll.contentView.widthAnchor)])
        root.addArrangedSubview(propertyScroll); propertyScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bodyButton.isBordered = false; bodyButton.contentTintColor = .secondaryLabelColor; bodyButton.target = self; bodyButton.action = #selector(toggleBody)
        let actions = scaledStack(stack(.horizontal, spacing: 16))
        actions.addArrangedSubview(bodyButton)
        imageButton.isBordered = false; imageButton.contentTintColor = WriterStyle.muted; imageButton.target = self; imageButton.action = #selector(addImages)
        imageButton.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)
        imageButton.imagePosition = .imageLeading; imageButton.imageHugsTitle = true; imageButton.setAccessibilityLabel("画像を追加")
        actions.addArrangedSubview(imageButton); actions.addArrangedSubview(imageCount)
        imageCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        configureEditor(bodyEditor)
        bodyEditor.drawsBackground = false
        bodyEditor.importImageFiles = { [weak self] urls in
            guard let self else { return }
            importImages(urls, at: NSMaxRange(bodyEditor.selectedRange()))
        }
        bodyEditor.importImageData = { [weak self] data in
            guard let self else { return }
            importImageData(data, at: NSMaxRange(bodyEditor.selectedRange()))
        }
        bodyEditor.placeholder = "本文を入力…"
        bodyEditor.setAccessibilityLabel("本文")
        bodyEditor.allowsUndo = true
        bodyEditor.importsGraphics = false
        bodyEditor.tab = { [weak self] back in if back { self?.focusProperty((self?.tagRows.count ?? 0) + (self?.urlFields.count ?? 0) - 1) } else { self?.window?.makeFirstResponder(self?.titleEditor) } }
        bodyEditor.dismiss = { [weak self] in self?.hide() }
        bodyScroll.documentView = bodyEditor
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .noBorder
        bodyHeight = bodyScroll.heightAnchor.constraint(equalToConstant: 130)
        bodyHeight.isActive = true
        bodyScroll.isHidden = !bodyExpanded
        root.addArrangedSubview(bodyScroll)
        bodyScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let footer = scaledStack(stack(.horizontal, spacing: 10))
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(status)
        pendingButton.target = self; pendingButton.action = #selector(resolvePending); pendingButton.bezelStyle = .rounded; footer.addArrangedSubview(pendingButton)

        root.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        panel.contentMinSize = NSSize(width: preferredWidth, height: 260); panel.setContentSize(NSSize(width: preferredWidth,height: 480)); panel.initialFirstResponder = titleEditor; update(); panel.setContentSize(NSSize(width: preferredWidth, height: 480)); fitContent(); panel.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func scaledConstraint(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        let base = constraint.constant; scaledConstraints.append((constraint, base)); constraint.constant = base * state.display.scale
        return constraint
    }
    private func scaledStack(_ view: NSStackView) -> NSStackView {
        let base = view.spacing; scaledStacks.append((view, base)); view.spacing = base * state.display.scale
        return view
    }
    private func applyDisplayLayout() {
        guard let window, let content = window.contentView else { return }
        fittingContent = true
        let scale = state.display.scale
        for (constraint, base) in scaledConstraints { constraint.constant = base * scale }
        for (view, base) in scaledStacks { view.spacing = base * scale }
        content.layer?.cornerRadius = 14 * scale
        preferredWidth = min(980 * scale, ((window.screen ?? NSScreen.main)?.visibleFrame.width ?? 1200) - 48)
        minimumWidth.constant = preferredWidth
        window.contentMinSize = NSSize(width: preferredWidth, height: 180 * scale)
        window.setContentSize(NSSize(width: preferredWidth, height: window.frame.height))
        window.isMovable = !state.display.fixedPosition
        window.isMovableByWindowBackground = !state.display.fixedPosition
        for editor in [titleEditor, bodyEditor] { editor.textContainerInset = NSSize(width: 0, height: 3 * scale) }
        imageButton.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12 * scale, weight: .regular))
        status.font = state.display.scaledFont(size: 11); imageCount.font = status.font
        fittingContent = false
    }
    private func positionAtFixedLocation(on screen: NSScreen? = nil) {
        guard let window else { return }
        let visible = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let x = visible.midX - window.frame.width / 2
        let y = visible.midY + visible.height * 0.08 - window.frame.height / 2
        fittingContent = true
        window.setFrameOrigin(NSPoint(x: max(visible.minX + 16, min(x, visible.maxX - window.frame.width - 16)), y: max(visible.minY + 20, min(y, visible.maxY - window.frame.height - 20))))
        fittingContent = false
    }
    func windowDidMove(_ notification: Notification) {
        guard !fittingContent, !state.display.fixedPosition, let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: "writerFreeOrigin")
    }
    func configureEditor(_ editor: WriterTextView) {
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.backgroundColor = .white; editor.textColor = NSColor(white: 0.18, alpha: 1); editor.insertionPointColor = .labelColor; editor.font = .systemFont(ofSize: 16); editor.textContainerInset = NSSize(width: 0, height: 3); editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self
        editor.registerForDraggedTypes(editor.registeredDraggedTypes + [.fileURL,.png,.tiff])
        editor.importImageFiles = { [weak self] urls in self?.importImages(urls) }
        editor.importImageData = { [weak self] data in self?.importImageData(data) }
    }
    func editorScroll(_ editor: WriterTextView) -> NSScrollView {
        configureEditor(editor)
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.autohidesScrollers = true
        return scroll
    }
    func show() {
        if window?.isVisible != true { bodyExpanded = false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = NSWorkspace.shared.frontmostApplication }
        tagRows.forEach { $0.collapse() }; update(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(titleEditor)
        if state.display.fixedPosition {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            positionAtFixedLocation(on: screen)
        } else if let origin = UserDefaults.standard.string(forKey: "writerFreeOrigin") {
            fittingContent = true; window?.setFrameOrigin(NSPointFromString(origin)); fittingContent = false
        }
        fitContent(); state.opened()
    }
    func hide() {
        tagRows.forEach { $0.collapse() }
        do { try state.flush() } catch { showError(error); return }
        window?.orderOut(nil); previousApp?.activate(options: [])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func textDidChange(_ notification: Notification) {
        guard !resettingDraft else { return }
        if (notification.object as? NSTextView) === titleEditor {
            state.draft.title = titleEditor.string
            state.edited()
            titleEditor.needsDisplay = true
            fitContent()
        } else {
            syncBodyDraft()
            bodyEditor.needsDisplay = true
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        state.draft.urls[id] = field.stringValue; state.edited()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let field = control as? NSTextField, let index = urlFields.firstIndex(of: field) else { return false }
        if selector == #selector(NSResponder.insertTab(_:)) { focusProperty(tagRows.count + index + 1); return true }
        if selector == #selector(NSResponder.insertBacktab(_:)) { focusProperty(tagRows.count + index - 1); return true }
        return false
    }
    func focusProperty(_ index: Int) {
        tagRows.forEach { $0.collapse() }
        if tagRows.indices.contains(index) {
            let row = tagRows[index]; row.focus(); row.scrollToVisible(row.bounds)
        } else if urlFields.indices.contains(index - tagRows.count) { window?.makeFirstResponder(urlFields[index - tagRows.count]) }
        else if index >= tagRows.count + urlFields.count && bodyExpanded { window?.makeFirstResponder(bodyEditor) }
        else { window?.makeFirstResponder(titleEditor) }
    }
    func update() {
        if loadedDraftRevision != state.draftRevision {
            loadedDraftRevision = state.draftRevision
            resettingDraft = true
            titleEditor.unmarkText()
            bodyEditor.unmarkText()
            window?.undoManager?.removeAllActions()
            titleEditor.undoManager?.removeAllActions()
            bodyEditor.undoManager?.removeAllActions()
            loadedBody = nil
            bodyLoadError = nil
            resettingDraft = false
        }
        loadBodyDraft()
        updateEditorAvailability()
        let quiet = bodyLoadError == nil && ((state.activeDestination.map { state.status.hasPrefix($0.name + " · ") } ?? false) || state.status == "プロパティを同期中…" || state.status == "Notionに保存しました" || state.status == "保存結果を確認しました" || state.status.hasPrefix("画像を"))
        let message = bodyLoadError ?? state.status
        status.stringValue = message; status.toolTip = message
        let destination = state.activeDestination?.name
        if quiet, let destination { status.stringValue = destination }
        status.isHidden = destination == nil && quiet && !state.busy && !state.draft.submissionPending
        status.superview?.isHidden = status.isHidden && !state.draft.submissionPending
        updateImageCount()
        pendingButton.isHidden = !state.draft.submissionPending
        let schema = state.visibleSchema
        if renderedSchema?.properties != schema.properties || renderedSchema?.dataSourceID != schema.dataSourceID || renderedDisplay?.overallPercent != state.display.overallPercent {
            rebuildProperties(schema); renderedSchema = schema
        }
        for row in tagRows {
            let values = state.draft.tags[row.property.id] ?? []
            if row.selection != values { row.selection = values; row.refresh() }
        }
        for field in urlFields {
            let value = state.draft.urls[field.identifier!.rawValue] ?? ""
            if field.stringValue != value { field.stringValue = value }
        }
        let displayChanged = renderedDisplay != state.display
        if displayChanged {
            let needsPosition = renderedDisplay?.fixedPosition != state.display.fixedPosition || renderedDisplay?.overallPercent != state.display.overallPercent
            applyDisplayLayout()
            titleEditor.font = state.display.scaledFont(size: state.display.titleSize)
            titleEditor.needsDisplay = true
            tagRows.forEach { $0.applyDisplay(state.display) }
            urlFields.forEach { $0.font = state.display.scaledFont(size: state.display.propertySize) }
            bodyButton.font = state.display.scaledFont(size: state.display.propertySize); imageButton.font = bodyButton.font
            renderedDisplay = state.display
            fitContent()
            if needsPosition && state.display.fixedPosition && window?.isVisible == true { positionAtFixedLocation() }
        }
        setEnabled(properties, enabled: titleEditor.isEditable)
        if titleEditor.string != state.draft.title && !titleEditor.hasMarkedText() { titleEditor.string = state.draft.title }
        updateBodyPresentation()
        fitContent()
    }

    private func updateEditorAvailability() {
        titleEditor.isEditable = !state.busy && !state.draft.submissionPending && !state.changingDestination
        bodyEditor.isEditable = titleEditor.isEditable && !state.importingImages && bodyLoadError == nil
        imageButton.isEnabled = bodyEditor.isEditable
    }

    func windowDidResize(_ notification: Notification) { fitContent() }
    func fitContent() {
        guard !fittingContent, let window, let content = window.contentView, let rootStack else { return }
        fittingContent = true
        defer { fittingContent = false }
        content.layoutSubtreeIfNeeded()
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let maximumHeight = visible.height - 40
        let sections = rootStack.arrangedSubviews.filter { !$0.isHidden }
        let otherSections = sections.filter { $0 !== propertyScroll && $0 !== rootStack.arrangedSubviews.first && $0 !== bodyScroll }
        let fixedHeight = 36 * state.display.scale + CGFloat(max(0, sections.count - 1)) * rootStack.spacing + otherSections.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
        let naturalProperties = max(26 * state.display.scale, properties.fittingSize.height + 2 * state.display.scale)
        // Keep the properties usable while giving long notes most of the available height.
        let reservedProperties = min(naturalProperties, max(86 * state.display.scale, maximumHeight * 0.30))
        let minimumBody = bodyExpanded ? maximumHeight * 0.52 : 0
        let titleBudget = max(34 * state.display.scale, maximumHeight - fixedHeight - reservedProperties - minimumBody)
        var naturalTitle: CGFloat = 34 * state.display.scale
        if let container = titleEditor.textContainer, let layout = titleEditor.layoutManager {
            layout.ensureLayout(for: container)
            // The extra line fragment includes a trailing Enter, even on an otherwise empty line.
            naturalTitle = max(34 * state.display.scale, max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 8 * state.display.scale)
        }
        titleHeight.constant = min(titleBudget, naturalTitle)
        let remainingHeight = maximumHeight - fixedHeight - titleHeight.constant
        propertyHeight.constant = min(naturalProperties, max(reservedProperties, remainingHeight - minimumBody))
        if bodyExpanded {
            bodyHeight.constant = max(44 * state.display.scale, remainingHeight - propertyHeight.constant)
        }
        content.layoutSubtreeIfNeeded()
        let height = min(maximumHeight, max(180 * state.display.scale, rootStack.fittingSize.height + 36 * state.display.scale))
        let width = min(visible.width - 32, max(preferredWidth, content.bounds.width))
        let top = bodyExpanded ? visible.maxY - 20 : min(window.frame.maxY, visible.maxY - 20)
        let x = min(max(window.frame.minX, visible.minX + 16), visible.maxX - width - 16)
        let y = max(visible.minY + 20, top - height)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if abs(window.frame.width - width) > 0.5 || abs(window.frame.height - height) > 0.5 || window.frame.minY < visible.minY || window.frame.maxY > visible.maxY {
            window.setFrame(frame, display: true)
        }
    }
    func setEnabled(_ view: NSView, enabled: Bool) {
        (view as? NSControl)?.isEnabled = enabled
        for child in view.subviews { setEnabled(child, enabled: enabled) }
    }
    func rebuildProperties(_ schema: Schema) {
        for view in properties.arrangedSubviews { properties.removeArrangedSubview(view); view.removeFromSuperview() }
        tagRows = []; urlFields = []
        for property in schema.tags {
            let index = tagRows.count
            let row = TagRow(property: property, selection: state.draft.tags[property.id] ?? [], display: state.display)
            row.saveRequested = { [weak self] in self?.submit() }
            row.activated = { [weak self] in self?.focusProperty(index) }
            row.layoutChanged = { [weak self] in self?.fitContent() }
            row.changed = { [weak self] values in guard let self else { return }; self.state.draft.tags[property.id] = values; self.state.edited() }
            row.move = { [weak self] back in self?.focusProperty(index + (back ? -1 : 1)) }
            properties.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: properties.widthAnchor).isActive = true; tagRows.append(row)
        }
        for property in schema.urls {
            let row = stack(.horizontal, spacing: 10 * state.display.scale)
            let icon = NSImageView(); icon.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil); icon.contentTintColor = WriterStyle.muted
            icon.widthAnchor.constraint(equalToConstant: 16 * state.display.scale).isActive = true; icon.heightAnchor.constraint(equalToConstant: 18 * state.display.scale).isActive = true
            let field = NSTextField(); field.placeholderString = property.name + "を追加"; field.stringValue = state.draft.urls[property.id] ?? ""
            field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
            field.font = state.display.scaledFont(size: state.display.propertySize); field.identifier = .init(property.id); field.delegate = self
            row.addArrangedSubview(icon); row.addArrangedSubview(field); row.heightAnchor.constraint(greaterThanOrEqualToConstant: max(26, CGFloat(state.display.propertySize + 10)) * state.display.scale).isActive = true
            properties.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: properties.widthAnchor).isActive = true
            field.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -26 * state.display.scale).isActive = true; urlFields.append(field)
        }
    }
    @objc func addImages() {
        guard let window, bodyEditor.isEditable, !bodyEditor.hasMarkedText() else { return }
        tagRows.forEach { $0.collapse() }
        let offset = bodyExpanded ? NSMaxRange(bodyEditor.selectedRange()) : nil
        let panel = NSOpenPanel()
        panel.title = "本文に追加する画像を選択"; panel.prompt = "画像を追加"
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.importImages(panel.urls, at: offset) }
        }
    }

    func importImages(_ urls: [URL], at offset: Int? = nil) {
        guard bodyEditor.isEditable, !bodyEditor.hasMarkedText() else { return }
        loadBodyDraft(force: true)
        if bodyLoadError != nil { update(); return }
        let caret = offset ?? (bodyEditor.string as NSString).length
        Task { await state.addImageFiles(urls) { try insertImages($0, at: caret) } }
    }

    func importImageData(_ data: Data, at offset: Int? = nil) {
        guard bodyEditor.isEditable, !bodyEditor.hasMarkedText() else { return }
        loadBodyDraft(force: true)
        if bodyLoadError != nil { update(); return }
        let caret = offset ?? (bodyEditor.string as NSString).length
        Task { await state.addImageData(data) { try insertImages($0, at: caret) } }
    }

    private var imagePreviewSize: NSSize {
        let scale = state.display.scale
        let width = (window?.contentView?.bounds.width ?? preferredWidth) - 60 * scale
        return NSSize(width: max(80, min(540 * scale, width)), height: 360 * scale)
    }

    private func insertImages(_ images: [DraftImage], at caret: Int) throws {
        bodyEditor.isEditable = true
        guard bodyEditor.insertImages(images, at: caret, root: state.store.root, size: imagePreviewSize) else {
            throw WriterError.validation("画像を本文に挿入できませんでした。")
        }
        if window?.isVisible == true {
            bodyExpanded = true
            updateBodyPresentation()
            fitContent()
            window?.makeFirstResponder(bodyEditor)
            bodyEditor.scrollRangeToVisible(bodyEditor.selectedRange())
        }
    }

    func resetAfterSave() {
        bodyExpanded = false
        loadBodyDraft(force: true)
        updateBodyPresentation()
        tagRows.forEach { $0.collapse() }
        titleEditor.setSelectedRange(NSRange(location: 0, length: 0))
        titleEditor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        fitContent()
        if state.display.fixedPosition { positionAtFixedLocation() }
    }
    private func loadBodyDraft(force: Bool = false) {
        guard (bodyExpanded || force), !bodyEditor.hasMarkedText() else { return }
        let draft = state.draft
        let font = state.display.scaledFont(size: state.display.bodySize)
        let images = draft.images.map(\.id)
        guard draft.body != loadedBody || draft.formattedBody != loadedBlocks ||
              draft.bodyFormat != loadedFormat || font != loadedFont || images != loadedImages else { return }
        let previousSelection = bodyEditor.selectedRange()
        bodyEditor.baseFont = font
        bodyEditor.isRichText = true
        let plain = NSAttributedString(string: draft.body, attributes: bodyEditor.normalAttributes)
        let attributed: NSAttributedString
        do {
            if draft.bodyFormat == .markdown || !draft.images.isEmpty || draft.formattedBody != nil {
                let blocks = try PagePayload.bodyWithImages(draft)
                let byID = Dictionary(draft.images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let image: (String) -> NSAttributedString? = { [self] id in
                    byID[id].map { bodyEditor.imageFragment($0, root: state.store.root, size: imagePreviewSize) }
                }
                attributed = draft.bodyFormat == .markdown
                    ? MarkdownPreview.render(blocks, font: font, image: image)
                    : BodyDocument.renderPlain(blocks, attributes: bodyEditor.normalAttributes, image: image)
            } else { attributed = plain }
            bodyLoadError = nil
        } catch {
            attributed = plain
            bodyLoadError = "本文を復元できませんでした。下書きを保護するため、本文の編集と送信を止めました。"
        }
        bodyEditor.textStorage?.setAttributedString(attributed)
        let offset = min(previousSelection.location, attributed.length)
        bodyEditor.setSelectedRange(NSRange(location: offset, length: min(previousSelection.length, attributed.length - offset)))
        bodyEditor.typingAttributes = bodyEditor.normalAttributes
        loadedBody = draft.body
        loadedBlocks = draft.formattedBody
        loadedFormat = draft.bodyFormat
        loadedFont = font
        loadedImages = images
    }
    private func syncBodyDraft() {
        guard bodyLoadError == nil, !bodyEditor.hasMarkedText() else { return }
        let raw = bodyEditor.string
        guard let storage = bodyEditor.textStorage else { return }
        let document = BodyDocument.read(storage)
        let current = Dictionary(state.draft.images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let images = document.images.map { current[$0.id] ?? $0 }
        guard let encoded = try? JSONSerialization.data(withJSONObject: document.blocks, options: [.sortedKeys]) else {
            bodyLoadError = "本文の書式を保存できませんでした。直前の下書きを保持しました。"
            update()
            return
        }
        state.draft.body = raw
        state.draft.bodyFormat = .markdown
        state.draft.formattedBody = encoded
        state.draft.images = images
        loadedBody = raw
        loadedBlocks = encoded
        loadedFormat = .markdown
        loadedImages = images.map(\.id)
        updateImageCount()
        state.edited()
    }
    private func updateImageCount() {
        imageCount.stringValue = state.importingImages ? "追加中…" : (state.draft.images.isEmpty ? "" : "画像\(state.draft.images.count)枚")
    }
    private func updateBodyPresentation() {
        bodyScroll.isHidden = !bodyExpanded
        if bodyExpanded { bodyButton.title = "▾ 本文" }
        else { bodyButton.title = state.draft.body.isEmpty && state.draft.images.isEmpty ? "▸ 本文を追加" : "▸ 本文" }
    }
    @objc func toggleBody() {
        bodyExpanded.toggle()
        update()
        if bodyExpanded { window?.makeFirstResponder(bodyEditor) }
        else {
            window?.makeFirstResponder(titleEditor)
            if state.display.fixedPosition { positionAtFixedLocation() }
        }
    }
    @objc func saveClicked() { submit() }
    func submit() {
        guard bodyLoadError == nil else { return }
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        tagRows.forEach { $0.collapse() }
        window?.makeKeyAndOrderFront(nil)
        Task { await state.submit() }
    }
    @objc func resolvePending() {
        let alert = NSAlert(); alert.messageText = "Notionで保存結果を確認してください"
        alert.informativeText = "ページが作成済みなら「保存済み」を選んでください。見つからない場合だけ「再送を許可」を選ぶと、この下書きをもう一度保存できます。"
        let partialPage = state.draft.pendingPageID.flatMap(UUID.init(uuidString:))
        if partialPage != nil {
            alert.informativeText = "保存先にページが作成されています。本文が最後まで入っているか確認してください。新しく保存し直す場合は、Notion側の途中ページを先に整理してください。"
        }
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存済み・下書きを閉じる")
        alert.addButton(withTitle: partialPage == nil ? "未保存を確認・再送を許可" : "途中ページを整理済み・再送を許可")
        if partialPage != nil { alert.addButton(withTitle: "Notionで確認") }
        let result = alert.runModal()
        if let partialPage, result.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1,
           let url = URL(string: "https://www.notion.so/" + partialPage.uuidString.replacingOccurrences(of: "-", with: "")) {
            NSWorkspace.shared.open(url)
            return
        }
        do {
            if result == .alertSecondButtonReturn { try state.resolvePending(discard: true) }
            if result == .alertThirdButtonReturn { try state.resolvePending(discard: false) }
        } catch { showError(error) }
    }
    func showError(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
}
