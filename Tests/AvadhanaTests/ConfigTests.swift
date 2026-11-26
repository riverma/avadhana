import XCTest
@testable import Avadhana

final class ConfigTests: XCTestCase {
    private func makeConfig() -> Config {
        var c = Config.defaults
        c.apps = [AppTile(name: "Notes", bundleID: "com.apple.Notes"),
                  AppTile(name: "Mail", bundleID: "com.apple.mail")]
        c.sites = [SiteTile(name: "GitHub", url: "https://github.com", allowedDomains: ["github.com"])]
        return c
    }

    // MARK: Tile order

    func testTilesFollowSavedOrderThenUnlistedTiles() {
        var c = makeConfig()
        c.order = ["site:https://github.com", "app:com.apple.mail"]
        XCTAssertEqual(c.tiles.map(\.id), ["site:https://github.com", "app:com.apple.mail", "app:com.apple.Notes"])
    }

    func testMoveTileOntoAnother() {
        var c = makeConfig()
        c.moveTile("site:https://github.com", to: "app:com.apple.Notes")
        XCTAssertEqual(c.tiles.map(\.id), ["site:https://github.com", "app:com.apple.Notes", "app:com.apple.mail"])
    }

    func testMoveTileToIndexIsClamped() {
        var c = makeConfig()
        c.moveTile("app:com.apple.Notes", toIndex: 99)
        XCTAssertEqual(c.tiles.last?.id, "app:com.apple.Notes")
        c.moveTile("app:com.apple.Notes", toIndex: -5)
        XCTAssertEqual(c.tiles.first?.id, "app:com.apple.Notes")
    }

    func testRenamingATileKeepsItsPosition() {
        var c = makeConfig()
        c.order = ["site:https://github.com", "app:com.apple.Notes", "app:com.apple.mail"]
        c.sites[0].url = "https://github.com/riverma"
        c.renameTileID("site:https://github.com", to: "site:https://github.com/riverma")
        XCTAssertEqual(c.tiles.first?.id, "site:https://github.com/riverma")
    }

    // MARK: Decoding

    func testMissingKeysFallBackToDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(c.layout, .grid)
        XCTAssertTrue(c.hideDockDuringSession)
        XCTAssertEqual(c.browser, .safari)
        XCTAssertTrue(c.apps.isEmpty && c.sites.isEmpty && c.order.isEmpty && c.shortcuts.isEmpty)
        XCTAssertTrue(c.openLinks, "web links open by default")
        XCTAssertTrue(c.checkForUpdates)
        XCTAssertTrue(c.openAppLinks)
    }

    func testLinkAndUpdateSettingsAreKept() throws {
        let json = #"{"openLinks": false, "openAppLinks": false, "checkForUpdates": false}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertFalse(c.openLinks)
        XCTAssertFalse(c.checkForUpdates)
        XCTAssertFalse(c.openAppLinks)
    }

    func testUnknownBrowserFallsBackToSafari() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"browser": "netscape"}"#.utf8))
        XCTAssertEqual(c.browser, .safari)
    }

    func testRetiredShortcutsAreDropped() throws {
        let json = #"""
        {"shortcuts": {
          "endNow": {"enabled": true, "ignoreWhileTyping": false, "combo": {"keyCode": 36, "modifiers": 1048576, "key": "↩"}},
          "home":   {"enabled": false, "ignoreWhileTyping": false, "combo": {"keyCode": 53, "modifiers": 1048576, "key": "Esc"}}
        }}
        """#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(Set(c.shortcuts.keys), ["home"])
        XCTAssertFalse(c.shortcut(.home).enabled)
    }

    func testEncodingRoundTrips() throws {
        var c = makeConfig()
        c.layout = .rows
        c.openLinks = false
        c.openAppLinks = false
        c.order = c.tiles.map(\.id).reversed()
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
    }

    // MARK: Menu bar, browser start page and browser windows (issue #1)

    func testMenuBarAndStartPageDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(c.hideMenuBarDuringSession, "menu bar hidden by default")
        XCTAssertEqual(c.browserStartPage, "https://duckduckgo.com")
    }

    func testMenuBarSettingRoundTripsWhenOff() throws {
        var c = Config.defaults
        c.hideMenuBarDuringSession = false
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(decoded.hideMenuBarDuringSession)
    }

    func testOldRestoreFileWithOnlyDockKeysStillDecodes() throws {
        let snap = try JSONDecoder().decode(SystemTweaks.Snapshot.self, from: Data(#"{"dockAutohide": true, "dockAutohideDelay": 0.5}"#.utf8))
        XCTAssertTrue(snap.dockAutohide)
        XCTAssertEqual(snap.dockAutohideDelay, 0.5)
        XCTAssertNil(snap.menuBarAutohideWasSet, "menu bar was never changed by an older version")
    }

    func testBrowserKindFromBundleID() {
        XCTAssertEqual(BrowserKind.from(bundleID: "com.google.Chrome"), .chrome)
        XCTAssertNil(BrowserKind.from(bundleID: "com.apple.TextEdit"))
    }

    func testBrowserChromeIsHiddenByDefaultAndCanBeTurnedOff() throws {
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).hideBrowserChrome)
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"hideBrowserChrome": false}"#.utf8))
        XCTAssertFalse(off.hideBrowserChrome)
    }

    func testBrowserStartPageURLUsesValidValue() {
        var c = Config.defaults
        c.browserStartPage = "https://example.com"
        XCTAssertEqual(c.browserStartPageURL.absoluteString, "https://example.com")
    }

    func testBrowserStartPageURLFallsBackToDuckDuckGo() {
        for bad in ["", "   ", "javascript:alert(1)", "not a url", "intranet"] {
            var c = Config.defaults
            c.browserStartPage = bad
            XCTAssertEqual(c.browserStartPageURL.absoluteString, "https://duckduckgo.com", bad)
        }
    }

    func testBareLocalAddressBecomesHTTP() {
        var c = Config.defaults
        c.browserStartPage = "localhost:3000"
        XCTAssertEqual(c.browserStartPageURL.absoluteString, "http://localhost:3000")
    }

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(Config.normalizedAddress("duckduckgo.com"), "https://duckduckgo.com")
    }
}
