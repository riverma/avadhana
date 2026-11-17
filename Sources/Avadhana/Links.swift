import Foundation

/// Rules for web links while Avadhāna is on: links from your apps and links clicked in your sites
/// open one page at a time, without an address bar, and stay on that page's site.
enum Links {
    /// What a browser window shows: the address in its address bar, and its number of tabs (nil
    /// when the browser doesn't report tabs, as with Safari).
    struct WindowState: Equatable {
        var address: String?
        var tabs: Int?
    }

    /// Whether a browser that just came forward shows a page that wasn't there before: a new window,
    /// a new tab, or (when tabs aren't reported) a different address. A browser opened during the
    /// session shows only new pages.
    static func isNewPage(_ now: WindowState, comparedTo before: WindowState?, launched: Bool) -> Bool {
        guard now.address?.isEmpty == false else { return false }   // nothing loaded yet
        guard let before, !launched else { return true }
        if let tabs = now.tabs, let earlier = before.tabs { return tabs > earlier }
        return now.address != before.address
    }

    /// A web address from a browser's address bar, which often leaves out "https://".
    /// Search text and other kinds of addresses give nil.
    static func webURL(fromAddress text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        let lower = t.lowercased()
        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = t
        } else if t.contains("://") || t.hasPrefix("about:") || !t.contains(".") {
            return nil
        } else {
            candidate = "https://" + t
        }
        guard let url = URL(string: candidate), url.host?.contains(".") == true else { return nil }
        return url
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
}

extension SiteTile {
    /// A page opened from a link, named after its site (or file).
    static func link(to url: URL) -> SiteTile {
        let name = url.isFileURL ? url.lastPathComponent : Links.siteDomain(of: url.host ?? url.absoluteString)
        return SiteTile(name: name, url: url.absoluteString, allowedDomains: [])
    }
}
