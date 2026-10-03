import SwiftUI
import ArpeggioServices
import SoulseekCore
import TransferEngine
import Persistence

struct RootView: View {
    @Bindable var model: AppModel
    let bootstrap: Bootstrap
    @State private var navigator = Navigator()
    @SceneStorage("Arpeggio.selectedSection") private var restoredSection = SidebarSection.search.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, navigator: navigator)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let error = model.error {
                        ErrorBanner(model: model, message: error) { model.error = nil }
                    }
                }
        }
        .frame(minWidth: 880, minHeight: 560)
        .tint(.arpeggio)
        .preferredColorScheme(model.settings.appearance == "light" ? .light : model.settings.appearance == "dark" ? .dark : nil)
        .environment(\.defaultMinListRowHeight, model.settings.compact ? 22 : 28)
        .focusedSceneValue(\.navigator, navigator)
        .sheet(isPresented: $navigator.showLogin) { LoginSheet(model: model) }
        .sheet(isPresented: $navigator.showPalette) { CommandPalette(model: model, navigator: navigator) }
        .sheet(item: $navigator.prompt) { prompt in UserPromptSheet(prompt: prompt, model: model, navigator: navigator) }
        .sheet(item: $navigator.profile) { request in UserProfileSheet(username: request.username, model: model, navigator: navigator) }
        .task { await bootstrap.start(model) }
        .onAppear { navigator.section = SidebarSection(rawValue: restoredSection) ?? .search }
        .onChange(of: navigator.section) { _, section in if let section { restoredSection = section.rawValue } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.error)
        .onChange(of: model.unread.count) { _, count in NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil }
    }

    @ViewBuilder private var detail: some View {
        switch navigator.section ?? .search {
        case .search: SearchView(model: model, navigator: navigator)
        case .downloads: TransfersView(model: model, navigator: navigator, upload: false)
        case .uploads: TransfersView(model: model, navigator: navigator, upload: true)
        case .browse: BrowseView(model: model, navigator: navigator)
        case .wishlist: WishlistView(model: model, navigator: navigator)
        case .messages: MessagesView(model: model, navigator: navigator)
        case .rooms: RoomsView(model: model, navigator: navigator)
        case .users: UsersView(model: model, navigator: navigator)
        case .shared: SharedFilesView(model: model)
        }
    }
}

struct Sidebar: View {
    let model: AppModel
    @Bindable var navigator: Navigator

    var body: some View {
        List(selection: $navigator.section) {
            Section("Discover") {
                row(.search)
                row(.wishlist, badge: model.wishlist.filter { $0.matches > 0 }.count)
                row(.browse)
            }
            Section("Transfers") {
                row(.downloads, badge: activeCount(upload: false))
                row(.uploads, badge: activeCount(upload: true))
            }
            Section("Community") {
                row(.messages, badge: model.unread.count)
                row(.rooms, badge: model.joinedRooms.count)
                row(.users)
            }
            Section("Library") { row(.shared) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountFooter(model: model, navigator: navigator) }
    }

    private func row(_ section: SidebarSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge)
            .tag(section)
    }

    private func activeCount(upload: Bool) -> Int {
        model.transfers.filter { $0.upload == upload && [.queued, .negotiating, .transferring].contains($0.status) }.count
    }
}

struct AccountFooter: View {
    let model: AppModel
    let navigator: Navigator

    private var account: String {
        model.connection.isConnected ? model.activeAccount : (model.settings.username.isEmpty ? "No Account" : model.settings.username)
    }

    var body: some View {
        Button { navigator.showLogin = true } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.connection.tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: model.connection.tint.opacity(0.6), radius: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(model.connection.label).foregroundStyle(.secondary).fixedSize()
                        Text("·").foregroundStyle(.tertiary).fixedSize()
                        ServerTargetText(settings: model.settings, compact: true)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        .padding(10)
        .help("Account and connection · \(model.settings.targetDescription), \(model.settings.serverEndpoint)")
        .accessibilityLabel("Account: \(model.settings.username.isEmpty ? "none" : model.settings.username), \(model.connection.label), \(model.settings.targetDescription) \(model.settings.serverEndpoint)")
    }
}

