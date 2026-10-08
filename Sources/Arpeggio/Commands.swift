import SwiftUI
import ArpeggioServices

/// Every menu key equivalent in one place, so a test can prove none collide. Playback uses Control-Command
/// throughout: plain Space previews in lists, and Command-arrows edit text in the search field.
enum AppShortcut: CaseIterable {
    case help, newMessage, browseUser, find, goTo, disconnect, connect, expandAll, collapseAll, clearSearch, pauseDownloads, pauseUploads
    case playPause, stop, skipBack, skipForward, volumeUp, volumeDown, mute

    var key: KeyEquivalent {
        switch self {
        case .help: "?"
        case .newMessage: "n"
        case .browseUser: "b"
        case .find: "f"
        case .goTo: "k"
        case .disconnect: "d"
        case .connect: "l"
        case .expandAll, .skipForward: .rightArrow
        case .collapseAll, .skipBack: .leftArrow
        case .clearSearch: .delete
        case .pauseDownloads, .pauseUploads, .playPause: "p"
        case .stop: "."
        case .volumeUp: .upArrow
        case .volumeDown: .downArrow
        case .mute: "m"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .help, .find, .goTo: .command
        case .newMessage, .browseUser, .clearSearch: [.command, .shift]
        case .disconnect, .connect, .expandAll, .collapseAll, .pauseDownloads: [.command, .option]
        case .pauseUploads: [.command, .option, .shift]
        case .playPause, .stop, .skipBack, .skipForward, .volumeUp, .volumeDown, .mute: [.command, .control]
        }
    }

    var isPlayback: Bool { [.playPause, .stop, .skipBack, .skipForward, .volumeUp, .volumeDown, .mute].contains(self) }
}

/// A comparable key plus modifiers, for collision checks.
struct ShortcutKey: Hashable {
    let character: Character
    let modifiers: Int
    init(_ key: KeyEquivalent, _ modifiers: EventModifiers) { character = key.character; self.modifiers = modifiers.rawValue }

    static var all: [ShortcutKey] {
        AppShortcut.allCases.map { ShortcutKey($0.key, $0.modifiers) } + SidebarSection.allCases.map { ShortcutKey($0.shortcut, $0.modifiers) }
    }
}

extension View {
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View { keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers) }
}

struct ArpeggioCommands: Commands {
    let model: AppModel?
    @FocusedValue(\.navigator) private var navigator
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool { model?.connection.isConnected ?? false }
    private var outlineSection: Bool { [.search, .downloads, .uploads].contains(navigator?.section) }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Arpeggio") { NSApp.orderFrontStandardAboutPanel(options: AboutPanel.options()) }
            Button("Check for Updates…") { if let model { Task { await model.checkForUpdates() } } }
                .disabled(model == nil || model?.canUpdateInPlace == false)
        }
        CommandGroup(replacing: .help) {
            Button("Arpeggio Help") { openWindow(id: "help") }
                .keyboardShortcut(.help)
            Button("Welcome to Arpeggio") { navigator?.showOnboarding = true }
                .disabled(navigator == nil)
        }
        CommandGroup(after: .newItem) {
            Button("New Message…") { navigator?.prompt = .message }
                .keyboardShortcut(.newMessage)
                .disabled(navigator == nil)
            Button("Browse User…") { navigator?.prompt = .browse }
                .keyboardShortcut(.browseUser)
                .disabled(navigator == nil || !connected)
        }
        CommandMenu("Network") {
            Button("Find…") { navigator?.focusSearch() }
                .keyboardShortcut(.find)
                .disabled(navigator == nil)
            Button("Go to…") { navigator?.showPalette = true }
                .keyboardShortcut(.goTo)
                .disabled(navigator == nil)
            Divider()
            if connected {
                Button("Disconnect") { if let model { Task { await model.disconnect() } } }
                    .keyboardShortcut(.disconnect)
            } else {
                Button("Connect…") { navigator?.showLogin = true }
                    .keyboardShortcut(.connect)
                    .disabled(navigator == nil || model?.connection.isBusy == true)
            }
            Button("Sign Out…") { navigator?.confirmSignOut = true }
                .disabled(navigator == nil || model?.settings.username.isEmpty != false)
            Divider()
            Button(navigator?.section == .search ? "Expand All Results" : "Expand All Groups") { navigator?.expandAllRequest += 1 }
                .keyboardShortcut(.expandAll)
                .disabled(!outlineSection)
            Button(navigator?.section == .search ? "Collapse All Results" : "Collapse All Groups") { navigator?.collapseAllRequest += 1 }
                .keyboardShortcut(.collapseAll)
                .disabled(!outlineSection)
            Button("Clear Search") { model?.clearSearch() }
                .keyboardShortcut(.clearSearch)
                .disabled(navigator?.section != .search || (model?.results.isEmpty != false && model?.query.isEmpty != false))
            Divider()
            Button("Rescan Shared Folders") { if let model { Task { await model.rescanShares() } } }
                .disabled(model == nil || model?.indexing == true)
            Button(model?.downloadsSuspended == true ? "Resume Downloads" : "Pause Downloads") {
                if let model { Task { await model.setTransfersSuspended(upload: false, !model.downloadsSuspended) } }
            }.keyboardShortcut(.pauseDownloads).disabled(model == nil)
            Button(model?.uploadsSuspended == true ? "Resume Uploads" : "Pause Uploads") {
                if let model { Task { await model.setTransfersSuspended(upload: true, !model.uploadsSuspended) } }
            }.keyboardShortcut(.pauseUploads).disabled(model == nil)
        }
        CommandMenu("Playback") { PlaybackMenu(model: model) }
        CommandGroup(before: .sidebar) {
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) { navigator?.go(section) }
                    .keyboardShortcut(section.shortcut, modifiers: section.modifiers)
                    .disabled(navigator == nil)
            }
            Divider()
        }
    }
}

