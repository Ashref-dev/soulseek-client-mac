import SwiftUI
import ArpeggioServices
import SoulseekCore

/// Native outline of search results: user → folder/release → tracks. Users start collapsed; a folder can be
/// downloaded whole from its row without expanding its tracks.
struct SearchResultsOutline: View {
    let model: AppModel
    let navigator: Navigator
    let hierarchy: ResultHierarchy
    @Binding var selection: Set<ResultNodeID>
    @Binding var expandedUsers: Set<String>
    @Binding var expandedFolders: Set<String>
    let actions: SearchResultActions

    var body: some View {
        List(selection: $selection) {
            ForEach(hierarchy.users) { user in
                DisclosureGroup(isExpanded: member(user.id, of: $expandedUsers)) {
                    ForEach(user.folders) { folder in
                        DisclosureGroup(isExpanded: member(folder.id, of: $expandedFolders)) {
                            ForEach(folder.tracks) { track in
                                TrackResultRow(result: track).tag(ResultNodeID.track(track.id))
                            }
                        } label: {
                            FolderResultRow(folder: folder, online: model.connection.isConnected) { actions.downloadFolders([folder]) }
                        }
                        .tag(ResultNodeID.folder(folder.id))
                    }
                } label: {
                    UserResultRow(user: user)
                }
                .tag(ResultNodeID.user(user.id))
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: ResultNodeID.self) { ids in
            SearchResultMenu(model: model, navigator: navigator, actions: actions, ids: ids)
        } primaryAction: { ids in
            primary(ids)
        }
    }

    private func member(_ id: String, of set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    /// Return/double-click: tracks download; user and folder rows toggle like Finder's outline.
    private func primary(_ ids: Set<ResultNodeID>) {
        let selected = actions.resolve(ids)
        if !selected.tracks.isEmpty {
            if model.connection.isConnected { actions.downloadTracks(selected.tracks) }
            return
        }
        for id in ids {
            switch id {
            case .user(let user): expandedUsers.formSymmetricDifference([user])
            case .folder(let folder): expandedFolders.formSymmetricDifference([folder])
            case .track: break
            }
        }
    }
}

/// Resolves outline selections and performs downloads without scanning the full result list.
struct SearchResultActions {
    let model: AppModel
    let hierarchy: ResultHierarchy

    struct Resolved { var tracks: [SearchResult] = []; var folders: [ResultFolderNode] = []; var users: [String] = [] }

    func resolve(_ ids: Set<ResultNodeID>) -> Resolved {
        var output = Resolved()
        for id in ids {
            switch id {
            case .track(let key): if let track = hierarchy.tracks[key] { output.tracks.append(track) }
            case .folder(let key): if let folder = hierarchy.folders[key] { output.folders.append(folder) }
            case .user(let user): output.users.append(user)
            }
        }
        return output
    }

    /// Folders containing the selection; selected tracks contribute their own folder.
    func folders(for ids: Set<ResultNodeID>) -> [ResultFolderNode] {
        let selected = resolve(ids)
        var seen = Set(selected.folders.map(\.id)); var output = selected.folders
        for track in selected.tracks {
            let key = ResultHierarchy.folderID(user: track.user, path: track.file.folder)
            if seen.insert(key).inserted, let folder = hierarchy.folders[key] { output.append(folder) }
        }
        return output
    }

    func downloadTracks(_ tracks: [SearchResult]) {
        guard !tracks.isEmpty else { return }
        Task { await model.download(tracks) }
    }

    /// Asks each peer for the complete remote folder, not only the files that matched the search.
    func downloadFolders(_ folders: [ResultFolderNode]) {
        for folder in folders {
            Task { await model.requestFolderDownload(user: folder.user, folder: folder.path) }
        }
    }

    /// Toolbar action: selected tracks download directly; selected folders download whole.
    func download(_ ids: Set<ResultNodeID>) {
        let selected = resolve(ids)
        downloadTracks(selected.tracks)
        downloadFolders(selected.folders)
    }
}

private struct SearchResultMenu: View {
    let model: AppModel
    let navigator: Navigator
    let actions: SearchResultActions
    let ids: Set<ResultNodeID>

    var body: some View {
        let selected = actions.resolve(ids)
        let folders = actions.folders(for: ids)
        let users = Array(Set(selected.users + folders.map(\.user) + selected.tracks.map(\.user))).sorted()
        let online = model.connection.isConnected
        if !selected.tracks.isEmpty {
            Button(selected.tracks.count > 1 ? "Download \(selected.tracks.count) Files" : "Download File") {
                actions.downloadTracks(selected.tracks)
            }
            .disabled(!online)
        }
        if !folders.isEmpty {
            Button(folders.count > 1 ? "Download \(folders.count) Entire Folders" : "Download Entire Folder") {
                actions.downloadFolders(folders)
            }
            .disabled(!online)
        }
        if users.count == 1, let user = users.first {
            Divider()
            Button("Browse \(user)’s Files") { navigator.browse(user, model: model) }.disabled(!online)
            Button("Get Info for \(user)") { navigator.showProfile(user) }
            Button("Message \(user)") { navigator.message(user) }
            Button("Add \(user) to Users") { Task { await model.bookmark(user) } }
                .disabled(model.users.contains { $0.username == user })
        }
        Divider()
        if !selected.tracks.isEmpty || !folders.isEmpty {
            Button("Copy Path") { copy(selected.tracks.isEmpty ? folders.map(\.path) : selected.tracks.map(\.file.path)) }
        }
        if !users.isEmpty {
            Button(users.count > 1 ? "Copy Usernames" : "Copy Username") { copy(users) }
        }
    }

    private func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
