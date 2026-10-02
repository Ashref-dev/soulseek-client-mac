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
                    .applicationName: "Arpeggio",
                    .credits: NSAttributedString(string: "A native Soulseek client for macOS.\nNot affiliated with Soulseek."),
                ])
            }
        }
        CommandGroup(replacing: .help) {
            Button("Arpeggio Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
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
            Divider()
            Button("Rescan Shared Folders") { if let model { Task { await model.rescanShares() } } }
                .disabled(model == nil || model?.indexing == true)
        }
        CommandGroup(before: .sidebar) {
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) { navigator?.go(section) }
                    .keyboardShortcut(section.shortcut)
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
                Label("Arpeggio", systemImage: "music.quarternote.3").font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.arpeggio)
                topic("Connecting", "Choose Network › Connect and sign in with your Soulseek account. The legacy protocol sends passwords without encryption, so use a password unique to Soulseek.")
                topic("Searching", "Press ⌘F, type a query and press Return. Results stream in live. Exclude words with a leading minus. Filter, sort and group results from the bar above the table; double-click to download.")
                topic("Transfers", "Downloads and Uploads list every transfer grouped by state. Pause, resume or cancel from the toolbar or context menu. Press Space to Quick Look a finished file.")
                topic("Sharing", "Add folders in Settings › Sharing. Mark folders as trusted-only to hide them from everyone except users you trust.")
                topic("Navigation", "⌘1–⌘9 jump to sections. ⌘K opens the command palette. ⇧⌘N starts a new message, ⇧⌘B browses a user.")
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
