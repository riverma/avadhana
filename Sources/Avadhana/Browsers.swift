@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import WebKit

/// Opens site tiles without browser chrome. One implementation per supported browser.
@MainActor
protocol SiteBrowser: AnyObject {
    var kind: BrowserKind { get }
    /// Bundle ID of the external app that shows sites, or nil when sites open inside Avadhāna.
    var externalBundleID: String? { get }
    func prepare() throws
    func open(_ tile: SiteTile, completion: @escaping (String?) -> Void)
    /// Opens a web link (from one of your apps or sites) on its own, without an address bar.
    func openLink(_ url: URL, completion: @escaping (String?) -> Void)
    /// True for processes belonging to the dedicated focus instance (not the user's normal browser).
    func isFocusProcess(_ app: NSRunningApplication) -> Bool
    /// Browser "back" in the frontmost external window.
    func goBack(in app: NSRunningApplication)
    func closeAll()
}

// MARK: - Firefox & Chrome: a dedicated profile launched with chrome hidden

@MainActor
final class ExternalBrowser: SiteBrowser {
    let kind: BrowserKind
    let appURL: URL
    let profileDir: URL
    private var tileWindows: [String: AXUIElement] = [:]
    private var pollTimer: Timer?
    private var pendingCompletion: ((String?) -> Void)?

    init?(kind: BrowserKind) {
        guard kind != .safari, let url = kind.appURL else { return nil }
        self.kind = kind
        appURL = url
        profileDir = Config.supportDir.appendingPathComponent(kind == .firefox ? "FirefoxProfile" : "ChromeProfile",
                                                              isDirectory: true)
    }

    var externalBundleID: String? { kind.bundleID }
    private var binary: URL? { Bundle(url: appURL)?.executableURL }

    func prepare() throws {
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        guard kind == .firefox else { return }
        let chrome = profileDir.appendingPathComponent("chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try Self.firefoxUserJS.write(to: profileDir.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)
        try Self.firefoxUserChrome.write(to: chrome.appendingPathComponent("userChrome.css"), atomically: true, encoding: .utf8)
    }

    /// `url` is always a validated http(s) URL, so it can't be read as a command-line option.
    private func args(for url: String) -> [String] {
        switch kind {
        case .firefox:
            return ["-profile", profileDir.path, "-new-window", url]
        case .chrome:
            return ["--user-data-dir=\(profileDir.path)", "--no-first-run", "--no-default-browser-check", "--app=\(url)"]
        case .safari:
            return []
        }
    }

    func isFocusProcess(_ app: NSRunningApplication) -> Bool {
        processArguments(pid: app.processIdentifier).contains { $0.contains(profileDir.path) }
    }

    private func focusApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID)
            .filter { !$0.isTerminated && isFocusProcess($0) }
            .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
    }

    func open(_ tile: SiteTile, completion: @escaping (String?) -> Void) {
        guard let url = tile.validatedURL?.absoluteString else { completion("\(tile.name) doesn't have a valid web address"); return }
        guard let binary else { completion("\(kind.displayName) couldn't be found"); return }
        do { try prepare() } catch { completion("Couldn't set up the \(kind.displayName) profile: \(error.localizedDescription)"); return }

        if let app = focusApp() {
            app.unhide()
            if let w = tileWindows[tile.id], AX.isAlive(w) {
                AX.raise(w)
                app.activate()
                completion(nil)
                return
            }
            let before = AX.windows(pid: app.processIdentifier)
            // A second invocation with the same profile is forwarded to the running instance.
            run(binary, args(for: url))
            waitForNewWindow(tile: tile, before: before, completion: completion)
        } else {
            // Through LaunchServices so the browser is its own "responsible" app (its own camera/mic prompts).
            run(URL(fileURLWithPath: "/usr/bin/open"), ["-n", "-a", appURL.path, "--args"] + args(for: url))
            waitForNewWindow(tile: tile, before: [], completion: completion)
        }
    }

    func openLink(_ url: URL, completion: @escaping (String?) -> Void) {
        open(.link(to: url), completion: completion)
    }

    func goBack(in app: NSRunningApplication) {
        // ⌘[ is "Back" in both Firefox and Chrome.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 33, keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(app.processIdentifier)
        }
    }

    func closeAll() {}   // the dedicated instance is left running; it's harmless once Avadhāna exits

    private func waitForNewWindow(tile: SiteTile, before: [AXUIElement], completion: @escaping (String?) -> Void) {
        pollTimer?.invalidate()
        pendingCompletion?(nil)   // a newer request replaces the earlier one
        pendingCompletion = completion
        let completion: (String?) -> Void = { [weak self] result in
            self?.pendingCompletion = nil
            completion(result)
        }
        let deadline = Date().addingTimeInterval(20)
        let trusted = AX.isTrusted(prompt: false)
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if let app = self.focusApp() {
                    if !trusted {   // can't track windows without Accessibility; just bring it forward
                        t.invalidate(); app.activate(); completion(nil); return
                    }
                    let current = AX.windows(pid: app.processIdentifier).filter(AX.isStandardWindow)
                    if let w = current.first(where: { c in !before.contains { CFEqual($0, c) } }) {
                        t.invalidate()
                        self.tileWindows[tile.id] = w
                        AX.raise(w)
                        app.activate()
                        completion(nil)
                        return
                    }
                }
                if Date() > deadline { t.invalidate(); completion("\(self.kind.displayName) didn't open a window in time") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func run(_ exe: URL, _ args: [String]) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("Avadhana: failed to run \(exe.path): \(error)") }
    }

    static let firefoxUserJS = """
    // Managed by Avadhāna: rewritten every time a site opens. Edits here will be lost.
    user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

    // No start page, welcome tour, default-browser nag or privacy-notice tab.
    user_pref("browser.startup.page", 0);
    user_pref("browser.startup.homepage", "about:blank");
    user_pref("browser.startup.homepage_override.mstone", "ignore");
    user_pref("startup.homepage_welcome_url", "");
    user_pref("startup.homepage_welcome_url.additional", "");
    user_pref("browser.aboutwelcome.enabled", false);
    user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
    user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
    user_pref("browser.shell.checkDefaultBrowser", false);
    user_pref("browser.sessionstore.resume_from_crash", false);

    // Nothing to browse to: no new-tab page, no searching from typed text, no suggestions.
    user_pref("browser.newtabpage.enabled", false);
    user_pref("browser.newtab.preload", false);
    user_pref("keyword.enabled", false);
    user_pref("browser.search.suggest.enabled", false);
    user_pref("browser.urlbar.suggest.searches", false);
    user_pref("browser.urlbar.suggest.topsites", false);
    user_pref("extensions.pocket.enabled", false);

    // Tabs are hidden, so links that would open a new tab open in the current one instead.
    user_pref("browser.link.open_newwindow", 1);
    user_pref("browser.tabs.closeWindowWithLastTab", true);
    user_pref("browser.tabs.warnOnClose", false);
    user_pref("browser.warnOnQuitShortcut", false);
    user_pref("browser.toolbars.bookmarks.visibility", "never");
    user_pref("sidebar.revamp", false);
    user_pref("sidebar.verticalTabs", false);
    """

    static let firefoxUserChrome = """
    /* Managed by Avadhāna: hides all browser chrome so only the page shows. */
    #titlebar, #TabsToolbar, #nav-bar, #PersonalToolbar,
    #sidebar-main, #sidebar-box, #sidebar-splitter {
      visibility: collapse !important;
    }
    """
}