/// Transport commands for the shared player. Every item is disabled while nothing is loaded.
struct PlaybackMenu: View {
    let model: AppModel?

    var body: some View {
        let playback = model?.playback
        let loaded = playback?.item != nil
        let seekable = loaded && (playback?.duration ?? 0) > 0
        let volume = playback?.volume ?? 1
        Button(playback?.isPlaying == true ? "Pause" : "Play") { playback?.togglePlay() }
            .keyboardShortcut(.playPause)
            .disabled(!loaded || playback?.failure != nil)
        Button("Stop") { if let model { Task { await model.stopPlayback() } } }
            .keyboardShortcut(.stop)
            .disabled(!loaded)
        Divider()
        Button("Back 15 Seconds") { playback?.skip(by: -15) }
            .keyboardShortcut(.skipBack)
            .disabled(!seekable)
        Button("Forward 15 Seconds") { playback?.skip(by: 15) }
            .keyboardShortcut(.skipForward)
            .disabled(!seekable)
        Divider()
        Button("Volume Up") { playback?.changeVolume(by: 0.1) }
            .keyboardShortcut(.volumeUp)
            .disabled(!loaded || volume >= 1)
        Button("Volume Down") { playback?.changeVolume(by: -0.1) }
            .keyboardShortcut(.volumeDown)
            .disabled(!loaded || volume <= 0)
        Button(volume == 0 ? "Unmute" : "Mute") { playback?.volume = volume == 0 ? 1 : 0 }
            .keyboardShortcut(.mute)
            .disabled(!loaded)
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ArpeggioLogo().frame(width: 40, height: 40)
                    Text("Soulseek-Arpeggio").font(.largeTitle.weight(.semibold))
                }
                .foregroundStyle(Color.arpeggio)
                topic("Connecting", "Sign in once with Network › Connect. With Remember password on, Arpeggio connects automatically every time it opens until you choose Network › Sign Out, which forgets the saved password. Disconnect only goes offline for now. Arpeggio uses server.slsknet.org:2242 unless you change it in Settings › Advanced. The legacy protocol sends passwords without encryption, so use a password unique to Soulseek.")
                topic("New Accounts", "Soulseek has no separate sign-up. Signing in with an unused username (up to 30 ASCII characters) registers it with that password. Availability can’t be checked in advance: if the name is already taken, the server reports a wrong password.")
                topic("Local Test Server", "A server on localhost or 127.0.0.1 is a developer fixture, not the Soulseek network. Choose Use Soulseek Server in the sign-in sheet, or Restore Default Server in Settings › Advanced, to switch back.")
                topic("Searching", "Press ⌘F, type a query and press Return. Results stream into a fully expanded user → folder → track outline, ranked by free slot and speed. A search ends by itself after 15 seconds without new results (change this in Settings › General). Exclude words with a leading minus. Use the ⓘ button in the filter bar for every filter and quality term. Double-click a track to download it, or use Download Entire Folder for the complete release. ⌥⌘→ and ⌥⌘← expand or collapse everything.")
                topic("Previews", "Use Preview or Space in Search, Browse or Transfers. Native audio may stream as bytes arrive. Other audio, video, images and PDFs fetch first, then open using macOS media playback or Quick Look. Codec support depends on macOS. Temporary previews are limited to 512 MB and a five-minute fetch deadline. Close to discard, or Download to keep. Kept and existing downloads are never deleted when closing a preview.")
                topic("Transfer Suspension", "Pause or resume all Uploads or Downloads from the menu bar or Network menu. Active connections stop safely and queued requests remain. Resume restarts negotiation using partial download bytes. Your Available or Away presence is unchanged. Suspension lasts for this app session.")
                topic("Sharing Policy and Indexing", "Settings › Sharing can require sharing before downloading from you. Confirmed zero-share users are declined and receive your configurable message at most once per hour. Unknown counts are not treated as zero. Share indexing shows its current folder and actual file count, without an invented percentage.")
                topic("Ports", "Settings › Network shows your listening port, router mapping and checks. New profiles listen on TCP port 61147; a port you saved before is never changed automatically. If your former Soulseek client worked with a router rule, use that same port, and quit the other client first because only one app can listen on a port at a time. To forward manually, add a TCP rule for the port to this Mac in your router’s Port Forwarding or Virtual Server settings. NAT-PMP and UPnP are separate controls. A mapping acknowledgment is not proof of external reachability. Check Ports tests the local listener only. Check External Reachability, only when you confirm it while connected, asks the Soulseek port checker at slsknet.org to reach your listening port from your public IP address. OPEN means that checker reached the TCP port; it does not prove uploads succeed, test other ports, or match every route, for example with a VPN. Unclear answers are reported as unavailable, not closed. Firewalls, double NAT, VPNs and carrier NAT may still prevent incoming connections.")
                topic("Transfers", "Downloads and Uploads each remember their own layout: Flat, Folders, or Users then Folders then Files. ⌥⌘→ and ⌥⌘← expand or collapse every group. Remove from List (Delete) stops a transfer that is still in progress after you confirm, then removes only the row: downloaded files, partial data and shared files stay on disk, and Statistics totals never go down. A finished download whose file was moved or deleted says so and can't be previewed. When Downloads or Uploads are paused, a banner offers Resume; queued rows say whether they wait for one of your slots or in another person's queue. Change slots and speed limits in the bar at the bottom.")
                topic("Sharing", "Open Shared Files to add folders, or drop them from Finder. Each folder can be visible to everyone or only to users you trust. Arpeggio picks up changes in shared folders automatically.")
                topic("Status and Menu Bar", "Closing the window keeps Arpeggio connected and sharing. The menu bar icon is dimmed when offline and shows a small moon when you're away. While files move, its notes fill in and the wavy line gains an arrow: down while downloading, up while uploading, both ways when both are active. The icon never animates. The menu bar panel shows live speeds and lets you pause or resume Downloads and Uploads. In the panel and the status menus, a purple bird shows your status: wings spread for Available, wings folded for Away, grey when offline. Choose Available or Away from the account menu at the bottom of the sidebar or from the menu bar.")
                topic("Statistics", "Statistics counts what you've downloaded and uploaded since you started using Arpeggio. Share or copy it as a picture from the toolbar.")
                topic("Updates", "Arpeggio checks GitHub for new releases once a day and installs them only if they're signed by the same developer. Use Arpeggio › Check for Updates to check now.")
                topic("Playback", "The Playback menu plays or pauses (⌃⌘P), stops (⌃⌘.), skips back or forward 15 seconds (⌃⌘← and ⌃⌘→) and changes volume (⌃⌘↑, ⌃⌘↓, ⌃⌘M). Media keys, headphone controls and Now Playing work while something is loaded. In short windows the player shrinks to one row.")
                topic("Navigation", "⌘1 to ⌘9 jump to sections, ⌘0 opens Statistics. ⌘K opens the command palette. ⇧⌘N starts a new message, ⇧⌘B browses a user.")
                Text("Arpeggio is not affiliated with Soulseek.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func topic(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
