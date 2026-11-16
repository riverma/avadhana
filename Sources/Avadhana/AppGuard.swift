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
            if isFocusBrowser(app) { return .allowed }
            return isPreexisting ? .hideOnly : .block
        }
        if allowedBundleIDs.contains(bid) || Self.systemAllowed.contains(bid) { return .allowed }
        if bid == "com.apple.finder" || isPreexisting { return .hideOnly }
        return .block
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
        where app.activationPolicy == .regular && !app.isTerminated {
            switch verdict(for: app) {
            case .hideOnly where !app.isHidden: hide(app)
            case .block: block(app)
            default: break
            }
        }
    }

    private func handle(_ note: Notification, launched: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        switch verdict(for: app) {
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
