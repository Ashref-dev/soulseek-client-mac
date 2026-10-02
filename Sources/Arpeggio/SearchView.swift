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
    @State private var selection = Set<SearchResult.ID>()
    @State private var sortOrder = [KeyPathComparator(\SearchResult.slotRank), KeyPathComparator(\SearchResult.speed, order: .reverse)]
    @State private var filters = ResultFilters()
    @State private var grouping = ResultGrouping.none
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
        .onChange(of: model.searchToken) { selection.removeAll() }
        .task(id: ProjectionKey(token: model.searchToken, count: model.results.count, filters: filters, grouping: grouping, sort: sortOrder)) {
            let source = model.results
            let filters = filters; let order = sortOrder; let grouping = grouping
            let output = await Task.detached(priority: .userInitiated) {
                SearchProjection.make(source, filters: filters, order: order, grouping: grouping)
            }.value
            guard !Task.isCancelled else { return }
            projection = output
        }
        .toolbar {
            ToolbarItemGroup {
                if model.searching {
                    Button("Stop", systemImage: "stop.circle") { model.stopSearch() }
                        .help("Stop accepting new results")
                }
                Button("Download", systemImage: "arrow.down.circle") { download(selection) }
                    .disabled(selection.isEmpty || !model.connection.isConnected)
                    .help("Download selected files")
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
        let users = Set(model.results.map(\.user)).count
        return "\(model.results.count.formatted()) results from \(users.formatted()) users" + (model.searching ? " · live" : "")
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
            ResultsTable(model: model, navigator: navigator, groups: projection.groups, selection: $selection, sortOrder: $sortOrder,
                         download: download)
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
            Picker("Group", selection: $grouping) {
                ForEach(ResultGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            if filters.isActive {
                Text("\(count.formatted()) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Clear", systemImage: "xmark.circle.fill") { filters = ResultFilters() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func runSearch() {
        guard model.connection.isConnected else { navigator.showLogin = true; return }
        filters = ResultFilters()
        Task { await model.search() }
    }

    private func download(_ ids: Set<SearchResult.ID>) {
        let items = model.results.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        Task { await model.download(items) }
    }
}

struct ResultsTable: View {
    let model: AppModel
    let navigator: Navigator
    let groups: [ResultGroup]
    @Binding var selection: Set<SearchResult.ID>
    @Binding var sortOrder: [KeyPathComparator<SearchResult>]
    let download: (Set<SearchResult.ID>) -> Void

    var body: some View {
        Table(of: SearchResult.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { result in
                Label {
                    Text(result.name).lineLimit(1).help(result.file.path)
                } icon: {
                    Image(systemName: result.file.symbol).foregroundStyle(.secondary)
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Folder", value: \.folder) { Text($0.folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 220)
            TableColumn("User", value: \.user) { Text($0.user).lineLimit(1) }
                .width(min: 80, ideal: 120)
            TableColumn("Size", value: \.size) { Text(Format.bytes($0.size)).monospacedDigit() }
                .width(min: 60, ideal: 76)
            TableColumn("Quality", value: \.bitrate) { Text($0.file.quality).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn("Length", value: \.length) { Text(Format.clock($0.length)).monospacedDigit() }
                .width(min: 44, ideal: 56)
            TableColumn("Slot", value: \.slotRank) { result in
                Image(systemName: result.freeSlot ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(result.freeSlot ? Color.green : Color.secondary)
                    .help(result.freeSlot ? "Free upload slot" : "Queued: \(result.queue)")
                    .accessibilityLabel(result.freeSlot ? "Free slot" : "Queue \(result.queue)")
            }
            .width(min: 34, ideal: 40)
            TableColumn("Speed", value: \.speed) { Text(Format.speed(Double($0.speed))).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
        } rows: {
            ForEach(groups) { group in
                if group.title.isEmpty {
                    ForEach(group.items) { TableRow($0) }
                } else {
                    Section {
                        ForEach(group.items) { TableRow($0) }
                    } header: {
                        Text("\(group.title)  ·  \(group.items.count)")
                    }
                }
            }
        }
        .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if model.connection.isConnected { download(ids) }
        }
    }

    @ViewBuilder private func menu(for ids: Set<SearchResult.ID>) -> some View {
        let items = model.results.filter { ids.contains($0.id) }
        let users = Array(Set(items.map(\.user))).sorted()
        let online = model.connection.isConnected
        Button(items.count > 1 ? "Download \(items.count) Files" : "Download") { download(ids) }
            .disabled(items.isEmpty || !online)
        if let first = items.first {
            Button("Download Entire Folder") {
                Task { await model.requestFolderDownload(user: first.user, folder: first.folder) }
            }
            .disabled(!online)
        }
        Divider()
        if users.count == 1, let user = users.first {
            Button("Browse \(user)’s Files") { navigator.browse(user, model: model) }.disabled(!online)
            Button("Message \(user)") { navigator.message(user) }
            Button("Get Info for \(user)") { navigator.showProfile(user) }
            Button("Add \(user) to Users") { Task { await model.bookmark(user) } }
                .disabled(model.users.contains { $0.username == user })
            Divider()
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.map(\.file.path).joined(separator: "\n"), forType: .string)
        }
        .disabled(items.isEmpty)
    }
}
