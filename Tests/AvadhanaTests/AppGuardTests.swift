import XCTest
@testable import Avadhana

@MainActor
final class AppGuardTests: XCTestCase {
    func testChosenBrowserInAllowListPassesEvenWhenNotFocus() {
        XCTAssertEqual(AppGuard.browserVerdict(isFocus: false, allowed: true, isPreexisting: true), .allowed)
        XCTAssertEqual(AppGuard.browserVerdict(isFocus: false, allowed: true, isPreexisting: false), .allowed)
    }

    func testFocusInstanceIsAllowed() {
        XCTAssertEqual(AppGuard.browserVerdict(isFocus: true, allowed: false, isPreexisting: false), .allowed)
    }

    func testNormalBrowserIsHiddenIfOpenBeforeOtherwiseBlocked() {
        XCTAssertEqual(AppGuard.browserVerdict(isFocus: false, allowed: false, isPreexisting: true), .hideOnly)
        XCTAssertEqual(AppGuard.browserVerdict(isFocus: false, allowed: false, isPreexisting: false), .block)
    }
}
