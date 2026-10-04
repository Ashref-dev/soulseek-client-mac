import Foundation
import SoulseekCore
import TransferEngine
import Persistence

public struct Notice: Identifiable, Equatable, Sendable {
    public enum Action: Sendable { case showDownloads, none }
    public let id = UUID()
    public let title: String
    public let detail: String
    public let symbol: String
    public let action: Action
    public init(title: String, detail: String, symbol: String, action: Action = .none) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.action = action
    }
}

extension AppModel {
    public static func downloadKey(user: String, path: String) -> String { user + "\u{1F}" + path }

    public func downloadState(user: String, path: String) -> Transfer? { downloadIndex[Self.downloadKey(user: user, path: path)] }

    func indexDownloads(_ transfers: [Transfer]) {
        var index: [String: Transfer] = [:]
        for transfer in transfers where !transfer.upload && !transfer.isPreview && transfer.status != .cancelled {
            index[Self.downloadKey(user: transfer.user, path: transfer.file.path)] = transfer
        }
        downloadIndex = index
    }

    public func announceDownload(_ items: [SearchResult], wholeFolder: String? = nil) {
        if let folder = wholeFolder {
            notice = Notice(title: "Downloading folder", detail: folder, symbol: "arrow.down.circle.fill", action: .showDownloads)
        } else if items.count == 1, let item = items.first {
            notice = Notice(title: "Download started", detail: item.file.name, symbol: "arrow.down.circle.fill", action: .showDownloads)
        } else if !items.isEmpty {
            notice = Notice(title: "Downloading \(items.count) files", detail: items.first.map { $0.file.folder.split(separator: "\\").last.map(String.init) ?? $0.user } ?? "", symbol: "arrow.down.circle.fill", action: .showDownloads)
        }
    }

    /// Plays a finished download, streams an in-progress one, or starts a cached preview transfer.
    public func listen(to result: SearchResult) async {
        guard let format = PreviewFormat.classify(result.file.name) else { error = "This format has no built-in preview. Download it to use another app."; return }
        if format != .streamingAudio {
            if let done = downloadState(user: result.user, path: result.file.path), done.status == .completed,
               let path = done.destination, FileManager.default.fileExists(atPath: path) {
                previewLocal(URL(fileURLWithPath: path), title: result.file.name)
            } else { await fetchPreview(result) }
            return
        }
        if playback.item?.user == result.user, playback.item?.remotePath == result.file.path { playback.togglePlay(); return }
        if let done = downloadState(user: result.user, path: result.file.path), done.status == .completed,
           let path = done.destination, FileManager.default.fileExists(atPath: path) {
            play(file: URL(fileURLWithPath: path), title: result.file.name, subtitle: result.user, info: result.file); return
        }
        guard connection == .connected else { error = "Connect to Soulseek to preview files."; return }
        let selection = reservePlaybackSelection(); let revision = selection.revision
        await discardAbandonedPreviews(selection.abandoned)
        guard revision == playbackRevision else { return }
        do {
            let id = try await transferEngine.preview(result)
            guard revision == playbackRevision else {
                if !isSelectedPreview(id) { await transferEngine.discardPreview(id) }
                return
            }
            let snapshot = await transferEngine.snapshot()
            guard revision == playbackRevision else {
                if !isSelectedPreview(id) { await transferEngine.discardPreview(id) }
                return
            }
            let isPreview = snapshot.first(where: { $0.id == id })?.isPreview ?? true
            playback.playStream(transferID: id, user: result.user, file: result.file, preview: isPreview)
            playback.refresh(snapshot)
        } catch { if revision == playbackRevision { self.error = error.localizedDescription } }
    }

    public func play(file url: URL, title: String, subtitle: String, info: SharedFile? = nil) {
        let selection = reservePlaybackSelection()
        playback.playFile(url, title: title, subtitle: subtitle, file: info)
        Task { await discardAbandonedPreviews(selection.abandoned) }
    }

    public func play(_ transfer: Transfer) {
        guard transfer.status == .completed, let path = transfer.destination, FileManager.default.fileExists(atPath: path) else { return }
        previewLocal(URL(fileURLWithPath: path), title: transfer.file.name)
    }

    public func keepPreview() async {
        guard let item = playback.item, item.isPreview, let id = item.transferID else { return }
        do {
            try await transferEngine.keep(id)
            if playback.item?.transferID == id { playback.markKept() }
            notice = Notice(title: "Saved to Downloads", detail: item.title, symbol: "checkmark.circle.fill", action: .showDownloads)
        } catch { self.error = error.localizedDescription }
    }

    public func stopPlayback() async {
        await abandonCurrentPreview()
    }

    func abandonCurrentPreview() async {
        let selection = reservePlaybackSelection()
        await discardAbandonedPreviews(selection.abandoned)
    }

    func reservePlaybackSelection() -> (revision: UInt64, abandoned: Set<String>) {
        playbackRevision &+= 1
        let previous = playback.stop(); let document = documentPreview; documentPreview = nil
        var ids = Set<String>()
        if let previous, previous.isPreview, let id = previous.transferID { ids.insert(id) }
        if let id = document?.transferID { ids.insert(id) }
        return (playbackRevision, ids)
    }
    func isSelectedPreview(_ id: String) -> Bool {
        playback.item?.transferID == id || documentPreview?.transferID == id
    }
    func discardAbandonedPreviews(_ ids: Set<String>) async {
        for id in ids where !isSelectedPreview(id) { await transferEngine.discardPreview(id) }
    }

    public static func previewDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tn.ashref.arpeggio/Previews", isDirectory: true)
    }
}
