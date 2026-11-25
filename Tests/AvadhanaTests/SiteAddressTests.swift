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
        for input in ["", "   ", "file:///definitely/not/here.html", "javascript:alert(1)", "intranet"] {
            var draft = SiteDraft(index: nil, site: nil)
            draft.url = input
            XCTAssertNil(draft.toTile(), input)
        }
    }

    func testLocalAddressesUseHTTPAndTheirOwnHost() throws {
        let cases: [(input: String, url: String, name: String)] = [
            ("localhost", "http://localhost", "localhost"),
            ("localhost:3000", "http://localhost:3000", "localhost:3000"),
            ("localhost:8080/app", "http://localhost:8080/app", "localhost:8080"),
            ("127.0.0.1", "http://127.0.0.1", "127.0.0.1"),
            ("127.0.0.1:5173", "http://127.0.0.1:5173", "127.0.0.1:5173"),
            ("192.168.1.20:8000", "http://192.168.1.20:8000", "192.168.1.20:8000"),
            ("10.0.0.7", "http://10.0.0.7", "10.0.0.7"),
            ("172.20.5.9:4000", "http://172.20.5.9:4000", "172.20.5.9:4000"),
            ("https://localhost:8443", "https://localhost:8443", "localhost:8443"),
        ]
        for c in cases {
            var draft = SiteDraft(index: nil, site: nil)
            draft.url = c.input
            let tile = try XCTUnwrap(draft.toTile(), c.input)
            XCTAssertEqual(tile.url, c.url, c.input)
            XCTAssertEqual(tile.name, c.name, c.input)
            XCTAssertEqual(tile.allowedDomains, [URL(string: c.url)!.host!], c.input)
        }
    }

    func testPublicAddressesStillUseHTTPS() throws {
        var draft = SiteDraft(index: nil, site: nil)
        draft.url = "192.168.example.com"
        XCTAssertEqual(try XCTUnwrap(draft.toTile()).url, "https://192.168.example.com")
        draft.url = "172.32.0.1"   // just outside the private 172.16–31 range
        XCTAssertEqual(try XCTUnwrap(draft.toTile()).url, "https://172.32.0.1")
    }

    func testLocalHostRanges() {
        for host in ["localhost", "app.localhost", "127.0.0.1", "127.255.0.9", "10.1.2.3",
                     "172.16.0.1", "172.31.255.255", "192.168.0.1"] {
            XCTAssertTrue(Links.isLocalHost(host), host)
        }
        for host in ["github.com", "example.localhost.com", "8.8.8.8", "172.15.0.1", "172.32.0.1",
                     "192.169.0.1", "11.0.0.1", "192.168.1", "localhost.example.com"] {
            XCTAssertFalse(Links.isLocalHost(host), host)
        }
    }
}
