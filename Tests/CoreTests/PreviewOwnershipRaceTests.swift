import Foundation
import Testing
import Persistence
import SoulseekCore
@testable import TransferEngine

extension TransferEngine {
    func installPreviewJoiningTask(_ id: String, task: Task<Void, Never>) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = .transferring; tasks[id] = task
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func keepDuringPreviewTerminalJoinPreservesBytesAndPersistedOwnership(discard: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
    await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
    let result = SearchResult(user: "peer", file: SharedFile(path: "Folder\\book.pdf", size: 10), freeSlot: true, speed: 0, queue: 0)
    let id = try await engine.preview(result)
    let partial = try #require(await engine.snapshot().first?.partial)
    let bytes = Data("partial".utf8); try bytes.write(to: URL(fileURLWithPath: partial))
    let gate = RaceGate(); let writer = Task { await gate.wait() }
    await engine.installPreviewJoiningTask(id, task: writer)
    try await raceWait { await gate.arrivals == 1 }
    let terminal = Task { if discard { await engine.discardPreview(id) } else { await engine.expirePreview(id) } }
    try await raceWait { await engine.closing.contains(id) }
    try await engine.keep(id)
    #expect(await engine.snapshot().first?.isPreview == false)
    await gate.release(); await terminal.value
    #expect(try Data(contentsOf: URL(fileURLWithPath: partial)) == bytes)
    let current = try #require(await engine.snapshot().first)
    #expect(!current.isPreview); #expect(current.status == .queued)
    let persisted = try #require(try await db.all(Transfer.self, collection: "transfers").first)
    #expect(!persisted.isPreview); #expect(persisted.destination == current.destination)
    await engine.shutdown(); await db.close()
}
