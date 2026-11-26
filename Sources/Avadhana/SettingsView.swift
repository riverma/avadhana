import AppKit
import SwiftUI

/// Everything in config.json, editable without touching the file. Changes save immediately.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppsSettings().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SitesSettings().tabItem { Label("Sites", systemImage: "globe") }
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            CreditsView().tabItem { Label("Credits", systemImage: "heart") }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .themed()
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section("Home screen") {
                Picker("Layout", selection: $c.config.layout) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(Layout.grid)
                    Label("Rows", systemImage: "list.bullet").tag(Layout.rows)
                }
                .pickerStyle(.inline)
            }
            Section("While Avadhāna is on") {
                Toggle("Hide the Dock", isOn: $c.config.hideDockDuringSession)
                Toggle("Hide the menu bar", isOn: $c.config.hideMenuBarDuringSession)
            }
            Section {
                Picker("Open sites in", selection: browserBinding) {
                    ForEach(BrowserKind.installed) { kind in
                        HStack(spacing: 8) {
                            if let url = kind.appURL {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 18, height: 18)
                            }
                            Text(kind.displayName)
                        }
                        .tag(kind)
                    }
                }
                .pickerStyle(.inline)
                Toggle("Open web links from my sites", isOn: $c.config.openLinks)
                Toggle("Open web links from my apps", isOn: $c.config.openAppLinks)
                Toggle("Hide address bar and tabs for browsers I've added", isOn: $c.config.hideBrowserChrome)
                BrowserStartPageField()
                    .disabled(!c.config.hideBrowserChrome)
            } header: {
                Text("Web browser")
            }
            Section {
                HStack {
                    Text("Settings are saved automatically to config.json.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { c.revealConfig() }
                }
            }
            UpdateSettings()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Shows Safari when the saved browser has been uninstalled.
    private var browserBinding: Binding<BrowserKind> {
        Binding(get: { c.config.effectiveBrowser }, set: { c.config.browser = $0 })
    }
}

/// Where a browser opens when its address bar is hidden. Cleaned up when the field loses focus.
struct BrowserStartPageField: View {
    @EnvironmentObject var c: AppController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Browsers open to") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $text, prompt: Text(Config.defaultBrowserStartPage))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                Text("Used when a browser you've added opens without an address bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = c.config.browserStartPage }
    }

    private func commit() {
        let cleaned = Config.normalizedAddress(text)
        text = cleaned
        if cleaned != c.config.browserStartPage { c.config.browserStartPage = cleaned }
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    @EnvironmentObject var c: AppController
    @EnvironmentObject var updater: Updater

    var body: some View {
        Section {
            LabeledContent("Version", value: AppInfo.versionLine)
            if let updated = AppInfo.lastUpdated {
                LabeledContent("Last updated", value: updated)
            }
            status
            Toggle("Check for updates automatically", isOn: $c.config.checkForUpdates)
        } header: {
            Text("Updates")
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle, .upToDate:
            HStack {
                Text(updater.state == .upToDate ? "Avadhāna is up to date." : "Not checked yet.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check now") { updater.check(force: true) }
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .available(let release):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Version \(release.version) is available.", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("What's new") { c.openWebPage(release.pageURL) }
                    Button("Update") { updater.install(release) }
                        .buttonStyle(.borderedProminent)
                        .disabled(c.inSession)
                }
                Text(c.inSession ? "Exit Avadhāna to update." : "Avadhāna will reopen when the update is done.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .updating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            }
        case .failed(let message, let release):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Download") { c.openWebPage(release?.pageURL ?? Release.allReleasesPage) }
                    Button("Try again") {
                        if let release { updater.install(release) } else { updater.check(force: true) }
                    }
                    .disabled(release != nil && c.inSession)
                }
            }
        }
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @EnvironmentObject var c: AppController
    @State private var installed: [InstalledApp] = []
    @State private var search = ""
    @State private var addedOnly = false

    private var addedIDs: Set<String> { Set(c.config.apps.map(\.bundleID)) }

    private var visible: [InstalledApp] {
        installed.filter { app in
            (!addedOnly || addedIDs.contains(app.bundleID))
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $search).textFieldStyle(.plain)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Toggle("Added only", isOn: $addedOnly)
            }

            List(visible) { app in
                let added = addedIDs.contains(app.bundleID)
                HStack(spacing: 10) {
                    Button {
                        binding(for: app).wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: added ? "checkmark.square.fill" : "square")
                                .font(.system(size: 15))
                                .foregroundStyle(added ? Theme.accent : .secondary)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 24, height: 24)
                            Text(app.name)
                            Spacer()
                            if added {
                                Text("Added").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Text("\(c.config.apps.count) added · The browser used for sites is set under General.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add app from elsewhere…", action: addOther)
            }
        }
        .onAppear(perform: rescan)
    }

    private func rescan() {
        installed = InstalledApp.scan(including: c.config.apps)
    }

    private func binding(for app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { c.config.apps.contains { $0.bundleID == app.bundleID } },
            set: { on in
                if on {
                    if !c.config.apps.contains(where: { $0.bundleID == app.bundleID }) {
                        c.config.apps.append(AppTile(name: app.name, bundleID: app.bundleID))
                    }
                } else {
                    c.config.apps.removeAll { $0.bundleID == app.bundleID }
                }
            }
        )
    }

    private func addOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  !c.config.apps.contains(where: { $0.bundleID == id }) else { continue }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            c.config.apps.append(AppTile(name: name, bundleID: id))
        }
        rescan()
    }
}

