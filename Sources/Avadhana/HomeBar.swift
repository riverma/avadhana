import AppKit
import SwiftUI

/// Always-on-top strip at the bottom of the screen: the only navigation you need in a session.
/// Non-activating, so clicking it doesn't steal focus from the current app until you press a button.
final class HomeBar: NSPanel {
    static let height: CGFloat = 48

    init(controller: AppController) {
        super.init(contentRect: Self.barFrame(), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: HomeBarView().environmentObject(controller))
    }

    static func barFrame() -> NSRect {
        let vf = NSScreen.screens.first?.visibleFrame ?? .zero
        return NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: height)
    }

    /// The visible frame changes when the Dock starts auto-hiding or the menu bar appears.
    func reposition() {
        let f = Self.barFrame()
        if frame != f { setFrame(f, display: true) }
    }
}

struct HomeBarView: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        HStack(spacing: 16) {
            Button { c.goHome() } label: {
                Label("Home", systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .controlSize(.large)
            .fixedSize()

            Button { c.goBack() } label: {
                Label("Back", systemImage: "chevron.backward")
                    .font(.system(size: 14, weight: .medium))
            }
            .controlSize(.large)
            .fixedSize()
            .disabled(c.atHome)

            if let opening = c.launching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening \(opening.name)…").font(.system(size: 14, weight: .medium))
                }
            } else {
                Text(c.currentAppName ?? "Home")
                    .font(.system(size: 14, weight: .medium))
            }

            if let toast = c.toast {
                Label(toast, systemImage: "hand.raised.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            }

            Spacer()

            Button { c.openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.large)
            .fixedSize()

            Button("Exit Avadhāna") { c.requestEndSession() }
                .controlSize(.large)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paperSoft)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .themed()
        .animation(.easeInOut(duration: 0.2), value: c.toast)
    }
}
