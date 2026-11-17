import AppKit
@preconcurrency import ApplicationServices

/// Moves web links from your apps into Avadhāna. While Avadhāna is on, a link clicked in one of your
/// apps still goes to your usual browser; when that browser comes forward with a new page, the page
/// is read (with Accessibility access), its tab is closed, and it opens in Avadhāna instead.
/// Your default browser is never changed.
@MainActor
final class LinkCatcher {
    /// What a browser window was showing when Avadhāna last looked.
    private struct Known {
        let window: AXUIElement
        let state: Links.WindowState
    }

    private var browserIDs: Set<String> = []
    private var known: [pid_t: [Known]] = [:]
    private var timer: Timer?

    /// Apps that open web links, other than Avadhāna.
    func start() {
        let probe = URL(string: "https://example.com")!
        browserIDs = Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { Bundle(url: $0)?.bundleIdentifier })
        browserIDs.remove(Bundle.main.bundleIdentifier ?? "")
        known = [:]
        for app in NSWorkspace.shared.runningApplications where isBrowser(app) { remember(app) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        known = [:]
    }

    func isBrowser(_ app: NSRunningApplication) -> Bool {
        browserIDs.contains(app.bundleIdentifier ?? "")
    }

    /// Notes what each of the browser's windows shows, so a new page can be told apart from yours.
    func remember(_ app: NSRunningApplication) {
        known[app.processIdentifier] = AX.windows(pid: app.processIdentifier).map {
            Known(window: $0, state: AX.browserPage(in: $0).state)
        }
    }

    /// Keeps notes current for hidden browsers (pages can change on their own). A browser that has
    /// just been unhidden to show a link is left alone, so the link isn't mistaken for your page.
    func refresh(skipping busy: Set<pid_t>) {
        for app in NSWorkspace.shared.runningApplications
        where isBrowser(app) && app.isHidden && !app.isTerminated && !busy.contains(app.processIdentifier) {
            remember(app)
        }
        known = known.filter { pid, _ in NSRunningApplication(processIdentifier: pid) != nil }
    }

    /// Waits briefly for a new page in a browser that just came forward. If one appears, closes its
    /// tab and returns its address. `launched` means the browser was opened during the session, so
    /// any page it shows is new.
    func catchLink(in app: NSRunningApplication, launched: Bool, completion: @escaping (URL?) -> Void) {
        timer?.invalidate()
        let pid = app.processIdentifier
        let before = known[pid] ?? []
        let deadline = Date().addingTimeInterval(launched ? 6 : 1.5)
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if app.isTerminated || Date() > deadline {
                    t.invalidate()
                    completion(nil)
                    return
                }
                guard let window = AX.focusedWindow(pid: pid) ?? AX.windows(pid: pid).first else { return }
                let page = AX.browserPage(in: window)
                let prior = before.first { CFEqual($0.window, window) }?.state
                guard Links.isNewPage(page.state, comparedTo: prior, launched: launched),
                      let url = page.url ?? page.state.address.flatMap(Links.webURL(fromAddress:)) else { return }
                t.invalidate()
                Self.closeFrontTab(of: app)
                // Let the tab close while the browser is still in front, then take over.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.remember(app)
                    completion(url)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// ⌘W, sent while the browser is in front (Safari and Chrome ignore it once hidden).
    private static func closeFrontTab(of app: NSRunningApplication) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(app.processIdentifier)
        }
    }
}

extension AX {
    /// The page a browser window shows: its address (from the page itself when exposed, otherwise
    /// the address bar) and how many tabs the window has, where the browser reports that.
    static func browserPage(in window: AXUIElement) -> (url: URL?, state: Links.WindowState) {
        AXUIElementSetMessagingTimeout(window, 0.2)
        var url: URL?, address: String?, tabs: Int?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 1500 && (url == nil || address == nil || tabs == nil) {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            switch role {
            case "AXWebArea":
                if url == nil, let u = copy(el, "AXURL") { url = (u as? URL) ?? (u as? String).flatMap(URL.init(string:)) }
                continue   // the page's own contents aren't needed
            case kAXTextFieldRole, kAXComboBoxRole:
                let label = (string(el, kAXDescriptionAttribute) ?? "").lowercased()
                if address == nil, label.contains("address") || label.contains("search") {
                    address = string(el, kAXValueAttribute)
                }
            case kAXTabGroupRole:
                if tabs == nil {
                    let n = countTabs(in: el, depth: 0)
                    tabs = n > 0 ? n : nil
                }
            default:
                break
            }
            if depth < 14, let kids = copy(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue += kids.map { ($0, depth + 1) }
            }
        }
        if let u = url, !["http", "https"].contains(u.scheme?.lowercased() ?? "") { url = nil }
        return (url, Links.WindowState(address: address, tabs: tabs))
    }

    private static func countTabs(in el: AXUIElement, depth: Int) -> Int {
        let kids = copy(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return kids.reduce(0) { n, kid in
            n + (string(kid, kAXRoleAttribute) == kAXRadioButtonRole ? 1 : depth < 2 ? countTabs(in: kid, depth: depth + 1) : 0)
        }
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }
}
