import AppKit
import Carbon

struct Shortcut: Codable {
    var keyCode: UInt32 = 49
    var modifiers: UInt = NSEvent.ModifierFlags.command.rawValue
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }; if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }; if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
    var label: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }; if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }; if flags.contains(.command) { text += "⌘" }
        let keys: [UInt32: String] = [49:"Space",0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",36:"Return",48:"Tab",18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0"]
        return text + (keys[keyCode] ?? "Key \(keyCode)")
    }
    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "shortcut"), let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return Shortcut() }
        return value
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "shortcut") }
}
@MainActor final class HotKey {
    var reference: EventHotKeyRef?
    var handler: EventHandlerRef?
    var action: () -> Void = {}
    func register(_ shortcut: Shortcut) -> String? {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if spotlightConflict(shortcut) { return "Spotlightと競合しています。システム設定でSpotlightのキーを変更するか、別のキーを記録してください。" }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let object = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { object.action() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: 0x4E575254, id: 1), GetApplicationEventTarget(), 0, &reference)
        return status == noErr ? nil : "このショートカットは登録できません (\(status))。別のキーを記録してください。"
    }
    func spotlightConflict(_ shortcut: Shortcut) -> Bool {
        let domain = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        if let hotkeys = domain?.dictionary(forKey: "AppleSymbolicHotKeys") {
            for id in ["64", "65"] {
                guard let item = hotkeys[id] as? [String: Any], item["enabled"] as? Bool != false,
                      let value = item["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { continue }
                if parameters[1].uint32Value == shortcut.keyCode && parameters[2].uintValue == shortcut.modifiers { return true }
            }
            if hotkeys["64"] != nil { return false }
        }
        // When system preferences are unavailable, preserve Spotlight's standard binding.
        return shortcut.keyCode == 49 && shortcut.flags.intersection([.command,.control,.option,.shift]) == .command
    }
}
final class ShortcutRecorder: NSButton {
    var changed: ((Shortcut) -> Void)?
    var shortcut = Shortcut.load()
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero); bezelStyle = .rounded; title = shortcut.label + "  —  変更"
        target = self; action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func begin() { recording = true; title = "キーを押してください（Escで取消）"; window?.makeFirstResponder(self) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = shortcut.label + "  —  変更"; return }
        let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
        guard !flags.intersection([.command,.option,.control]).isEmpty, ![UInt16(12),13,36,48].contains(event.keyCode) || flags != .command else { NSSound.beep(); return }
        shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
        recording = false; title = shortcut.label + "  —  変更"; changed?(shortcut)
    }
}
