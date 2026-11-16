import AppKit

/// System-wide keyboard tap, used only for Home/Back shortcuts set to "ignore while typing": unlike a
/// hot key, a tap can decide per key press whether to let it through. Requires Accessibility access,
/// and runs only while Avadhāna is on and such a shortcut exists.
final class KeyTap {
    /// Return true to swallow the key press.
    var handler: (CGKeyCode, CGEventFlags) -> Bool = { _, _ in false }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            return me.handler(code, event.flags) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }

        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    deinit { stop() }

    func stop() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }
}
