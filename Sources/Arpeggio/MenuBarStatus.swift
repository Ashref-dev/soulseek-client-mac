import SwiftUI
import Observation
import ArpeggioServices
import TransferEngine

/// What the menu bar icon shows. It depends only on the connection, Away, and whether bytes are moving in
/// either direction, so the icon redraws when one of those changes and never on speed or progress ticks.
/// Moving bytes win over Away: the icon shows the transfer, and the panel still shows Away.
enum MenuBarState: CaseIterable, Hashable, Sendable {
    case offline, available, away, downloading, uploading, downloadingAndUploading

    init(presence: Presence, transfers: [Transfer]) {
        guard presence != .offline else { self = .offline; return }
        var downloading = false, uploading = false
        for transfer in transfers where transfer.status == .transferring && !transfer.isPreview {
            if transfer.upload { uploading = true } else { downloading = true }
            if downloading, uploading { break }
        }
        switch (downloading, uploading) {
        case (true, true): self = .downloadingAndUploading
        case (true, false): self = .downloading
        case (false, true): self = .uploading
        case (false, false): self = presence == .away ? .away : .available
        }
    }

    @MainActor init(_ model: AppModel) { self.init(presence: model.presence, transfers: model.transfers) }

    var isDownloading: Bool { self == .downloading || self == .downloadingAndUploading }
    var isUploading: Bool { self == .uploading || self == .downloadingAndUploading }
    var isTransferring: Bool { isDownloading || isUploading }

    var accessibilityLabel: String {
        switch self {
        case .offline: "Arpeggio, offline"
        case .available: "Arpeggio, available"
        case .away: "Arpeggio, away"
        case .downloading: "Arpeggio, downloading"
        case .uploading: "Arpeggio, uploading"
        case .downloadingAndUploading: "Arpeggio, downloading and uploading"
        }
    }
}

/// The label's only observable input. `follow` reduces every model change, transfer ticks included, to a
/// MenuBarState and writes `state` only when that differs, so the menu bar label re-renders only then.
@MainActor @Observable
final class MenuBarStatus {
    private(set) var state = MenuBarState.offline

    func follow(_ model: AppModel) async {
        for await next in Observations({ MenuBarState(model) }) where next != state {
            state = next
        }
    }
}

/// One direction of transfers as the panel summarises it. Previews are left out, as in the transfer lists.
struct TransferPulse: Equatable, Sendable {
    /// Files moving bytes right now.
    var transferring = 0
    /// Files queued or connecting.
    var waiting = 0
    /// Different people among the moving files.
    var people = 0
    var speed: Double = 0
    /// How far the moving files are, by bytes. Nil while nothing moves.
    var progress: Double?

    init() {}

    init(_ transfers: [Transfer], upload: Bool) {
        var users = Set<String>(), done: UInt64 = 0, total: UInt64 = 0
        for transfer in transfers where transfer.upload == upload && !transfer.isPreview {
            switch transfer.status {
            case .transferring:
                transferring += 1
                speed += transfer.speed
                users.insert(transfer.user)
                done += min(transfer.transferred, transfer.file.size)
                total += transfer.file.size
            case .queued, .negotiating:
                waiting += 1
            case .paused, .completed, .failed, .cancelled:
                break
            }
        }
        people = users.count
        progress = transferring > 0 && total > 0 ? Double(done) / Double(total) : nil
    }
}

/// Everything in the panel that can change often: transfers, lifetime totals and indexing. The panel reads
/// these only through MenuBarPanelFeed, which samples them while the panel is open.
struct MenuBarPanelLive: Equatable {
    var downloads = TransferPulse()
    var uploads = TransferPulse()
    var share = ShareStatus.pending
    var uploadedBytes: UInt64 = 0
    var downloadedBytes: UInt64 = 0
    var listeners = 0
    var since: Date?
    var downloadsFolderExists = false

    init() {}

    @MainActor init(_ model: AppModel) {
        downloads = TransferPulse(model.transfers, upload: false)
        uploads = TransferPulse(model.transfers, upload: true)
        share = model.shareStatus
        uploadedBytes = model.statistics.uploadedBytes
        downloadedBytes = model.statistics.downloadedBytes
        listeners = model.statistics.listeners.count
        since = model.statistics.since
        downloadsFolderExists = FileManager.default.fileExists(atPath: model.settings.downloadDirectory)
    }
}

/// Samples MenuBarPanelLive for the open panel: the current values at once, then at most one update per
/// `interval` while anything changes. Nothing runs while the panel is closed.
@MainActor @Observable
final class MenuBarPanelFeed {
    static let interval = Duration.milliseconds(500)
    private(set) var live = MenuBarPanelLive()

    func refresh(_ model: AppModel) {
        let next = MenuBarPanelLive(model)
        if next != live { live = next }
    }

    func follow(_ model: AppModel) async {
        for await next in Observations({ MenuBarPanelLive(model) }) {
            if next != live { live = next }
            do { try await Task.sleep(for: Self.interval) } catch { return }
        }
    }
}

/// Requests from the menu bar panel for the main window. Opening the window comes first and the window may
/// not exist yet, so a request waits until the window takes it.
@MainActor @Observable
final class MenuBarRoute {
    enum Request: Equatable, Sendable { case search, sharedFiles, signIn }

    private(set) var revision = 0
    @ObservationIgnored private var pending: Request?

    func send(_ request: Request) {
        pending = request
        revision += 1
    }

    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}
