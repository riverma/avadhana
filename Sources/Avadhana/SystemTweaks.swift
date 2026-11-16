import Foundation

/// System settings changed for the duration of a session. The original values are written to disk
/// *before* changing anything, so a crash or force-quit is undone the next time the app launches.
final class SystemTweaks {
    private struct Snapshot: Codable {
        var dockAutohide: Bool
        var dockAutohideDelay: Double?   // nil = the key wasn't set
    }
    private var restoreFile: URL { Config.supportDir.appendingPathComponent("restore.json") }

    /// Hides the Dock and makes it effectively impossible to reveal by moving the pointer to the
    /// screen edge, so it can't be used to open other apps during a session.
    func hideDock() {
        guard !FileManager.default.fileExists(atPath: restoreFile.path) else { return }   // already applied
        let snap = Snapshot(dockAutohide: read("autohide") == "1", dockAutohideDelay: read("autohide-delay").flatMap(Double.init))
        guard let data = try? JSONEncoder().encode(snap), (try? data.write(to: restoreFile, options: .atomic)) != nil else { return }
        defaults(["write", "com.apple.dock", "autohide", "-bool", "true"])
        defaults(["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        restartDock()
    }

    /// Call at launch and at session end.
    func restoreIfNeeded() {
        guard let data = try? Data(contentsOf: restoreFile) else { return }
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
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
        try? FileManager.default.removeItem(at: restoreFile)
    }

    private func read(_ key: String) -> String? {
        let out = run("/usr/bin/defaults", ["read", "com.apple.dock", key]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private func defaults(_ args: [String]) { run("/usr/bin/defaults", args) }
    private func restartDock() { run("/usr/bin/killall", ["Dock"]) }

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
