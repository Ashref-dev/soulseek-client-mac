import SwiftUI
import ArpeggioServices

struct ArpeggioCommands: Commands {
    let model: AppModel?
    @FocusedValue(\.navigator) private var navigator
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool { model?.connection.isConnected ?? false }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Arpeggio") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Soulseek-Arpeggio",
                    .credits: NSAttributedString(string: "A native Soulseek client for macOS.\nNot affiliated with Soulseek."),
                ])
            }
            Button("Check for Updates…") { if let model { Task { await model.checkForUpdates() } } }
                .disabled(model == nil || model?.canUpdateInPlace == false)
        }
        CommandGroup(replacing: .help) {
            Button("Arpeggio Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Welcome to Arpeggio") { navigator?.showOnboarding = true }
                .disabled(navigator == nil)
        }
        CommandGroup(after: .newItem) {
            Button("New Message…") { navigator?.prompt = .message }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(navigator == nil)
            Button("Browse User…") { navigator?.prompt = .browse }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(navigator == nil || !connected)
        }
        CommandMenu("Network") {
            Button("Find…") { navigator?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(navigator == nil)
            Button("Go to…") { navigator?.showPalette = true }
                .keyboardShortcut("k")
                .disabled(navigator == nil)
            Divider()
            if connected {
                Button("Disconnect") { if let model { Task { await model.disconnect() } } }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            } else {
                Button("Connect…") { navigator?.showLogin = true }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(navigator == nil || model?.connection.isBusy == true)
            }
            Button("Sign Out…") { navigator?.confirmSignOut = true }
                .disabled(navigator == nil || model?.settings.username.isEmpty != false)
            Divider()
            Button("Expand All Results") { navigator?.expandAllRequest += 1 }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(navigator?.section != .search)
            Button("Collapse All Results") { navigator?.collapseAllRequest += 1 }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(navigator?.section != .search)
            Button("Clear Search") { model?.clearSearch() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(navigator?.section != .search || (model?.results.isEmpty != false && model?.query.isEmpty != false))
            Divider()
            Button("Rescan Shared Folders") { if let model { Task { await model.rescanShares() } } }
                .disabled(model == nil || model?.indexing == true)
            Button(model?.downloadsSuspended == true ? "Resume Downloads" : "Pause Downloads") {
                if let model { Task { await model.setTransfersSuspended(upload: false, !model.downloadsSuspended) } }
            }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(model == nil)
            Button(model?.uploadsSuspended == true ? "Resume Uploads" : "Pause Uploads") {
                if let model { Task { await model.setTransfersSuspended(upload: true, !model.uploadsSuspended) } }
            }.keyboardShortcut("p", modifiers: [.command, .option, .shift]).disabled(model == nil)
        }
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
                topic("Listening", "Click the play button on any audio track, or press Space, to stream a preview before downloading. Preview bytes go to a temporary cache; press Download in the player to keep the file, which then finishes straight into your Downloads folder. Finished downloads play the same way from Search or Downloads.")
                topic("Transfers", "Downloads and Uploads group transfers by album. Change slots and speed limits right in the bar at the bottom, and clear finished items with Clear Completed. Each album lands in its own folder in your download folder; unfinished files wait in a hidden folder until they're complete.")
                topic("Sharing", "Open Shared Files to add folders, or drop them from Finder. Each folder can be visible to everyone or only to users you trust. Arpeggio picks up changes in shared folders automatically.")
                topic("Status and Menu Bar", "Closing the window keeps Arpeggio connected and sharing. The menu bar icon is dimmed when offline, shows a moon when you're away and an arrow while someone downloads from you. Choose Available or Away from the account menu at the bottom of the sidebar or from the menu bar.")
                topic("Statistics", "Statistics counts what you've downloaded and uploaded since you started using Arpeggio. Share or copy it as a picture from the toolbar.")
                topic("Updates", "Arpeggio checks GitHub for new releases once a day and installs them only if they're signed by the same developer. Use Arpeggio › Check for Updates to check now.")
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