// MARK: - Safari: Avadhāna's own WebKit windows

@MainActor
final class WebKitBrowser: SiteBrowser {
    let kind = BrowserKind.safari
    var externalBundleID: String? { nil }
    weak var controller: AppController?
    private var windows: [String: WebWindow] = [:]
    /// The page opened from the latest link. Each new link replaces it.
    private var linkWindow: WebWindow?

    init(controller: AppController) {
        self.controller = controller
    }

    func prepare() throws {}
    func isFocusProcess(_ app: NSRunningApplication) -> Bool { false }   // our own windows
    func goBack(in app: NSRunningApplication) {}

    func open(_ tile: SiteTile, completion: @escaping (String?) -> Void) {
        guard let c = controller, let url = tile.validatedURL else { completion("\(tile.name) doesn't have a valid web address"); return }
        if let w = windows[tile.id] {
            show(w)
            completion(nil)
            return
        }
        let w = makeWindow(tile: tile, url: url, isLink: false, controller: c)
        w.onClose = { [weak self] in self?.windows[tile.id] = nil }
        windows[tile.id] = w
        show(w)
        completion(nil)
    }

    func openLink(_ url: URL, completion: @escaping (String?) -> Void) {
        guard let c = controller else { completion("The link couldn't be opened"); return }
        linkWindow?.close()
        let w = makeWindow(tile: .link(to: url), url: url, isLink: true, controller: c)
        w.onClose = { [weak self, weak w] in
            if let self, self.linkWindow === w { self.linkWindow = nil }
        }
        linkWindow = w
        show(w)
        completion(nil)
    }

