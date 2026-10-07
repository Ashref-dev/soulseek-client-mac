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
            DetailChrome(showsPlayer: model.playback.item != nil) {
                detail
            } banners: {
                if model.settingsRecovery != nil { SettingsRecoveryBanner(model: model) }
                if let error = model.error, error != model.settingsRecovery?.reason {
                    ErrorBanner(model: model, message: error) { model.error = nil }
                }
                ReconnectBanner(model: model)
                UpdateBanner(model: model)
            } player: { layout in
                NowPlayingBar(model: model, navigator: navigator, layout: layout)
            } toast: { padding in
                NoticeToast(model: model, navigator: navigator, bottomPadding: padding)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: model.playback.item?.transferID ?? model.playback.item?.title)
        }
        .confirmationDialog("Sign out of \(model.settings.username)?", isPresented: $navigator.confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Arpeggio disconnects and forgets the saved password. Your downloads, history and settings stay on this Mac.")
        }
        .frame(minWidth: 880, minHeight: 560)
        .tint(.arpeggio)
        .preferredColorScheme(model.settings.appearance == "light" ? .light : model.settings.appearance == "dark" ? .dark : nil)
        .environment(\.defaultMinListRowHeight, model.settings.compact ? 22 : 28)
        .focusedSceneValue(\.navigator, navigator)
        .sheet(isPresented: $navigator.showLogin) { LoginSheet(model: model) }
        .sheet(isPresented: $navigator.showOnboarding) { OnboardingView(model: model, navigator: navigator) }
        .sheet(isPresented: $navigator.showPalette) { CommandPalette(model: model, navigator: navigator) }
        .sheet(item: $navigator.prompt) { prompt in UserPromptSheet(prompt: prompt, model: model, navigator: navigator) }
        .sheet(item: $navigator.profile) { request in UserProfileSheet(username: request.username, model: model, navigator: navigator) }
        .sheet(item: Binding(get: { model.documentPreview }, set: { value in
            if value == nil { Task { await model.closeDocumentPreview() } }
        })) { preview in DocumentPreviewView(model: model, identity: preview.id) }
        .task {
            await bootstrap.start(model)
            if model.settings.onboardingVersion == nil { navigator.showOnboarding = true }
        }
        .onAppear {
            navigator.section = SidebarSection(rawValue: restoredSection) ?? .search
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            if model.settings.hideDockWhenClosed == true, model.settings.showsMenuBarIcon { NSApp.setActivationPolicy(.accessory) }
        }
        .onChange(of: navigator.section) { _, section in if let section { restoredSection = section.rawValue } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.error)
        .onChange(of: model.settings.onboardingVersion) { _, version in if version == nil { navigator.showOnboarding = true } }
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
        case .shared: SharedFilesView(model: model, navigator: navigator)
        case .received: ReceivedSearchesView(model: model, navigator: navigator)
        case .statistics: StatisticsView(model: model)
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
            Section("Library") {
                row(.shared)
                row(.received)
                row(.statistics)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountFooter(model: model, navigator: navigator) }
    }

    private func row(_ section: SidebarSection, badge: Int = 0) -> some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: section.symbol)
                .symbolEffect(.bounce.down, value: section == .downloads ? badge : 0)
        }
        .badge(badge)
        .tag(section)
    }

    private func activeCount(upload: Bool) -> Int {
        model.transfers.filter { $0.upload == upload && !$0.isPreview && [.queued, .negotiating, .transferring].contains($0.status) }.count
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

/// Where an error message should send people in Settings. Port and listener problems go to Network.
enum ErrorRoute {
    static func destination(for message: String) -> SettingsDestination? {
        let text = message.lowercased()
        if text.contains("settings › network") || text.contains("listening port") || text.contains("port forwarding") { return .network }
        return nil
    }
}

struct ErrorBanner: View {
    let model: AppModel
    let message: String
    let dismiss: () -> Void
    @State private var expanded = false
    @State private var copied = false

    private var headline: String { DiagnosticDigest.headline(message) }
    /// Only warnings and errors: routine peer activity is not presented as the cause of this problem.
    private var details: [DiagnosticDigest.Entry] { DiagnosticDigest.collapse(model.diagnosticStore.problems.map(\.message), limit: 12) }
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
                    if let destination = ErrorRoute.destination(for: message) {
                        SettingsDestinationLink(destination: destination, model: model) { Text("Network Settings…") }
                    }
                    if !details.isEmpty {
                        Button(expanded ? "Hide Details" : "Details") { expanded.toggle() }
                            .accessibilityHint("Shows recent warnings and errors")
                    }
                    Button(copied ? "Copied" : "Copy Report", action: copy)
                        .help("Copies a privacy-safe report without usernames, paths, addresses or message text")
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
                    Text("\(details.count) recent problem\(details.count == 1 ? "" : "s").")
                    SettingsDestinationLink(tab: .advanced, model: model) { Text("All activity in Settings › Advanced") }
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
        NSPasteboard.general.setString(model.redactedCopyReport(), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}

/// While a lost connection waits to retry: a live countdown and Retry Now. Hidden when not retrying.
struct ReconnectBanner: View {
    let model: AppModel

    var body: some View {
        if case .failed = model.connection, let deadline = model.reconnectSchedule.deadline {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.arpeggio).accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.countdown(deadline: deadline, now: context.date))
                        .font(.callout).monospacedDigit()
                }
                Spacer()
                Button("Retry Now") { Task { await model.retryNow() } }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        } else if model.connection == .reconnecting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reconnecting…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    nonisolated static func countdown(deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        if seconds == 0 { return "Connection lost. Reconnecting now…" }
        let wait = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
        return "Connection lost. Reconnecting in \(wait)."
    }
}

/// Unreadable saved settings: Arpeggio stays offline and leaves them untouched until the person chooses a recovery.
struct SettingsRecoveryBanner: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved settings couldn’t be read").font(.callout.weight(.semibold))
                Text("Arpeggio won’t sign in or save over them until you choose how to recover. Downloads and history are safe.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsDestinationLink(destination: .recovery, model: model) { Text("Recover Settings…") }
                .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
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
