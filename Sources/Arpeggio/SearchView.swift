import SwiftUI
import ArpeggioServices
import SoulseekCore

enum ResultGrouping: String, CaseIterable, Identifiable, Sendable {
    case none = "None", user = "User", folder = "Folder"
    var id: Self { self }
}

struct ResultGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [SearchResult]
}

extension SearchResult {
    var name: String { file.name }
    var folder: String { file.folder }
    var size: UInt64 { file.size }
    var bitrate: UInt32 { file.bitrate }
    var length: UInt32 { file.length }
    var slotRank: Int { freeSlot ? 0 : 1 }
}

struct SearchView: View {
    @Bindable var model: AppModel
    let navigator: Navigator
    @State private var selection = Set<ResultNodeID>()
    @State private var collapsedUsers = Set<String>()
    @State private var collapsedFolders = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SearchResult.slotRank), KeyPathComparator(\SearchResult.speed, order: .reverse)]
    @State private var filters = ResultFilters()
    @FocusState private var searchFocused: Bool
    @State private var pipeline = SearchPreparation.pipeline()
    @State private var generation: UInt64 = 0

    private var projection: SearchProjection { pipeline.output?.projection ?? SearchProjection() }
    private var hierarchy: ResultHierarchy { pipeline.output?.hierarchy ?? ResultHierarchy() }

    var body: some View {
        let rows = projection.rows
        VStack(spacing: 0) {
            OfflineNotice(model: model, navigator: navigator)
            if !model.results.isEmpty {
                SearchFilterBar(filters: $filters, formats: projection.formats, shown: rows.count,
                                expandAll: expandAll, collapseAll: collapseAll)
            }
            content(rows).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Search")
        .navigationSubtitle(subtitle)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Artist, album, track…")
        .searchFocused($searchFocused)
        .searchSuggestions {
            if model.query.isEmpty {
                ForEach(model.history.prefix(8)) { item in
                    Label(item.query, systemImage: "clock.arrow.circlepath").searchCompletion(item.query)
                }
            }
        }
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: navigator.searchFocusRequest) { searchFocused = true }
        .onChange(of: navigator.expandAllRequest) { expandAll() }
        .onChange(of: navigator.collapseAllRequest) { collapseAll() }
        .onChange(of: model.searchToken) { _, token in
            guard token != nil else { return }
            resetOutline()
        }
        .onChange(of: model.results.isEmpty) { _, empty in if empty { resetOutline() } }
        .onChange(of: ProjectionKey(token: model.searchToken, filters: filters, sort: sortOrder), initial: true) { old, new in
            restartPreparation(clear: old.token != new.token)
        }
        .onChange(of: model.results.count) { submitResults() }
        .onChange(of: pipeline.failure) { _, failure in
            if let failure { model.error = "Couldn’t prepare the search results. \(failure)" }
        }
        .onDisappear { pipeline.cancel() }
        .toolbar {
            ToolbarItemGroup {
                if model.searching {
                    Button("Stop", systemImage: "stop.circle") { model.stopSearch() }
                        .help("Stop accepting new results now")
                }
                Button("Clear", systemImage: "xmark.circle") { clear() }
                    .disabled(model.results.isEmpty && model.query.isEmpty)
                    .help("Clear the search and its results (⇧⌘⌫)")
                Button("Download", systemImage: "arrow.down.circle") { actions.download(selection) }
                    .disabled(!selection.contains(where: { if case .user = $0 { return false }; return true }) || !model.connection.isConnected)
                    .help("Download selected files; selected folders download in full")
                Button("Add to Wishlist", systemImage: "star") {
                    let query = model.query
                    Task { await model.addWish(query) }
                }
                .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Keep looking for this search in the background")
            }
        }
    }

    private var subtitle: String {
        if model.results.isEmpty { return model.searching ? "Searching…" : "" }
        let users = hierarchy.users.count
        return "\(projection.rows.count.formatted()) results from \(users.formatted()) users" + (model.searching ? " · live" : " · done")
    }

    @ViewBuilder private func content(_ rows: [SearchResult]) -> some View {
        if model.results.isEmpty {
            emptyState
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No Matching Results", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("\(model.results.count.formatted()) results are hidden by the current filters.")
            } actions: {
                Button("Clear Filters") { filters = ResultFilters() }
            }
        } else {
            SearchResultsOutline(model: model, navigator: navigator, hierarchy: hierarchy, selection: $selection,
                                 collapsedUsers: $collapsedUsers, collapsedFolders: $collapsedFolders, actions: actions)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.searching {
            ContentUnavailableView {
                Label("Listening for Results", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } description: {
                Text("Peers answer over the next few seconds. Results appear as they arrive.")
            }
        } else if !model.connection.isConnected {
            ContentUnavailableView {
                Label("Search the Soulseek Network", systemImage: "music.quarternote.3")
            } description: {
                Text("Connect your account to search files shared by other people.")
            } actions: {
                Button("Connect…") { navigator.showLogin = true }.disabled(model.connection.isBusy)
            }
        } else if !model.query.isEmpty && model.searchToken == nil && model.history.first?.query == model.query.trimmingCharacters(in: .whitespacesAndNewlines) {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No one answered “\(model.query)”. Try fewer or different words.")
            } actions: {
                Button("Search Again") { runSearch() }
            }
        } else {
            ContentUnavailableView {
                Label("Find Something to Listen To", systemImage: "music.quarternote.3")
            } description: {
                Text("Type an artist, album or track in the search field. Prefix a word with - to exclude it.")
            } actions: {
                if !model.history.isEmpty {
                    HStack {
                        ForEach(model.history.prefix(4)) { item in
                            Button(item.query) { navigator.runSearch(item.query, model: model) }
                        }
                    }
                }
            }
        }
    }

    private func runSearch() {
        guard model.connection.isConnected else { navigator.showLogin = true; return }
        filters = ResultFilters()
        Task { await model.search() }
    }

    private func clear() {
        model.clearSearch()
        filters = ResultFilters()
        resetOutline()
        searchFocused = true
    }

    private func resetOutline() {
        selection.removeAll(); collapsedUsers.removeAll(); collapsedFolders.removeAll()
        restartPreparation(clear: true)
    }

    /// A new search, filter or sort order starts a new generation; older preparations can no longer publish.
    private func restartPreparation(clear: Bool) {
        generation &+= 1
        pipeline.reset(generation: generation, clear: clear)
        submitResults()
    }

    /// Called only when results actually change: no polling while a search is idle.
    private func submitResults() {
        pipeline.submit(SearchSnapshot(results: model.results, filters: filters, order: sortOrder))
    }

    private func expandAll() {
        withAnimation(.smooth(duration: 0.25)) { collapsedUsers.removeAll(); collapsedFolders.removeAll() }
    }

    private func collapseAll() {
        withAnimation(.smooth(duration: 0.25)) {
            collapsedUsers = Set(hierarchy.users.map(\.id))
            collapsedFolders = Set(hierarchy.folders.keys)
        }
    }

    private var actions: SearchResultActions { SearchResultActions(model: model, hierarchy: hierarchy) }
}