// MARK: - Sites

struct SiteDraft: Identifiable {
    let id = UUID()
    var index: Int?          // nil = new site
    var name: String
    var url: String
    var domains: String      // comma or newline separated

    init(index: Int?, site: SiteTile?) {
        self.index = index
        name = site?.name ?? ""
        url = site?.url ?? ""
        domains = site?.allowedDomains.joined(separator: ", ") ?? ""
    }

    /// Accepts a web address ("github.com", "https://…"), a file: URL, or a path ("/…", "~/…").
    /// Web addresses need a real host name; local files must exist.
    var resolvedURL: URL? {
        var t = url.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.lowercased().hasPrefix("file:") {
            t = t.replacingOccurrences(of: "\\", with: "/")   // accept file:\path as file:/path
        }
        if t.hasPrefix("/") || t.hasPrefix("~") {
            let path = (t as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        // Local addresses (localhost:3000, 192.168.1.20) are usually plain http dev servers.
        let typedHost = String(t.prefix { $0 != ":" && $0 != "/" })
        let scheme = Links.isLocalHost(typedHost) ? "http://" : "https://"
        let candidate = (t.contains("://") || t.lowercased().hasPrefix("file:")) ? t : scheme + t
        guard let u = SiteTile.openableURL(candidate) else { return nil }
        if !u.isFileURL, u.host?.contains(".") != true, !Links.isLocalHost(u.host ?? "") { return nil }
        return u
    }

    var isLocalFile: Bool { resolvedURL?.isFileURL == true }

    /// The web host without "www." (nil for local files).
    var host: String? {
        guard let u = resolvedURL, !u.isFileURL, let h = u.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Fills in a name and allowed domain from the address when they're left blank.
    func toTile() -> SiteTile? {
        guard var u = resolvedURL else { return nil }
        if u.isFileURL { u = URL(fileURLWithPath: u.path) }   // always stored as file:///…
        let parsed = domains
            .components(separatedBy: CharacterSet(charactersIn: ",\n "))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let fallbackName: String
        if let host, Links.isLocalHost(host) {
            fallbackName = u.port.map { "\(host):\($0)" } ?? host
        } else if let host {
            fallbackName = host.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? host
        } else {
            fallbackName = u.deletingPathExtension().lastPathComponent
        }
        return SiteTile(name: trimmedName.isEmpty ? fallbackName : trimmedName,
                        url: u.absoluteString,
                        allowedDomains: parsed.isEmpty ? host.map { [$0] } ?? [] : parsed)
    }
}

struct SitesSettings: View {
    @EnvironmentObject var c: AppController
    @State private var editing: SiteDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if c.config.sites.isEmpty {
                VStack(spacing: 8) {
                    Text("No sites yet").font(.headline)
                    Text("Add the few sites you need while focusing, like GitHub or your docs.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(c.config.sites.enumerated()), id: \.offset) { i, site in
                        HStack(spacing: 12) {
                            SiteIcon(name: site.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name)
                                Text(site.url).font(.caption).foregroundStyle(.secondary)
                                if !site.allowedDomains.isEmpty {
                                    Text("Allowed: " + site.allowedDomains.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Preview") { c.open(.site(site)) }
                            Button("Edit") { editing = SiteDraft(index: i, site: site) }
                            Button("Remove") { c.config.sites.remove(at: i) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            HStack {
                Text("\(c.config.sites.count) added · Sites open in \(c.config.effectiveBrowser.displayName).")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = SiteDraft(index: nil, site: nil)
                } label: {
                    Label("Add site", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { draft in
            SiteEditor(draft: draft,
                       browser: c.config.effectiveBrowser,
                       takenURLs: Set(c.config.sites.enumerated().filter { $0.offset != draft.index }.map(\.element.url))) { tile in
                if let i = draft.index, c.config.sites.indices.contains(i) {
                    let oldID = c.config.sites[i].id
                    var updated = c.config
                    updated.sites[i] = tile
                    updated.renameTileID(oldID, to: tile.id)   // keep its place on the home screen
                    c.config = updated
                } else {
                    c.config.sites.append(tile)
                }
            }
        }
    }
}

struct SiteEditor: View {
    @State var draft: SiteDraft
    let browser: BrowserKind
    /// Start pages of the other sites, to prevent adding the same one twice.
    let takenURLs: Set<String>
    let onSave: (SiteTile) -> Void

    private var tile: SiteTile? { draft.toTile() }
    private var isDuplicate: Bool { tile.map { takenURLs.contains($0.url) } ?? false }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.index == nil ? "Add site" : "Edit site").font(.title2.weight(.semibold))

            Form {
                TextField("Start page", text: $draft.url, prompt: Text("github.com or /path/to/page.html"))
                TextField("Name", text: $draft.name, prompt: Text(draft.toTile()?.name ?? "GitHub"))
                TextField("Allowed domains", text: $draft.domains,
                          prompt: Text(draft.host ?? "github.com, githubusercontent.com"), axis: .vertical)
                    .lineLimit(2...4)
                Text(draft.isLocalFile
                     ? "A page on this Mac. It can link to other files in the same folder; links to websites only open for the domains listed here."
                     : browser == .safari
                     ? "Subdomains are included. Links to other sites won't open. Sign-in pages often live on other domains, like accounts.google.com."
                     : "Subdomains are included. Links to other sites are blocked when sites open in Safari (Settings → General).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !draft.url.trimmingCharacters(in: .whitespaces).isEmpty && tile == nil {
                    Label("Enter a web address, or the path of a file that exists on this Mac.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                if isDuplicate {
                    Label("This start page has already been added.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let tile, !isDuplicate { onSave(tile); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(tile == nil || isDuplicate)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettings: View {
    @EnvironmentObject var c: AppController

    private let fixedKeys: [(String, String)] = [
        ("Just type", "Search apps and sites"),
        ("← ↑ → ↓", "Move the highlight"),
        ("Page Up / Page Down", "Move a screenful at a time"),
        ("Home / End", "First / last tile"),
        ("Return", "Open the highlighted tile"),
        ("Esc", "Clear the search, or stay when asked to exit"),
        ("⌘Q", "Exit Avadhāna (asks Stay or Exit)"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases.filter(\.isGlobal)) { ShortcutRow(action: $0) }
            } header: {
                Text("In any app while Avadhāna is on")
            } footer: {
                Text("These work in every app while Avadhāna is on and take priority over the app's own shortcuts, so pick keys your apps don't use. \u{201C}Ignore while typing\u{201D} lets the key through whenever a text field has focus (handy for ⌘⌫, which apps use to delete text); it needs Accessibility access.")
                    .foregroundStyle(.secondary)
            }
            Section("When Avadhāna is in front") {
                ForEach(ShortcutAction.allCases.filter { !$0.isGlobal }) { ShortcutRow(action: $0) }
            }
            Section("Home Screen") {
                ForEach(fixedKeys, id: \.0) { keys, action in
                    LabeledContent(keys) { Text(action).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Leaving this tab mid-recording would otherwise leave every shortcut switched off.
        .onDisappear { c.endRecording() }
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var c: AppController
    let action: ShortcutAction

    private var setting: ShortcutSetting { c.config.shortcut(action) }

    /// Another enabled shortcut with the same keys.
    private var clash: ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && c.config.shortcut(other).enabled && c.config.shortcut(other).combo == setting.combo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { setting.enabled }, set: { v in c.updateShortcut(action) { $0.enabled = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                        Text(action.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                ShortcutRecorder(action: action)
                    .disabled(!setting.enabled)
                Button("Reset") { c.resetShortcut(action) }
                    .disabled(setting == action.defaultSetting)
            }
            if action.isGlobal {
                Toggle("Ignore while typing in a text field",
                       isOn: Binding(get: { setting.ignoreWhileTyping }, set: { v in c.updateShortcut(action) { $0.ignoreWhileTyping = v } }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(!setting.enabled)
                    .padding(.leading, 22)
            }
            if setting.enabled && c.unavailableShortcuts.contains(action) {
                warning("Another app is already using \(setting.combo.display). Pick different keys.")
            } else if setting.enabled && action.isGlobal && setting.ignoreWhileTyping && !c.axTrusted {
                warning("\u{201C}Ignore while typing\u{201D} needs Accessibility access to work in other apps.")
            } else if setting.enabled, let clash {
                warning("Same keys as \u{201C}\(clash.title)\u{201D}.")
            } else if setting.enabled && action.isGlobal && setting.combo.isCommonAppShortcut && !setting.ignoreWhileTyping {
                warning("Many apps use \(setting.combo.display) for something else.")
            }
        }
        .padding(.vertical, 2)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .padding(.leading, 22)
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @EnvironmentObject var c: AppController
    let action: ShortcutAction

    private var recording: Bool { c.recordingAction == action }

    var body: some View {
        Button {
            recording ? c.endRecording() : c.beginRecording(action)
        } label: {
            Text(recording ? "Press keys…" : c.config.shortcut(action).combo.display)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .tint(recording ? Theme.accent : nil)
    }
}

// MARK: - Credits

enum AppInfo {
    static let donateURL = URL(string: "https://buy.stripe.com/9B6eVe8Gf4Bt21I6HFgrS00")!

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    /// The git commit the app was built from, stamped into Info.plist by build.sh.
    static var commit: String? { Bundle.main.infoDictionary?["AvadhanaCommit"] as? String }

    static var versionLine: String {
        commit.map { "\(version) (\($0))" } ?? version
    }

    /// The date of that commit.
    static var lastUpdated: String? {
        guard let raw = Bundle.main.infoDictionary?["AvadhanaDate"] as? String,
              let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }
}

struct CreditsView: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                VStack(spacing: 4) {
                    Text("Avadhāna").font(.largeTitle.bold())
                    Text("अवधान · attention, concentration")
                        .foregroundStyle(.secondary)
                    Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Why Avadhāna")
                        .font(.headline)
                    Text("A computer puts the entire world one click away. Every app, every site, every notification, from anything and anywhere, can reach you. Each one competes for your attention, and it's easy to drift from what you sat down to do.")
                    Text("What if you could choose more intentionally what reaches you, and what you put your attention on?")
                        .fontWeight(.medium)
                    Text("With Avadhāna you choose the few apps and sites that matter, and use them one at a time, with nothing else on screen.")
                }
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                Divider().frame(maxWidth: 480)

                VStack(spacing: 10) {
                    Text("Created by Rishi Verma")
                    Button {
                        c.openWebPage(AppInfo.donateURL)
                    } label: {
                        Label("Donate", systemImage: "heart.fill")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    Text("Donations support development of Avadhāna and other apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
