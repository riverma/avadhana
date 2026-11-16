import AppKit
import Security

/// A published release of Avadhāna on GitHub.
struct Release: Equatable {
    var version: String
    var pageURL: URL
    var dmgURL: URL?

    static let latestAPI = URL(string: "https://api.github.com/repos/riverma/avadhana/releases/latest")!
    static let allReleasesPage = URL(string: "https://github.com/riverma/avadhana/releases")!

    /// Reads GitHub's "latest release" response.
    static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Payload: Decodable { var tag_name: String; var html_url: URL; var assets: [Asset] }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let dmgs = p.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let dmg = dmgs.first { $0.name == "Avadhana.dmg" } ?? dmgs.first
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        return Release(version: version, pageURL: p.html_url, dmgURL: dmg?.browser_download_url)
    }

    /// Compares dotted version numbers ("0.10.0" is newer than "0.9.2"). A pre-release such as
    /// "1.0.0-beta" comes before "1.0.0".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func split(_ v: String) -> ([Int], String?) {
            let v = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
            let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, parts.count > 1 ? parts[1] : nil)
        }
        let (a, aPre) = split(candidate), (b, bPre) = split(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        switch (aPre, bPre) {
        case (nil, .some): return true
        case (.some(let x), .some(let y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }
}

/// Checks GitHub for a newer release and, when you choose to update, replaces this copy of
/// Avadhāna with it. Nothing is shown outside Settings. The only request is to GitHub's public
/// release API; nothing about you or your Mac is sent.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case updating
        case failed(String, Release?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var currentVersion: String { AppInfo.version }

    /// Checks at most once an hour unless asked to check now.
    func check(force: Bool = false) {
        if state == .checking || state == .updating { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < 3600 { return }
        state = .checking
        var request = URLRequest(url: Release.latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Avadhana/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        Task {
            let result: State
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 {
                    result = .upToDate   // nothing has been released yet
                } else if status == 200 {
                    let release = try Release.parse(data)
                    result = Release.isVersion(release.version, newerThan: currentVersion) ? .available(release) : .upToDate
                } else {
                    result = .failed("GitHub couldn't be reached (error \(status)).", nil)
                }
            } catch {
                result = .failed("Couldn't check for updates: \(error.localizedDescription)", nil)
            }
            lastChecked = Date()
            state = result
        }
    }

    /// Downloads the release, checks it's signed by the same developer as this copy, swaps it in
    /// and reopens Avadhāna.
    func install(_ release: Release) {
        guard state != .updating else { return }
        guard let dmgURL = release.dmgURL else {
            state = .failed("This release has no download for Mac yet.", release)
            return
        }
        let appURL = Bundle.main.bundleURL
        if let problem = Self.inPlaceProblem(appURL) {
            state = .failed(problem, release)
            return
        }
        state = .updating
        Task {
            do {
                let requirement = try Self.ownRequirement()
                let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                    throw UpdateError("The download didn't complete.")
                }
                let version = currentVersion
                try await Task.detached {
                    try Self.installUpdate(dmg: downloaded, replacing: appURL, requirement: requirement, newerThan: version)
                }.value
                Self.relaunch(appURL)
            } catch {
                state = .failed((error as? UpdateError)?.message ?? "The update couldn't be installed: \(error.localizedDescription)", release)
            }
        }
    }

    // MARK: Installing

    struct UpdateError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// Why this copy can't replace itself, if it can't.
    nonisolated static func inPlaceProblem(_ appURL: URL) -> String? {
        if appURL.path.contains("/AppTranslocation/") {
            return "Move Avadhāna to your Applications folder, open it from there, then update."
        }
        if !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            return "Avadhāna can't replace itself in its current folder."
        }
        return nil
    }

    /// The code requirement this copy was signed with. An update must meet the same one, so only
    /// the developer who signed this copy can replace it.
    nonisolated static func ownRequirement() throws -> SecRequirement {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("This copy of Avadhāna isn't signed, so it can't check updates. Download the new version instead.")
        }
        return requirement
    }

    /// Checks an app's signature is intact and meets `requirement`.
    nonisolated static func verify(_ app: URL, satisfies requirement: SecRequirement) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    /// Mounts the disk image, checks the app inside, and puts it in place of `appURL`.
    nonisolated static func installUpdate(dmg: URL, replacing appURL: URL, requirement: SecRequirement,
                                          newerThan version: String) throws {
        let fm = FileManager.default
        // Mounted in the ordinary temporary folder: macOS doesn't allow reading a disk image
        // mounted inside the replacement folder.
        let mount = fm.temporaryDirectory.appendingPathComponent("Avadhana-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        // A folder on the same disk as the app, so the final swap is a quick rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? fm.removeItem(at: work) }

        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path],
                failure: "The download couldn't be opened.")
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"], failure: "") }

        let ownID = Bundle(url: appURL)?.bundleIdentifier
        let items = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let found = items.first(where: { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == ownID }) else {
            throw UpdateError("The download doesn't contain Avadhāna.")
        }
        guard let newVersion = Bundle(url: found)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              Release.isVersion(newVersion, newerThan: version) else {
            throw UpdateError("The download isn't a newer version of Avadhāna.")
        }
        guard verify(found, satisfies: requirement) else {
            throw UpdateError("The download isn't signed by Avadhāna's developer, so it wasn't installed.")
        }

        // Copy next to the current app (same disk), check the copy, then swap it in.
        let staged = work.appendingPathComponent(appURL.lastPathComponent)
        try run("/usr/bin/ditto", [found.path, staged.path], failure: "The update couldn't be copied.")
        guard verify(staged, satisfies: requirement) else {
            throw UpdateError("The update was damaged while copying, so it wasn't installed.")
        }
        _ = try fm.replaceItemAt(appURL, withItemAt: staged)
    }

    private nonisolated static func run(_ tool: String, _ args: [String], failure: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(failure) }
    }

    /// Opens the updated app once this one has quit.
    private static func relaunch(_ appURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(getpid()), appURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
