import AppKit
import ApplicationServices

final class FocusTracker {

    // Electron/Chromium apps (Cursor, VS Code, Slack, Discord, ...) ship their
    // accessibility tree disabled by default and only build it once an
    // assistive-technology client asks for it. We nudge them into building it
    // by setting AXManualAccessibility (falling back to the legacy
    // AXEnhancedUserInterface flag) on first contact with each app. The tree
    // materializes asynchronously, so the very first keystroke or two in a
    // freshly-focused Electron app may still miss — subsequent ones succeed
    // once Chromium finishes building it.
    private var accessibilityNudgedPids = Set<pid_t>()

    private func nudgeAccessibilityIfNeeded(for pid: pid_t) {
        guard !accessibilityNudgedPids.contains(pid) else { return }
        accessibilityNudgedPids.insert(pid)

        let axApp = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .attributeUnsupported {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // Returns the currently focused AXUIElement, or nil if none / not accessible.
    func focusedElement() -> AXUIElement? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            nudgeAccessibilityIfNeeded(for: pid)
        }

        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              CFGetTypeID(ref!) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    // Returns the string value of a text element, or nil.
    func value(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    // Returns true if the element is a secure/password text field.
    func isSecureTextField(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success,
              let role = ref as? String
        else { return false }
        return role == "AXSecureTextField"
    }

    // Returns true if the element is an editable text field or area.
    func isEditableTextField(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success,
              let role = ref as? String
        else { return false }
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        return editableRoles.contains(role)
    }

    // Returns the screen frame of the element in NSWindow/AppKit coordinates
    // (origin bottom-left, Y increases upward). Returns nil if unavailable.
    func screenBounds(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef
        else { return nil }

        // AX position is top-left origin, Y increases downward (same as CGPoint on macOS screens)
        var axPosition = CGPoint.zero
        var axSize = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &axPosition),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &axSize)
        else { return nil }

        // Convert from AX top-left-origin to AppKit bottom-left-origin
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitY = screenHeight - axPosition.y - axSize.height
        return CGRect(x: axPosition.x, y: appKitY, width: axSize.width, height: axSize.height)
    }

    // Fields taller than this are treated as big editors, where the bubble should
    // follow the cursor line instead of sitting above the whole editor.
    private static let compactFieldMaxHeight: CGFloat = 160

    // Where to attach the bubble when it floats near the text: the field itself for
    // normal input boxes, or the cursor line for tall editors. AppKit coordinates.
    // Returns nil when the app doesn't expose usable geometry.
    func bubbleAnchorRect(for element: AXUIElement) -> CGRect? {
        let field = screenBounds(of: element).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }

        if let field, field.height <= Self.compactFieldMaxHeight {
            return field
        }
        if let caret = caretBounds(of: element) {
            // Make sure the caret really belongs to this field before trusting it.
            if let field {
                let slack = field.insetBy(dx: -40, dy: -40)
                if slack.contains(CGPoint(x: caret.midX, y: caret.midY)) { return caret }
            } else {
                return caret
            }
        }
        return field
    }

    // Screen rect (AppKit coordinates) of the character just before the cursor, or
    // of the selection. Nil if the app doesn't support AXBoundsForRange.
    func caretBounds(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        // A bare cursor has no width, so measure the character before it instead.
        if range.length == 0 {
            guard range.location > 0 else { return nil }
            range = CFRange(location: range.location - 1, length: 1)
        }

        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.width >= 0
        else { return nil }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: screenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    // Returns the bundle ID of the frontmost app.
    func frontmostAppBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
