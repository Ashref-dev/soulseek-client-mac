import SwiftUI
import ArpeggioServices

private struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var enabled = true
    let run: () -> Void
}

struct CommandPalette: View {
    let model: AppModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    private var items: [PaletteItem] {
        let online = model.connection.isConnected
        let query = text.trimmingCharacters(in: .whitespaces)
        var list: [PaletteItem] = []
        if !query.isEmpty {
            list.append(PaletteItem(id: "search", title: "Search for “\(query)”", detail: "Soulseek network", symbol: "magnifyingglass",
                                    enabled: online) { navigator.runSearch(query, model: model) })
            list.append(PaletteItem(id: "browse", title: "Browse \(query)", detail: "User’s shared files", symbol: "folder",
                                    enabled: online) { navigator.browse(query, model: model) })
            list.append(PaletteItem(id: "message", title: "Message \(query)", detail: "Private conversation", symbol: "bubble.left") {
                navigator.message(query)
            })
        }
        list += SidebarSection.allCases.map { section in
            PaletteItem(id: "go-\(section.rawValue)", title: section.title, detail: "Go to · ⌘\(section.shortcut.character)", symbol: section.symbol) {
                navigator.go(section)
            }
        }
        list.append(online
            ? PaletteItem(id: "disconnect", title: "Disconnect", detail: "Network", symbol: "bolt.slash") { Task { await model.disconnect() } }
            : PaletteItem(id: "connect", title: "Connect…", detail: "Network", symbol: "bolt") { navigator.showLogin = true })
        list.append(PaletteItem(id: "rescan", title: "Rescan Shared Folders", detail: "Library", symbol: "arrow.clockwise",
                                enabled: !model.indexing) { Task { await model.rescanShares() } })
        list += model.users.map { user in
            PaletteItem(id: "user-\(user.username)", title: user.username, detail: "Message user", symbol: "person.crop.circle") {
                navigator.message(user.username)
            }
        }
        guard !query.isEmpty else { return list }
        return list.filter { ["search", "browse", "message"].contains($0.id) || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let visible = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Search, browse a user, or jump to…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(visible.first { $0.id == highlighted } ?? visible.first) }
                    .onKeyPress(.downArrow) { move(1, in: visible); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: visible); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(visible) { item in
                    Button { run(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(Color.arpeggio)
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                    .opacity(item.enabled ? 1 : 0.45)
                    .listRowBackground(item.id == (highlighted ?? visible.first?.id) ? Color.arpeggio.opacity(0.15) : Color.clear)
                    .id(item.id)
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true }
        .onChange(of: text) { highlighted = nil }
        .onExitCommand { dismiss() }
    }

    private func move(_ delta: Int, in list: [PaletteItem]) {
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == highlighted } ?? 0
        highlighted = list[max(0, min(list.count - 1, current + delta))].id
    }

    private func run(_ item: PaletteItem?) {
        guard let item, item.enabled else { return }
        dismiss()
        item.run()
    }
}

struct UserPromptSheet: View {
    let prompt: UserPrompt
    let model: AppModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""

    private var name: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt == .message ? "New Message" : "Browse User").font(.headline)
            Text(prompt == .message ? "Start a private conversation with a Soulseek user." : "Request the full list of files a user shares.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt == .message ? "Open Conversation" : "Browse", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (prompt == .browse && !model.connection.isConnected))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func confirm() {
        guard !name.isEmpty else { return }
        dismiss()
        switch prompt {
        case .message: navigator.message(name)
        case .browse: navigator.browse(name, model: model)
        }
    }
}
