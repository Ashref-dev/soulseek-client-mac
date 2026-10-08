import Foundation
import Observation
import Synchronization
import Testing
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices

@Suite @MainActor struct DownloadObservationTests {
    @Test func progressDoesNotInvalidateUnrelatedOrMissingDownloadRows() throws {
        try withModel { model in
            var active = Transfer(user: "active", file: SharedFile(path: "album\\one.flac", size: 100))
            let other = Transfer(user: "other", file: active.file)
            model.indexDownloads([active, other])
            let otherChanges = observe(model, user: other.user, path: other.file.path)
            let missingChanges = observe(model, user: "missing", path: active.file.path)
            active.status = .transferring; active.transferred = 50; active.speed = 20
            model.indexDownloads([active, other])
            #expect(otherChanges.withLock { $0 } == 0)
            #expect(missingChanges.withLock { $0 } == 0)
            #expect(model.downloadState(user: active.user, path: active.file.path)?.transferred == 50)
        }
    }

    @Test func identicalSnapshotsDoNotInvalidateDownloadRows() throws {
        try withModel { model in
            let transfer = Transfer(user: "peer", file: SharedFile(path: "one.flac", size: 100))
            model.indexDownloads([transfer])
            let changes = observe(model, user: transfer.user, path: transfer.file.path)
            model.indexDownloads([transfer])
            #expect(changes.withLock { $0 } == 0)
        }
    }

    @Test func insertingUpdatingAndRemovingWatchedDownloadStillInvalidates() throws {
        try withModel { model in
            var transfer = Transfer(user: "peer", file: SharedFile(path: "one.flac", size: 100))
            var changes = observe(model, user: transfer.user, path: transfer.file.path)
            model.indexDownloads([transfer])
            #expect(changes.withLock { $0 } == 1)
            changes = observe(model, user: transfer.user, path: transfer.file.path)
            transfer.status = .transferring; transfer.transferred = 50
            model.indexDownloads([transfer])
            #expect(changes.withLock { $0 } == 1)
            #expect(model.downloadState(user: transfer.user, path: transfer.file.path)?.progress == 0.5)
            changes = observe(model, user: transfer.user, path: transfer.file.path)
            transfer.status = .cancelled
            model.indexDownloads([transfer])
            #expect(changes.withLock { $0 } == 1)
            #expect(model.downloadState(user: transfer.user, path: transfer.file.path) == nil)
            model.indexDownloads([])
            #expect(model.downloadIndex.isEmpty)
        }
    }

    @Test func previewUpdatesDoNotInvalidateDownloadRows() throws {
        try withModel { model in
            var preview = Transfer(user: "peer", file: SharedFile(path: "one.flac", size: 100))
            preview.preview = true
            let changes = observe(model, user: preview.user, path: preview.file.path)
            model.indexDownloads([preview])
            preview.transferred = 50
            model.indexDownloads([preview])
            #expect(changes.withLock { $0 } == 0)
            #expect(model.downloadState(user: preview.user, path: preview.file.path) == nil)
        }
    }

    private func observe(_ model: AppModel, user: String, path: String) -> ChangeCount {
        let changes = ChangeCount()
        withObservationTracking {
            _ = model.downloadState(user: user, path: path)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        return changes
    }

    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-observation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppModel(dataDirectory: root))
    }
}

private final class ChangeCount: Sendable {
    private let storage = Mutex(0)
    func withLock<Result: Sendable>(_ body: (inout Int) -> Result) -> Result { storage.withLock { body(&$0) } }
}
