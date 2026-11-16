import AppKit
import XCTest
@testable import Avadhana

final class ShortcutTests: XCTestCase {
    func testDefaults() {
        XCTAssertEqual(ShortcutAction.home.defaultSetting.combo.display, "⌘Esc")
        XCTAssertEqual(ShortcutAction.back.defaultSetting.combo.display, "⌃⌘⌫")
        XCTAssertTrue(ShortcutAction.home.isGlobal && ShortcutAction.back.isGlobal)
        XCTAssertFalse(ShortcutAction.settings.isGlobal)
    }

    func testNoTwoDefaultsShareKeys() {
        let combos = ShortcutAction.allCases.map(\.defaultSetting.combo)
        XCTAssertEqual(Set(combos).count, combos.count)
    }

    func testMatchingIgnoresNonModifierFlags() {
        let combo = KeyCombo(keyCode: 51, modifiers: [.control, .command], key: "⌫")
        XCTAssertTrue(combo.matches(keyCode: 51, flags: [.control, .command, .capsLock, .numericPad]))
        XCTAssertFalse(combo.matches(keyCode: 51, flags: [.command]), "missing ⌃")
        XCTAssertFalse(combo.matches(keyCode: 51, flags: [.control, .command, .shift]), "extra ⇧")
        XCTAssertFalse(combo.matches(keyCode: 53, flags: [.control, .command]), "different key")
    }

    func testDisplayOrdersModifiersLikeMacOS() {
        let combo = KeyCombo(keyCode: 40, modifiers: [.command, .shift, .option, .control], key: "K")
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘K")
    }

    func testCommonAppShortcutDetection() {
        XCTAssertTrue(KeyCombo(keyCode: 1, modifiers: .command, key: "S").isCommonAppShortcut)
        XCTAssertFalse(KeyCombo(keyCode: 53, modifiers: .command, key: "Esc").isCommonAppShortcut)
        XCTAssertFalse(KeyCombo(keyCode: 1, modifiers: [.command, .control], key: "S").isCommonAppShortcut)
    }
}
