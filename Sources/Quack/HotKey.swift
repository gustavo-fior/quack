import AppKit
import Carbon.HIToolbox

struct Shortcut: Equatable {
    var keyCode: Int
    /// NSEvent.ModifierFlags raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    var label: String

    static let standard = Shortcut(
        keyCode: kVK_ANSI_K,
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue,
        label: "K")

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }
}

/// One system-wide shortcut, registered through Carbon so it needs no extra permission.
final class HotKey {
    static let shared = HotKey()
    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    func register(_ shortcut: Shortcut?) {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        guard let shortcut else { return }
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = EventHotKeyID(signature: OSType(0x5155_434B), id: 1) // "QUCK"
        RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
            GetApplicationEventTarget(), 0, &ref)
    }
}
