import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArpeggioServices
import Persistence
import ServiceManagement

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings(model: model) }
            Tab("Account", systemImage: "person.badge.key", value: SettingsTab.account) { AccountSettings(model: model) }
            Tab("Network", systemImage: "network", value: SettingsTab.network) { NetworkSettingsView(model: model) }
            Tab("Profile", systemImage: "person.crop.circle", value: SettingsTab.profile) { ProfileSettings(model: model) }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: SettingsTab.transfers) { TransferSettings(model: model) }
            Tab("Sharing", systemImage: "externaldrive", value: SettingsTab.sharing) { SharingSettings(model: model) }
            Tab("Statistics", systemImage: "chart.bar.xaxis", value: SettingsTab.statistics) { StatisticsSettings(model: model) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver", value: SettingsTab.advanced) { AdvancedSettings(model: model) }
        }
        .frame(width: 600)
        .tint(.arpeggio)
        .task(id: try? JSONEncoder().encode(model.settings)) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await model.saveSettings()
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Arpeggio at login", isOn: Binding(get: { loginEnabled }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = value; loginError = nil
                    } catch { loginError = "Couldn’t update the login item. Install Arpeggio in Applications and try again." }
                }))
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
                Toggle("Show Arpeggio in the menu bar", isOn: Binding(get: { model.settings.showsMenuBarIcon }, set: { model.settings.menuBarIcon = $0 }))
                Toggle("Hide the Dock icon while the window is closed", isOn: Binding(get: { model.settings.hideDockWhenClosed ?? false }, set: { model.settings.hideDockWhenClosed = $0 }))
                    .disabled(!model.settings.showsMenuBarIcon)
            } header: {
                Text("Background")
            } footer: {
                Text("Closing the window keeps Arpeggio connected and sharing. Quit from the menu bar icon or with ⌘Q.").foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $model.settings.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("Compact rows", isOn: $model.settings.compact)
                Toggle("Notify about messages and finished downloads", isOn: $model.settings.notifications)
            }
            Section {
                Toggle("Set my status to Away when I’m idle", isOn: Binding(get: { model.settings.goesAwayWhenIdle }, set: { model.settings.awayWhenIdle = $0 }))
                if model.settings.goesAwayWhenIdle {
                    Stepper("After \(model.settings.idleAwayMinutes) minutes without using the Mac",
                            value: Binding(get: { model.settings.idleAwayMinutes }, set: { model.settings.idleMinutes = $0 }), in: 1...120)
                }
            } header: {
                Text("Status")
            }
            Section {
                Toggle("Stop searches automatically", isOn: Binding(
                    get: { model.settings.searchAutoStopSeconds > 0 },
                    set: { model.settings.searchIdleSeconds = $0 ? 15 : 0 }))
                if model.settings.searchAutoStopSeconds > 0 {
                    Stepper("After \(model.settings.searchAutoStopSeconds) seconds without new results",
                            value: Binding(get: { model.settings.searchAutoStopSeconds }, set: { model.settings.searchIdleSeconds = $0 }),
                            in: 5...120, step: 5)
                }
            } header: {
                Text("Search")
            } footer: {
                Text("Soulseek has no end-of-search signal, so peers keep answering while a search is open. Searches also end after 2 minutes at most.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { model.settings.checksForUpdates }, set: { model.settings.checkForUpdates = $0 }))
                HStack {
                    Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    updateStatus
                    Button("Check Now") { Task { await model.checkForUpdates() } }
                        .disabled(model.update == .checking)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates come from GitHub Releases and are installed only if they’re signed by the same developer as this copy.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }

    @ViewBuilder private var updateStatus: some View {
        switch model.update {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("Up to date").foregroundStyle(.green)
        case .available(let release): Text("\(release.version) available").foregroundStyle(Color.arpeggio)
        case .downloading: Text("Downloading…").foregroundStyle(.secondary)
        case .failed: Text("Check failed").foregroundStyle(.orange)
        default: EmptyView()
        }
    }
}

private struct AccountSettings: View {
    @Bindable var model: AppModel
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $model.settings.username)
                    .disabled(model.connection.isConnected || model.connection.isBusy)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.statusTint).frame(width: 7, height: 7)
                        Text(model.statusText)
                    }
                }
                if model.connection.isConnected {
                    Picker("Show me as", selection: Binding(get: { model.settings.isAway }, set: { value in Task { await model.setAway(value) } })) {
                        Text("Available").tag(false)
                        Text("Away").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                LabeledContent("Server") {
                    HStack(spacing: 4) {
                        if !model.settings.isLocalServer { Text(model.settings.targetDescription).foregroundStyle(.secondary); Text("·").foregroundStyle(.tertiary) }
                        ServerTargetText(settings: model.settings)
                    }
                    .lineLimit(1)
                }
            } header: {
                Text("Account")
            } footer: {
                Text(model.settings.isLocalServer
                     ? "This is a local test server, not the Soulseek network. Change it in Advanced."
                     : "Passwords you choose to remember are stored in the macOS Keychain. Soulseek sends them to the server unencrypted.")
                    .foregroundStyle(model.settings.isLocalServer ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Section {
                Toggle("Connect automatically when Arpeggio opens", isOn: Binding(
                    get: { model.settings.connectsAutomatically }, set: { model.settings.autoConnect = $0 }))
                    .help("Uses the password saved in Keychain. Sign Out forgets it.")
                HStack {
                    Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                        .disabled(model.settings.username.isEmpty)
                        .help("Disconnect and forget the saved password so you can use another account")
                    Spacer()
                    if model.connection.isConnected {
                        Button("Disconnect") { Task { await model.disconnect() } }
                    } else {
                        Button("Reconnect") { model.reconnect(nil) }
                            .disabled(model.connection.isBusy || model.settings.username.isEmpty)
                            .help("Connect using the password saved in Keychain")
                    }
                }
            }
            Section {
                LabeledContent("Listening port") {
                    HStack(spacing: 8) {
                        Text(String(model.settings.listeningPort)).monospacedDigit()
                        SettingsDestinationLink(destination: .network, model: model) { Text("Network Settings…") }
                    }
                }
            } footer: {
                Text("Port forwarding, router mapping and reachability checks are in Network.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        .confirmationDialog("Sign out of \(model.settings.username)?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Arpeggio disconnects and forgets the saved password. Downloads, history and settings stay on this Mac.")
        }
    }
}

private struct ProfileSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ProfileAvatar(model: model, size: 88, showsPresence: false)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first else { return false }
                            model.setProfilePicture(from: url); return true
                        }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.accountName).font(.title3.weight(.semibold))
                        HStack {
                            Button("Choose Picture…") { choosePicture() }
                            if model.profilePicture != nil {
                                Button("Remove", role: .destructive) { model.clearProfilePicture() }
                            }
                        }
                        Text("Drop an image on the picture or choose one. It’s resized to 512 px.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Picture")
            }
            Section {
                TextEditor(text: Binding(get: { model.settings.profileDescription ?? "" }, set: { model.settings.profileDescription = String($0.prefix(4000)) }))
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("About Me")
            } footer: {
                Text("People see your picture and this text when they view your profile, along with your upload slots and queue.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Picture"
        if panel.runModal() == .OK, let url = panel.url { model.setProfilePicture(from: url) }
    }
}

