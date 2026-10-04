import Foundation
import Testing
import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func olderSelectionCannotSupersedeNewerDocumentDuringPriorOwnerJoin(streaming: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root)
    await model.transferEngine.setPreviewRoot(root.appendingPathComponent("Previews"))
    model.connection = .connected
    func result(_ name: String) -> SearchResult { SearchResult(user: "peer", file: SharedFile(path: "Folder\\" + name, size: 10), freeSlot: true, speed: 0, queue: 0) }
    let oldID = try await model.transferEngine.preview(result("prior.pdf"))
    model.documentPreview = DocumentPreview(id: UUID(), title: "prior", transferID: oldID, status: "Fetching")
    let gate = RaceGate(); let writer = Task { await gate.wait() }
    await model.transferEngine.installPreviewJoiningTask(oldID, task: writer)
    try await raceWait { await gate.arrivals == 1 }
    let older = Task { await model.listen(to: result(streaming ? "older.mp3" : "older.pdf")) }
    try await raceWait { await model.transferEngine.closing.contains(oldID) }
    await model.listen(to: result("newer.pdf"))
    let newest = try #require(model.documentPreview?.transferID)
    let revision = model.playbackRevision
    await gate.release(); await older.value
    #expect(model.documentPreview?.transferID == newest)
    #expect(model.documentPreview?.title == "newer.pdf")
    #expect(model.playbackRevision == revision); #expect(model.playback.item == nil)
    #expect(await model.transferEngine.snapshot().contains { $0.id == newest && $0.isPreview })
    await model.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stopDuringPriorOwnerJoinDoesNotStopLaterStreamingSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root)
    await model.transferEngine.setPreviewRoot(root.appendingPathComponent("Previews")); model.connection = .connected
    let result = SearchResult(user: "peer", file: SharedFile(path: "Folder\\song.mp3", size: 10), freeSlot: true, speed: 0, queue: 0)
    let oldID = try await model.transferEngine.preview(SearchResult(user: "peer", file: SharedFile(path: "Folder\\prior.pdf", size: 10), freeSlot: true, speed: 0, queue: 0))
    model.documentPreview = DocumentPreview(id: UUID(), title: "prior", transferID: oldID, status: "Fetching")
    let gate = RaceGate(); let writer = Task { await gate.wait() }
    await model.transferEngine.installPreviewJoiningTask(oldID, task: writer)
    try await raceWait { await gate.arrivals == 1 }
    let stop = Task { await model.stopPlayback() }
    try await raceWait { await model.transferEngine.closing.contains(oldID) }
    await model.listen(to: result)
    let selected = try #require(model.playback.item?.transferID)
    await gate.release(); await stop.value
    #expect(model.playback.item?.transferID == selected)
    #expect(await model.transferEngine.snapshot().contains { $0.id == selected })
    await model.shutdown()
}
