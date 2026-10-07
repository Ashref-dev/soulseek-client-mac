import Foundation
import Testing
import Persistence
@testable import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices

struct PartialOwnershipTests {
    @Test func cancelledEnqueueReusesPartialOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        let result = SearchResult(user: "fixture", file: SharedFile(path: "album\\song", size: 300000), freeSlot: true, speed: 0, queue: 0)
        try await engine.enqueue([result])
        let original = try #require(await engine.snapshot().first)
        try Data(repeating: 42, count: 100).write(to: URL(fileURLWithPath: try #require(original.partial)))
        await engine.cancel(original.id)
        try await engine.enqueue([result])
        await engine.resume(original.id)
        #expect(await engine.snapshot().count == 1)
        #expect(await engine.snapshot().first?.id == original.id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(original.partial))) == Data(repeating: 42, count: 100))
        await engine.shutdown(); await db.close()
    }
}

struct RestoreNonterminalTests {
    @Test func oldQueuedWorkBeyondHistoryLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let queued = Transfer(user: "fixture", file: SharedFile(path: "old", size: 1))
        try await db.put(queued, collection: "transfers", id: queued.id)
        var unfinished = [queued]
        for status in [TransferStatus.paused, .failed, .negotiating, .transferring] {
            var item = Transfer(user: "fixture", file: SharedFile(path: status.rawValue, size: 1)); item.status = status
            unfinished.append(item); try await db.put(item, collection: "transfers", id: item.id)
        }
        try await db.putRaw(Data("{bad".utf8), collection: "transfers", id: "malformed")
        for index in 0..<10050 {
            var item = Transfer(user: "fixture", file: SharedFile(path: "terminal\(index)", size: 1)); item.status = .completed
            try await db.put(item, collection: "transfers", id: item.id)
        }
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        try await engine.restore()
        #expect(await engine.snapshot().contains { $0.id == queued.id })
        #expect(Set(await engine.snapshot().map(\.id)).isSuperset(of: Set(unfinished.map(\.id))))
        #expect(await engine.snapshot().filter { $0.status == .completed }.count == 10000)
        await engine.shutdown(); await db.close()
    }
}

struct DurableAccountingTests {
    @Test func failedCommitAndRemovalRetainReplayableBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        var legacy = TransferStatistics(since: Date(timeIntervalSince1970: 1000))
        legacy.downloadedBytes = 900; legacy.sources = ["old-source"]; legacy.peakDownloadSpeed = 88
        try await db.put(legacy, collection: "statistics", id: "main")
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        try await engine.restore()
        var item = Transfer(user: "new-source", file: SharedFile(path: "song", size: 1000))
        try await db.put(item, collection: "transfers", id: item.id)
        item.bytesMoved = 100; item.status = .completed
        await engine.seed(item)
        await db.failNextTransactionCommit()
        do { try await engine.checkpoint([item]); Issue.record("Expected failed checkpoint") } catch { }
        #expect(try await db.get(TransferStatistics.self, collection: "statistics", id: "main")?.downloadedBytes == 900)
        await db.failNextTransactionCommit()
        do { try await engine.removeTransfers([item.id]); Issue.record("Expected failed removal") } catch { }
        #expect(await engine.snapshot().contains { $0.id == item.id })
        #expect(try await db.raw(collection: "transfers", id: item.id) != nil)
        try await engine.removeTransfers([item.id])
        try await engine.checkpoint([])
        let saved = try #require(try await db.get(TransferStatistics.self, collection: "statistics", id: "main"))
        #expect(saved.downloadedBytes == 1000)
        #expect(saved.downloadsCompleted == 1)
        #expect(saved.since == legacy.since)
        #expect(saved.sources == ["old-source", "new-source"])
        #expect(saved.peakDownloadSpeed == 88)
        await engine.shutdown(); await db.close()
        let reopened = try Database(url: root.appendingPathComponent("db"))
        #expect(try await reopened.get(TransferStatistics.self, collection: "statistics", id: "main") == saved)
        #expect(try await reopened.raw(collection: "transfers", id: item.id) == nil)
        #expect(try await reopened.schemaVersion() == 1)
        await reopened.close()
    }

    @Test func resumedOffsetIsNotNetworkBytesAndLegacyCursorDoesNotRecount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 1000)); item.bytesMoved = 40
        try await db.put(item, collection: "transfers", id: item.id)
        var old = TransferStatistics(); old.downloadedBytes = 500
        try await db.put(old, collection: "statistics", id: "main")
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        try await engine.restore()
        await engine.testResumeBytes(item.id, offset: 700, bytes: 800)
        let snapshot = await engine.snapshot()
        try await engine.checkpoint(snapshot)
        try await engine.checkpoint(snapshot)
        #expect(try await db.get(TransferStatistics.self, collection: "statistics", id: "main")?.downloadedBytes == 600)
        await engine.shutdown(); await db.close()
    }
}

