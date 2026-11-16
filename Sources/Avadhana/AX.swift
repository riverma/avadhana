import AppKit
import ApplicationServices

/// Thin helpers over the Accessibility API, used to find, raise and resize other apps' windows.
enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// False once the window has been closed.
    static func isAlive(_ el: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value) == .success
    }

    static func isStandardWindow(_ el: AXUIElement) -> Bool {
        string(el, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// `rect` is in AX coordinates (top-left origin of the primary screen).
    static func setFrame(_ el: AXUIElement, _ rect: CGRect) {
        var pos = rect.origin, size = rect.size
        guard let posVal = AXValueCreate(.cgPoint, &pos), let sizeVal = AXValueCreate(.cgSize, &size) else { return }
        // Position, size, position again: some apps clamp size against the old position.
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
    }

    static func exitFullScreen(_ el: AXUIElement) {
        AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, kCFBooleanFalse)
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    /// Whether the focused element of the frontmost app is something you type into.
    /// Errs on the side of "yes" so a shortcut never eats a keystroke meant for text.
    static func focusedElementIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return true }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.15)
        let editableRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                                          kAXComboBoxRole as String, "AXSearchField"]
        if let role = string(el, kAXRoleAttribute), editableRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }
}