private struct TransferSettings: View {
    @Bindable var model: AppModel

    private var example: String {
        let folder = (model.settings.downloadDirectory as NSString).abbreviatingWithTildeInPath
        var parts = [folder]
        if model.settings.userFolders == true { parts.append("someuser") }
        parts.append(model.settings.fullRemotePaths == true ? "Music/Artist/Album" : "Album")
        parts.append("01 Track.flac")
        return parts.joined(separator: "/")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text((model.settings.downloadDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .help(model.settings.downloadDirectory)
                        Button("Choose…") {
                            if let url = FolderPicker.choose(prompt: "Use Folder", multiple: false).first {
                                model.settings.downloadDirectory = url.path
                            }
                        }
                    }
                }
                Toggle("Put each user’s files in their own folder", isOn: Binding(get: { model.settings.userFolders ?? false }, set: { model.settings.userFolders = $0 }))
                Toggle("Keep the sharer’s full folder path", isOn: Binding(get: { model.settings.fullRemotePaths ?? false }, set: { model.settings.fullRemotePaths = $0 }))
                Stepper("Simultaneous downloads: \(model.settings.downloadSlots)", value: $model.settings.downloadSlots, in: 1...20)
                TextField("Speed limit (KB/s, 0 = unlimited)", value: Binding(get: { model.settings.downloadLimitKB ?? 0 }, set: { model.settings.downloadLimitKB = max(0, $0) }), format: .number)
                Toggle("Remove finished downloads from the list", isOn: Binding(get: { model.settings.autoClearDownloads ?? false }, set: { model.settings.autoClearDownloads = $0 }))
            } header: {
                Text("Downloads")
            } footer: {
                Text("Example: \(example). Unfinished files wait in a hidden folder and appear only when complete.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper("Upload slots: \(model.settings.uploadSlots)", value: $model.settings.uploadSlots, in: 1...20)
                TextField("Speed limit (KB/s, 0 = unlimited)", value: Binding(get: { model.settings.uploadLimitKB ?? 0 }, set: { model.settings.uploadLimitKB = max(0, $0) }), format: .number)
                Stepper(model.settings.uploadQueueLimit == 0 ? "Queued files per user: unlimited" : "Queued files per user: \(model.settings.uploadQueueLimit)",
                        value: Binding(get: { model.settings.uploadQueueLimit }, set: { model.settings.queuedUploadsPerUser = $0 }), in: 0...1000, step: 50)
            } header: {
                Text("Uploads")
            } footer: {
                Text("Requests beyond the per-user queue limit are politely refused with “Too many files”. To require sharing before people download from you, see Sharing.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

private struct SharingSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.settings.sharedFolders.isEmpty {
                    Text("No shared folders. Sharing helps the network and is expected by many people.")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.settings.sharedFolders) { $folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Color.arpeggio)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                            Text(summary(folder)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Toggle("Trusted users only", isOn: $folder.buddyOnly)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        Button("Remove", systemImage: "minus.circle") {
                            model.settings.sharedFolders.removeAll { $0.id == folder.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus") {
                        let urls = FolderPicker.choose(prompt: "Share", multiple: true)
                        Task { await model.share(urls) }
                    }
                    Spacer()
                    if model.indexing { ProgressView().controlSize(.small) }
                    Button("Rescan Now") { Task { await model.saveSettings(); await model.rescanShares() } }
                        .disabled(model.indexing)
                }
            } header: {
                Text("Shared Folders")
            } footer: {
                Text("Shared Files in the sidebar shows each folder in detail and accepts folders dropped from Finder.")
                    .foregroundStyle(.secondary)
            }
            Section("Require Sharing") {
                SharingRequirementControls(model: model)
            }
            Section("Index") {
                if model.indexing { Text(model.shareProgress.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                TextField("Exclude names (comma-separated patterns)", text: Binding(get: { (model.settings.shareExclusions ?? []).joined(separator: ", ") }, set: { model.settings.shareExclusions = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .help("Examples: *.tmp, *.cue, Artwork. Matches file or folder names, case-insensitively.")
                LabeledContent("Files", value: model.sharedCount.formatted())
                LabeledContent("Size", value: Format.bytes(model.sharedBytes))
            }
        }
        .formStyle(.grouped)
        .frame(height: 680)
    }

    private func summary(_ folder: ShareFolder) -> String {
        let path = (folder.path as NSString).abbreviatingWithTildeInPath
        guard let summary = model.shareSummaries[folder.path] else { return path }
        return "\(summary.files.formatted()) files · \(Format.bytes(summary.bytes)) · \(path)"
    }
}

private struct AdvancedSettings: View {
    @Bindable var model: AppModel
    @State private var confirmClearHistory = false

    private var log: String { model.diagnostics.joined(separator: "\n") }
    private var displayLog: String {
        var runs: [(line: String, count: Int)] = []
        for line in model.diagnostics {
            if let last = runs.last, last.line == line { runs[runs.count - 1].count += 1 } else { runs.append((line, 1)) }
        }
        return runs.map { $0.count > 1 ? "\($0.line)  (×\($0.count))" : $0.line }.joined(separator: "\n")
    }

    var body: some View {
        Form {
            if model.settingsRecovery != nil { SettingsRecoverySection(model: model) }
            Section {
                TextField("Server", text: $model.settings.server)
                TextField("Server port", value: $model.settings.port, format: .number.grouping(.never))
                LabeledContent("Target") {
                    Label(model.settings.targetDescription,
                          systemImage: model.settings.isSoulseekServer ? "globe" : model.settings.isLocalServer ? "exclamationmark.triangle.fill" : "server.rack")
                        .foregroundStyle(model.settings.isLocalServer ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                if let reason = model.connection.failureReason {
                    LabeledContent("Last error") {
                        Text(DiagnosticDigest.headline(reason)).lineLimit(4).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                if model.privilegeSeconds > 0 {
                    LabeledContent("Privileges", value: Format.duration(Double(model.privilegeSeconds)))
                }
                HStack {
                    Spacer()
                    Button("Restore Default Server") { Task { await model.useSoulseekServer() } }
                        .disabled(model.settings.isSoulseekServer)
                        .help("Switch to \(AppSettings.soulseekEndpoint). Username, password and other settings are kept.")
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Default: \(AppSettings.soulseekEndpoint). Changes apply the next time you connect.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Export…") { exportConfiguration() }
                    Button("Import…") { importConfiguration() }
                    Spacer()
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("Exports settings, your user list and wishlist as JSON. Passwords are never included.").foregroundStyle(.secondary)
            }
            Section("Privacy and Setup") {
                HStack {
                    Button("Clear Search History…") { confirmClearHistory = true }
                        .disabled(model.history.isEmpty)
                    Spacer()
                    Button("Show Welcome Again") { model.settings.onboardingVersion = nil }
                }
            }
            Section {
                Group {
                    if model.diagnostics.isEmpty {
                        Text("No diagnostic messages yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        ScrollView {
                            Text(displayLog)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(height: 150)
                        .accessibilityLabel("Diagnostic log, \(model.diagnostics.count) entries")
                    }
                }
                HStack {
                    Text("\(model.diagnostics.count) of 200 recent entries").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log, forType: .string)
                    }
                    Button("Clear") { model.diagnostics.removeAll() }
                }
                .disabled(model.diagnostics.isEmpty)
                .controlSize(.small)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Protocol and peer messages useful when reporting problems. Review before sharing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .confirmationDialog("Clear all \(model.history.count) recent searches?", isPresented: $confirmClearHistory) {
            Button("Clear History", role: .destructive) { Task { await model.clearSearchHistory() } }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Arpeggio Configuration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportConfiguration(to: url) } catch { model.error = error.localizedDescription }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.importConfiguration(from: url) } catch { model.error = "That file isn’t an Arpeggio configuration. \(error.localizedDescription)" }
        }
    }
}

/// Explains a settings record that could not be read and offers only explicit, user-chosen recovery.
/// Nothing is overwritten until the person imports a configuration or resets, and both keep a backup.
struct SettingsRecoverySection: View {
    let model: AppModel
    @State private var confirmReset = false
    @State private var status: String?

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved settings need attention").font(.headline)
                    Text(model.settingsRecovery?.reason ?? "")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Arpeggio is not signing in and will not save over the original settings until you choose an option below.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Button("Save a Copy…") { saveCopy() }
                    .help("Save the unreadable settings exactly as they are, for support or manual repair")
                Button("Import Configuration…") { importConfiguration() }
                    .help("Replace the unreadable settings with an exported Arpeggio configuration. A backup is kept.")
                Spacer()
                Button("Reset Settings…", role: .destructive) { confirmReset = true }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Recovery")
        }
        .confirmationDialog("Reset settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset Settings", role: .destructive) {
                Task {
                    do { try await model.resetSettingsRecovery(); status = nil }
                    catch { status = "Couldn’t reset settings. \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("A backup of the unreadable settings is kept. Downloads, transfer history, statistics and your saved password are not affected. New settings use listening port \(String(AppSettings().listeningPort)); set your previous port again in Network if your router forwards a different one.")
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Arpeggio Settings Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.backupSettingsRecovery(to: url); status = "Saved a copy to \(url.lastPathComponent)." }
            catch { status = "Couldn’t save the copy. \(error.localizedDescription)" }
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.importConfiguration(from: url); status = nil }
            catch { status = "That file isn’t a valid Arpeggio configuration. \(error.localizedDescription)" }
        }
    }
}

/// Opens Settings on a specific tab, for deep links from banners, errors and other settings.
struct SettingsDestinationLink<Label: View>: View {
    let tab: SettingsTab
    let model: AppModel
    @ViewBuilder let label: () -> Label
    @Environment(\.openSettings) private var openSettings

    init(destination: SettingsDestination, model: AppModel, @ViewBuilder label: @escaping () -> Label) {
        self.init(tab: destination.tab, model: model, label: label)
    }

    init(tab: SettingsTab, model: AppModel, @ViewBuilder label: @escaping () -> Label) {
        self.tab = tab; self.model = model; self.label = label
    }

    var body: some View {
        Button { model.settingsTab = tab; openSettings() } label: { label() }
            .buttonStyle(.link)
    }
}

@MainActor
enum FolderPicker {
    static func choose(prompt: String, multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
    }
}
