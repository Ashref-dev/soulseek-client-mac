import Foundation
import SoulseekCore

extension TransferEngine {
    public func setPreviewRoot(_ root: URL) { previewRoot = root }

    /// Starts (or reuses) a transfer that can be played while it arrives. Previews live in a cache folder
    /// until kept, skip the download-slot limit, and are discarded when abandoned or on relaunch.
    public func preview(_ result: SearchResult) async throws -> String {
        guard result.file.size <= 16 * 1024 * 1024 * 1024 else { throw ProtocolError.oversized }
        if let existing = transfers.first(where: { !$0.upload && $0.user == result.user && $0.file.path == result.file.path && $0.status != .cancelled }) {
            if [.failed, .paused].contains(existing.status) { await resume(existing.id) }
            return existing.id
        }
        let (destination, partial) = try SafeDestination.plan(root: previewRoot, user: result.user, remotePath: result.file.path)
        var transfer = Transfer(user: result.user, file: result.file)
        transfer.destination = destination.path; transfer.partial = partial.path; transfer.preview = true
        transfers.insert(transfer, at: 0)
        try await database.put(transfer, collection: "transfers", id: transfer.id)
        publish(); await pump()
        return transfer.id
    }

    /// Turns a preview into a normal download. Finished files move into the download folder;
    /// unfinished ones keep their partial bytes and complete straight into it.
    public func keep(_ id: String) async throws {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].isPreview else { return }
        let item = transfers[index]
        var (destination, _) = try SafeDestination.plan(root: downloadRoot, user: item.user, remotePath: item.file.path, layout: layout)
        if item.status == .completed, let current = item.destination {
            destination = try SafeDestination.publish(URL(fileURLWithPath: current), to: destination)
        }
        guard let fresh = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[fresh].destination = destination.path
        transfers[fresh].preview = nil
        transfers[fresh].date = Date()
        if transfers[fresh].status == .cancelled { transfers[fresh].status = .queued }
        await save(transfers[fresh]); publish(); await pump()
    }

    public func discardPreview(_ id: String) async {
        guard let item = transfers.first(where: { $0.id == id }), item.isPreview else { return }
        if !item.status.isTerminal { await change(id, to: .cancelled) }
        guard let current = transfers.first(where: { $0.id == id }), current.isPreview else { return }
        await removePreviewFiles(current)
        transfers.removeAll { $0.id == id }
        try? await database.remove(collection: "transfers", id: id)
        publish(); await pump()
    }

    public func snapshot() -> [Transfer] { transfers }

    /// Deletes everything in the preview cache that no transfer still points at (abandoned previews,
    /// leftovers from a crash). Kept previews still finishing keep their partial file.
    public func purgePreviewCache() {
        let manager = FileManager.default
        let root = previewRoot.standardizedFileURL
        guard manager.fileExists(atPath: root.path), root.resolvingSymlinksInPath().path == root.path else { return }
        let referenced = Set(transfers.flatMap { [$0.partial, $0.destination] }.compactMap { $0.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true { directories.append(url); continue }
            if !referenced.contains(url.standardizedFileURL.path) { try? manager.removeItem(at: url) }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? manager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true { try? manager.removeItem(at: directory) }
        }
    }

    func removePreviewFiles(_ item: Transfer) async {
        let root = previewRoot.resolvingSymlinksInPath().path + "/"
        for path in [item.partial, item.destination].compactMap({ $0 }) {
            let url = URL(fileURLWithPath: path)
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
            guard parent.hasPrefix(root), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension TransferStatus {
    var isTerminal: Bool { self == .completed || self == .cancelled }
}
