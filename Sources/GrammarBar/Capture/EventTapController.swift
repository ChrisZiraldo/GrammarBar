import AppKit
import CoreGraphics

// Called on the main thread for every keyDown event that isn't Return.
typealias KeystrokeHandler = @MainActor () -> Void

// Called synchronously (still on the main thread) for Return / keypad-Enter
// keydowns. `ctrlHeld` reports whether Control was held. Return `true` to
// swallow the keystroke so it never reaches the frontmost app; return
// `false` to let it pass through untouched.
typealias ReturnKeyHandler = (Bool) -> Bool

private let returnKeyCode: CGKeyCode = 36
private let keypadEnterKeyCode: CGKeyCode = 76

final class EventTapController {
    var onKeystroke: KeystrokeHandler?
    var onReturnKey: ReturnKeyHandler?

    /// Stamped onto CGEvents that GrammarBar posts itself (e.g. TextWriter's paste-replace
    /// fallback), so the tap callback can tell them apart from real user keystrokes.
    static let syntheticEventMarker: Int64 = 0x67625F73796E7468 // "gb_synth" as an int

    private(set) var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Not .listenOnly: we need the ability to swallow Ctrl+Return so it
        // doesn't also trigger the frontmost app's own Return/Ctrl+Return behavior.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: selfPtr
        ) else {
            print("[EventTap] Failed — check Input Monitoring permission in System Settings.")
            return
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit { stop() }
}

// File-scope C-compatible callback: cannot capture state, uses userInfo pointer.
// This fires synchronously on the main run loop (the tap's source is attached
// to CFRunLoopGetMain()), so it's safe for onReturnKey to touch main-actor
// state via MainActor.assumeIsolated internally.
private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable if macOS disabled the tap due to timeout
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = controller.tap {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        // Ignore keystrokes GrammarBar posted itself (e.g. the paste-replace fallback's
        // synthetic Cmd+A/Cmd+V) — let them pass through to the frontmost app untouched,
        // but don't treat them as new user typing.
        guard event.getIntegerValueField(.eventSourceUserData) != EventTapController.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Ignore pure modifier keystrokes (Cmd, Shift, Ctrl, Option alone)
        let isModifierOnly: Bool = [
            CGKeyCode(55), // Cmd
            CGKeyCode(56), // Shift
            CGKeyCode(59), // Ctrl
            CGKeyCode(58), // Option
            CGKeyCode(57), // CapsLock
            CGKeyCode(63)  // Fn
        ].contains(keyCode)

        guard !isModifierOnly else { return Unmanaged.passUnretained(event) }

        if keyCode == returnKeyCode || keyCode == keypadEnterKeyCode {
            let ctrlHeld = flags.contains(.maskControl)
            if let shouldConsume = controller.onReturnKey?(ctrlHeld), shouldConsume {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async {
            Task { @MainActor in
                controller.onKeystroke?()
            }
        }
    }

    return Unmanaged.passUnretained(event)
}
