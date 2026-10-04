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
    var statusRank: Int {
        switch status {
        case .transferring: 0
        case .negotiating: 1
        case .queued: 2
        case .paused: 3
        case .failed: 4
        case .completed: 5
        case .cancelled: 6
        }
    }
    var localURL: URL? {
        guard let path = status == .completed ? destination : (partial ?? destination) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Transfers from one user's remote folder, presented like a release (album) with aggregate progress.
struct TransferRelease: Identifiable {
    let id: String
    let user: String
    let folder: String
    var items: [Transfer]

    var title: String { folder.split(separator: "\\").last.map(String.init) ?? (folder.isEmpty ? "Loose Files" : folder) }
    var context: String? { folder.split(separator: "\\").dropLast().last.map(String.init) }
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
    var doneBytes: UInt64 { items.reduce(0) { $0 + ($1.status == .completed ? $1.size : min($1.transferred, $1.size)) } }
    var speed: Double { items.filter { $0.status == .transferring }.reduce(0) { $0 + $1.speed } }
    var progress: Double { totalBytes == 0 ? (isFinished ? 1 : 0) : Double(doneBytes) / Double(totalBytes) }
    var completed: Int { items.filter { $0.status == .completed }.count }
    var failed: Int { items.filter { $0.status == .failed }.count }
    var isFinished: Bool { items.allSatisfy(\.status.isFinished) }
    var isTransferring: Bool { items.contains { $0.status == .transferring } }
    var rank: Int { items.map(\.statusRank).min() ?? 9 }
    var latest: Date { items.map(\.date).max() ?? .distantPast }
    var eta: Double? {
        let remaining = items.filter { !$0.status.isFinished }.reduce(UInt64(0)) { $0 + $1.size - min($1.transferred, $1.size) }
        return speed > 0 ? Double(remaining) / speed : nil
    }

    static func group(_ transfers: [Transfer]) -> [TransferRelease] {
        var order: [String] = []
        var map: [String: TransferRelease] = [:]
        for transfer in transfers {
            let key = transfer.user + "\0" + transfer.file.folder
            if map[key] == nil {
                order.append(key)
                map[key] = TransferRelease(id: key, user: transfer.user, folder: transfer.file.folder, items: [])
            }
            map[key]?.items.append(transfer)
        }
        return order.compactMap { map[$0] }.sorted { ($0.isFinished ? 1 : 0, $0.rank, $1.latest) < ($1.isFinished ? 1 : 0, $1.rank, $0.latest) }
    }
}

struct TransfersView: View {
    let model: AppModel
    let navigator: Navigator
    let upload: Bool
    @State private var selection = Set<Transfer.ID>()
    @State private var preview: URL?
    @State private var filter = ""

    private var items: [Transfer] {
        model.transfers
            .filter { $0.upload == upload && !$0.isPreview }
            .filter { filter.isEmpty || $0.file.path.localizedCaseInsensitiveContains(filter) || $0.user.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending }
    }
    private var selected: [Transfer] { model.transfers.filter { selection.contains($0.id) } }
    private var engine: TransferEngine { model.transferEngine }

    var body: some View {
        let rows = items
        VStack(spacing: 0) {
            OfflineNotice(model: model, navigator: navigator)
            Group { if rows.isEmpty { emptyState } else { table(rows) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            summary(rows)
        }
        .navigationTitle(upload ? "Uploads" : "Downloads")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter transfers")
        .quickLookPreview($preview)
        .toolbar {
            ToolbarItemGroup {
                if !upload {
                    Button("Resume", systemImage: "play.fill") { act(selected, .resume) }
                        .disabled(!selected.contains { [.paused, .failed, .cancelled].contains($0.status) })
                    Button("Pause", systemImage: "pause.fill") { act(selected, .pause) }
                        .disabled(!selected.contains { $0.status.isActive })
                }
                Button("Cancel", systemImage: "xmark") { act(selected, .cancel) }
                    .disabled(!selected.contains { !$0.status.isFinished })
                Button("Clear Completed", systemImage: "checkmark.circle.badge.xmark") { Task { await engine.clearFinished(upload: upload) } }
                    .disabled(!model.transfers.contains { $0.upload == upload && !$0.isPreview && $0.status.isFinished })
                    .help(upload ? "Remove finished uploads from this list" : "Remove finished downloads from this list. Files stay in your download folder.")
                Button("Clear Failed", systemImage: "exclamationmark.triangle") { Task { await engine.clearFailed(upload: upload) } }
                    .disabled(!model.transfers.contains { $0.upload == upload && !$0.isPreview && $0.status == .failed })
                    .help("Remove failed transfers from this list")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if upload {
            ContentUnavailableView("No Uploads", systemImage: "arrow.up.circle",
                                   description: Text(model.settings.sharedFolders.isEmpty
                                                     ? "Share a folder in Settings so others can download from you."
                                                     : "Files other people request from your shares appear here."))
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

    private func table(_ rows: [Transfer]) -> some View {
        Table(of: Transfer.self, selection: $selection) {
            TableColumn("Name") { transfer in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transfer.name).lineLimit(1)
                            .foregroundStyle(transfer.status.isFinished ? .secondary : .primary)
                        if let error = transfer.error, transfer.status == .failed {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                        }
                    }
                } icon: {
                    if transfer.status == .completed && transfer.file.isAudio && transfer.localURL != nil {
                        Button { model.play(transfer) } label: {
                            Image(systemName: isPlaying(transfer) ? "speaker.wave.2.fill" : "play.circle.fill")
                                .foregroundStyle(Color.arpeggio)
                                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying(transfer))
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
            .width(min: 200, ideal: 360)
            TableColumn("Progress") { TransferProgress(transfer: $0) }.width(min: 140, ideal: 190)
            TableColumn("Size") { Text(Format.bytes($0.size)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 56, ideal: 72)
            TableColumn("Speed") { Text($0.status == .transferring ? Format.speed($0.speed) : "-").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 56, ideal: 76)
            TableColumn("Remaining") { Text($0.status == .transferring ? Format.duration($0.eta ?? 0) : "-").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 56, ideal: 76)
        } rows: {
            ForEach(TransferRelease.group(rows)) { release in
                Section {
                    ForEach(release.items) { TableRow($0) }
                } header: {
                    ReleaseHeader(release: release, upload: upload) { action in
                        act(release.items, action)
                    } reveal: {
                        NSWorkspace.shared.activateFileViewerSelecting(release.items.compactMap(\.localURL))
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Transfer.ID.self) { ids in
            menu(model.transfers.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard let transfer = model.transfers.first(where: { ids.contains($0.id) }) else { return }
            if transfer.status == .completed, transfer.file.isAudio, transfer.localURL != nil { model.play(transfer) }
            else if let url = transfer.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .onKeyPress(.space) {
            guard let url = selected.first?.localURL else { return .ignored }
            preview = preview == nil ? url : nil
            return .handled
        }
    }

    @ViewBuilder private func menu(_ transfers: [Transfer]) -> some View {
        if !upload {
            Button("Resume") { act(transfers, .resume) }
                .disabled(!transfers.contains { [.paused, .failed, .cancelled].contains($0.status) })
            Button("Pause") { act(transfers, .pause) }
                .disabled(!transfers.contains { $0.status.isActive })
        }
        Button("Cancel") { act(transfers, .cancel) }
            .disabled(!transfers.contains { !$0.status.isFinished })
        Divider()
        let urls = transfers.compactMap(\.localURL)
        if let playable = transfers.first(where: { $0.status == .completed && $0.file.isAudio && $0.localURL != nil }) {
            Button("Play", systemImage: "play.fill") { model.play(playable) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            .disabled(urls.isEmpty)
        Button("Quick Look") { preview = urls.first }
            .disabled(urls.isEmpty)
        Button("Copy Remote Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transfers.map(\.file.path).joined(separator: "\n"), forType: .string)
        }
        if let user = Set(transfers.map(\.user)).first, Set(transfers.map(\.user)).count == 1 {
            Divider()
            Button("Browse \(user)’s Files") { navigator.browse(user, model: model) }
                .disabled(!model.connection.isConnected)
            Button("Message \(user)") { navigator.message(user) }
        }
    }

    private func isPlaying(_ transfer: Transfer) -> Bool {
        model.playback.isPlaying && model.playback.item?.fileURL?.path == transfer.destination
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
}

enum TransferAction { case resume, pause, cancel }

/// Compact one-line section header: release title, source, aggregate progress and throughput.
struct ReleaseHeader: View {
    let release: TransferRelease
    let upload: Bool
    let perform: (TransferAction) -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: release.isFinished ? "checkmark.circle" : release.failed > 0 ? "exclamationmark.circle" : "square.stack")
                .foregroundStyle(release.isFinished ? Color.secondary : release.failed > 0 ? Color.red : Color.arpeggio)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(release.title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text([release.context, release.user].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            .help(release.folder)
            Spacer(minLength: 8)
            if !release.isFinished {
                ProgressView(value: release.progress)
                    .progressViewStyle(.linear)
                    .tint(release.isTransferring ? .arpeggio : .secondary)
                    .frame(width: 90)
            }
            Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            Menu {
                if !upload {
                    Button("Resume All") { perform(.resume) }
                        .disabled(!release.items.contains { [.paused, .failed, .cancelled].contains($0.status) })
                    Button("Pause All") { perform(.pause) }
                        .disabled(!release.items.contains { $0.status.isActive })
                }
                Button("Cancel All") { perform(.cancel) }
                    .disabled(release.isFinished)
                Divider()
                Button("Show in Finder", action: reveal)
                    .disabled(!release.items.contains { $0.localURL != nil })
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(release.title)")
        }
        .opacity(release.isFinished ? 0.65 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(release.title) from \(release.user), \(detail)")
    }

    private var detail: String {
        let files = "\(release.completed)/\(release.items.count) files"
        if release.isFinished { return "\(files) · \(Format.bytes(release.totalBytes))" }
        var parts = [files, "\(Format.bytes(release.doneBytes)) of \(Format.bytes(release.totalBytes))"]
        if release.speed > 0 { parts.append(Format.speed(release.speed)) }
        if let eta = release.eta { parts.append(Format.duration(eta) + " left") }
        if release.failed > 0 { parts.append("\(release.failed) failed") }
        return parts.joined(separator: " · ")
    }
}

struct TransferProgress: View {
    let transfer: Transfer
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.status.symbol)
                .foregroundStyle(transfer.status.tint)
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
                Text(statusText).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.status.label), \(Int(transfer.progress * 100)) percent")
    }
    private var statusText: String {
        if [.queued, .negotiating].contains(transfer.status) && transfer.queuePosition > 0 { return "Queued · #\(transfer.queuePosition)" }
        return transfer.status.label
    }
}
