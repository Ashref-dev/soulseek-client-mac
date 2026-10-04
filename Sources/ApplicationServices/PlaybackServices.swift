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
        if playback.item?.user == result.user, playback.item?.remotePath == result.file.path { playback.togglePlay(); return }
        if let done = downloadState(user: result.user, path: result.file.path), done.status == .completed,
           let path = done.destination, FileManager.default.fileExists(atPath: path) {
            play(file: URL(fileURLWithPath: path), title: result.file.name, subtitle: result.user, info: result.file); return
        }
        guard connection == .connected else { error = "Connect to Soulseek to preview files."; return }
        playbackRevision &+= 1; let revision = playbackRevision
        do {
            let id = try await transferEngine.preview(result)
            guard revision == playbackRevision else {
                if playback.item?.transferID != id { await transferEngine.discardPreview(id) }
                return
            }
            let isPreview = transfers.first(where: { $0.id == id })?.isPreview ?? true
            let previous = playback.item
            playback.playStream(transferID: id, user: result.user, file: result.file, preview: isPreview)
            playback.refresh(transfers)
            await discardIfPreview(previous, except: id)
        } catch { if revision == playbackRevision { self.error = error.localizedDescription } }
    }

    public func play(file url: URL, title: String, subtitle: String, info: SharedFile? = nil) {
        playbackRevision &+= 1
        let previous = playback.item
        playback.playFile(url, title: title, subtitle: subtitle, file: info)
        Task { await discardIfPreview(previous, except: nil) }
    }

    public func play(_ transfer: Transfer) {
        guard transfer.status == .completed, let path = transfer.destination, FileManager.default.fileExists(atPath: path) else { return }
        play(file: URL(fileURLWithPath: path), title: transfer.file.name, subtitle: transfer.user, info: transfer.file)
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
        playbackRevision &+= 1
        let previous = playback.stop()
        await discardIfPreview(previous, except: nil)
    }

    private func discardIfPreview(_ item: Playback.Item?, except keep: String?) async {
        guard let item, item.isPreview, let id = item.transferID, id != keep else { return }
        await transferEngine.discardPreview(id)
    }

    public static func previewDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tn.ashref.arpeggio/Previews", isDirectory: true)
    }
}
