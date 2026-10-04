import SwiftUI
import ArpeggioServices
import SoulseekCore
import Persistence

struct BrowseView: View {
    @Bindable var model: AppModel
    let navigator: Navigator

    private var user: String? { model.browsingUser ?? model.libraries.keys.sorted().first }

    var body: some View {
        VStack(spacing: 0) {
            OfflineNotice(model: model, navigator: navigator)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Browse")
        .navigationSubtitle(user ?? "")
        .toolbar {
            ToolbarItemGroup {
                if !model.libraries.isEmpty {
                    Picker("User", selection: Binding(get: { user ?? "" }, set: { model.browsingUser = $0 })) {
                        ForEach(model.libraries.keys.sorted(), id: \.self) { Text($0).tag($0) }
                        if let pending = model.browsingUser, model.libraries[pending] == nil { Text(pending).tag(pending) }
                    }
                    .help("Previously browsed users")
                }
                Button("Refresh", systemImage: "arrow.clockwise") { if let user { Task { await model.browse(user) } } }
                    .disabled(user == nil || !model.connection.isConnected || model.browseLoading)
                Button("Browse User…", systemImage: "person.crop.circle.badge.plus") { navigator.prompt = .browse }
                    .disabled(!model.connection.isConnected)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.browseLoading {
            ContentUnavailableView {
                Label("Requesting \(model.browsingUser ?? "")’s Files", systemImage: "folder.badge.gearshape")
            } description: {
                ProgressView().controlSize(.small)
            }
        } else if let user, let library = model.libraries[user] {
            if library.folders.isEmpty {
                ContentUnavailableView("\(user) Shares Nothing", systemImage: "folder", description: Text("This user isn’t sharing any files with you."))
            } else {
                LibraryBrowser(folders: library.folders, identity: "\(user)-\(model.browseRevision)", rootTitle: user) { files, folder in
                    remoteMenu(user: user, files: files, folder: folder)
                } onOpen: { files in
                    download(user: user, files)
                } onPreview: { file in
                    Task { await model.listen(to: SearchResult(user: user, file: file, freeSlot: false, speed: 0, queue: 0)) }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Browse a User", systemImage: "folder")
            } description: {
                Text(user.map { "No files were received from \($0). They may be offline or unreachable." }
                     ?? "See everything someone shares, folder by folder.")
            } actions: {
                Button("Browse User…") { navigator.prompt = .browse }.disabled(!model.connection.isConnected)
            }
        }
    }

    @ViewBuilder private func remoteMenu(user: String, files: [SharedFile], folder: String?) -> some View {
        let online = model.connection.isConnected
        if files.count == 1, let file = files.first, PreviewFormat.classify(file.name) != nil {
            Button("Preview", systemImage: "play.circle") {
                Task { await model.listen(to: SearchResult(user: user, file: file, freeSlot: false, speed: 0, queue: 0)) }
            }
        }
        if !files.isEmpty {
            Button(files.count > 1 ? "Download \(files.count) Files" : "Download") { download(user: user, files) }.disabled(!online)
        }
        if let folder {
            Button("Download Folder") { Task { await model.downloadFolder(user: user, folder: folder) } }.disabled(!online)
        }
        Divider()
        Button("Message \(user)") { navigator.message(user) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.isEmpty ? (folder ?? "") : files.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }

    private func download(user: String, _ files: [SharedFile]) {
        guard model.connection.isConnected, !files.isEmpty else { return }
        Task { await model.download(files.map { SearchResult(user: user, file: $0, freeSlot: false, speed: 0, queue: 0) }) }
    }
}

struct WishlistView: View {
    let model: AppModel
    let navigator: Navigator
    @State private var draft = ""
    @State private var selection = Set<WishlistEntry.ID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add a search to keep watching for…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            Divider()
            Group {
            if model.wishlist.isEmpty {
                ContentUnavailableView("Your Wishlist Is Empty", systemImage: "star",
                                       description: Text("Arpeggio periodically re-runs these searches while you’re connected, at the pace the server allows."))
            } else {
                Table(model.wishlist, selection: $selection) {
                    TableColumn("") { entry in
                        Toggle("Enabled", isOn: Binding(get: { entry.enabled }, set: { value in
                            var copy = entry; copy.enabled = value
                            Task { await model.saveWish(copy) }
                        }))
                        .labelsHidden()
                    }
                    .width(24)
                    TableColumn("Search") { Text($0.query) }
                    TableColumn("New Matches") { Text($0.matches.formatted()).monospacedDigit() }.width(min: 70, ideal: 90)
                    TableColumn("Last Checked") { entry in
                        Text(entry.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 120)
                }
                .contextMenu(forSelectionType: WishlistEntry.ID.self) { ids in
                    let entries = model.wishlist.filter { ids.contains($0.id) }
                    if let entry = entries.first {
                        Button("Search Now") { navigator.runSearch(entry.query, model: model) }
                            .disabled(!model.connection.isConnected)
                        Button("Reset Match Count") {
                            for var item in entries { item.matches = 0; Task { await model.saveWish(item) } }
                        }
                        Divider()
                        Button("Remove", role: .destructive) { for item in entries { Task { await model.removeWish(item) } } }
                    }
                } primaryAction: { ids in
                    if let entry = model.wishlist.first(where: { ids.contains($0.id) }), model.connection.isConnected {
                        navigator.runSearch(entry.query, model: model)
                    }
                }
                .onDeleteCommand {
                    for item in model.wishlist where selection.contains(item.id) { Task { await model.removeWish(item) } }
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Wishlist")
    }

    private func add() {
        let text = draft
        draft = ""
        Task { await model.addWish(text) }
    }
}
