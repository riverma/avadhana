import Foundation

/// System settings changed for the duration of a session. The original values are written to disk
/// *before* changing anything, so a crash or force-quit is undone the next time the app launches.
final class SystemTweaks {
    struct Snapshot: Codable {
        var dockAutohide: Bool
        var dockAutohideDelay: Double?   // nil = the key wasn't set
        /// Whether Avadhāna changed the Dock. nil in files from older versions, which always did.
        var dockApplied: Bool? = nil
        /// Menu bar: nil = not changed by Avadhāna (also the case for files written by older versions).
        var menuBarAutohideWasSet: Bool?
        /// The original `_HIHideMenuBar` value, used when `menuBarAutohideWasSet` is true.
        var menuBarAutohide: Bool?
    }
    private var restoreFile: URL { Config.supportDir.appendingPathComponent("restore.json") }

    /// Applies the requested session tweaks. Anything already applied by a session in progress is
    /// left alone, and its saved original is kept.
    func apply(hideDock: Bool, hideMenuBar: Bool) {
        let existing = readSnapshot()
        var snap = existing ?? Snapshot(dockAutohide: read("autohide") == "1",
                                        dockAutohideDelay: read("autohide-delay").flatMap(Double.init),
                                        dockApplied: false)
        let dockAlreadyApplied = existing.map { $0.dockApplied ?? true } ?? false   // older files always applied it
        let dockNeedsChange = hideDock && !dockAlreadyApplied
        if dockNeedsChange { snap.dockApplied = true }
        let menuNeedsChange = hideMenuBar && snap.menuBarAutohideWasSet == nil
        if menuNeedsChange {
            let original = readGlobal("_HIHideMenuBar")
            snap.menuBarAutohideWasSet = original != nil
            snap.menuBarAutohide = original == "1"
        }
        guard dockNeedsChange || menuNeedsChange else { return }

        guard let data = try? JSONEncoder().encode(snap), (try? data.write(to: restoreFile, options: .atomic)) != nil else { return }
        if dockNeedsChange {
            // Hides the Dock and makes it effectively impossible to reveal by moving the pointer to the
            // screen edge, so it can't be used to open other apps during a session.
            defaults(["write", "com.apple.dock", "autohide", "-bool", "true"])
            defaults(["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            restartDock()
        }
        if menuNeedsChange {
            defaults(["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool", "true"])
            restartDock()
            restartSystemUI()
        }
    }

    /// Call at launch and at session end.
    func restoreIfNeeded() {
        guard FileManager.default.fileExists(atPath: restoreFile.path) else { return }
        guard let snap = readSnapshot() else {
            try? FileManager.default.removeItem(at: restoreFile)   // unreadable; don't block future sessions
            return
        }
        defaults(["write", "com.apple.dock", "autohide", "-bool", snap.dockAutohide ? "true" : "false"])
        if let delay = snap.dockAutohideDelay {
            defaults(["write", "com.apple.dock", "autohide-delay", "-float", String(delay)])
        } else {
            defaults(["delete", "com.apple.dock", "autohide-delay"])
        }
        restartDock()
        if snap.menuBarAutohideWasSet == true {
            defaults(["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool", snap.menuBarAutohide == true ? "true" : "false"])
            restartDock()
            restartSystemUI()
        } else if snap.menuBarAutohideWasSet == false {
            defaults(["delete", "NSGlobalDomain", "_HIHideMenuBar"])
            restartDock()
            restartSystemUI()
        }
        try? FileManager.default.removeItem(at: restoreFile)
    }

    private func readSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: restoreFile) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func read(_ key: String) -> String? { readValue(domain: "com.apple.dock", key) }
    private func readGlobal(_ key: String) -> String? { readValue(domain: "NSGlobalDomain", key) }

    private func readValue(domain: String, _ key: String) -> String? {
        let out = run("/usr/bin/defaults", ["read", domain, key]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private func defaults(_ args: [String]) { run("/usr/bin/defaults", args) }
    private func restartDock() { run("/usr/bin/killall", ["Dock"]) }
    private func restartSystemUI() { run("/usr/bin/killall", ["SystemUIServer"]) }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // read first so a full pipe can't stall it
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
