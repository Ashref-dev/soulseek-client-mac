import Foundation
import Testing
import Persistence
@testable import SoulseekCore
@testable import TransferEngine

extension TransferEngine {
    func connectQueueFixture() { connected = true; sendPeer = { _, _, _, _ in } }
    func gateRetrySleep(_ gate: RaceGate) { retrySleep = { _ in await gate.wait(); try Task.checkCancellation() } }
    func gateFirstFailureSave(_ gate: FirstFailureSave) { beforePersistence = { _ in await gate.wait() } }
}

actor FirstFailureSave {
    let gate = RaceGate()
    var calls = 0
    func wait() async { calls += 1; if calls == 1 { await gate.wait() } }
}

struct QueueContextTests {
    @Test func retryIdentityReplacementCannotBeClearedByStaleFireOrCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.connectQueueFixture()
        var item = Transfer(user: "fixture", file: SharedFile(path: "download", size: 1)); item.status = .negotiating
        await engine.seed(item)
        await engine.fail(item.id, error: ProtocolError.disconnected)
        let first = try #require(await engine.snapshot().first?.runtimeState?.pendingRetry)
        await engine.fail(item.id, error: ProtocolError.disconnected)
        let second = try #require(await engine.snapshot().first?.runtimeState?.pendingRetry)
        #expect(first.identity != second.identity && second.deadline > first.deadline)
        await engine.retryIfFailed(item.id, identity: first.identity)
        await engine.retireRetry(item.id, identity: first.identity)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry == second)
        #expect(await engine.snapshot().first?.status == .failed)
        await engine.resume(item.id)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry == nil)
        #expect(await engine.retryTasks.isEmpty)
        await engine.fail(item.id, error: ProtocolError.disconnected)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry != nil)
        await engine.cancel(item.id)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry == nil)
        var other = Transfer(user: "other", file: SharedFile(path: "download", size: 1)); other.status = .negotiating
        await engine.seed(other); await engine.fail(other.id, error: ProtocolError.disconnected)
        #expect(await engine.snapshot().first { $0.id == other.id }?.runtimeState?.pendingRetry != nil)
        await engine.setConnected(false)
        #expect(await engine.snapshot().allSatisfy { $0.runtimeState?.pendingRetry == nil })
        #expect(await engine.retryTasks.isEmpty)
        await engine.shutdown(); await db.close()
    }

    @Test func actualRetryFireRemovesPublishedPendingIdentityBeforeNegotiating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        let gate = RaceGate()
        await engine.connectQueueFixture(); await engine.gateRetrySleep(gate)
        var item = Transfer(user: "fixture", file: SharedFile(path: "download", size: 1)); item.status = .negotiating
        await engine.seed(item); await engine.fail(item.id, error: ProtocolError.disconnected)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry != nil)
        try await raceWait { await gate.arrivals == 1 }
        await gate.release()
        try await raceWait { await engine.snapshot().first?.status == .negotiating }
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry == nil)
        #expect(await engine.retryTasks.isEmpty)
        var iterator = engine.updates.makeAsyncIterator()
        let published = await iterator.next()
        #expect(published?.first?.runtimeState?.pendingRetry == nil)
        await engine.shutdown(); await db.close()
    }

    @Test(arguments: [false, true])
    func supersededFailurePersistenceCannotScheduleAfterSafetyFailureOrDisconnect(disconnect: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.connectQueueFixture()
        var item = Transfer(user: "fixture", file: SharedFile(path: "download", size: 1)); item.status = .negotiating
        await engine.seed(item)
        let save = FirstFailureSave(); await engine.gateFirstFailureSave(save)
        let id = item.id
        let oldFailure = Task { await engine.fail(id, error: ProtocolError.disconnected) }
        try await raceWait { await save.gate.arrivals == 1 }
        if disconnect { await engine.setConnected(false) }
        else { await engine.fail(id, error: FileSafetyError.sizeMismatch) }
        await save.gate.release(); await oldFailure.value
        #expect(await engine.snapshot().first?.status == .failed)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry == nil)
        #expect(await engine.retryTasks.isEmpty)
        await engine.shutdown(); await db.close()
    }

    @Test func tokenlessNegotiationsReserveEveryDownloadSlotButRemoteQueueAndPreviewsDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.connectQueueFixture()
        var holders: [Transfer] = []
        for index in 0..<3 {
            var item = Transfer(user: "fixture", file: SharedFile(path: "holder\(index)", size: 1)); item.status = .negotiating
            await engine.seed(item); holders.append(item)
        }
        let queued = Transfer(user: "fixture", file: SharedFile(path: "queued", size: 1))
        await engine.seed(queued)
        await engine.pump()
        let full = await engine.snapshot()
        #expect(full.first { $0.id == queued.id }?.status == .queued)
        #expect(full.first { $0.id == queued.id }?.runtimeState?.queueWait == .localSlots)
        #expect(full.first { $0.id == queued.id }?.runtimeState?.localSlotsInUse == 3)
        #expect(full.filter { $0.runtimeState?.holdsLocalSlot == true }.count == 3)
        var position = WireWriter(); position.string(holders[0].file.path); position.uint(7)
        try await engine.peerMessage(user: "fixture", code: 44, payload: position.data)
        let remote = await engine.snapshot().first { $0.id == holders[0].id }
        #expect(remote?.runtimeState?.queueWait == .remoteQueue)
        #expect(remote?.runtimeState?.holdsLocalSlot == false)
        var preview = Transfer(user: "fixture", file: SharedFile(path: "preview", size: 1)); preview.preview = true; preview.status = .transferring
        await engine.seed(preview)
        #expect(await engine.snapshot().first { $0.id == preview.id }?.runtimeState?.holdsLocalSlot == false)
        await engine.shutdown(); await db.close()
    }

    @Test func queuedPeerDeclineReportsBackoffWithZeroOccupiedUploadSlots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.connectQueueFixture()
        var item = Transfer(user: "fixture", file: SharedFile(path: "upload", size: 1), upload: true); item.status = .negotiating; item.token = 77
        await engine.seed(item)
        var decline = WireWriter(); decline.uint(77); decline.byte(0); decline.string("Queued")
        try await engine.peerMessage(user: "fixture", code: 41, payload: decline.data)
        let snapshot = await engine.snapshot()
        #expect(snapshot.first?.status == .queued)
        #expect(snapshot.first?.runtimeState?.localSlotsInUse == 0)
        #expect(snapshot.first?.runtimeState?.queueWait == .peerBackoff)
        #expect((snapshot.first?.runtimeState?.peerBlockedUntil ?? .distantPast) > Date())
        var iterator = engine.updates.makeAsyncIterator()
        await engine.publish()
        let published = await iterator.next()
        #expect(published?.first?.runtimeState == snapshot.first?.runtimeState)
        await engine.shutdown(); await db.close()
    }

    @Test func fileSafetyFailureAfterEarlierRetryNeverPromisesOrRetainsAutomaticRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.connectQueueFixture()
        var item = Transfer(user: "fixture", file: SharedFile(path: "download", size: 1)); item.status = .negotiating
        await engine.seed(item)
        await engine.fail(item.id, error: ProtocolError.disconnected)
        #expect(await engine.snapshot().first?.retries == 1)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry != nil)
        await engine.fail(item.id, error: FileSafetyError.sizeMismatch)
        #expect(await engine.snapshot().first?.status == .failed)
        #expect(await engine.snapshot().first?.retries == 1)
        #expect(await engine.snapshot().first?.runtimeState?.pendingRetry == nil)
        #expect(await engine.retryTasks.isEmpty, "A prior retry must be revoked on an actual FileSafetyError")
        var iterator = engine.updates.makeAsyncIterator()
        let published = await iterator.next()
        #expect(published?.first?.runtimeState == (await engine.snapshot().first?.runtimeState))
        await engine.shutdown(); await db.close()
    }
}
