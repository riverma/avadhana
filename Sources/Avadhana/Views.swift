import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Icons

struct TileIcon: View {
    let tile: Tile
    var size: CGFloat

    var body: some View {
        switch tile {
        case .app(let a):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: size, height: size)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .resizable().scaledToFit().frame(width: size * 0.7, height: size * 0.7)
                    .frame(width: size, height: size)
                    .foregroundStyle(.secondary)
            }
        case .site(let s):
            SiteIcon(name: s.name, size: size)
        }
    }
}

struct SiteIcon: View {
    let name: String
    var size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.accent.gradient)
                .frame(width: size * 0.84, height: size * 0.84)
                .overlay(
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
            if size >= 32 {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size * 0.06)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
        }
    }
}

// MARK: - Shared tile collection (setup preview and session home are the same view)

enum GridLayout {
    static let tileSize: CGFloat = 150
    static let spacing: CGFloat = 24
    static let maxWidth: CGFloat = 960

    static func columns(for width: CGFloat) -> Int {
        max(1, Int((min(width, maxWidth) + spacing) / (tileSize + spacing)))
    }
}

enum RowLayout {
    static let iconSize: CGFloat = 44
    static let spacing: CGFloat = 8
    static let pitch: CGFloat = 68 + spacing   // row height + gap, for Page Up / Page Down
}

private func tileBackground(selected: Bool, hovering: Bool, radius: CGFloat, resting: Double = 0) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(selected ? Theme.accent.opacity(0.16) : (resting > 0 && !hovering ? Theme.card : Color.primary.opacity(hovering ? 0.06 : 0)))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : (resting > 0 ? Theme.line : .clear), lineWidth: selected ? 2.5 : 1)
        )
}

/// One tile, as a grid square or a full-width row. `action` is nil while arranging.
struct TileView: View {
    let tile: Tile
    let layout: Layout
    let selected: Bool
    var loading = false
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .grid:
            VStack(spacing: 12) {
                TileIcon(tile: tile, size: 88)
                    .opacity(loading ? 0.45 : 1)
                    .overlay { if loading { ProgressView().controlSize(.large) } }
                Text(tile.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: GridLayout.tileSize, height: GridLayout.tileSize)
            .background(tileBackground(selected: selected, hovering: hovering, radius: 20))
            .contentShape(Rectangle())
        case .rows:
            HStack(spacing: 16) {
                TileIcon(tile: tile, size: RowLayout.iconSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.name).font(.system(size: 19, weight: .medium))
                    Text(tile.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Opening…").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if selected {
                    Image(systemName: "return").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(tileBackground(selected: selected, hovering: hovering, radius: 14, resting: 0.03))
            .contentShape(Rectangle())
        }
    }
}

struct TileCollection: View {
    @EnvironmentObject var c: AppController
    let tiles: [Tile]
    let layout: Layout
    let columns: Int
    var selection: Int? = nil
    /// Arrange mode: tiles can be dragged into a new order and don't open when clicked.
    var arranging = false
    @State private var dragging: Tile?

    var body: some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(GridLayout.tileSize), spacing: GridLayout.spacing), count: columns),
                      spacing: GridLayout.spacing) { items }
                .frame(maxWidth: .infinity)
        case .rows:
            LazyVStack(spacing: RowLayout.spacing) { items }
        }
    }

    private var items: some View {
        ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
            let view = TileView(tile: tile, layout: layout, selected: i == selection,
                                loading: !arranging && c.launching?.id == tile.id,
                                action: arranging ? nil : { c.open(tile) })
                .id(tile.id)
            if arranging {
                view
                    .opacity(dragging?.id == tile.id ? 0.35 : 1)
                    .onDrag {
                        dragging = tile
                        return NSItemProvider(object: tile.id as NSString)
                    }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(target: tile, dragging: $dragging) { from, to in
                        c.moveTile(from, to: to)
                    })
                    .contextMenu {   // the same arranging without dragging
                        Button("Move to Start") { c.moveTile(tile.id, .start) }.disabled(i == 0)
                        Button("Move Earlier") { c.moveTile(tile.id, .earlier) }.disabled(i == 0)
                        Button("Move Later") { c.moveTile(tile.id, .later) }.disabled(i == tiles.count - 1)
                        Button("Move to End") { c.moveTile(tile.id, .end) }.disabled(i == tiles.count - 1)
                    }
            } else {
                view
            }
        }
    }
}