/// Where Arpeggio will sign in. Local loopback targets are developer fixtures, never the Soulseek network.
extension AppSettings {
    var isSoulseekServer: Bool {
        server.trimmingCharacters(in: .whitespaces).lowercased() == Self.soulseekHost && port == Self.soulseekPort
    }
    var targetDescription: String {
        isSoulseekServer ? "Soulseek network" : isLocalServer ? "Local test server" : "Custom server"
    }
    static var soulseekEndpoint: String { "\(soulseekHost):\(soulseekPort)" }
}

/// Configured server host, warning-tinted when it points at a loopback fixture.
struct ServerTargetText: View {
    let settings: AppSettings
    var compact = false

    var body: some View {
        if settings.isLocalServer {
            Label(compact ? "Local \(settings.serverEndpoint)" : settings.serverEndpoint, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .truncationMode(.middle)
        } else {
            Text(compact && settings.isSoulseekServer ? settings.server : settings.serverEndpoint)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
    }
}

/// Collapses noisy, repetitive diagnostics (e.g. one refused socket per reconnect) into unique lines with counts.
enum DiagnosticDigest {
    struct Entry: Hashable {
        let text: String
        let count: Int
        var display: String { count > 1 ? "\(text)  (×\(count))" : text }
    }

    /// Most recent `limit` unique lines, oldest first, each with its total occurrence count.
    static func collapse(_ lines: [String], limit: Int) -> [Entry] {
        var counts: [String: Int] = [:]
        var newestFirst: [String] = []
        for raw in lines.reversed() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if counts[line] == nil { newestFirst.append(line) }
            counts[line, default: 0] += 1
        }
        return newestFirst.prefix(limit).reversed().map { Entry(text: $0, count: counts[$0, default: 1]) }
    }

    /// Joins the distinct lines of a message so repeated failures read once.
    static func headline(_ message: String) -> String {
        var seen = Set<String>()
        return message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: " ")
    }
}

struct ErrorBanner: View {
    let model: AppModel
    let message: String
    let dismiss: () -> Void
    @State private var expanded = false

    private var headline: String { DiagnosticDigest.headline(message) }
    private var details: [DiagnosticDigest.Entry] { DiagnosticDigest.collapse(model.diagnostics, limit: 12) }
    private var offerSoulseekServer: Bool { model.settings.isLocalServer && !model.connection.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.callout)
                        .lineLimit(expanded ? 4 : 1)
                        .textSelection(.enabled)
                        .help(headline)
                    if offerSoulseekServer {
                        Text("Arpeggio is set to a local test server (\(model.settings.serverEndpoint)), not the Soulseek network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if offerSoulseekServer {
                    Button("Use Soulseek Server") { Task { await model.useSoulseekServer() } }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Switch to \(AppSettings.soulseekEndpoint). Your username and saved password are kept.")
                }
                Group {
                    if !details.isEmpty {
                        Button(expanded ? "Hide Details" : "Details") { expanded.toggle() }
                            .accessibilityHint("Shows recent unique diagnostic messages")
                    }
                    Button("Copy", action: copy)
                }
                .buttonStyle(.link)
                .fixedSize()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Dismiss error")
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(details, id: \.self) { entry in
                            Text(entry.display)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(entry.text)
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 88)
                HStack(spacing: 4) {
                    Text("\(details.count) unique of \(model.diagnostics.count) recent messages.")
                    SettingsLink { Text("Full log in Settings › Advanced") }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([headline] + details.map(\.display)).joined(separator: "\n"), forType: .string)
    }
}

/// Inline hint shown in network-dependent views while offline.
struct OfflineNotice: View {
    let model: AppModel
    let navigator: Navigator
    var body: some View {
        if !model.connection.isConnected {
            let local = model.settings.isLocalServer && !model.connection.isBusy
            HStack(spacing: 8) {
                Image(systemName: local ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle")
                    .foregroundStyle(local ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(model.connection.isBusy ? model.connection.label
                     : local ? "Offline. Set to a local test server (\(model.settings.serverEndpoint)), not the Soulseek network."
                     : "You’re offline. Network actions are unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if local {
                    Button("Use Soulseek Server") { Task { await model.useSoulseekServer() } }.controlSize(.small)
                }
                if !model.connection.isBusy {
                    Button("Connect…") { navigator.showLogin = true }.controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
