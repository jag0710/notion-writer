import AppKit
import NotionWriterCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var state: AppState!
    private var writer: WriterWindow?
    var settings: SettingsWindow?
    let hotKey = HotKey()
    var hotKeyWarning: String?
    var shortcutItem: NSMenuItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        do { state = try AppState(qa: CommandLine.arguments.contains("--qa")) }
        catch {
            let alert = NSAlert(error: error); alert.messageText = "保存済みデータを安全に開けませんでした"; alert.informativeText = "既存ファイルを上書きせず終了します。\n" + error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        if !state.qa { try? ImageAttachments.tidyCache(root: state.store.root) }
        state.updated = { [weak self] in self?.writer?.update(); self?.settings?.update() }
        state.saved = { [weak self] in
            guard let self else { return }
            self.writer?.update(); self.writer?.resetAfterSave(); self.writer?.hide(); self.item.button?.title = "✓ 保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.item.button?.title = self?.item.button?.image == nil ? "W" : "" }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "WriterIcon", withExtension: "png"), let original = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = original
        }
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let menuIcon = NSImage(contentsOf: url) {
            menuIcon.size = NSSize(width: 22, height: 22)
            // The alpha template lets macOS choose a legible color for the menu bar.
            menuIcon.isTemplate = true
            item.button?.image = menuIcon
        }
        if item.button?.image == nil { item.button?.title = "W" }
        item.button?.setAccessibilityLabel("Notion Writer")
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "入力ウィンドウを表示 / 非表示", action: #selector(toggle), keyEquivalent: ""); openItem.target = self; menu.addItem(openItem)
        shortcutItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""); menu.addItem(shortcutItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ","); settingsItem.target = self; menu.addItem(settingsItem)
        let syncItem = NSMenuItem(title: "プロパティを再同期", action: #selector(sync), keyEquivalent: ""); syncItem.target = self; menu.addItem(syncItem)
        menu.addItem(.separator()); let quitItem = NSMenuItem(title: "Notion Writerを終了", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self; menu.addItem(quitItem)
        item.menu = menu
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appMenu.addItem(appItem); appItem.submenu = menu.copy() as? NSMenu
        let edit = NSMenuItem(title: "編集", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "編集")
        for (title, action, key) in [("取り消す",Selector(("undo:")),"z"),("やり直す",Selector(("redo:")),"Z"),("カット",#selector(NSText.cut(_:)),"x"),("コピー",#selector(NSText.copy(_:)),"c"),("ペースト",#selector(NSText.paste(_:)),"v"),("すべて選択",#selector(NSText.selectAll(_:)),"a")] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        edit.submenu = editMenu; appMenu.addItem(edit); NSApp.mainMenu = appMenu
        hotKey.action = { [weak self] in self?.toggle() }; register(Shortcut.load())
        if CommandLine.arguments.contains("--show") || state.qa { showWriter() }
    }
    func register(_ shortcut: Shortcut) {
        hotKeyWarning = hotKey.register(shortcut)
        shortcutItem.title = shortcut.label + (hotKeyWarning == nil ? " · 有効" : " · 要設定（競合）")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWriter() }; return true
    }
    private func showWriter() {
        if writer == nil { writer = WriterWindow(state: state) }
        writer?.show()
    }
    @objc func toggle() {
        if let writer, writer.window?.isVisible == true { writer.hide() }
        else { showWriter() }
    }
    @objc func showSettings() {
        if settings == nil {
            settings = SettingsWindow(state: state)
            settings?.shortcutChanged = { [weak self] value in
                value.save(); self?.register(value); return self?.hotKeyWarning
            }
        }
        settings?.setShortcutMessage(hotKeyWarning)
        settings?.show()
    }
    @objc func sync() { Task { await state.sync() } }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state?.busy == true || state?.importingImages == true || state?.changingDestination == true { let alert = NSAlert(); alert.messageText = "処理が終わるまでお待ちください"; alert.runModal(); return .terminateCancel }
        do { try state?.flush(); return .terminateNow } catch { NSAlert(error: error).runModal(); return .terminateCancel }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
