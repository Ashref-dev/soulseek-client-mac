import Foundation
import Persistence

struct AccountingCursor: Codable, Sendable {
    var bytes: UInt64
    var completed: Bool
}

extension TransferEngine {
    func scheduleCheckpoint(_ id: String) {
        dirtyCheckpoints.insert(id)
        guard checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
            await self?.flushCheckpoints()
        }
    }
    func flushCheckpoints() async {
        checkpointTask = nil
        let ids = dirtyCheckpoints; dirtyCheckpoints.subtract(ids)
        let items = transfers.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        do { try await checkpoint(items) }
        catch {
            dirtyCheckpoints.formUnion(ids)
            for index in transfers.indices where ids.contains(transfers[index].id) { transfers[index].error = "Checkpoint was not saved: \(error.localizedDescription)" }
        }
    }
    func initializeAccounting() async throws {
        let history = accountingBaseline ?? transfers
        try await database.transaction { db in
            if try db.raw(collection: "accounting", id: "initialized") != nil { return }
            var totals = try db.get(LifetimeStatistics.self, collection: "statistics", id: "main")
            if totals == nil {
                var seeded = LifetimeStatistics(since: history.map(\.date).min() ?? Date())
                for item in history where item.status == .completed && !item.isPreview {
                    if item.upload { seeded.uploadedBytes &+= item.file.size; seeded.uploadsCompleted += 1; seeded.listeners.insert(item.user) }
                    else { seeded.downloadedBytes &+= item.file.size; seeded.downloadsCompleted += 1; seeded.sources.insert(item.user) }
                }
                totals = seeded
            }
            if let totals { try db.put(totals, collection: "statistics", id: "main") }
            for item in history {
                try db.put(AccountingCursor(bytes: item.bytesMoved ?? 0, completed: item.status == .completed && !item.isPreview), collection: "transfer-accounting", id: item.id)
            }
            try db.put(true, collection: "accounting", id: "initialized")
        }
        accountingReady = true; accountingBaseline = nil
    }

    func requireAccountingInitialization() throws {
        guard !accountingBlocked else { throw StorageError.sqlite("Transfer accounting initialization failed. Retry initialization before changing the queue.") }
    }

    func checkpoint(_ items: [Transfer], removing ids: Set<String> = []) async throws {
        try requireAccountingInitialization()
        try await database.transaction { db in
            var totals = try db.get(LifetimeStatistics.self, collection: "statistics", id: "main") ?? LifetimeStatistics()
            for item in items {
                let old = try db.get(AccountingCursor.self, collection: "transfer-accounting", id: item.id) ?? AccountingCursor(bytes: 0, completed: false)
                let bytes = max(old.bytes, item.bytesMoved ?? 0)
                let completed = old.completed || (item.status == .completed && !item.isPreview)
                let delta = bytes - old.bytes
                let peak = max(item.speed, item.accountingPeakSpeed ?? 0)
                if item.upload { totals.uploadedBytes &+= delta; totals.peakUploadSpeed = max(totals.peakUploadSpeed, peak) }
                else { totals.downloadedBytes &+= delta; totals.peakDownloadSpeed = max(totals.peakDownloadSpeed, peak) }
                if completed && !old.completed {
                    if item.upload { totals.uploadsCompleted += 1; if totals.listeners.count < 50000 { totals.listeners.insert(item.user) } }
                    else { totals.downloadsCompleted += 1; if totals.sources.count < 50000 { totals.sources.insert(item.user) } }
                }
                try db.put(AccountingCursor(bytes: bytes, completed: completed), collection: "transfer-accounting", id: item.id)
                if ids.contains(item.id) { try db.remove(collection: "transfers", id: item.id) }
                else { try db.put(item, collection: "transfers", id: item.id) }
            }
            try db.put(totals, collection: "statistics", id: "main")
        }
    }
}
