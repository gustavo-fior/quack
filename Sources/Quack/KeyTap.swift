import CoreGraphics
import Foundation

enum InputKind {
    case keyDown, keyUp, flagsChanged, mouseDown, mouseUp, scroll
}

struct InputEvent {
    var kind: InputKind
    var keyCode: Int = 0
    var isRepeat = false
    var flags: CGEventFlags = []
}

/// A listen-only event tap on its own thread. It can observe input but never alter or block it,
/// and Quack only ever looks at which key moved, never at what was typed.
final class KeyTap {
    var handler: ((InputEvent) -> Void)?
    private var port: CFMachPort?
    private var thread: Thread?

    var isInstalled: Bool { port != nil }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    @discardableResult
    func install() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        // The tap sits as early in the event path as macOS allows, ahead of other taps, which
        // measures about a millisecond quicker than the usual session tap. The session tap is
        // the fallback if the earlier one is refused.
        var created: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            created = CGEvent.tapCreate(
                tap: location, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: keyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            if created != nil { break }
        }
        guard let tap = created else { return false }
        port = tap

        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "quack.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    /// Turning the tap off means Quack does no work at all while disabled or asleep.
    func setEnabled(_ enabled: Bool) {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown, .keyUp:
            handler?(InputEvent(
                kind: type == .keyDown ? .keyDown : .keyUp,
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
        case .flagsChanged:
            handler?(InputEvent(
                kind: .flagsChanged,
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handler?(InputEvent(kind: .mouseDown))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            handler?(InputEvent(kind: .mouseUp))
        case .scrollWheel:
            handler?(InputEvent(kind: .scroll))
        default:
            break
        }
    }
}

private func keyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
