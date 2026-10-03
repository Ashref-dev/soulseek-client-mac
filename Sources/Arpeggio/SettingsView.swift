import SwiftUI
import AppKit
import ArpeggioServices
import Persistence
import ServiceManagement

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Network", systemImage: "network") { NetworkSettings(model: model) }
            Tab("Transfers", systemImage: "arrow.up.arrow.down") { TransferSettings(model: model) }
            Tab("Sharing", systemImage: "externaldrive") { SharingSettings(model: model) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings(model: model) }
        }
        .frame(width: 540)
        .tint(.arpeggio)
        // Persist edits shortly after they settle instead of on every keystroke.
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
            Picker("Appearance", selection: $model.settings.appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle("Compact rows", isOn: $model.settings.compact)
            Toggle("Notify about messages and finished downloads", isOn: $model.settings.notifications)
        }
        .formStyle(.grouped)
        .frame(height: 280)
    }
}

private struct NetworkSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                TextField("Username", text: $model.settings.username)
                    .disabled(model.connection.isConnected || model.connection.isBusy)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.connection.tint).frame(width: 7, height: 7)
                        Text(model.connection.label)
                    }
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
                HStack {
                    Spacer()
                    if model.connection.isConnected {
                        Button("Disconnect") { Task { await model.disconnect() } }
                    } else {
                        Button("Reconnect") {
                            Task {
                                let password = await model.savedPassword()
                                await model.login(password: password)
                            }
                        }
                        .disabled(model.connection.isBusy || model.settings.username.isEmpty)
                        .help("Connect using the password saved in Keychain")
                    }
                }
            } footer: {
                Text("Server and port settings are in Advanced and apply the next time you connect.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}

private struct TransferSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Downloads") {
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
                Stepper("Simultaneous downloads: \(model.settings.downloadSlots)", value: $model.settings.downloadSlots, in: 1...20)
                TextField("Speed limit (KB/s, 0 = unlimited)", value: Binding(get: { model.settings.downloadLimitKB ?? 0 }, set: { model.settings.downloadLimitKB = max(0, $0) }), format: .number)
            }
            Section("Uploads") {
                Stepper("Upload slots: \(model.settings.uploadSlots)", value: $model.settings.uploadSlots, in: 1...20)
                TextField("Speed limit (KB/s, 0 = unlimited)", value: Binding(get: { model.settings.uploadLimitKB ?? 0 }, set: { model.settings.uploadLimitKB = max(0, $0) }), format: .number)
            }
        }
        .formStyle(.grouped)
        .frame(height: 350)
    }
}

private struct SharingSettings: View {
    @Bindable var model: AppModel
    @State private var selection: ShareFolder.ID?

    var body: some View {
        Form {
            Section {
                if model.settings.sharedFolders.isEmpty {
                    Text("No shared folders. Sharing helps the network and is expected by many peers.")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.settings.sharedFolders) { $folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                        for url in FolderPicker.choose(prompt: "Share", multiple: true)
                        where !model.settings.sharedFolders.contains(where: { $0.path == url.path }) {
                            model.settings.sharedFolders.append(ShareFolder(path: url.path))
                        }
                    }
                    Spacer()
                    if model.indexing { ProgressView().controlSize(.small) }
                    Button("Rescan Now") {
                        Task { await model.saveSettings(); await model.rescanShares() }
                    }
                    .disabled(model.indexing)
                }
            } header: {
                Text("Shared Folders")
            } footer: {
                Text("Trusted-only folders are visible to users you mark as trusted. Hidden files and symbolic links are never shared.")
                    .foregroundStyle(.secondary)
            }
            Section("Index") {
                TextField("Exclude names (comma-separated globs)", text: Binding(get: { (model.settings.shareExclusions ?? []).joined(separator: ", ") }, set: { model.settings.shareExclusions = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .help("Examples: *.tmp, *.partial, Artwork. Matches file or folder names, case-insensitively.")
                LabeledContent("Files", value: model.sharedCount.formatted())
                LabeledContent("Size", value: Format.bytes(model.sharedBytes))
                if !model.shareErrors.isEmpty {
                    DisclosureGroup("\(model.shareErrors.count) items could not be read") {
                        ForEach(model.shareErrors.prefix(50), id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}

private struct AdvancedSettings: View {
    @Bindable var model: AppModel

    private var log: String { model.diagnostics.joined(separator: "\n") }
    /// Display-only: consecutive repeats (e.g. one refused socket per retry) collapse into a single counted line.
    private var displayLog: String {
        var runs: [(line: String, count: Int)] = []
        for line in model.diagnostics {
            if let last = runs.last, last.line == line { runs[runs.count - 1].count += 1 } else { runs.append((line, 1)) }
        }
        return runs.map { $0.count > 1 ? "\($0.line)  (×\($0.count))" : $0.line }.joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.connection.tint).frame(width: 7, height: 7)
                        Text(model.connection.label)
                    }
                }
                if let reason = model.connection.failureReason {
                    LabeledContent("Last error") {
                        Text(DiagnosticDigest.headline(reason)).lineLimit(4).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                if model.privilegeSeconds > 0 {
                    LabeledContent("Privileges", value: Format.duration(Double(model.privilegeSeconds)))
                }
            } header: {
                Text("Connection")
            }
            Section {
                TextField("Server", text: $model.settings.server)
                TextField("Server port", value: $model.settings.port, format: .number.grouping(.never))
                LabeledContent("Target") {
                    Label(model.settings.targetDescription,
                          systemImage: model.settings.isSoulseekServer ? "globe" : model.settings.isLocalServer ? "exclamationmark.triangle.fill" : "server.rack")
                        .foregroundStyle(model.settings.isLocalServer ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                HStack {
                    if model.settings.isLocalServer {
                        Text("Local test servers are developer fixtures. Their accounts and files aren’t on Soulseek.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                TextField("Listening port", value: $model.settings.listeningPort, format: .number.grouping(.never))
                    .help("Other peers connect to this port. Forward it in your router for best connectivity.")
            } header: {
                Text("Incoming Connections")
            } footer: {
                Text("Peers that can’t reach your listening port fall back to indirect connections, which fail if neither side is reachable.")
                    .foregroundStyle(.secondary)
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
        .frame(height: 600)
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