    private func makeWindow(tile: SiteTile, url: URL, isLink: Bool, controller c: AppController) -> WebWindow {
        let chromeless = c.inSession
        let frame = chromeless ? c.windows.cocoaTargetFrame() : Self.previewFrame()
        let w = WebWindow(tile: tile, url: url, frame: frame, chromeless: chromeless, isLink: isLink)
        w.openLinks = { [weak c] in c?.config.openLinks ?? false }
        w.onBlockedNavigation = { [weak c] message in c?.showToast(message) }
        w.onOpenLink = { [weak c, weak w] link in c?.openLink(link, fromWindow: w) }
        w.onSiteChanged = { [weak c, weak w] in
            if let c, let w, c.inSession, NSApp.keyWindow === w { c.currentAppName = w.tile.name }
        }
        return w
    }

    private func show(_ w: WebWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        controller?.webWindowShown(w)
    }

    /// Keeps session windows filling the screen above the Home bar.
    func relayout(to frame: NSRect) {
        for w in windows.values + [linkWindow].compactMap({ $0 }) where w.chromeless && w.frame != frame {
            w.setFrame(frame, display: true)
        }
    }

    func closeAll() {
        let all = Array(windows.values) + [linkWindow].compactMap { $0 }
        windows = [:]
        linkWindow = nil
        all.forEach { $0.close() }
    }

    private static func previewFrame() -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: min(1200, vf.width - 80), height: min(850, vf.height - 80))
        return NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// A single site in a window with no address bar or tabs. Navigation is limited to the site's
/// allowed domains; sign-in popups open in a small window of their own.
/// A link window shows a page opened from a link, and stays on that page's site.
final class WebWindow: NSWindow, WKNavigationDelegate, WKUIDelegate {
    private(set) var tile: SiteTile
    let chromeless: Bool
    let isLink: Bool
    let webView: WKWebView
    var onClose: (() -> Void)?
    /// Shows a message when a page is kept from opening.
    var onBlockedNavigation: ((String) -> Void)?
    /// Whether a clicked link to another site may open on its own (Settings → General).
    var openLinks: () -> Bool = { false }
    var onOpenLink: ((URL) -> Void)?
    /// A link window followed a redirect to another site.
    var onSiteChanged: (() -> Void)?
    /// The site a link window stays on, set once its first page loads.
    private var linkSite: String?
    private var pagesLoaded = 0
    private var followNextPage = false
    /// Whether a text field or editable area has focus in the page, so a Back shortcut set to
    /// "ignore while typing" leaves the key alone.
    fileprivate(set) var isEditingText = false
    private var popups: [PopupWindow] = []
    private static let messageName = "avadhanaEditing"

