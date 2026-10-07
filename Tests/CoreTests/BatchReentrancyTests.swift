import Foundation
import Testing
import Persistence
import SoulseekCore
@testable import TransferEngine

private actor BatchKeepGate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func waitOnce() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

private extension TransferEngine {
    func installBatchFixture(_ rows: [Transfer], previewID: String, gate: BatchKeepGate) {
        transfers = rows
        beforePersistence = { id in if id == previewID { await gate.waitOnce() } }
    }
}

struct BatchReentrancyTests {
    private func encoded(_ rows: [Transfer]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(rows)
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["removeC", "removeD", "pauseD", "removePendingD", "pausePendingD", "insertD", "insertPendingD"])
    func keepSuspensionUsesFreshUUIDAuthority(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("state.sqlite"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        let gate = BatchKeepGate()
        var p = Transfer(user: "peer", file: SharedFile(path: "Album\\P.mp3", size: 1))
        p.preview = true; p.status = .completed
        let cached = root.appendingPathComponent("cache/P.mp3")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: cached); p.destination = cached.path
        var c = Transfer(user: "peer", file: SharedFile(path: "Album\\C.mp3", size: 1))
        c.status = .completed
        var d = Transfer(user: "peer", file: SharedFile(path: "Album\\D.mp3", size: 1))
        d.status = .cancelled; d.error = "cancelled fixture"
        await engine.installBatchFixture(action.hasPrefix("insert") ? [p, c] : [p, c, d], previewID: p.id, gate: gate)
        try await db.put(true, collection: "accounting", id: "initialized")
        try await engine.initializeAccounting()
        try await engine.checkpoint(await engine.transfers)
        let pResult = SearchResult(user: p.user, file: p.file, freeSlot: true, speed: 0, queue: 0)
        let dResult = SearchResult(user: d.user, file: d.file, freeSlot: true, speed: 0, queue: 0)
        let batch = Task { try await engine.enqueue(action.contains("Pending") ? [dResult, pResult] : [pResult, dResult]) }
        try await raceWait { await gate.entered }
        switch action {
        case "removeC": try await engine.removeTransfers([c.id])
        case "removeD", "removePendingD": try await engine.removeTransfers([d.id])
        case "pauseD", "pausePendingD": await engine.pause(d.id)
        case "insertD", "insertPendingD": try await engine.enqueue([dResult])
        default: Issue.record("Unknown batch fixture action")
        }
        let during = await engine.snapshot()
        await gate.release(); try await batch.value
        let final = await engine.snapshot()
        #expect(final.filter { $0.file.path == d.file.path }.count == (action.hasPrefix("remove") && action != "removeC" ? 0 : 1))
        if action == "removeC" {
            let queued = try #require(final.first { $0.id == d.id })
            #expect(queued.status == .queued); #expect(queued.error == nil)
            #expect(!final.contains { $0.id == c.id })
        } else {
            #expect(try encoded(final.filter { $0.id != p.id }) == encoded(during.filter { $0.id != p.id }))
        }
        let kept = try #require(final.first { $0.id == p.id })
        #expect(!kept.isPreview); #expect(kept.status == .completed)
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(kept.destination))) == Data([1]))
        let persisted = try await db.all(Transfer.self, collection: "transfers")
        #expect(Set(persisted.map(\.id)) == Set(final.map(\.id)))
        for row in await engine.transfers {
            let saved = try #require(persisted.first { $0.id == row.id })
            #expect(try encoded([saved]) == encoded([row]))
        }
        await engine.shutdown(); await db.close()
    }
}
