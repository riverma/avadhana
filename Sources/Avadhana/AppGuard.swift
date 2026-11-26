import AppKit

/// Enforces the session's app allowlist:
/// - apps launched during a session that aren't allowed are quit immediately
/// - apps that were already running are hidden (never quit, so no unsaved work is lost)
/// - your normal browser counts as "not allowed"; only the dedicated focus instance is
@MainActor
final class AppGuard {
    enum Verdict { case ours, allowed, hideOnly, block }

    private(set) var allowedBundleIDs: Set<String> = []
    /// The external browser app used for site tiles (nil when sites open inside Avadhāna).
    var browserBundleID: () -> String? = { nil }
    var isFocusBrowser: (NSRunningApplication) -> Bool = { _ in false }
    var onBlocked: (NSRunningApplication) -> Void = { _ in }
    var onAllowedActivated: (NSRunningApplication) -> Void = { _ in }
    var onHomeActivated: () -> Void = {}
    /// Offered a browser that just came forward, before it's closed or hidden, in case it's showing
    /// a link from one of your apps. Returns true to take it; `done(true)` means the link was moved.
    var catchLink: (NSRunningApplication, _ launched: Bool, _ done: @escaping (Bool) -> Void) -> Bool = { _, _, _ in false }
    /// Browsers being checked for a link; left alone until that's done.
    private(set) var checking: Set<pid_t> = []
    /// When Spotlight was last in use. Links opened from Spotlight aren't moved.
    private var spotlightUsed: Date?

    private var observers: [NSObjectProtocol] = []
    private var preexisting: Set<pid_t> = []
    private var hiddenByUs: Set<pid_t> = []

    /// System UI that shouldn't be fought with (permission prompts, settings).
    static let systemAllowed: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
    ]

    func verdict(for app: NSRunningApplication) -> Verdict {
        if app.processIdentifier == getpid() { return .ours }
        guard app.activationPolicy == .regular else { return .allowed }
        let bid = app.bundleIdentifier ?? ""
        let isPreexisting = preexisting.contains(app.processIdentifier)

        if let browser = browserBundleID(), bid == browser {
            return Self.browserVerdict(isFocus: isFocusBrowser(app), allowed: allowedBundleIDs.contains(bid), isPreexisting: isPreexisting)
        }
        if allowedBundleIDs.contains(bid) || Self.systemAllowed.contains(bid) { return .allowed }
        if bid == "com.apple.finder" || isPreexisting { return .hideOnly }
        return .block
    }

    /// The chosen browser: its dedicated instance and any browser you've added as an app are allowed.
    /// Your normal browser (not on the list) is hidden if it was open before, otherwise closed.
    static func browserVerdict(isFocus: Bool, allowed: Bool, isPreexisting: Bool) -> Verdict {
        if isFocus || allowed { return .allowed }
        return isPreexisting ? .hideOnly : .block
    }

    func start() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        preexisting = Set(running.map(\.processIdentifier))
        for app in running where verdict(for: app) == .hideOnly { hide(app) }

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note, launched: true) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note, launched: false) }
        })
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        for app in NSWorkspace.shared.runningApplications where hiddenByUs.contains(app.processIdentifier) {
            app.unhide()
        }
        hiddenByUs = []
        preexisting = []
        checking = []
    }

    /// Single-app view: hide every other regular app (they're unhidden when the session ends).
    /// Pass nil when one of Avadhāna's own windows is in front.
    func hideOthers(except keep: NSRunningApplication?) {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier != getpid()
            && app.processIdentifier != keep?.processIdentifier
            && !app.isHidden {
            hide(app)
        }
    }

    private func hide(_ app: NSRunningApplication) {
        app.hide()
        hiddenByUs.insert(app.processIdentifier)
        // Hiding an app while it's still activating can be ignored; try again shortly after.
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !app.isTerminated && !app.isHidden { app.hide() }
            }
        }
    }

    /// Sets the allowlist. Apps that are running but no longer allowed (because the list or the
    /// browser changed) are treated like apps that were open before: hidden, never quit.
    func updateAllowed(_ ids: Set<String>) {
        allowedBundleIDs = ids
        guard !observers.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if verdict(for: app) == .block { preexisting.insert(app.processIdentifier) }
        }
    }

    /// Quits an app that was opened while Avadhāna is on. It's force-quit only if it ignores the
    /// request within a few seconds of launching, before it could hold any work.
    private func block(_ app: NSRunningApplication) {
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !app.isTerminated, let launched = app.launchDate, Date().timeIntervalSince(launched) < 10 else { return }
            app.forceTerminate()
        }
    }

    /// Runs every second: catches anything that slipped past the launch/activate notifications
    /// (e.g. an app opened from the Dock while it was revealing, or one that ignored a hide).
    func sweep() {
        guard !observers.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated && !checking.contains(app.processIdentifier) {
            switch verdict(for: app) {
            case .hideOnly where !app.isHidden: hide(app)
            case .block: block(app)
            default: break
            }
        }
    }

    /// True if Spotlight was in use in the last few seconds, or is on screen.
    var spotlightRecentlyUsed: Bool {
        if let spotlightUsed, Date().timeIntervalSince(spotlightUsed) < 3 { return true }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "Spotlight" }
    }

    private func handle(_ note: Notification, launched: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == "com.apple.Spotlight" { spotlightUsed = Date() }
        let pid = app.processIdentifier
        if checking.contains(pid) { return }
        let v = verdict(for: app)
        // A browser coming forward may be showing a link from one of your apps.
        if !launched, v == .hideOnly || v == .block,
           catchLink(app, v == .block, { [weak self] moved in
               guard let self else { return }
               self.checking.remove(pid)
               guard !app.isTerminated else { return }
               if v == .block { self.block(app) } else { self.hide(app) }
               if !moved { self.onBlocked(app) }
           }) {
            checking.insert(pid)
            return
        }
        switch v {
        case .ours:
            if !launched { onHomeActivated() }
        case .allowed:
            if !launched && app.activationPolicy == .regular { onAllowedActivated(app) }
        case .hideOnly:
            guard !launched else { return }
            hide(app)
            onBlocked(app)
        case .block:
            block(app)
            if !launched || app.isActive { onBlocked(app) }
        }
    }
}