/// Live reordering: tiles shift as the dragged tile passes over them.
struct ReorderDropDelegate: DropDelegate {
    let target: Tile
    @Binding var dragging: Tile?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d.id != target.id else { return }
        withAnimation(.easeInOut(duration: 0.15)) { move(d.id, target.id) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct LayoutPicker: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Picker("Layout", selection: $c.config.layout) {
            Label("Grid", systemImage: "square.grid.3x3").tag(Layout.grid)
            Label("Rows", systemImage: "list.bullet").tag(Layout.rows)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Session home screen

struct SessionHomeView: View {
    @EnvironmentObject var c: AppController
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    LayoutPicker()
                    Button { c.openSettings() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                searchField
                tiles
            }
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, HomeBar.height + 20)

            if c.confirmingExit {
                ExitConfirmView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: c.confirmingExit)
        .themed()
        .onAppear { searchFocused = true }
        .onChange(of: c.focusToken) { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Type to search apps and sites", text: $c.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .font(.system(size: 20))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        )
    }

    @ViewBuilder
    private var tiles: some View {
        let list = c.filteredTiles
        if c.config.tiles.isEmpty {
            emptyState("Nothing here yet", "Open Settings to choose the apps and sites for your focus space.")
        } else if list.isEmpty {
            emptyState("No matches", "Nothing called “\(c.query)”.")
        } else {
            GeometryReader { geo in
                let cols = GridLayout.columns(for: geo.size.width)
                ScrollViewReader { proxy in
                    ScrollView {
                        TileCollection(tiles: list, layout: c.config.layout, columns: cols, selection: c.selection)
                            .padding(4)
                    }
                    .onChange(of: c.selection) {
                        if list.indices.contains(c.selection) {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(list[c.selection].id) }
                        }
                    }
                }
                .onAppear { c.updateMetrics(columns: cols, height: geo.size.height) }
                .onChange(of: geo.size) { c.updateMetrics(columns: GridLayout.columns(for: geo.size.width), height: geo.size.height) }
            }
        }
    }

    private func emptyState(_ title: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            if c.config.tiles.isEmpty {
                Button("Open Settings") { c.openSettings() }.padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Exit Avadhāna?" with two equal choices and no timer. Esc stays, Return exits.
struct ExitConfirmView: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Exit Avadhāna?")
                    .font(.title2.weight(.semibold))
                Text("Your Dock and the apps you had open will come back.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { c.cancelEnd() } label: {
                        Text("Stay").frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.cocoa)
                    .controlSize(.large)
                    Button { c.endNow() } label: {
                        Text("Exit").frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                }
                .padding(.top, 4)
                Text("Esc to stay · Return to exit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
                    .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
            )
        }
    }
}

// MARK: - Setup window (outside a session)

struct SetupView: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Avadhāna").font(.largeTitle.bold())
                    Text("Cultivating your attention, one thing at a time.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { c.openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            if let err = c.configError {
                Notice(icon: "exclamationmark.triangle.fill", color: Theme.accent, text: err)
            }
            if !c.axTrusted {
                Notice(icon: "lock.fill", color: Theme.accent,
                       text: "Grant Accessibility access so Avadhāna can size windows and use the Home and Back shortcuts in other apps.") {
                    Button("Open Settings") { c.requestAccessibility() }
                }
            }

            HStack {
                Text("Your focus space").font(.headline)
                if !c.config.tiles.isEmpty {
                    Text("Drag, or right-click a tile, to arrange").foregroundStyle(.secondary)
                }
                Spacer()
                LayoutPicker()
            }

            Group {
                if c.config.tiles.isEmpty {
                    VStack(spacing: 8) {
                        Text("Nothing chosen yet.").foregroundStyle(.secondary)
                        Button("Choose apps and sites…") { c.openSettings() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        ScrollView {
                            TileCollection(tiles: c.config.tiles, layout: c.config.layout,
                                           columns: GridLayout.columns(for: geo.size.width - 32), arranging: true)
                                .padding(16)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.paperSoft)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            )

            Button { c.startSession() } label: {
                Text("Start Avadhāna").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 520)
        .themed()
    }
}

struct Notice<Accessory: View>: View {
    let icon: String
    let color: Color
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            accessory()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }
}

extension Notice where Accessory == EmptyView {
    init(icon: String, color: Color, text: String) {
        self.init(icon: icon, color: color, text: text) { EmptyView() }
    }
}
