import XCTest
@testable import Avadhana

final class AppPickerTests: XCTestCase {
    /// Browsers can be added to the allowed apps like any other app.
    func testInstalledBrowsersAreListedAsApps() throws {
        let browsers = BrowserKind.installed
        try XCTSkipIf(browsers.isEmpty, "no supported browser installed on this Mac")
        let listed = Set(InstalledApp.scan(including: []).map(\.bundleID))
        for browser in browsers {
            XCTAssertTrue(listed.contains(browser.bundleID), browser.displayName)
        }
    }
}
