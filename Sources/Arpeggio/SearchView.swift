import SwiftUI
import ArpeggioServices
import SoulseekCore

enum ResultGrouping: String, CaseIterable, Identifiable, Sendable {
    case none = "None", user = "User", folder = "Folder"
    var id: Self { self }
}

struct ResultFilters: Equatable, Sendable {
    var text = ""
    var format = "Any"
    var minBitrate = 0
    var freeSlotsOnly = false
    var audioOnly = false
    var minimumSampleRate = 0
    var minimumBitDepth = 0
    var maximumMegabytes = 0

    var isActive: Bool { !text.isEmpty || format != "Any" || minBitrate > 0 || freeSlotsOnly || audioOnly || minimumSampleRate > 0 || minimumBitDepth > 0 || maximumMegabytes > 0 }

    func matches(_ result: SearchResult) -> Bool {
        if freeSlotsOnly && !result.freeSlot { return false }
        if audioOnly && !result.file.isAudio { return false }
        if format != "Any" && result.file.format != format { return false }
        if minBitrate > 0 && result.file.bitrate < minBitrate && result.file.attributes[5] == nil { return false }
        if minimumSampleRate > 0 && result.file.attributes[4, default: 0] < minimumSampleRate { return false }
        if minimumBitDepth > 0 && result.file.attributes[5, default: 0] < minimumBitDepth { return false }
        if maximumMegabytes > 0 && result.file.size > UInt64(maximumMegabytes) * 1_000_000 { return false }
        if !text.isEmpty {
            let path = result.file.path.lowercased() + " " + result.user.lowercased()
            for term in text.lowercased().split(separator: " ") {
                if term.hasPrefix("-") { if path.contains(term.dropFirst()) { return false } }
                else if !path.contains(term) { return false }
            }
        }
        return true
    }
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
    @State private var expandedUsers = Set<String>()
    @State private var expandedFolders = Set<String>()
    @State private var hierarchy = ResultHierarchy()
    @State private var autoExpandedToken: UInt32?
    @State private var sortOrder = [KeyPathComparator(\SearchResult.slotRank), KeyPathComparator(\SearchResult.speed, order: .reverse)]
    @State private var filters = ResultFilters()
    @FocusState private var searchFocused: Bool
    @State private var projection = SearchProjection()
    @State private var showAdvancedFilters = false

    var body: some View {
        let rows = projection.rows
        VStack(spacing: 0) {
            OfflineNotice(model: model, navigator: navigator)
            if !model.results.isEmpty { filterBar(count: rows.count) }
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
        .onChange(of: model.searchToken) { _, token in
            // Stop clears the token; keep the user's place. Only a new search resets the outline.
            guard token != nil else { return }
            selection.removeAll(); expandedUsers.removeAll(); expandedFolders.removeAll(); autoExpandedToken = nil
            projection = SearchProjection(); hierarchy = ResultHierarchy()
        }
        .task(id: ProjectionKey(token: model.searchToken, count: 0, filters: filters, grouping: .none, sort: sortOrder)) {
            var preparedCount = -1
            while !Task.isCancelled {
                if preparedCount == model.results.count {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                let source = model.results
                let filters = filters; let order = sortOrder
                let work = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let projection = try SearchProjection.make(source, filters: filters, order: order, grouping: .none)
                    try Task.checkCancellation()
                    return (projection, try ResultHierarchy.make(projection.rows))
                }
                do {
                    let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    guard !Task.isCancelled else { return }
                    projection = output.0; hierarchy = output.1
                    preparedCount = source.count
                    autoExpand()
                } catch is CancellationError { return }
                catch { model.error = "Couldn’t prepare the search results. \(error.localizedDescription)"; return }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.searching {
                    Button("Stop", systemImage: "stop.circle") { model.stopSearch() }
                        .help("Stop accepting new results")
                }
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
        return "\(projection.rows.count.formatted()) results from \(users.formatted()) users" + (model.searching ? " · live" : "")
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
                                 expandedUsers: $expandedUsers, expandedFolders: $expandedFolders, actions: actions)
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
        } else {
            ContentUnavailableView {
                Label("Find Something to Listen To", systemImage: "music.quarternote.3")
            } description: {
                Text("Type an artist, album or track in the search field. Prefix a word with – to exclude it.")
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

    private func filterBar(count: Int) -> some View {
        HStack(spacing: 12) {
            TextField("Filter results", text: $filters.text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Picker("Format", selection: $filters.format) {
                Text("Any Format").tag("Any")
                Divider()
                ForEach(projection.formats, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Free slots", isOn: $filters.freeSlotsOnly).toggleStyle(.checkbox)
            Button("Quality", systemImage: "slider.horizontal.3") { showAdvancedFilters.toggle() }
                .popover(isPresented: $showAdvancedFilters) {
                    Form {
                        Toggle("Audio only", isOn: $filters.audioOnly)
                        Picker("Minimum bitrate", selection: $filters.minBitrate) {
                            Text("Any").tag(0)
                            ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                        }
                        Picker("Minimum sample rate", selection: $filters.minimumSampleRate) {
                            Text("Any").tag(0)
                            ForEach([44100, 48000, 96000, 192000], id: \.self) { Text("\(Double($0) / 1000, specifier: "%.1f") kHz").tag($0) }
                        }
                        Picker("Minimum bit depth", selection: $filters.minimumBitDepth) {
                            Text("Any").tag(0); Text("16-bit").tag(16); Text("24-bit").tag(24)
                        }
                        TextField("Maximum size (MB, 0 = any)", value: $filters.maximumMegabytes, format: .number)
                    }.padding(16).frame(width: 340)
                }
            Spacer()
            if filters.isActive {
                Text("\(count.formatted()) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Clear", systemImage: "xmark.circle.fill") { filters = ResultFilters() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func runSearch() {
        guard model.connection.isConnected else { navigator.showLogin = true; return }
        filters = ResultFilters()
        Task { await model.search() }
    }

    private var actions: SearchResultActions { SearchResultActions(model: model, hierarchy: hierarchy) }

    /// Reveal the first few peers' folders once per search so results are readable without clicking.
    private func autoExpand() {
        guard let token = model.searchToken, autoExpandedToken != token, !hierarchy.users.isEmpty else { return }
        autoExpandedToken = token
        expandedUsers.formUnion(hierarchy.users.prefix(3).map(\.id))
    }
}
