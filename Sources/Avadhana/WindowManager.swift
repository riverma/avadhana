import AppKit

/// Keeps the frontmost allowed app's window filling the screen above the Home bar.
/// Uses a plain resize instead of native full screen (no separate Spaces, no animations).
@MainActor
final class WindowManager {
    let reservedBottom: CGFloat
    /// Bumped on each activation so retries from an earlier activation stop.
    private var generation: [pid_t: Int] = [:]

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

    /// Runs `enforce` a few times after an app comes forward. A window on another desktop or in
    /// full screen isn't reachable until macOS finishes switching Spaces, so one attempt isn't enough.
    func enforceWithRetries(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let gen = (generation[pid] ?? 0) + 1
        generation[pid] = gen
        for delay in [0.3, 0.8, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation[pid] == gen, !app.isTerminated,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.enforce(app)
            }
        }
    }

    func enforce(_ app: NSRunningApplication) {
        guard AX.isTrusted(prompt: false), let target = targetFrame() else { return }
        let pid = app.processIdentifier
        let w: AXUIElement
        if let focused = AX.focusedWindow(pid: pid) {
            w = focused
        } else if let first = AX.windows(pid: pid).first(where: AX.isStandardWindow) {
            // No focused window readable (e.g. it's on another desktop): raise the first one instead.
            AX.raise(first)
            w = first
        } else {
            return
        }
        guard AX.isStandardWindow(w) else { return }   // leave dialogs and panels alone

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
