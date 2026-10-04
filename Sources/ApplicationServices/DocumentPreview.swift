import Foundation
import SoulseekCore
import TransferEngine

public struct DocumentPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public var transferID: String?
    public var url: URL?
    public var status: String
    public var failure: String?
}

extension AppModel {
    func fetchPreview(_ result: SearchResult) async {
        guard connection == .connected else { error = "Connect to Soulseek to preview files."; return }
        let selection = reservePlaybackSelection(); let revision = selection.revision
        let identity = UUID()
        documentPreview = DocumentPreview(id: identity, title: result.file.name, status: "Requesting the file from \(result.user)…")
        await discardAbandonedPreviews(selection.abandoned)
        guard revision == playbackRevision, documentPreview?.id == identity else { return }
        do {
            let id = try await transferEngine.preview(result)
            guard revision == playbackRevision, documentPreview?.id == identity else {
                if !isSelectedPreview(id) { await transferEngine.discardPreview(id) }
                return
            }
            documentPreview?.transferID = id
            let snapshot = await transferEngine.snapshot()
            guard revision == playbackRevision, documentPreview?.id == identity else { return }
            refreshDocumentPreview(snapshot)
        } catch {
            if documentPreview?.id == identity { documentPreview?.failure = error.localizedDescription }
        }
    }

    func refreshDocumentPreview(_ transfers: [Transfer]) {
        guard let preview = documentPreview, let id = preview.transferID,
              let transfer = transfers.first(where: { $0.id == id }) else { return }
        switch transfer.status {
        case .completed:
            guard let path = transfer.destination else { return }
            let url = URL(fileURLWithPath: path)
            if PreviewFormat.classify(transfer.file.name)?.isAudio == true {
                documentPreview = nil
                playback.playCompletedTransfer(transfer, url: url)
            } else { documentPreview?.url = url; documentPreview?.status = "Ready" }
        case .transferring:
            documentPreview?.status = "Fetching \(ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.transferred), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.file.size), countStyle: .file))…"
        case .queued, .negotiating: documentPreview?.status = "Waiting for \(transfer.user) to send the file…"
        case .paused: documentPreview?.status = "Download paused"
        case .failed, .cancelled: documentPreview?.failure = transfer.error ?? "The preview transfer stopped. Close and try again."
        }
    }

    public func closeDocumentPreview() async {
        guard let previous = documentPreview else { return }
        documentPreview = nil; playbackRevision &+= 1
        if let id = previous.transferID { await discardAbandonedPreviews([id]) }
    }

    public func keepDocumentPreview() async {
        guard let previous = documentPreview, let id = previous.transferID else { return }
        do { try await transferEngine.keep(id) } catch {
            if documentPreview?.id == previous.id { documentPreview?.failure = error.localizedDescription }
        }
    }

    public func previewLocal(_ url: URL, title: String) {
        guard let format = PreviewFormat.classify(url.lastPathComponent) else { error = "This format has no built-in preview."; return }
        if format.isAudio { play(file: url, title: title, subtitle: "") }
        else {
            let selection = reservePlaybackSelection()
            documentPreview = DocumentPreview(id: UUID(), title: title, url: url, status: "Ready")
            Task { await discardAbandonedPreviews(selection.abandoned) }
        }
    }
}
