import XCTest
@testable import Avadhana

final class SiteAddressTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("avadhana-test-\(UUID().uuidString).html")
        try "<h1>test</h1>".write(to: tempFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile)
    }

    // MARK: SiteTile.openableURL

    func testWebAddressesNeedHTTPSchemeAndHost() {
        XCTAssertNotNil(SiteTile.openableURL("https://github.com"))
        XCTAssertNotNil(SiteTile.openableURL("http://example.com/path?q=1"))
        XCTAssertNil(SiteTile.openableURL("https://"))
        XCTAssertNil(SiteTile.openableURL("github.com"), "no scheme")
    }

    func testLocalFilesMustExist() {
        XCTAssertNotNil(SiteTile.openableURL(tempFile.absoluteString))
        XCTAssertNil(SiteTile.openableURL("file:///definitely/not/here.html"))
    }

    func testOtherSchemesAndOptionLikeStringsAreRejected() {
        for s in ["javascript:alert(1)", "mailto:a@example.com", "ftp://example.com", "-start-debugger-server", "--app=x"] {
            XCTAssertNil(SiteTile.openableURL(s), s)
        }
    }

    // MARK: SiteTile.allows(host:)

    func testAllowedDomainsIncludeSubdomainsOnly() {
        let site = SiteTile(name: "GitHub", url: "https://github.com", allowedDomains: ["github.com"])
        XCTAssertTrue(site.allows(host: "github.com"))
        XCTAssertTrue(site.allows(host: "gist.github.com"))
        XCTAssertTrue(site.allows(host: "GitHub.com"), "case-insensitive")
        XCTAssertFalse(site.allows(host: "evilgithub.com"), "a suffix that isn't a subdomain")
        XCTAssertFalse(site.allows(host: "github.com.evil.example"))
    }

    // MARK: SiteDraft (Settings → Sites)

    func testBareDomainBecomesHTTPSWithNameAndDomain() throws {
        var draft = SiteDraft(index: nil, site: nil)
        draft.url = "www.github.com"
        let tile = try XCTUnwrap(draft.toTile())
        XCTAssertEqual(tile.url, "https://www.github.com")
        XCTAssertEqual(tile.name, "Github")
        XCTAssertEqual(tile.allowedDomains, ["github.com"])
    }

    func testListedDomainsAreParsedAndLowercased() throws {
        var draft = SiteDraft(index: nil, site: nil)
        draft.url = "https://docs.google.com"
        draft.domains = "docs.google.com, Accounts.Google.com\nGSTATIC.com"
        XCTAssertEqual(try XCTUnwrap(draft.toTile()).allowedDomains,
                       ["docs.google.com", "accounts.google.com", "gstatic.com"])
    }

    func testLocalFileFormsAreAcceptedAndNormalized() throws {
        let expected = URL(fileURLWithPath: tempFile.path).absoluteString
        for input in [tempFile.path, tempFile.absoluteString, "file:" + tempFile.path,
                      "file:" + tempFile.path.replacingOccurrences(of: "/", with: "\\")] {
            var draft = SiteDraft(index: nil, site: nil)
            draft.url = input
            let tile = try XCTUnwrap(draft.toTile(), input)
            XCTAssertEqual(tile.url, expected, input)
            XCTAssertTrue(tile.allowedDomains.isEmpty, "local pages get no web domains by default")
            XCTAssertEqual(tile.name, tempFile.deletingPathExtension().lastPathComponent)
        }
    }

    func testInvalidInputProducesNoTile() {
        for input in ["", "   ", "localhost", "file:///definitely/not/here.html", "javascript:alert(1)"] {
            var draft = SiteDraft(index: nil, site: nil)
            draft.url = input
            XCTAssertNil(draft.toTile(), input)
        }
    }
}
