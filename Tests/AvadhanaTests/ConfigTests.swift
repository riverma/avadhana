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
}
