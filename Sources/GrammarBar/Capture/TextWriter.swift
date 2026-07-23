import AppKit
import ApplicationServices

final class TextWriter {

    /// Copy text to the system clipboard without modifying the focused element.
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Write corrected text into the focused element by simulating select-all + paste.
    ///
    /// We deliberately don't use AXUIElementSetAttributeValue(kAXValueAttribute) here. Custom
    /// text editors — most notably Electron/Chromium apps like Cursor and VS Code, which back
    /// their AX tree with a Monaco text area — can report `.success` and even echo back the new
    /// value on read, while leaving their *real* internal editor model out of sync with that AX
    /// shadow value. The visible text can appear to update, but the editor's own input pipeline
    /// gets confused afterward and stops accepting further keystrokes correctly. Select-all +
    /// paste goes through the same real input path a user's own typing would, which every editor
    /// (native or custom) is built to handle correctly.
    @discardableResult
    func write(_ text: String, to element: AXUIElement) -> Bool {
        pasteReplace(text)
    }

    // MARK: - Paste

    private func pasteReplace(_ text: String) -> Bool {
        // Stash and restore the original pasteboard contents to be minimally invasive
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)

        // Select all (Cmd+A)
        postKey(keyCode: 0, flags: .maskCommand, source: source)
        // Small delay to let the app process select-all
        Thread.sleep(forTimeInterval: 0.05)
        // Paste (Cmd+V)
        postKey(keyCode: 9, flags: .maskCommand, source: source)

        // Restore pasteboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let prev = previousContents {
                pasteboard.setString(prev, forType: .string)
            }
        }

        return true
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags   = flags
        // Our own EventTapController sees every session keystroke, including ones we post
        // ourselves — without this marker it would treat this synthetic Cmd+A/Cmd+V as real
        // typing and immediately kick off a spurious new correction cycle mid-paste.
        down?.setIntegerValueField(.eventSourceUserData, value: EventTapController.syntheticEventMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: EventTapController.syntheticEventMarker)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
