import AppKit
import Darwin

/// Rules for web links while Avadhāna is on: links from your apps and links clicked in your sites
/// open one page at a time, without an address bar. Everything else stays closed.
enum Links {
    /// The app bundle an executable belongs to, so helper processes count as their app:
    /// ".../Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper" → ".../Slack.app".
    static func appBundlePath(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// The app that sent a link: the sending process's app, or the nearest app among its parents
    /// (for links opened by a helper, or by `open` in a terminal).
    static func sendingApp(pid: pid_t) -> (bundleID: String, name: String)? {
        var current = pid
        for _ in 0..<16 where current > 1 {
            if let path = executablePath(pid: current), let appPath = appBundlePath(forExecutable: path),
               let id = Bundle(path: appPath)?.bundleIdentifier {
                var name = FileManager.default.displayName(atPath: appPath)
                if name.hasSuffix(".app") { name.removeLast(4) }
                return (id, name)
            }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
        }
        return nil
    }

    /// Links may come from Avadhāna itself or from an added app (including its helpers).
    static func isAllowedSender(_ bundleID: String, allowedApps: Set<String>, own: String) -> Bool {
        bundleID == own || allowedApps.contains(bundleID) || allowedApps.contains { bundleID.hasPrefix($0 + ".") }
    }

    /// The site a host belongs to, so a link can move between that site's pages:
    /// "docs.github.com" → "github.com", "www.bbc.co.uk" → "bbc.co.uk".
    static func siteDomain(of host: String) -> String {
        let host = host.lowercased()
        let labels = host.split(separator: ".").map(String.init)
        let isIPAddress = host.contains(":") || labels.allSatisfy { Int($0) != nil }
        guard labels.count > 2, !isIPAddress else { return host }
        // Country domains that register names one level down, like co.uk, com.au and ac.jp.
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]
        let n = labels.count
        let keep = labels[n - 1].count == 2 && secondLevel.contains(labels[n - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    static func host(_ host: String, isWithin domain: String) -> Bool {
        let host = host.lowercased(), domain = domain.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    enum SiteNavigation: Equatable { case allow, openAsLink, block }

    /// A page in one of your sites: its allowed domains load in place. A clicked link to anywhere
    /// else opens on its own when links are on; other navigation away is blocked.
    static func siteNavigation(_ site: SiteTile, to host: String, isLinkClick: Bool, openLinks: Bool) -> SiteNavigation {
        // With no domains listed, a web site may stay on its own host.
        if site.allows(host: host) || (site.allowedDomains.isEmpty && host.lowercased() == site.startHost) {
            return .allow
        }
        return isLinkClick && openLinks ? .openAsLink : .block
    }

    enum LinkNavigation: Equatable { case allow, allowAndFollow, block }

    /// A page opened from a link stays on that page's site. Redirects are followed until the first
    /// page has loaded (link shorteners and "you're leaving" pages). Clicks to other sites are blocked.
    static func linkNavigation(to host: String, site: String?, isUserAction: Bool, onFirstPage: Bool,
                               isBackForward: Bool) -> LinkNavigation {
        if isBackForward { return .allow }
        guard let site else { return .allowAndFollow }
        if Links.host(host, isWithin: site) { return .allow }
        return !isUserAction && onFirstPage ? .allowAndFollow : .block
    }

    // MARK: Process info

    private static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Avadhāna receives web links by being the default web browser. While Avadhāna is off it passes
/// every link straight on to your everyday browser.
@MainActor
enum LinkHandler {
    private static let probe = URL(string: "https://example.com")!

    static var ownBundleID: String { Bundle.main.bundleIdentifier ?? "com.riverma.avadhana" }

    /// The app that currently opens web links.
    static var currentHandler: URL? { NSWorkspace.shared.urlForApplication(toOpen: probe) }

    static var isAvadhana: Bool {
        currentHandler.flatMap { Bundle(url: $0)?.bundleIdentifier } == ownBundleID
    }

    /// Browsers that can open web links, other than Avadhāna, one per bundle ID.
    static var browsers: [(bundleID: String, name: String, url: URL)] {
        var seen: Set<String> = [ownBundleID]
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            return (id, name, url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func appURL(bundleID: String?) -> URL {
        if let bundleID, bundleID != ownBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        return URL(fileURLWithPath: "/Applications/Safari.app")
    }

    /// Makes an app the default web browser. macOS asks you to confirm.
    static func makeDefault(_ appURL: URL, completion: @escaping @MainActor (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
            DispatchQueue.main.async {
                guard error == nil else { completion(error); return }
                // macOS normally sets both together; set https too if it didn't.
                let httpsHandler = NSWorkspace.shared.urlForApplication(toOpen: probe)
                if httpsHandler.flatMap({ Bundle(url: $0)?.bundleIdentifier }) == Bundle(url: appURL)?.bundleIdentifier {
                    completion(nil)
                } else {
                    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
                        DispatchQueue.main.async { completion(error) }
                    }
                }
            }
        }
    }

    /// Opens links in your everyday browser, never in Avadhāna.
    static func forward(_ urls: [URL], to bundleID: String?) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL(bundleID: bundleID),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

extension SiteTile {
    /// A page opened from a link, named after its site (or file).
    static func link(to url: URL) -> SiteTile {
        let name = url.isFileURL ? url.lastPathComponent : Links.siteDomain(of: url.host ?? url.absoluteString)
        return SiteTile(name: name, url: url.absoluteString, allowedDomains: [])
    }
}
