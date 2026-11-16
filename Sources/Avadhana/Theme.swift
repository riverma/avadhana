import AppKit
import SwiftUI

/// The warm palette shared with the website (avadhana.riverma.com), in light and dark variants.
/// The app uses one orange (`accent`, the same as the website) for every control and highlight.
enum Theme {
    static let paper = color(light: 0xFFFAF2, dark: 0x17120D)       // window backgrounds
    static let paperSoft = color(light: 0xFFF1DC, dark: 0x211810)   // bars and panels
    static let card = color(light: 0xFFFFFF, dark: 0x241B13)        // fields, rows, dialogs
    static let line = color(light: 0xF0DFC6, dark: 0x3A2C1F)        // hairlines
    static let accent = color(light: 0xE8650F, dark: 0xF5821F)      // buttons, controls, selection
    static let cocoa = color(light: 0x74604F, dark: 0x8A7563)       // Stay

    static let nsPaper = nsColor(light: 0xFFFAF2, dark: 0x17120D)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nsColor(light: light, dark: dark))
    }

    private static func nsColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

extension View {
    /// Applies the accent to controls: buttons, pickers, radio buttons, checkboxes, selection.
    func themed() -> some View {
        tint(Theme.accent)
    }
}
