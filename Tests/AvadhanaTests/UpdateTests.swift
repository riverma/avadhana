import Security
import XCTest
@testable import Avadhana

final class UpdateTests: XCTestCase {
    // MARK: Versions

    func testNewerVersions() {
        XCTAssertTrue(Release.isVersion("0.2.0", newerThan: "0.1.0"))
        XCTAssertTrue(Release.isVersion("0.10.0", newerThan: "0.9.2"))
        XCTAssertTrue(Release.isVersion("v1.0", newerThan: "0.9.9"))
        XCTAssertTrue(Release.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertTrue(Release.isVersion("1.0.0", newerThan: "1.0.0-beta"))
        XCTAssertTrue(Release.isVersion("1.0.0-beta.2", newerThan: "1.0.0-beta.1"))
    }

    func testSameOrOlderVersions() {
        XCTAssertFalse(Release.isVersion("0.1.0", newerThan: "0.1.0"))
        XCTAssertFalse(Release.isVersion("1.0", newerThan: "1.0.0"))
        XCTAssertFalse(Release.isVersion("0.9.9", newerThan: "1.0.0"))
        XCTAssertFalse(Release.isVersion("1.0.0-beta", newerThan: "1.0.0"))
    }

    // MARK: GitHub's response

    func testParsesLatestRelease() throws {
        let json = #"""
        {"tag_name": "v0.2.0", "html_url": "https://github.com/riverma/avadhana/releases/tag/v0.2.0",
         "assets": [
           {"name": "Avadhana.dmg.sha256", "browser_download_url": "https://example.com/a.sha256"},
           {"name": "Avadhana.dmg", "browser_download_url": "https://github.com/riverma/avadhana/releases/download/v0.2.0/Avadhana.dmg"}
         ]}
        """#
        let r = try Release.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.pageURL.absoluteString, "https://github.com/riverma/avadhana/releases/tag/v0.2.0")
        XCTAssertEqual(r.dmgURL?.lastPathComponent, "Avadhana.dmg")
    }

    func testReleaseWithoutDiskImage() throws {
        let json = #"{"tag_name": "0.3.0", "html_url": "https://github.com/riverma/avadhana/releases/tag/0.3.0", "assets": []}"#
        let r = try Release.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertNil(r.dmgURL)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try Release.parse(Data(#"{"message": "Not Found"}"#.utf8)))
    }

    // MARK: Signatures

    private func requirement(_ text: String) throws -> SecRequirement {
        var req: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &req), errSecSuccess)
        return try XCTUnwrap(req)
    }

    func testSignatureMustMatchTheRequirement() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        XCTAssertTrue(Updater.verify(calculator, satisfies: try requirement("anchor apple")))
        XCTAssertFalse(Updater.verify(calculator, satisfies: try requirement(#"identifier "com.riverma.avadhana""#)))
    }

    func testUnsignedFolderFailsVerification() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("Fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        XCTAssertFalse(Updater.verify(fake, satisfies: try requirement("anchor apple generic")))
    }

    func testTranslocatedCopyCantUpdateInPlace() {
        let url = URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABC/d/Avadhana.app")
        XCTAssertNotNil(Updater.inPlaceProblem(url))
        XCTAssertNil(Updater.inPlaceProblem(FileManager.default.temporaryDirectory.appendingPathComponent("Avadhana.app")))
    }
}
