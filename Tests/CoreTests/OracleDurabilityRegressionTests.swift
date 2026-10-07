import Foundation
import Testing
import Persistence
@testable import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices

struct OracleDurabilityRegressionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func cleanupRequestedDuringPauseRunsAfterJoinUnlessKept(discard: Bool, keep: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
        await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
        let result = SearchResult(user: "fixture", file: SharedFile(path: "album\\book.pdf", size: 300000), freeSlot: true, speed: 0, queue: 0)
        let id = try await engine.preview(result)
        let partial = URL(fileURLWithPath: try #require(await engine.snapshot().first?.partial))
        let bytes = Data(repeating: 31, count: 300000); try bytes.write(to: partial)
        let gate = RaceGate(); let worker = Task { await gate.wait() }
        await engine.installPreviewJoiningTask(id, task: worker)
        try await raceWait { await gate.arrivals == 1 }
        let pause = Task { await engine.pause(id) }
        try await raceWait { await engine.closing.contains(id) }
        if discard { await engine.discardPreview(id) } else { await engine.expirePreview(id) }
        #expect(try Data(contentsOf: partial) == bytes)
        #expect(await engine.previewTerminalOwners[id] == nil)
        if keep { try await engine.keep(id) }
        await gate.release(); await pause.value
        await engine.joinDeferredPreviewCleanup()
        if keep {
            #expect(await engine.snapshot().contains { $0.id == id && !$0.isPreview })
            #expect(try Data(contentsOf: partial) == bytes)
            #expect(try await db.get(Transfer.self, collection: "transfers", id: id)?.isPreview == false)
        } else {
            do {
                try await raceWait {
                    let remains = await engine.snapshot().contains { $0.id == id }
                    return !FileManager.default.fileExists(atPath: partial.path) && remains == !discard
                }
            } catch { Issue.record("Close/TTL request must clean automatically after writer join, without a second caller: \(error)") }
            #expect(!FileManager.default.fileExists(atPath: partial.path))
            if discard { #expect(try await db.raw(collection: "transfers", id: id) == nil) }
            else { #expect(await engine.snapshot().first?.status == .cancelled) }
        }
        await engine.shutdown(); await db.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func pausedPreviewWriterMustJoinBeforeDiscardOrExpiry(discard: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
        await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
        let result = SearchResult(user: "fixture", file: SharedFile(path: "album\\book.pdf", size: 300000), freeSlot: true, speed: 0, queue: 0)
        let id = try await engine.preview(result)
        let partial = URL(fileURLWithPath: try #require(await engine.snapshot().first?.partial))
        let bytes = Data(repeating: 19, count: 300000)
        try bytes.write(to: partial)
        let gate = RaceGate()
        let worker = Task { await gate.wait() }
        await engine.installPreviewJoiningTask(id, task: worker)
        try await raceWait { await gate.arrivals == 1 }
        let pause = Task { await engine.pause(id) }
        try await raceWait { await engine.closing.contains(id) }
        if discard { await engine.discardPreview(id) } else { await engine.expirePreview(id) }
        #expect(await engine.snapshot().contains { $0.id == id && $0.status == .paused && $0.isPreview }, "Cleanup must not mutate/remove the row owned by an unfinished pause join")
        #expect(FileManager.default.fileExists(atPath: partial.path), "Cleanup must not delete a partial with a joining writer")
        if FileManager.default.fileExists(atPath: partial.path) { #expect(try Data(contentsOf: partial) == bytes) }
        #expect(await engine.previewDeadlines[id] != nil, "Refused cleanup must not claim/cancel the preview deadline")
        #expect(await engine.previewTerminalOwners[id] == nil)
        #expect(await engine.closing.contains(id))
        #expect(try await db.raw(collection: "transfers", id: id) != nil)
        await gate.release(); await pause.value
        await engine.joinDeferredPreviewCleanup()
        if discard {
            await engine.discardPreview(id)
            #expect(!(await engine.snapshot().contains { $0.id == id }))
            #expect(try await db.raw(collection: "transfers", id: id) == nil)
        } else {
            await engine.expirePreview(id)
            #expect(await engine.snapshot().first?.status == .cancelled)
        }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        await engine.shutdown(); await db.close()
    }

    @Test(arguments: [TransferStatus.cancelled, .paused])
    func overlappingChangesCannotReleaseAnotherJoinBarrier(secondStatus: TransferStatus) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 300000)); item.status = .transferring
        let gate = RemovalGate()
        let worker = Task { await gate.wait(); await gate.finished() }
        await engine.seed(item, task: worker)
        let id = item.id
        let first = Task { await engine.cancel(id) }
        while !(await engine.closing.contains(id)) { await Task.yield() }
        await engine.change(id, to: secondStatus)
        #expect(await engine.closing.contains(id), "First cancellation must own the barrier until writer join")
        await engine.resume(id)
        #expect(await engine.snapshot().first?.status == .cancelled, "Resume cannot advance while the original writer is joining")
        do { try await engine.removeTransfers([id]); Issue.record("Removal must reject the still-joining writer") } catch { }
        #expect(await engine.snapshot().contains { $0.id == id })
        await gate.release(); await first.value
        #expect(await gate.didFinish)
        #expect(!(await engine.closing.contains(id)))
        try await engine.removeTransfers([id])
        await engine.shutdown(); await db.close()
    }

    @Test func failedLegacyInitializationBlocksMutationUntilOriginalBaselineIsCommitted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        var totals = TransferStatistics(); totals.downloadedBytes = 500
        try await db.put(totals, collection: "statistics", id: "main")
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 1000)); item.status = .paused; item.bytesMoved = 40
        try await db.put(item, collection: "transfers", id: item.id)
        let original = try #require(try await db.raw(collection: "transfers", id: item.id))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await db.failNextTransactionCommit()
        try await engine.restore()
        #expect(!(await engine.accountingReady))
        #expect(try await db.raw(collection: "accounting", id: "initialized") == nil)
        #expect(try await db.raw(collection: "transfer-accounting", id: item.id) == nil)
        await engine.resume(item.id)
        #expect(await engine.snapshot().first?.status == .paused)
        await engine.setConnected(true)
        #expect(!(await engine.connected))
        await engine.pause(item.id); await engine.cancel(item.id)
        #expect(await engine.snapshot().first?.status == .paused)
        do { try await engine.checkpoint(await engine.snapshot()); Issue.record("Checkpoint must fail closed before legacy baseline commit") } catch { }
        do { try await engine.removeTransfers([item.id]); Issue.record("Removal must fail closed before legacy baseline commit") } catch { }
        #expect(try await db.raw(collection: "transfers", id: item.id) == original)
        #expect(try await db.get(TransferStatistics.self, collection: "statistics", id: "main")?.downloadedBytes == 500)
        try await engine.retryAccountingInitialization()
        #expect(await engine.accountingReady)
        await engine.resume(item.id)
        await engine.testResumeBytes(item.id, offset: 700, bytes: 800)
        try await engine.checkpoint(await engine.snapshot())
        try await engine.removeTransfers([item.id])
        await engine.shutdown(); await db.close()
        let reopened = try Database(url: root.appendingPathComponent("db"))
        #expect(try await reopened.get(TransferStatistics.self, collection: "statistics", id: "main")?.downloadedBytes == 600)
        #expect(try await reopened.raw(collection: "transfers", id: item.id) == nil)
        await reopened.close()
    }
}