extension TransferEngine {
    func testResumeBytes(_ id: String, offset: UInt64, bytes: UInt64) {
        startAttempt(id, offset: offset)
        if let index = transfers.firstIndex(where: { $0.id == id }) { recordMoved(index, bytes: bytes) }
    }
}

struct SettingsRecoveryTests {
    @Test @MainActor func malformedSettingsRemainByteIdenticalThroughEditAndQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let original = Data("{broken essential settings \n".utf8)
        try await model.database.putRaw(original, collection: "settings", id: "main")
        try await model.database.putRaw(Data("broken ancillary".utf8), collection: "users", id: "bad")
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 100)); item.status = .paused
        try await model.database.put(item, collection: "transfers", id: item.id)
        await model.start()
        #expect(model.settingsRecovery != nil)
        #expect(await model.transferEngine.snapshot().contains { $0.id == item.id })
        model.settings.username = "replacement"; await model.saveSettings(); await model.connectAtLaunch()
        #expect(model.connection == .offline)
        #expect(try await model.database.raw(collection: "settings", id: "main") == original)
        await model.shutdown()
        let db = try Database(url: root.appendingPathComponent("arpeggio.sqlite"))
        #expect(try await db.raw(collection: "settings", id: "main") == original)
        await db.close()
    }

    @Test @MainActor func explicitResetBacksUpRawBytesAndMalformedStatisticsAreNotReseeded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let broken = Data("{broken".utf8)
        try await model.database.putRaw(broken, collection: "settings", id: "main")
        try await model.database.putRaw(broken, collection: "statistics", id: "main")
        await model.start()
        let backup = root.appendingPathComponent("backup.json")
        try await model.backupSettingsRecovery(to: backup)
        #expect(try Data(contentsOf: backup) == broken)
        try await model.resetSettingsRecovery()
        #expect(model.settingsRecovery == nil)
        #expect(try await model.database.get(AppSettings.self, collection: "settings", id: "main")?.isValid == true)
        #expect(try await model.database.raw(collection: "statistics", id: "main") == broken)
        await model.shutdown()
    }
}

struct TransferRemovalTests {
    @Test func removalPreservesNormalFilesAndJoinsWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        let destination = root.appendingPathComponent("destination"), partial = root.appendingPathComponent("partial"), source = root.appendingPathComponent("source")
        let bytes = Data(repeating: 23, count: 300000)
        for path in [destination, partial, source] { try bytes.write(to: path) }
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: UInt64(bytes.count)))
        item.destination = destination.path; item.partial = partial.path; item.status = .transferring
        let gate = RemovalGate()
        let task = Task { await gate.wait(); await gate.finished() }
        await engine.seed(item, source: source, task: task)
        let id = item.id
        let removal = Task { try await engine.removeTransfers([id]) }
        let duplicate = Task { try await engine.removeTransfers([id]) }
        await Task.yield()
        #expect(await engine.snapshot().contains { $0.id == item.id })
        await gate.release(); try await removal.value; try await duplicate.value
        #expect(await gate.didFinish)
        #expect(await engine.snapshot().isEmpty)
        for path in [destination, partial, source] { #expect(try Data(contentsOf: path) == bytes) }
        try await engine.removeTransfers([item.id])
        await engine.shutdown(); await db.close()
    }
}

actor RemovalGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    var didFinish = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func finished() { didFinish = true }
}

struct TransferBatchTests {
    @Test func thousandRequestsPersistOnceAndDeduplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        let items = (0..<1000).map { SearchResult(user: "fixture", file: SharedFile(path: "album\\song\($0)", size: 1), freeSlot: true, speed: 0, queue: 0) }
        try await engine.enqueue(items + items)
        #expect(await engine.snapshot().count == 1000)
        #expect(await db.transactionCount == 1)
        #expect(await engine.publicationCount == 1)
        #expect(try await db.all(Transfer.self, collection: "transfers").count == 1000)
        await engine.shutdown(); await db.close()
    }
}
