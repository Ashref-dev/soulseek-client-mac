import SwiftUI
import ArpeggioServices
import SoulseekCore
import TransferEngine

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
                        ErrorBanner(message: error, diagnostics: model.diagnostics) { model.error = nil }
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

    var body: some View {
        Button { navigator.showLogin = true } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.connection.tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: model.connection.tint.opacity(0.6), radius: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.connection.isConnected ? model.activeAccount : (model.settings.username.isEmpty ? "No Account" : model.settings.username))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(model.connection.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .help("Account and connection")
        .accessibilityLabel("Account: \(model.settings.username.isEmpty ? "none" : model.settings.username), \(model.connection.label)")
    }
}

struct ErrorBanner: View {
    let message: String
    let diagnostics: [String]
    let dismiss: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).textSelection(.enabled).lineLimit(expanded ? nil : 2)
                Spacer()
                if !diagnostics.isEmpty {
                    Button(expanded ? "Hide Details" : "Details") { expanded.toggle() }
                        .buttonStyle(.link)
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(([message] + diagnostics.suffix(30)).joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.link)
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Dismiss error")
            }
            if expanded {
                ScrollView {
                    Text(diagnostics.suffix(30).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Inline hint shown in network-dependent views while offline.
struct OfflineNotice: View {
    let model: AppModel
    let navigator: Navigator
    var body: some View {
        if !model.connection.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
                Text(model.connection.isBusy ? model.connection.label : "You’re offline. Network actions are unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
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
