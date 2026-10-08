import SwiftUI
import AppKit
import ArpeggioServices

struct MenuBarLabel: View {
    let model: AppModel
    let bootstrap: Bootstrap
    @State private var status = MenuBarStatus()

    var body: some View {
        let state = status.state
        Image(nsImage: MenuBarGlyph.image(state))
            .accessibilityLabel(state.accessibilityLabel)
            .task { await bootstrap.start(model) }
            .task { await status.follow(model) }
    }
}

/// The panel behind the menu bar icon. MenuBarExtra keeps it alive while closed, so transfers, lifetime
/// totals and indexing are followed only while it is open, and then at most twice a second.
struct MenuBarPanel: View {
    let model: AppModel
    @State private var feed = MenuBarPanelFeed()
    @State private var isOpen = false

    var body: some View {
        MenuBarPanelContent(model: model, live: feed.live, isOpen: isOpen)
            .background {
                PanelVisibilityReader { open in
                    guard open != isOpen else { return }
                    if open { feed.refresh(model) }
                    isOpen = open
                }
            }
            .onAppear { feed.refresh(model) }
            .task(id: isOpen) {
                guard isOpen else { return }
                await feed.follow(model)
            }
    }
}

struct MenuBarPanelContent: View {
    let model: AppModel
    let live: MenuBarPanelLive
    var isOpen = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(MenuBarRoute.self) private var route: MenuBarRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transfers.padding(.top, 14)
            if let item = model.playback.item {
                NowPlayingRow(playback: model.playback, item: item).padding(.top, 8)
            }
            ShareSummary(live: live, isOpen: isOpen) { open(.sharedFiles) }.padding(.top, 14)
            actions.padding(.top, 16)
        }
        .padding(16)
        .frame(width: 320)
        .tint(.arpeggio)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProfileAvatar(model: model, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.accountName)
                    .font(.headline)
                    .lineLimit(1)
                Text(connectionLine)
                    .font(.caption)
                    .foregroundStyle(model.settings.isLocalServer ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help("Server \(model.settings.serverEndpoint)")
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            PresenceControl(model: model, connect: connect, signIn: { open(.signIn) })
        }
    }

    private var connectionLine: String {
        guard model.connection.isConnected else { return model.statusText }
        return model.settings.isSoulseekServer ? "Online" : "Online · \(model.settings.targetDescription)"
    }

    private var transfers: some View {
        VStack(spacing: 0) {
            TransferRow(upload: false, pulse: live.downloads, suspended: model.downloadsSuspended) {
                Task { await model.setTransfersSuspended(upload: false, !model.downloadsSuspended) }
            }
            Divider().padding(.leading, 52)
            TransferRow(upload: true, pulse: live.uploads, suspended: model.uploadsSuspended) {
                Task { await model.setTransfersSuspended(upload: true, !model.uploadsSuspended) }
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: openMain) {
                Label {
                    Text("Open Arpeggio")
                } icon: {
                    ArpeggioLogo().frame(width: 15, height: 15)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.defaultAction)
            .help("Open the Arpeggio window")
            Spacer(minLength: 0)
            PanelIconButton(symbol: "magnifyingglass", title: "Search", shortcut: "⌘F") { open(.search) }
                .keyboardShortcut("f")
            PanelIconButton(symbol: "folder", title: "Open Downloads Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.downloadDirectory))
            }
            .disabled(!live.downloadsFolderExists)
            PanelIconButton(symbol: "gearshape", title: "Settings", shortcut: "⌘,") { NSApp.activate(); openSettings() }
                .keyboardShortcut(",")
            PanelIconButton(symbol: "power", title: "Quit Arpeggio", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.large)
    }

    /// Connects with the saved password, or opens the sign-in sheet when there is none.
    private func connect() {
        Task {
            let password = await model.savedPassword()
            if password.isEmpty { open(.signIn) } else { await model.login(password: password) }
        }
    }

    private func open(_ request: MenuBarRoute.Request) {
        openMain()
        route?.send(request)
    }

    private func openMain() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Reports whether the panel's window is open, from window notifications: MenuBarExtra does not run view
/// lifecycle callbacks on every open and close.
private struct PanelVisibilityReader: NSViewRepresentable {
    let report: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.report = report }

    final class Probe: NSView {
        var report: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            if let window {
                let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.publish() }
                    }
                }
            }
            Task { [weak self] in self?.publish() }
        }

        private func publish() {
            guard let window else { report?(false); return }
            report?(window.isVisible && (window.isKeyWindow || window.occlusionState.contains(.visible)))
        }
    }
}
