import AppKit

/// Keeps the frontmost allowed app's window filling the screen above the Home bar.
/// Uses a plain resize instead of native full screen (no separate Spaces, no animations).
@MainActor
final class WindowManager {
    let reservedBottom: CGFloat

    init(reservedBottom: CGFloat) {
        self.reservedBottom = reservedBottom
    }

    /// Target frame in AX coordinates (origin at the top-left of the primary screen).
    func targetFrame() -> CGRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        var r = screen.visibleFrame
        r.origin.y += reservedBottom
        r.size.height -= reservedBottom
        return CGRect(x: r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The same area in AppKit coordinates, for Avadhāna's own windows.
    func cocoaTargetFrame() -> NSRect {
        guard let screen = NSScreen.screens.first else { return .zero }
        var r = screen.visibleFrame
        r.origin.y += reservedBottom
        r.size.height -= reservedBottom
        return r
    }

    func enforce(_ app: NSRunningApplication) {
        guard AX.isTrusted(prompt: false), let target = targetFrame(),
              let w = AX.focusedWindow(pid: app.processIdentifier),
              AX.isStandardWindow(w) else { return }   // leave dialogs and panels alone

        if AX.bool(w, "AXFullScreen") == true {
            AX.exitFullScreen(w)   // resized on a later tick, once the exit animation finishes
            return
        }
        if let f = AX.frame(w),
           abs(f.minX - target.minX) < 2, abs(f.minY - target.minY) < 2,
           abs(f.width - target.width) < 2, abs(f.height - target.height) < 2 { return }
        AX.setFrame(w, target)
    }
}
