import AppKit

/// A native Mac app allowed during a session.
struct AppTile: Codable, Hashable, Identifiable {
    var name: String
    var bundleID: String
    var id: String { "app:" + bundleID }
}

/// A website or local web page that opens without browser chrome in the chosen web browser.
struct SiteTile: Codable, Hashable, Identifiable {
    var name: String
    /// An http(s) address, or a file: URL for a page on this Mac.
    var url: String
    /// Domains the site may navigate to (subdomains included). Enforced in Safari mode.
    var allowedDomains: [String]
    var id: String { "site:" + url }

    /// Only http(s) addresses and existing local files are opened. Either way the URL starts with a
    /// scheme, so it can never be mistaken for a command-line option when passed to Firefox or Chrome.
    var validatedURL: URL? { Self.openableURL(url) }

    var isLocalFile: Bool { validatedURL?.isFileURL == true }

    static func openableURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        case "file":
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        default:
            return nil
        }
    }

    /// The web host this site starts on (nil for local files).
    var startHost: String? { validatedURL?.host?.lowercased() }

    func allows(host: String) -> Bool {
        let host = host.lowercased()
        return allowedDomains.contains { domain in
            let d = domain.lowercased()
            return host == d || host.hasSuffix("." + d)
        }
    }
}

enum Tile: Identifiable, Hashable {
    case app(AppTile)
    case site(SiteTile)

    var id: String {
        switch self {
        case .app(let a): return a.id
        case .site(let s): return s.id
        }
    }
    var name: String {
        switch self {
        case .app(let a): return a.name
        case .site(let s): return s.name
        }
    }
    var subtitle: String {
        switch self {
        case .app: return "App"
        case .site(let s):
            if s.isLocalFile, let file = s.validatedURL?.lastPathComponent { return file }
            return URL(string: s.url)?.host ?? s.url
        }
    }
}

enum Layout: String, Codable {
    case grid, rows
}

/// The browsers Avadhāna knows how to strip down. Others aren't offered because
/// there's no reliable way to hide their address bar and tabs.
enum BrowserKind: String, Codable, CaseIterable, Identifiable {
    case safari, firefox, chrome

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .chrome: return "Google Chrome"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .firefox: return "org.mozilla.firefox"
        case .chrome: return "com.google.Chrome"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }

    static var installed: [BrowserKind] { allCases.filter(\.isInstalled) }
}

struct Config: Codable, Equatable {
    var layout: Layout
    var hideDockDuringSession: Bool
    var browser: BrowserKind
    var apps: [AppTile]
    var sites: [SiteTile]
    /// Tile IDs in the order they appear on the home screen. Tiles missing here go at the end.
    var order: [String]
    /// Customized shortcuts, keyed by `ShortcutAction.rawValue`. Missing entries use the defaults.
    var shortcuts: [String: ShortcutSetting]
    /// While Avadhāna is on, links you click in your sites to other sites open on their own.
    var openLinks: Bool
    /// While Avadhāna is on, web links your apps open in your usual browser are moved into the
    /// chosen browser, without an address bar.
    var openAppLinks: Bool
    /// Looks for a new release on GitHub. Shown only in Settings.
    var checkForUpdates: Bool

    func shortcut(_ action: ShortcutAction) -> ShortcutSetting {
        shortcuts[action.rawValue] ?? action.defaultSetting
    }

    /// The chosen browser, or Safari if it has been uninstalled.
    var effectiveBrowser: BrowserKind { browser.isInstalled ? browser : .safari }

    var tiles: [Tile] {
        let all = apps.map(Tile.app) + sites.map(Tile.site)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return all.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Moves a tile to where `target` is, shifting the others.
    mutating func moveTile(_ id: String, to target: String) {
        var ids = tiles.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        order = ids
    }

    /// Moves a tile to a position, clamped to the list (for arranging without dragging).
    mutating func moveTile(_ id: String, toIndex index: Int) {
        var ids = tiles.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        order = ids
    }

    mutating func renameTileID(_ old: String, to new: String) {
        if let i = order.firstIndex(of: old) { order[i] = new }
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Avadhana", isDirectory: true)
    }
    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    static var invalidFileURL: URL { supportDir.appendingPathComponent("config.invalid.json") }

    /// Loads config.json, writing defaults on first run. An unreadable file is moved aside to
    /// config.invalid.json (never overwritten) and an error is returned for the UI to show.
    static func load() -> (Config, String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fileURL) else {
            let c = Config.defaults
            try? c.save()
            return (c, nil)
        }
        do {
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            try? fm.removeItem(at: invalidFileURL)
            try? fm.moveItem(at: fileURL, to: invalidFileURL)
            return (Config.defaults, "config.json couldn't be read, so it was moved to config.invalid.json. Your current settings are in use.")
        }
    }

    func save() throws {
        var copy = self
        let ids = Set(tiles.map(\.id))
        copy.order = order.filter(ids.contains)   // forget positions of removed tiles
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(copy).write(to: Config.fileURL, options: .atomic)
    }

    /// First run starts empty: you choose every app and site yourself.
    static var defaults: Config {
        Config(layout: .grid, hideDockDuringSession: true, browser: .safari,
               apps: [], sites: [], order: [], shortcuts: [:],
               openLinks: true, openAppLinks: true, checkForUpdates: true)
    }
}

extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .grid
        hideDockDuringSession = try c.decodeIfPresent(Bool.self, forKey: .hideDockDuringSession) ?? true
        browser = (try? c.decodeIfPresent(BrowserKind.self, forKey: .browser)) ?? .safari
        apps = try c.decodeIfPresent([AppTile].self, forKey: .apps) ?? []
        sites = try c.decodeIfPresent([SiteTile].self, forKey: .sites) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        let saved = (try? c.decodeIfPresent([String: ShortcutSetting].self, forKey: .shortcuts)) ?? [:]
        shortcuts = saved.filter { ShortcutAction(rawValue: $0.key) != nil }   // drop retired shortcuts
        openLinks = try c.decodeIfPresent(Bool.self, forKey: .openLinks) ?? true
        openAppLinks = try c.decodeIfPresent(Bool.self, forKey: .openAppLinks) ?? true
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
    }
}

/// An app found on disk, for the Apps picker in Settings.
struct InstalledApp: Identifiable, Hashable {
    var name: String
    var bundleID: String
    var url: URL
    var id: String { bundleID }

    /// Scans the standard Applications folders. Apps already in the config but installed elsewhere
    /// are included too.
    static func scan(including extra: [AppTile]) -> [InstalledApp] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen: Set<String> = [Bundle.main.bundleIdentifier ?? ""]
        var result: [InstalledApp] = []

        func add(_ url: URL) {
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { return }
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            result.append(InstalledApp(name: name, bundleID: id, url: url))
        }
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            items.filter { $0.pathExtension == "app" }.forEach(add)
        }
        for tile in extra {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tile.bundleID) { add(url) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
