import Security
import XCTest
@testable import Avadhana

/// Installs real updates from disk images, end to end. Needs a signed build, so it only runs when
/// pointed at one: `./build.sh && AVADHANA_TEST_APP=build/Avadhana.app swift test`
final class UpdateInstallTests: XCTestCase {
    private var work: URL!
    private var installed: URL!
    private var requirement: SecRequirement!
    private var identity: String!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["AVADHANA_TEST_APP"] else {
            throw XCTSkip("Set AVADHANA_TEST_APP to a signed Avadhana.app to run")
        }
        let built = URL(fileURLWithPath: path)
        identity = try XCTUnwrap(try signingIdentity(of: built), "the build must be signed with a certificate, not ad hoc")

        work = FileManager.default.temporaryDirectory.appendingPathComponent("avadhana-update-\(UUID().uuidString)")
        installed = work.appendingPathComponent("Applications/Avadhana.app")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try shell("/usr/bin/ditto", built.path, installed.path)
        try setVersion("0.1.0", of: installed, signWith: identity)

        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(installed as CFURL, [], &code), errSecSuccess)
        var req: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(code), [], &req), errSecSuccess)
        requirement = try XCTUnwrap(req)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func testInstallsANewerSignedRelease() throws {
        let dmg = try makeDiskImage(version: "0.1.1", signWith: identity)
        try Updater.installUpdate(dmg: dmg, replacing: installed, requirement: requirement, newerThan: "0.1.0")
        XCTAssertEqual(version(of: installed), "0.1.1")
        XCTAssertTrue(Updater.verify(installed, satisfies: requirement))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path),
                       ["Avadhana.app"], "nothing is left behind")
    }

    func testRejectsAReleaseSignedBySomeoneElse() throws {
        let dmg = try makeDiskImage(version: "0.1.1", signWith: "-")
        XCTAssertThrowsError(try Updater.installUpdate(dmg: dmg, replacing: installed, requirement: requirement, newerThan: "0.1.0")) {
            XCTAssertTrue(($0 as? Updater.UpdateError)?.message.contains("signed") == true, "\($0)")
        }
        XCTAssertEqual(version(of: installed), "0.1.0", "the installed copy is untouched")
    }

    func testRejectsTheSameVersion() throws {
        let dmg = try makeDiskImage(version: "0.1.0", signWith: identity)
        XCTAssertThrowsError(try Updater.installUpdate(dmg: dmg, replacing: installed, requirement: requirement, newerThan: "0.1.0"))
        XCTAssertEqual(version(of: installed), "0.1.0")
    }

    func testRejectsADamagedImage() throws {
        let dmg = work.appendingPathComponent("broken.dmg")
        try Data("not a disk image".utf8).write(to: dmg)
        XCTAssertThrowsError(try Updater.installUpdate(dmg: dmg, replacing: installed, requirement: requirement, newerThan: "0.1.0"))
        XCTAssertEqual(version(of: installed), "0.1.0")
    }

    // MARK: Helpers

    private func makeDiskImage(version: String, signWith identity: String) throws -> URL {
        let folder = work.appendingPathComponent("dmg-\(UUID().uuidString)")
        let app = folder.appendingPathComponent("Avadhana.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try shell("/usr/bin/ditto", installed.path, app.path)
        try setVersion(version, of: app, signWith: identity)
        let dmg = work.appendingPathComponent("Avadhana-\(UUID().uuidString).dmg")
        try shell("/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-srcfolder", folder.path, "-volname", "Avadhana", dmg.path)
        return dmg
    }

    private func setVersion(_ version: String, of app: URL, signWith identity: String) throws {
        try shell("/usr/libexec/PlistBuddy", "-c", "Set :CFBundleShortVersionString \(version)",
                  app.appendingPathComponent("Contents/Info.plist").path)
        try shell("/usr/bin/codesign", "--force", "--options", "runtime", "--sign", identity, app.path)
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func signingIdentity(of app: URL) throws -> String? {
        let out = try shell("/usr/bin/codesign", "-dvv", app.path)
        return out.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
    }

    @discardableResult
    private func shell(_ tool: String, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out]) }
        return out
    }
}