    init(tile: SiteTile, url: URL, frame: NSRect, chromeless: Bool, isLink: Bool = false) {
        self.tile = tile
        self.chromeless = chromeless
        self.isLink = isLink

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Identify as Safari so sites (notably Google sign-in) don't treat this as an embedded browser.
        let safariVersion = BrowserKind.safari.appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "18.0"
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        // The focus script runs in an isolated JavaScript world, so pages can't see or call it.
        let proxy = EditingMessageProxy()
        config.userContentController.add(proxy, contentWorld: .defaultClient, name: Self.messageName)
        config.userContentController.addUserScript(WKUserScript(source: Self.focusScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false, in: .defaultClient))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        super.init(contentRect: frame,
                   styleMask: chromeless ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        proxy.window = self
        title = tile.name
        isReleasedWhenClosed = false
        contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if url.isFileURL {
            // A local page may read the files next to it (images, styles, other pages).
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        popups.forEach { $0.close() }
        popups = []
        super.close()
        onClose?()
        onClose = nil
    }

    /// Returns false when there's no earlier page.
    func goBack() -> Bool {
        guard webView.canGoBack else { return false }
        webView.goBack()
        return true
    }

    // MARK: Navigation policy (shared with sign-in popups)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Embedded content (iframes) may come from anywhere; only top-level pages are limited.
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            let type = navigationAction.navigationType
            if isLink {
                switch Links.linkNavigation(to: host, site: linkSite,
                                            isUserAction: [.linkActivated, .formSubmitted, .formResubmitted].contains(type),
                                            onFirstPage: pagesLoaded <= 1, isBackForward: type == .backForward) {
                case .allow:
                    decisionHandler(.allow)
                case .allowAndFollow:
                    followNextPage = true
                    decisionHandler(.allow)
                case .block:
                    decisionHandler(.cancel)
                    onBlockedNavigation?(blockedMessage(host))
                }
            } else {
                switch Links.siteNavigation(tile, to: host, isLinkClick: type == .linkActivated, openLinks: openLinks()) {
                case .allow:
                    decisionHandler(.allow)
                case .openAsLink:
                    decisionHandler(.cancel)
                    onOpenLink?(url)
                case .block:
                    decisionHandler(.cancel)
                    onBlockedNavigation?(blockedMessage(host))
                }
            }
        case "file":
            // A local page may open other files in its own folder, nothing else on disk.
            if let start = tile.validatedURL, start.isFileURL,
               url.standardizedFileURL.path.hasPrefix(start.deletingLastPathComponent().standardizedFileURL.path + "/") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        case "about":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)   // mailto:, app links and other schemes stay closed
        }
    }

    private func blockedMessage(_ host: String) -> String {
        isLink ? "\(host) isn't one of your sites" : "\(host) isn't one of \(tile.name)'s allowed sites"
    }

    /// A link window settles on the site of the first page it shows, or of a redirect it followed.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard isLink, webView === self.webView else { return }
        pagesLoaded += 1
        if followNextPage || linkSite == nil, let url = webView.url {
            // A page on this Mac has no site, so it can't lead anywhere on the web.
            linkSite = url.host.map(Links.siteDomain) ?? ""
            tile = .link(to: url)
            title = tile.name
            onSiteChanged?()
        }
        followNextPage = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()   // recover from a crashed page instead of showing a blank window
    }

    // MARK: New windows

    /// Sized popups (typically "Sign in with…") get their own window so they can talk back to the
    /// page that opened them. Other links that would open a new tab load here instead (tabs are hidden).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard windowFeatures.width != nil || windowFeatures.height != nil else {
            if navigationAction.targetFrame == nil { openHere(navigationAction, in: webView) }
            return nil
        }
        let size = NSSize(width: CGFloat(windowFeatures.width?.doubleValue ?? 520),
                          height: CGFloat(windowFeatures.height?.doubleValue ?? 680))
        let popup = PopupWindow(configuration: configuration, size: size, over: self)
        popup.webView.navigationDelegate = self
        popup.onClose = { [weak self, weak popup] in self?.popups.removeAll { $0 === popup } }
        popups.append(popup)
        popup.makeKeyAndOrderFront(nil)
        return popup.webView
    }

    /// A link that would open a new tab. The same rules apply as for a link clicked in the page.
    private func openHere(_ action: WKNavigationAction, in webView: WKWebView) {
        guard let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            webView.load(action.request)
            return
        }
        let host = url.host?.lowercased() ?? ""
        if isLink {
            if linkSite.map({ Links.host(host, isWithin: $0) }) ?? true {
                webView.load(action.request)
            } else {
                onBlockedNavigation?(blockedMessage(host))
            }
            return
        }
        switch Links.siteNavigation(tile, to: host, isLinkClick: action.navigationType == .linkActivated, openLinks: openLinks()) {
        case .allow: webView.load(action.request)
        case .openAsLink: onOpenLink?(url)
        case .block: onBlockedNavigation?(blockedMessage(host))
        }
    }

    // MARK: Page dialogs (titled with the site's host so a page can't pose as the system)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = Self.pageAlert(message, from: frame)
        a.beginSheetModal(for: self) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = Self.pageAlert(message, from: frame)
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: self) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    private static func pageAlert(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : frame.securityOrigin.host
        a.informativeText = message
        return a
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: self) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// Reports whether the focused element is editable. Iframes count as editable, so editors that
    /// live in iframes (e.g. Google Docs) keep their delete shortcuts.
    static let focusScript = """
    (function () {
      function editable(e) {
        if (!e) return false;
        if (e.isContentEditable || e.tagName === 'TEXTAREA' || e.tagName === 'SELECT' || e.tagName === 'IFRAME') return true;
        if (e.tagName === 'INPUT') {
          var t = (e.type || 'text').toLowerCase();
          return ['button','checkbox','radio','submit','reset','image','file','range','color'].indexOf(t) < 0;
        }
        return false;
      }
      function report() {
        try { window.webkit.messageHandlers.avadhanaEditing.postMessage(editable(document.activeElement)); } catch (_) {}
      }
      document.addEventListener('focusin', report, true);
      document.addEventListener('focusout', function () { setTimeout(report, 0); }, true);
    })();
    """

    fileprivate final class EditingMessageProxy: NSObject, WKScriptMessageHandler {
        weak var window: WebWindow?
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            window?.isEditingText = (message.body as? Bool) ?? false
        }
    }
}

/// A small titled window for a sign-in popup. Closes itself when the page calls window.close().
final class PopupWindow: NSWindow, WKUIDelegate {
    let webView: WKWebView
    var onClose: (() -> Void)?

    init(configuration: WKWebViewConfiguration, size: NSSize, over parent: NSWindow) {
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2)
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        contentView = webView
        webView.uiDelegate = self
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    func webViewDidClose(_ webView: WKWebView) { close() }
}
