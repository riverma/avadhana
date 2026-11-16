import AppKit
import SwiftUI

/// Borderless windows can't become key by default; the session home screen needs to.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppController: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    /// Every change (from Settings or anywhere else) is saved to config.json and applied live.
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            saveConfig()
            applyConfig(old: oldValue)
        }
    }
    @Published var configError: String?
    @Published var inSession = false
    @Published var axTrusted = false
    /// The app or site in front, or nil on the home screen.
    @Published var currentAppName: String?
    var atHome: Bool { currentAppName == nil }
    @Published var toast: String?
    /// The tile that's opening, for the loading indicator.
    @Published var launching: Tile?
    /// The shortcut being recorded in Settings; no shortcut fires while this is set.
    @Published var recordingAction: ShortcutAction?
    /// System-wide shortcuts that couldn't be registered because another app already uses the keys.
    @Published var unavailableShortcuts: Set<ShortcutAction> = []
    private var registeredHotKeys: Set<ShortcutAction> = []
    private var launchToken = 0
    /// The allowed app you were using, to return to when something else is blocked.
    private weak var lastAllowedApp: NSRunningApplication?

    // Home screen state
    @Published var query = "" { didSet { if query != oldValue { selection = 0 } } }
    @Published var selection = 0
    @Published var focusToken = 0          // bumped to put keyboard focus in the search box
    private var gridColumns = 1
    private var visibleHeight: CGFloat = 600

    /// Showing the "Exit Avadhāna?" confirmation (Stay / Exit).
    @Published var confirmingExit = false

    private(set) var browser: SiteBrowser!
    let guardian = AppGuard()
    let windows = WindowManager(reservedBottom: HomeBar.height)
    let tweaks = SystemTweaks()
    private let keyTap = KeyTap()
    private let hotKeys = HotKeys()

    private var setupWindow: NSWindow!
    private var settingsWindow: NSWindow?
    private var sessionWindow: NSWindow?
    private var homeBar: HomeBar?
    private var ticker: Timer?
    private var quitAfterEnd = false
    private var toastWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var keyWindowObserver: NSObjectProtocol?

    override init() {
        let (cfg, err) = Config.load()
        config = cfg
        configError = err
        super.init()
        browser = makeBrowser(cfg.effectiveBrowser)
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        tweaks.restoreIfNeeded()   // undo anything a crashed session left behind
        buildMenu()
        axTrusted = AX.isTrusted(prompt: false)

        setupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        setupWindow.title = "Avadhāna"
        setupWindow.backgroundColor = Theme.nsPaper
        setupWindow.isReleasedWhenClosed = false
        setupWindow.contentView = NSHostingView(rootView: SetupView().environmentObject(self))
        setupWindow.center()
        setupWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()

        guardian.browserBundleID = { [weak self] in self?.browser.externalBundleID }
        guardian.isFocusBrowser = { [weak self] app in self?.browser.isFocusProcess(app) ?? false }
        guardian.onBlocked = { [weak self] app in
            guard let self else { return }
            self.showToast("\(app.localizedName ?? "That app") hasn't been added to Avadhāna")
            // Go back to what you were doing rather than jumping to the home screen.
            if let previous = self.lastAllowedApp, !previous.isTerminated, previous.processIdentifier != app.processIdentifier {
                previous.unhide()
                previous.activate()
            } else {
                self.goHome()
            }
        }
        guardian.onAllowedActivated = { [weak self] app in
            guard let self else { return }
            self.lastAllowedApp = app
            self.launching = nil
            self.currentAppName = app.localizedName ?? "App"
            self.guardian.hideOthers(except: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.windows.enforce(app) }
        }
        guardian.onHomeActivated = { [weak self] in
            guard let self else { return }
            self.currentAppName = (NSApp.keyWindow as? WebWindow)?.tile.name
        }

        keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.inSession else { return }
                if let w = note.object as? WebWindow { self.currentAppName = w.tile.name }
                else if (note.object as? NSWindow) === self.sessionWindow { self.currentAppName = nil }
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleLocalKey(event) ?? false }
            return consumed ? nil : event
        }
        keyTap.handler = { [weak self] code, flags in
            MainActor.assumeIsolated { self?.handleGlobalKey(code, flags) ?? false }
        }

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if inSession { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if inSession { goHome() } else { setupWindow.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Quitting while Avadhāna is on asks the same Stay / Exit question as "Exit Avadhāna".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard inSession else { return .terminateNow }
        if Self.isSystemQuit() {
            endSession()
            return .terminateNow
        }
        quitAfterEnd = true
        requestEndSession()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ticker?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyTap.stop()
        hotKeys.unregisterAll()
        tweaks.restoreIfNeeded()
    }

    /// True when macOS is quitting apps for a logout, restart or shutdown.
    private static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        endRecording()
        // Closing Settings during a session returns to the home screen with the keyboard ready.
        if inSession { DispatchQueue.main.async { self.goHome() } }
    }

    // MARK: - Config & settings

    private func makeBrowser(_ kind: BrowserKind) -> SiteBrowser {
        if let external = ExternalBrowser(kind: kind) { return external }
        return WebKitBrowser(controller: self)
    }

    private func applyConfig(old: Config) {
        if config.effectiveBrowser != browser.kind {
            browser.closeAll()
            browser = makeBrowser(config.effectiveBrowser)
            if inSession {
                do { try browser.prepare() } catch { showToast("Couldn't prepare \(browser.kind.displayName): \(error.localizedDescription)") }
            }
        }
        selection = min(selection, max(0, filteredTiles.count - 1))
        guard inSession else { return }
        guardian.updateAllowed(Set(config.apps.map(\.bundleID)))
        if config.shortcuts != old.shortcuts { registerHotKeys(); updateKeyTap() }
        if config.hideDockDuringSession != old.hideDockDuringSession {
            if config.hideDockDuringSession { tweaks.hideDock() } else { tweaks.restoreIfNeeded() }
        }
    }

    func reloadConfig() {
        let (cfg, err) = Config.load()
        configError = err
        if err != nil {
            saveConfig()   // the unreadable file was set aside; write the settings in use back out
        } else if cfg != config {
            config = cfg
        }
    }

    private func saveConfig() {
        do {
            try config.save()
        } catch {
            configError = "Settings couldn't be saved: \(error.localizedDescription)"
        }
    }

    func moveTile(_ id: String, to target: String) {
        config.moveTile(id, to: target)
    }

    enum TileMove { case start, earlier, later, end }

    func moveTile(_ id: String, _ move: TileMove) {
        guard let i = config.tiles.firstIndex(where: { $0.id == id }) else { return }
        switch move {
        case .start: config.moveTile(id, toIndex: 0)
        case .earlier: config.moveTile(id, toIndex: i - 1)
        case .later: config.moveTile(id, toIndex: i + 1)
        case .end: config.moveTile(id, toIndex: config.tiles.count)
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Settings"
            w.backgroundColor = Theme.nsPaper
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(self))
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([Config.fileURL])
    }

    func requestAccessibility() {
        _ = AX.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Session

    func startSession() {
        reloadConfig()
        browser.closeAll()   // preview windows reopen chromeless inside the session
        if !config.sites.isEmpty {
            do { try browser.prepare() } catch {
                configError = "Couldn't prepare \(browser.kind.displayName): \(error.localizedDescription)"
                return
            }
        }
        if config.hideDockDuringSession { tweaks.hideDock() }

        inSession = true
        query = ""
        selection = 0
        guardian.updateAllowed(Set(config.apps.map(\.bundleID)))
        guardian.start()
        registerHotKeys()
        updateKeyTap()

        setupWindow.orderOut(nil)
        guard let screen = NSScreen.screens.first else { return }   // the main display
        let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SessionHomeView().environmentObject(self))
        w.setFrame(screen.frame, display: true)
        sessionWindow = w

        let bar = HomeBar(controller: self)
        bar.orderFrontRegardless()
        homeBar = bar
        goHome()
    }

    func goHome() {
        guard inSession else { return }
        lastAllowedApp = nil
        currentAppName = nil
        NSApp.activate()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        sessionWindow?.makeKeyAndOrderFront(nil)
        focusSearch()
    }

    /// Back: the previous page in a site, otherwise the home screen.
    func goBack() {
        guard inSession else { return }
        if NSApp.isActive {
            if let w = NSApp.keyWindow as? WebWindow {
                if !w.goBack() { goHome() }
            } else if NSApp.keyWindow !== sessionWindow {
                goHome()
            }
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication, browser.isFocusProcess(front) {
            browser.goBack(in: front)
        } else {
            goHome()
        }
    }

    func webWindowShown(_ w: WebWindow) {
        launching = nil
        guard inSession else { return }
        lastAllowedApp = nil
        currentAppName = w.tile.name
        guardian.hideOthers(except: nil)
    }

    /// Asks "Exit Avadhāna?" with two equal choices. Nothing happens until one is chosen.
    func requestEndSession() {
        guard inSession, !confirmingExit else { return }
        goHome()
        confirmingExit = true
    }

    func cancelEnd() {
        confirmingExit = false
        quitAfterEnd = false
        focusSearch()
    }

    func endNow() {
        confirmingExit = false
        endSession()
        if quitAfterEnd { NSApp.terminate(nil) }
    }

    private func endSession() {
        guard inSession else { return }
        inSession = false
        launching = nil
        hotKeys.unregisterAll()
        registeredHotKeys = []
        keyTap.stop()
        guardian.stop()
        browser.closeAll()
        tweaks.restoreIfNeeded()
        NSApp.presentationOptions = []
        homeBar?.close(); homeBar = nil
        sessionWindow?.close(); sessionWindow = nil
        setupWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - Tiles

    /// Tiles matching the search box; names starting with the query come first.
    var filteredTiles: [Tile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return config.tiles }
        let matches = config.tiles.filter { $0.name.lowercased().contains(q) }
        return matches.filter { $0.name.lowercased().hasPrefix(q) } + matches.filter { !$0.name.lowercased().hasPrefix(q) }
    }

    func open(_ tile: Tile) {
        // Show a spinner until the app or site is in front (or give up after 20 seconds).
        launching = tile
        launchToken += 1
        let token = launchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.launchToken == token, self.launching != nil else { return }
            self.launching = nil
            self.showToast("\(tile.name) didn't open")
        }
        switch tile {
        case .app(let a): openApp(a)
        case .site(let s):
            browser.open(s) { [weak self] err in
                guard let self else { return }
                if self.launchToken == token { self.launching = nil }
                if let err { self.showToast(err) }
            }
        }
    }

    private func openApp(_ tile: AppTile) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tile.bundleID) else {
            launching = nil
            showToast("\(tile.name) isn't installed"); return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: tile.bundleID).forEach { $0.unhide() }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.launching = nil
                    self?.showToast("Couldn't open \(tile.name): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Keyboard

    /// Reported by the home screen so arrow and page keys know the grid's shape.
    func updateMetrics(columns: Int, height: CGFloat) {
        gridColumns = max(1, columns)
        visibleHeight = height
    }

    private var pageStep: Int {
        switch config.layout {
        case .grid: return max(1, Int(visibleHeight / (GridLayout.tileSize + GridLayout.spacing))) * gridColumns
        case .rows: return max(1, Int(visibleHeight / RowLayout.pitch))
        }
    }

    func focusSearch() {
        focusToken += 1
        // Focusing a text field selects its contents; put the cursor at the end so typing appends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            if let tv = self?.sessionWindow?.firstResponder as? NSTextView {
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    /// Shortcuts that apply while Avadhāna itself is in front, then home screen keys.
    private func handleLocalKey(_ e: NSEvent) -> Bool {
        if let action = recordingAction { return record(e, for: action) }
        func hit(_ a: ShortcutAction) -> Bool {
            let s = config.shortcut(a)
            return s.enabled && s.combo.matches(keyCode: e.keyCode, flags: e.modifierFlags)
        }
        if hit(.settings) { openSettings(); return true }
        let onTileScreen = NSApp.keyWindow === sessionWindow || NSApp.keyWindow === setupWindow
        if onTileScreen && hit(.gridLayout) { config.layout = .grid; return true }
        if onTileScreen && hit(.rowsLayout) { config.layout = .rows; return true }
        // Home/Back are normally caught system-wide (hot keys, or the tap for "ignore while typing");
        // inside Avadhāna's own windows this covers any that aren't.
        if inSession {
            for action in [ShortcutAction.home, .back] where hit(action) && !registeredHotKeys.contains(action) {
                if config.shortcut(action).ignoreWhileTyping && (keyTap.isRunning || isTypingInFront()) { continue }
                action == .home ? goHome() : goBack()
                return true
            }
        }
        return handleHomeKey(e)
    }

    /// Home screen keys. Returns true if the key was consumed.
    private func handleHomeKey(_ e: NSEvent) -> Bool {
        guard inSession, let w = sessionWindow, NSApp.keyWindow === w else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])

        if confirmingExit {
            guard mods.isEmpty else { return false }
            if e.keyCode == 53 { cancelEnd() }                        // Esc: stay
            if e.keyCode == 36 || e.keyCode == 76 { endNow() }        // Return: exit
            return true
        }
        guard mods.isEmpty else { return false }

        let count = filteredTiles.count
        let rowStep = config.layout == .grid ? gridColumns : 1
        let typingInSearch = w.firstResponder is NSTextView
        func move(_ d: Int) {
            guard count > 0 else { return }
            selection = min(max(selection + d, 0), count - 1)
        }

        switch e.keyCode {
        case 123: move(-1)                     // ←
        case 124: move(1)                      // →
        case 125: move(rowStep)                // ↓
        case 126: move(-rowStep)               // ↑
        case 116: move(-pageStep)              // Page Up
        case 121: move(pageStep)               // Page Down
        case 115: move(-count)                 // Home
        case 119: move(count)                  // End
        case 36, 76:                           // Return, Enter
            let tiles = filteredTiles
            if tiles.indices.contains(selection) { open(tiles[selection]) }
        case 53:                               // Esc
            query = ""
            focusSearch()
        case 51 where !typingInSearch:         // Delete, when the search box isn't focused
            if !query.isEmpty { query.removeLast() }
            focusSearch()
        default:
            // Any printable key goes straight to the search box, wherever focus is.
            guard !typingInSearch, let chars = e.characters, Self.isPrintable(chars) else { return false }
            query += chars
            focusSearch()
        }
        return true
    }

    private static func isPrintable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    /// Registers Home and Back as system-wide hot keys for the session. Shortcuts with
    /// "ignore while typing" go through the keyboard tap instead, which can let a key through.
    private func registerHotKeys() {
        guard inSession, recordingAction == nil else { hotKeys.unregisterAll(); registeredHotKeys = []; return }
        let actions = [ShortcutAction.home, .back].filter {
            let s = config.shortcut($0)
            return s.enabled && !s.ignoreWhileTyping
        }
        let failed = hotKeys.register(actions.map { action in
            (config.shortcut(action).combo, { [weak self] in
                action == .home ? self?.goHome() : self?.goBack()
            })
        })
        let failedActions = Set(actions.filter { failed.contains(config.shortcut($0).combo) })
        registeredHotKeys = Set(actions).subtracting(failedActions)
        if failedActions != unavailableShortcuts { unavailableShortcuts = failedActions }
    }

    /// The keyboard tap handles only shortcuts set to "ignore while typing" (it needs Accessibility).
    private func handleGlobalKey(_ code: CGKeyCode, _ cgFlags: CGEventFlags) -> Bool {
        guard inSession, recordingAction == nil else { return false }
        var flags: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskCommand) { flags.insert(.command) }
        if cgFlags.contains(.maskControl) { flags.insert(.control) }
        if cgFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgFlags.contains(.maskShift) { flags.insert(.shift) }

        for action in [ShortcutAction.home, .back] {
            let s = config.shortcut(action)
            guard s.enabled, s.ignoreWhileTyping, s.combo.matches(keyCode: UInt16(code), flags: flags) else { continue }
            if isTypingInFront() { return false }
            DispatchQueue.main.async { action == .home ? self.goHome() : self.goBack() }
            return true
        }
        return false
    }

    // MARK: Recording shortcuts (Settings)

    func beginRecording(_ action: ShortcutAction) {
        recordingAction = action
        hotKeys.unregisterAll()   // so the keys being recorded aren't swallowed by an existing hot key
        registeredHotKeys = []
    }

    func endRecording() {
        guard recordingAction != nil else { return }
        recordingAction = nil
        registerHotKeys()
    }

    /// Plain Esc cancels. Requires ⌘, ⌃ or ⌥ (or a function key) so ordinary typing can't trigger it.
    private func record(_ e: NSEvent, for action: ShortcutAction) -> Bool {
        let mods = e.modifierFlags.intersection(KeyCombo.relevant)
        if e.keyCode == 53 && mods.isEmpty { endRecording(); return true }
        guard !mods.subtracting(.shift).isEmpty || KeyCombo.functionKeys.contains(e.keyCode) else {
            NSSound.beep()
            return true
        }
        updateShortcut(action) { $0.combo = KeyCombo(event: e); $0.enabled = true }
        endRecording()
        return true
    }

    func updateShortcut(_ action: ShortcutAction, _ change: (inout ShortcutSetting) -> Void) {
        var s = config.shortcut(action)
        change(&s)
        config.shortcuts[action.rawValue] = s
    }

    func resetShortcut(_ action: ShortcutAction) {
        config.shortcuts[action.rawValue] = nil
    }

    private func isTypingInFront() -> Bool {
        if NSApp.isActive {
            if let w = NSApp.keyWindow as? WebWindow { return w.isEditingText }
            return NSApp.keyWindow?.firstResponder is NSTextView
        }
        return AX.focusedElementIsEditable()
    }

    // MARK: - Helpers

    func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// The keyboard tap is only needed for Home/Back shortcuts set to "ignore while typing", and only
    /// while Avadhāna is on. Otherwise it isn't running at all.
    private var needsKeyTap: Bool {
        inSession && [ShortcutAction.home, .back].contains {
            let s = config.shortcut($0)
            return s.enabled && s.ignoreWhileTyping
        }
    }

    private func updateKeyTap() {
        guard needsKeyTap else { keyTap.stop(); return }
        if !keyTap.isRunning && !keyTap.start() {
            NSLog("Avadhana: keyboard tap unavailable until Accessibility access is granted")
        }
    }

    private func tick() {
        let trusted = AX.isTrusted(prompt: false)
        if trusted != axTrusted { axTrusted = trusted }
        if trusted && needsKeyTap && !keyTap.isRunning { updateKeyTap() }   // permission granted later
        guard inSession else { return }
        guardian.sweep()

        homeBar?.reposition()
        if let screen = NSScreen.screens.first, sessionWindow?.frame != screen.frame {
            sessionWindow?.setFrame(screen.frame, display: true)
        }
        if NSApp.isActive {
            (browser as? WebKitBrowser)?.relayout(to: windows.cocoaTargetFrame())
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  guardian.verdict(for: front) == .allowed,
                  !AppGuard.systemAllowed.contains(front.bundleIdentifier ?? "") {
            windows.enforce(front)
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Shortcuts are user-configurable and handled in handleLocalKey, so menu items carry none.
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Avadhāna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Grid", action: #selector(showGrid), keyEquivalent: "").target = self
        view.addItem(withTitle: "Rows", action: #selector(showRows), keyEquivalent: "").target = self
        viewItem.submenu = view
        main.addItem(viewItem)

        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func showGrid() { config.layout = .grid }
    @objc private func showRows() { config.layout = .rows }
}
