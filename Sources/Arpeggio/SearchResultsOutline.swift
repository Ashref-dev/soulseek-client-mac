import SwiftUI
import ArpeggioServices
import SoulseekCore

/// Native outline of search results: user → folder/release → tracks, fully expanded unless the user collapses
/// a branch. A folder can be downloaded whole from its row; audio tracks can be streamed before downloading.
struct SearchResultsOutline: View {
    let model: AppModel
    let navigator: Navigator
    let hierarchy: ResultHierarchy
    @Binding var selection: Set<ResultNodeID>
    @Binding var collapsedUsers: Set<String>
    @Binding var collapsedFolders: Set<String>
    let actions: SearchResultActions

    var body: some View {
        List(selection: $selection) {
            ForEach(hierarchy.users) { user in
                DisclosureGroup(isExpanded: expanded(user.id, unless: $collapsedUsers)) {
                    ForEach(user.folders) { folder in
                        DisclosureGroup(isExpanded: expanded(folder.id, unless: $collapsedFolders)) {
                            ForEach(folder.tracks) { track in
                                TrackResultRow(result: track, model: model) { Task { await model.listen(to: track) } }
                                    .tag(ResultNodeID.track(track.id))
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
        .onKeyPress(.space) {
            guard let track = actions.resolve(selection).tracks.first, track.file.isAudio else { return .ignored }
            Task { await model.listen(to: track) }
            return .handled
        }
    }

    private func expanded(_ id: String, unless collapsed: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { !collapsed.wrappedValue.contains(id) },
                set: { if $0 { collapsed.wrappedValue.remove(id) } else { collapsed.wrappedValue.insert(id) } })
    }

    /// Return/double-click: finished downloads play, other tracks download; user and folder rows toggle.
    private func primary(_ ids: Set<ResultNodeID>) {
        let selected = actions.resolve(ids)
        if selected.tracks.count == 1, let track = selected.tracks.first,
           model.downloadState(user: track.user, path: track.file.path)?.status == .completed, track.file.isAudio {
            Task { await model.listen(to: track) }
            return
        }
        if !selected.tracks.isEmpty {
            if model.connection.isConnected { actions.downloadTracks(selected.tracks) }
            return
        }
        for id in ids {
            switch id {
            case .user(let user): collapsedUsers.formSymmetricDifference([user])
            case .folder(let folder): collapsedFolders.formSymmetricDifference([folder])
            case .track: break
            }
        }
    }
}

/// Resolves outline selections and performs downloads without scanning the full result list.
@MainActor
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
        let fresh = tracks.filter { model.downloadState(user: $0.user, path: $0.file.path) == nil }
        guard !fresh.isEmpty else {
            if !tracks.isEmpty { model.notice = Notice(title: "Already in Downloads", detail: tracks[0].file.name, symbol: "checkmark.circle.fill", action: .showDownloads) }
            return
        }
        model.announceDownload(fresh)
        Task { await model.download(fresh) }
    }

    /// Asks each peer for the complete remote folder, not only the files that matched the search.
    func downloadFolders(_ folders: [ResultFolderNode]) {
        guard let first = folders.first else { return }
        model.announceDownload([], wholeFolder: folders.count == 1 ? first.title : "\(folders.count) folders")
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
        if selected.tracks.count == 1, let track = selected.tracks.first, track.file.isAudio {
            let finished = model.downloadState(user: track.user, path: track.file.path)?.status == .completed
            Button(finished ? "Play" : "Preview (Stream Before Downloading)", systemImage: finished ? "play.fill" : "play.circle") {
                Task { await model.listen(to: track) }
            }
            .disabled(!finished && !online)
            Divider()
        }
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
