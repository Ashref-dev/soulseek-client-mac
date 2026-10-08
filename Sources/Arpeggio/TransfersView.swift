import SwiftUI
import QuickLook
import ArpeggioServices
import SoulseekCore
import TransferEngine

extension TransferStatus {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .negotiating: "Connecting"
        case .transferring: "Transferring"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .negotiating: "antenna.radiowaves.left.and.right"
        case .transferring: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
    var tint: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .transferring, .negotiating: .arpeggio
        default: .secondary
        }
    }
    var isActive: Bool { [.queued, .negotiating, .transferring].contains(self) }
    var isFinished: Bool { [.completed, .cancelled].contains(self) }
}

extension Transfer {
    var name: String { file.name }
    var size: UInt64 { file.size }
    var statusRank: Int { TransferTree.rank(status) }
    var localURL: URL? {
        guard let path = status == .completed ? destination : (partial ?? destination) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Removal is list housekeeping: it never deletes downloaded files, partial data or shared sources.
enum TransferRemoval {
    static func needsConfirmation(_ transfers: [Transfer]) -> Bool { transfers.contains { !$0.status.isFinished } }
    static func activeCount(_ transfers: [Transfer]) -> Int { transfers.filter(\.status.isActive).count }

    static func title(_ transfers: [Transfer]) -> String {
        let noun = transfers.count == 1 ? "transfer" : "\(transfers.count) transfers"
        return activeCount(transfers) > 0 ? "Stop and remove \(noun) from the list?" : "Remove \(noun) from the list?"
    }

    static func message(_ transfers: [Transfer], upload: Bool) -> String {
        let active = activeCount(transfers)
        let stopping = active == 0 ? "" : active == 1 ? "1 is still in progress and stops first. " : "\(active) are still in progress and stop first. "
        let files = upload ? "Your shared files are not touched." : "Files on this Mac, including partly downloaded ones, are not deleted."
        return stopping + files + " Statistics totals stay the same."
    }

    static func confirmTitle(_ transfers: [Transfer]) -> String { activeCount(transfers) > 0 ? "Stop and Remove" : "Remove from List" }
}

struct TransfersView: View {
    let model: AppModel
    let navigator: Navigator
    let upload: Bool
    @AppStorage private var storedLayout: String
    @State private var selection = Set<TransferNodeID>()
    @State private var collapsed = Set<TransferNodeID>()
    @State private var preview: URL?
    @State private var filter = ""
    @State private var missingFiles = Set<String>()
    @State private var pendingRemoval: [Transfer] = []
    @State private var confirmRemoval = false
    /// Nested outline rows only honour their initial expansion once the table exists, so rows open after first appearance.
    @State private var outlineReady = false

    init(model: AppModel, navigator: Navigator, upload: Bool) {
        self.model = model; self.navigator = navigator; self.upload = upload
        _storedLayout = AppStorage(wrappedValue: TransferLayout.fallback.rawValue, TransferLayout.preferenceKey(upload: upload))
    }

    private var layout: TransferLayout { TransferLayout(stored: storedLayout) }
    private var items: [Transfer] {
        model.transfers
            .filter { $0.upload == upload && !$0.isPreview }
            .filter { filter.isEmpty || $0.file.path.localizedCaseInsensitiveContains(filter) || $0.user.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending }
    }
    private var engine: TransferEngine { model.transferEngine }
    private var suspended: Bool { upload ? model.uploadsSuspended : model.downloadsSuspended }
    private var context: TransferQueueContext {
        TransferQueueContext.make(model.transfers, upload: upload, connected: model.connection.isConnected, suspended: suspended,
                                  slots: upload ? model.settings.uploadSlots : model.settings.downloadSlots)
    }

    var body: some View {
        let rows = items
        let tree = TransferTree.make(rows, layout: layout)
        let context = context
        let selected = tree.transfers(for: selection)
        VStack(spacing: 0) {
            OfflineNotice(model: model, navigator: navigator)
            TransferQueueNotice(banner: TransferQueueBanner.make(model.transfers, context: context), upload: upload,
                                connected: model.connection.isConnected) {
                Task { await model.setTransfersSuspended(upload: upload, false) }
            }
            Group { if rows.isEmpty { emptyState } else { table(tree, context: context, selected: selected) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            summary(rows)
        }
        .navigationTitle(upload ? "Uploads" : "Downloads")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter transfers")
        .quickLookPreview($preview)
        .toolbar { toolbar(tree, selected: selected) }
        .task(id: CompletedSignature(rows)) { await refreshMissingFiles(rows) }
        .onChange(of: navigator.expandAllRequest) { if navigator.section == section { expandAll() } }
        .onChange(of: navigator.collapseAllRequest) { if navigator.section == section { collapseAll(tree) } }
        .confirmationDialog(TransferRemoval.title(pendingRemoval), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(TransferRemoval.confirmTitle(pendingRemoval), role: .destructive) { remove(pendingRemoval) }
            Button("Keep in List", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text(TransferRemoval.message(pendingRemoval, upload: upload))
        }
    }

    private var section: SidebarSection { upload ? .uploads : .downloads }

    @ToolbarContentBuilder private func toolbar(_ tree: TransferTree, selected: [Transfer]) -> some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Layout", selection: Binding(get: { layout }, set: { storedLayout = $0.rawValue })) {
                    ForEach(TransferLayout.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Expand All") { expandAll() }.disabled(!layout.hasGroups)
                Button("Collapse All") { collapseAll(tree) }.disabled(!layout.hasGroups)
            } label: {
                Label("Layout: \(layout.title)", systemImage: layout.symbol)
            }
            .help("Show \(upload ? "uploads" : "downloads") flat, by folder, or by person then folder")
            .accessibilityLabel("Layout, \(layout.title)")
        }
        ToolbarItemGroup {
            if !upload {
                Button("Resume", systemImage: "play.fill") { act(selected, .resume) }
                    .disabled(!selected.contains(where: TransferExplanation.allowsManualRetry))
                Button("Pause", systemImage: "pause.fill") { act(selected, .pause) }
                    .disabled(!selected.contains { $0.status.isActive })
            }
            Button("Cancel", systemImage: "xmark") { act(selected, .cancel) }
                .disabled(!selected.contains { !$0.status.isFinished })
            Button("Remove from List", systemImage: "minus.circle") { requestRemoval(selected) }
                .disabled(selected.isEmpty)
                .help("Remove the selected rows from this list. Files on disk are kept. (Delete)")
            Button("Clear Completed", systemImage: "checkmark.circle.badge.xmark") { Task { await engine.clearFinished(upload: upload) } }
                .disabled(!model.transfers.contains { $0.upload == upload && !$0.isPreview && $0.status.isFinished })
                .help(upload ? "Remove finished uploads from this list" : "Remove finished downloads from this list. Files stay in your download folder.")
            Button("Clear Failed", systemImage: "exclamationmark.triangle") { Task { await engine.clearFailed(upload: upload) } }
                .disabled(!model.transfers.contains { $0.upload == upload && !$0.isPreview && $0.status == .failed })
                .help("Remove failed transfers from this list")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if upload {
            let status = model.shareStatus
            ContentUnavailableView {
                Label("No Uploads", systemImage: "arrow.up.circle")
            } description: {
                switch status {
                case .ready: Text("Files other people request from your shares appear here.")
                case .noFolders: Text("Share a folder so others can download from you.")
                default: Text([status.headline, status.detail].compactMap { $0 }.joined(separator: "\n"))
                }
            } actions: {
                if !status.isSharing, !status.isIndexing { Button("Open Shared Files") { navigator.go(.shared) } }
            }
        } else {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Files you download from search or browsing appear here.")
            } actions: {
                Button("Search") { navigator.focusSearch() }
            }
        }
    }

    private func table(_ tree: TransferTree, context: TransferQueueContext, selected: [Transfer]) -> some View {
        Table(of: TransferNode.self, selection: $selection) {
            TableColumn("Name") { node in
                TransferNameCell(node: node, layout: tree.layout, missing: isMissing(node.transfer), playing: isPlaying(node.transfer)) {
                    if let transfer = node.transfer { previewTransfer(transfer) }
                }
            }
            .width(min: 200, ideal: 360)
            TableColumn("Progress") { node in
                if let transfer = node.transfer {
                    TransferProgress(transfer: transfer, reason: TransferExplanation.reason(for: transfer, in: context, fileMissing: isMissing(transfer)), upload: upload)
                } else {
                    GroupProgress(summary: node.summary)
                }
            }
            .width(min: 150, ideal: 210)
            TableColumn("Size") { node in Text(Format.bytes(node.summary.totalBytes)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 56, ideal: 72)
            TableColumn("Speed") { node in
                Text(node.summary.speed > 0 ? Format.speed(node.summary.speed) : "-").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 76)
            TableColumn("Remaining") { node in
                Text(node.summary.eta.map(Format.duration) ?? "-").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 76)
        } rows: {
            ForEach(tree.roots) { root in
                if let children = root.children {
                    DisclosureTableRow(root, isExpanded: expansion(root.id)) {
                        ForEach(children) { child in
                            if let files = child.children {
                                DisclosureTableRow(child, isExpanded: expansion(child.id)) {
                                    ForEach(files) { TableRow($0) }
                                }
                            } else {
                                TableRow(child)
                            }
                        }
                    }
                } else {
                    TableRow(root)
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: TransferNodeID.self) { ids in
            menu(tree.transfers(for: ids))
        } primaryAction: { ids in
            primary(ids, tree: tree)
        }
        .onDeleteCommand { requestRemoval(selected) }
        .onKeyPress(.space) {
            guard let transfer = selected.first, PreviewFormat.classify(transfer.file.name) != nil else { return .ignored }
            previewTransfer(transfer)
            return .handled
        }
        .onChange(of: tree.leaves.count) { pruneSelection(tree) }
        .task {
            guard !outlineReady else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { outlineReady = true }
        }
    }

    @ViewBuilder private func menu(_ transfers: [Transfer]) -> some View {
        if !upload {
            Button(transfers.contains { $0.status == .failed } ? "Retry" : "Resume") { act(transfers, .resume) }
                .disabled(!transfers.contains(where: TransferExplanation.allowsManualRetry))
            Button("Pause") { act(transfers, .pause) }
                .disabled(!transfers.contains { $0.status.isActive })
        }
        Button("Cancel") { act(transfers, .cancel) }
            .disabled(!transfers.contains { !$0.status.isFinished })
        Divider()
        let urls = transfers.compactMap(\.localURL)
        if let playable = transfers.first(where: { PreviewFormat.classify($0.file.name) != nil }) {
            Button("Preview", systemImage: "play.fill") { previewTransfer(playable) }
                .disabled(isMissing(playable) || (playable.status != .completed && upload))
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            .disabled(urls.isEmpty)
        Button("Quick Look") { preview = urls.first }
            .disabled(urls.isEmpty)
        Button("Copy Remote Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transfers.map(\.file.path).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button(transfers.count > 1 ? "Remove \(transfers.count) from List…" : "Remove from List…") { requestRemoval(transfers) }
            .disabled(transfers.isEmpty)
        if let user = Set(transfers.map(\.user)).first, Set(transfers.map(\.user)).count == 1 {
            Divider()
            Button("Browse \(user)’s Files") { navigator.browse(user, model: model) }
                .disabled(!model.connection.isConnected)
            Button("Message \(user)") { navigator.message(user) }
        }
    }

    /// Return or double-click: groups expand or collapse, finished audio plays, other finished files reveal in Finder.
    private func primary(_ ids: Set<TransferNodeID>, tree: TransferTree) {
        let groups = ids.filter { if case .transfer = $0 { return false }; return true }
        if !groups.isEmpty {
            for id in groups { if collapsed.remove(id) == nil { collapsed.insert(id) } }
            return
        }
        guard let transfer = tree.transfers(for: ids).first else { return }
        guard transfer.status == .completed else {
            if let url = transfer.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        switch TransferLocalFiles.action(for: transfer) {
        case .openLocal(let url):
            missingFiles.remove(transfer.id)
            if transfer.file.isAudio { model.previewLocal(url, title: transfer.file.name) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .missing: markMissing(transfer)
        case .streamFromPeer, .unavailable: break
        }
    }

    private func expansion(_ id: TransferNodeID) -> Binding<Bool> {
        Binding(get: { outlineReady && !collapsed.contains(id) },
                set: { expanded in
                    guard outlineReady else { return }
                    if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                })
    }

    private func expandAll() { collapsed.removeAll() }
    private func collapseAll(_ tree: TransferTree) { collapsed = Set(tree.groupIDs) }

    private func pruneSelection(_ tree: TransferTree) {
        let valid = selection.filter(tree.contains)
        if valid.count != selection.count { selection = valid }
    }

    private func isMissing(_ transfer: Transfer?) -> Bool { transfer.map { missingFiles.contains($0.id) } ?? false }

    private func isPlaying(_ transfer: Transfer?) -> Bool {
        guard let transfer else { return false }
        return model.playback.isPlaying && model.playback.item?.fileURL?.path == transfer.destination
    }

    /// Play, Preview and Space re-check the file at that moment. A finished download is never fetched from the peer again.
    private func previewTransfer(_ transfer: Transfer) {
        switch TransferLocalFiles.action(for: transfer) {
        case .openLocal(let url):
            missingFiles.remove(transfer.id)
            model.previewLocal(url, title: transfer.file.name)
        case .missing:
            markMissing(transfer)
        case .streamFromPeer:
            Task { await model.listen(to: SearchResult(user: transfer.user, file: transfer.file, freeSlot: false, speed: 0, queue: 0)) }
        case .unavailable:
            break
        }
    }

    private func markMissing(_ transfer: Transfer) {
        missingFiles.insert(transfer.id)
        model.notice = Notice(title: "File missing", detail: transfer.file.name, symbol: "questionmark.folder.fill")
    }

    /// Finished downloads whose file has moved or been deleted are found off the main thread and kept as rows.
    private func refreshMissingFiles(_ rows: [Transfer]) async {
        let finished = rows.filter { !$0.upload && $0.status == .completed }
        let missing = await Task.detached(priority: .utility) { TransferLocalFiles.missing(finished) }.value
        guard !Task.isCancelled, missing != missingFiles else { return }
        missingFiles = missing
    }

    private func requestRemoval(_ transfers: [Transfer]) {
        guard !transfers.isEmpty else { return }
        if TransferRemoval.needsConfirmation(transfers) { pendingRemoval = transfers; confirmRemoval = true } else { remove(transfers) }
    }

    private func remove(_ transfers: [Transfer]) {
        let ids = Set(transfers.map(\.id))
        pendingRemoval = []
        guard !ids.isEmpty else { return }
        let upload = upload
        Task {
            guard await model.removeTransfers(ids) else { return }
            selection = selection.filter { if case .transfer(let id) = $0 { return !ids.contains(id) }; return true }
            model.notice = Notice(title: ids.count == 1 ? "Removed from list" : "Removed \(ids.count) from list",
                                  detail: upload ? "Shared files were not touched" : "Files on disk were kept", symbol: "minus.circle.fill")
        }
    }

    private func summary(_ rows: [Transfer]) -> some View {
        let active = rows.filter { $0.status == .transferring }
        let speed = active.reduce(0) { $0 + $1.speed }
        return HStack(spacing: 16) {
            Stepper(value: slotBinding, in: 1...20) {
                Label("\(active.count) of \(upload ? model.settings.uploadSlots : model.settings.downloadSlots) slots", systemImage: "square.stack.3d.up")
                    .monospacedDigit()
            }
            .help(upload ? "How many people can download from you at once" : "How many files download at once")
            Menu {
                Picker("Speed Limit", selection: limitBinding) {
                    Text("Unlimited").tag(0)
                    Divider()
                    ForEach([128, 256, 512, 1024, 2048, 5120, 10240], id: \.self) { Text(Self.limitLabel($0)).tag($0) }
                    if ![0, 128, 256, 512, 1024, 2048, 5120, 10240].contains(limitBinding.wrappedValue) {
                        Text(Self.limitLabel(limitBinding.wrappedValue)).tag(limitBinding.wrappedValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(limitBinding.wrappedValue == 0 ? "No speed limit" : "Max \(Self.limitLabel(limitBinding.wrappedValue))", systemImage: "gauge.with.dots.needle.33percent")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(upload ? "Limit how fast others download from you" : "Limit download speed")
            if speed > 0 {
                Label(Format.speed(speed), systemImage: upload ? "arrow.up" : "arrow.down")
                    .monospacedDigit().foregroundStyle(Color.arpeggio)
                    .contentTransition(.numericText())
            }
            Spacer()
            if !upload {
                Toggle("Clear when finished", isOn: Binding(get: { model.settings.autoClearDownloads ?? false },
                                                             set: { model.settings.autoClearDownloads = $0; Task { await model.saveSettings() } }))
                    .toggleStyle(.checkbox)
                    .help("Remove finished downloads from this list automatically. Files stay in your download folder.")
            }
            Text("\(rows.filter { $0.status == .completed }.count) completed").monospacedDigit()
            if !upload {
                Button("Open Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.downloadDirectory))
                }
                .buttonStyle(.borderless)
                .disabled(!FileManager.default.fileExists(atPath: model.settings.downloadDirectory))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var slotBinding: Binding<Int> {
        Binding(get: { upload ? model.settings.uploadSlots : model.settings.downloadSlots }, set: { value in
            if upload { model.settings.uploadSlots = value } else { model.settings.downloadSlots = value }
            Task { await model.saveSettings() }
        })
    }

    private var limitBinding: Binding<Int> {
        Binding(get: { (upload ? model.settings.uploadLimitKB : model.settings.downloadLimitKB) ?? 0 }, set: { value in
            if upload { model.settings.uploadLimitKB = value } else { model.settings.downloadLimitKB = value }
            Task { await model.saveSettings() }
        })
    }

    static func limitLabel(_ kilobytes: Int) -> String {
        kilobytes >= 1024 ? "\((Double(kilobytes) / 1024).formatted(.number.precision(.fractionLength(0...1)))) MB/s" : "\(kilobytes) KB/s"
    }

    private func act(_ transfers: [Transfer], _ action: TransferAction) {
        let ids = transfers.filter {
            switch action {
            case .resume: [.paused, .failed, .cancelled].contains($0.status)
            case .pause: $0.status.isActive
            case .cancel: !$0.status.isFinished
            }
        }.map(\.id)
        guard !ids.isEmpty else { return }
        if action == .resume {
            let retrying = transfers.filter { $0.status == .failed }.count
            model.notice = Notice(title: retrying == ids.count ? "Retrying \(Self.count(ids.count, "download"))" : "Resuming \(Self.count(ids.count, "download"))",
                                  detail: suspended ? "Downloads are paused. Resume Downloads to start them." : "They start as slots free up",
                                  symbol: "arrow.clockwise.circle.fill")
        }
        let engine = engine
        Task {
            for id in ids {
                switch action {
                case .resume: await engine.resume(id)
                case .pause: await engine.pause(id)
                case .cancel: await engine.cancel(id)
                }
            }
        }
    }

    private static func count(_ value: Int, _ noun: String) -> String { value == 1 ? "1 \(noun)" : "\(value) \(noun)s" }
}

enum TransferAction { case resume, pause, cancel }

/// Changes when the set of finished downloads or their saved paths changes, which is when files need checking.
private struct CompletedSignature: Equatable {
    let value: Int
    init(_ rows: [Transfer]) {
        var hasher = Hasher()
        for row in rows where !row.upload && row.status == .completed { hasher.combine(row.id); hasher.combine(row.destination) }
        value = hasher.finalize()
    }
}

/// Global pause with an inline Resume, or a quiet line saying why work is waiting.
private struct TransferQueueNotice: View {
    let banner: TransferQueueBanner?
    let upload: Bool
    let connected: Bool
    let resume: () -> Void

    var body: some View {
        switch banner {
        case .paused(let waiting):
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").foregroundStyle(Color.arpeggio).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(upload ? "Uploads are paused" : "Downloads are paused").font(.callout.weight(.semibold))
                    Text(waiting == 0 ? "Nothing is waiting. Your status is unchanged."
                         : "\(waiting) waiting. Partial data is kept and continues when you resume.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(upload ? "Resume Uploads" : "Resume Downloads", action: resume)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.arpeggio.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        case .queued(let remote, let local) where connected:
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(Self.queueLine(remote: remote, local: local, upload: upload))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .help(upload ? "Uploads wait for one of your upload slots. Raise slots in the bar below."
                         : "Other people's clients decide when queued requests start. Your own slots are set in the bar below.")
            .overlay(alignment: .bottom) { Divider() }
        default:
            EmptyView()
        }
    }

    static func queueLine(remote: Int, local: Int, upload: Bool) -> String {
        var parts: [String] = []
        if remote > 0 { parts.append(upload ? "\(remote) waiting for people to accept" : "\(remote) waiting in other people’s queues") }
        if local > 0 { parts.append("\(local) waiting for one of your \(upload ? "upload" : "download") slots") }
        return parts.joined(separator: " · ")
    }
}

/// Name column: people and folders read as headings; files show play state, errors and missing files.
private struct TransferNameCell: View {
    let node: TransferNode
    let layout: TransferLayout
    let missing: Bool
    let playing: Bool
    let play: () -> Void

    var body: some View {
        switch node.kind {
        case .user:
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(node.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(files).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } icon: {
                Image(systemName: "person.crop.circle").foregroundStyle(Color.arpeggio)
            }
            .accessibilityLabel("\(node.title), \(files)")
        case .folder:
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(node.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(folderContext).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(node.folder.isEmpty ? "Files shared from \(node.user)’s share root" : node.folder)
            } icon: {
                Image(systemName: node.summary.failed > 0 ? "exclamationmark.circle" : node.summary.isFinished ? "checkmark.circle" : "folder")
                    .foregroundStyle(node.summary.failed > 0 ? Color.red : node.summary.isFinished ? Color.secondary : Color.arpeggio)
            }
            .opacity(node.summary.isFinished ? 0.75 : 1)
            .accessibilityLabel("\(node.title) from \(node.user), \(files)")
        case .file:
            if let transfer = node.transfer { file(transfer) }
        }
    }

    private var files: String {
        let summary = node.summary
        return summary.completed == summary.files ? "\(summary.files) \(summary.files == 1 ? "file" : "files")" : "\(summary.completed)/\(summary.files) files"
    }

    private var folderContext: String {
        let user = layout == .folders ? node.user : nil
        return [node.context, user, files].compactMap { $0 }.joined(separator: " · ")
    }

    private func file(_ transfer: Transfer) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(transfer.name).lineLimit(1)
                        .foregroundStyle(transfer.status.isFinished ? .secondary : .primary)
                    if layout == .flat, let context = node.context {
                        Text(context).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if missing {
                    Text("Moved or deleted outside Arpeggio").font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if let error = transfer.error, transfer.status == .failed {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                }
            }
        } icon: {
            if missing {
                Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                    .help("The downloaded file is no longer at its saved location")
            } else if transfer.status == .completed && transfer.file.isAudio && !transfer.upload {
                Button(action: play) {
                    Image(systemName: playing ? "speaker.wave.2.fill" : "play.circle.fill")
                        .foregroundStyle(Color.arpeggio)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing)
                }
                .buttonStyle(.plain)
                .help("Play")
                .accessibilityLabel("Play \(transfer.name)")
            } else {
                Image(systemName: transfer.file.symbol).foregroundStyle(.tertiary)
            }
        }
        .help(transfer.file.path)
    }
}

/// Aggregate progress for a person or folder row.
private struct GroupProgress: View {
    let summary: TransferSummary

    var body: some View {
        HStack(spacing: 8) {
            if summary.isFinished {
                Text(summary.failed > 0 ? "\(summary.failed) failed" : "Done").foregroundStyle(.secondary)
            } else {
                ProgressView(value: summary.progress)
                    .progressViewStyle(.linear)
                    .tint(summary.isTransferring ? .arpeggio : .secondary)
                Text(summary.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var parts = ["\(summary.completed) of \(summary.files) files done", "\(Int(summary.progress * 100)) percent"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: ", ")
    }
}

struct TransferProgress: View {
    let transfer: Transfer
    let reason: TransferReason
    let upload: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            if transfer.status == .transferring || (transfer.status == .paused && transfer.transferred > 0) {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .tint(transfer.status == .paused ? .secondary : .arpeggio)
                Text(transfer.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text(TransferExplanation.label(reason)).foregroundStyle(reason.isProblem ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
        }
        .help(TransferExplanation.detail(reason, upload: upload))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(TransferExplanation.label(reason)), \(Int(transfer.progress * 100)) percent")
        .accessibilityHint(TransferExplanation.detail(reason, upload: upload))
    }

    private var symbol: String {
        switch reason {
        case .fileMissing: "questionmark.folder"
        case .directionPaused: "pause.circle"
        case .retrying: "arrow.clockwise.circle"
        case .remoteQueue: "person.2.wave.2"
        case .waitingForLocalSlot: "square.stack.3d.up"
        case .offline: "bolt.horizontal.circle"
        case .peerDeferred: "hand.raised"
        case .waitingToStart: "clock"
        case .storageRecovery: "externaldrive.badge.exclamationmark"
        case .stopping: "stop.circle"
        default: transfer.status.symbol
        }
    }

    private var tint: Color {
        switch reason {
        case .fileMissing: .orange
        case .retrying: .arpeggio
        default: transfer.status.tint
        }
    }
}
