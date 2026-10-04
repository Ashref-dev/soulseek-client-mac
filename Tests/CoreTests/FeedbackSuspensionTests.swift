import Foundation
import Testing
@testable import TransferEngine
@testable import SoulseekCore
@testable import ArpeggioServices
import Persistence
import ProtocolFixtures

@Test func directionSuspensionPreservesQueuedUploadsSourcesAndDownloadOffsets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    let file = SharedFile(path: "Music\\file.txt", size: 100)
    var download = Transfer(user: "peer", file: file); download.status = .transferring; download.transferred = 50; download.token = 2
    var upload = Transfer(user: "peer", file: file, upload: true); upload.status = .negotiating; upload.token = 3
    await engine.seed(download); await engine.seed(upload)
    let source = root.appendingPathComponent("file.txt")
    await engine.seedUploadSource(upload.id, source: source)
    await engine.setUploadAuthorizer { _, _, url in url == source }
    await engine.setSuspended(upload: false, true)
    #expect(await engine.snapshot().first?.status == .queued)
    #expect(await engine.snapshot().first?.transferred == 50)
    #expect(await engine.snapshot().last?.status == .negotiating)
    await engine.setSuspended(upload: true, true)
    #expect(await engine.snapshot().last?.status == .queued)
    #expect(await engine.uploadSources[upload.id] == source)
    #expect(await engine.snapshot().allSatisfy { $0.token == nil })
    await engine.revalidateUploads()
    #expect(await engine.snapshot().last?.status == .queued)
    await engine.setSuspended(upload: true, false)
    #expect(await engine.suspensionState().downloads)
    #expect(await engine.suspensionState().uploads == false)
    await engine.shutdown(); await db.close()
}

extension TransferEngine {
    func seedUploadSource(_ id: String, source: URL) { uploadSources[id] = source }
}

@MainActor private func feedbackWait(_ label: String, details: () async -> String = { "" }, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("\(label) timed out: \(await details())") }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor func activeDirectionPauseResumesSocketsQueuesAndBytesWithoutPresenceChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let share = root.appendingPathComponent("Music"); try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    let content = Data(repeating: 42, count: 2_000_000)
    try content.write(to: share.appendingPathComponent("file.txt"))
    try Data("queued".utf8).write(to: share.appendingPathComponent("queued.txt"))
    let server = try await MockSoulseekServer.start()
    let sender = try AppModel(dataDirectory: root.appendingPathComponent("sender")); await sender.start()
    let receiver = try AppModel(dataDirectory: root.appendingPathComponent("receiver")); await receiver.start()
    for model in [sender, receiver] {
        model.settings.server = "127.0.0.1"; model.settings.port = try await server.port(); model.settings.listeningPort = try unusedPort()
        model.settings.portMapping = false; model.settings.downloadDirectory = root.appendingPathComponent("Downloads").path
    }
    sender.settings.username = "sender"; receiver.settings.username = "receiver"
    sender.settings.sharedFolders = [ShareFolder(path: share.path)]; sender.settings.uploadLimitKB = 256; receiver.settings.downloadSlots = 1
    await sender.saveSettings(); await receiver.saveSettings()
    await sender.login(password: "fixture-only", remember: false); await receiver.login(password: "fixture-only", remember: false)
    let result = SearchResult(user: "sender", file: SharedFile(path: "Music\\file.txt", size: UInt64(content.count)), freeSlot: true, speed: 0, queue: 0)
    let other = SearchResult(user: "sender", file: SharedFile(path: "Music\\queued.txt", size: 6), freeSlot: true, speed: 0, queue: 0)
    await receiver.download([result, other])
    try await feedbackWait("active bytes") { receiver.transfers.contains { $0.status == .transferring && $0.transferred > 0 } }
    await receiver.setTransfersSuspended(upload: false, true)
    #expect(receiver.connection == .connected); #expect(!receiver.awayNow)
    #expect(await receiver.transferEngine.snapshot().allSatisfy { $0.status == .queued })
    #expect(await receiver.transferEngine.sockets.isEmpty)
    let item = try #require(await receiver.transferEngine.snapshot().first)
    let partial = try #require(item.partial)
    #expect(try Data(contentsOf: URL(fileURLWithPath: partial)).count > 0)
    await sender.setTransfersSuspended(upload: true, true)
    await receiver.setTransfersSuspended(upload: false, false)
    try await feedbackWait("queued while uploads suspended") { sender.transfers.contains { $0.upload && $0.status == .queued } }
    #expect(sender.connection == .connected); #expect(!sender.awayNow)
    #expect(await sender.transferEngine.sockets.isEmpty)
    await sender.setTransfersSuspended(upload: true, false)
    try await feedbackWait("download resumed", details: {
        "receiver=\(await receiver.transferEngine.snapshot().map { ($0.file.path, $0.status.rawValue, $0.token, $0.error) }); sender=\(await sender.transferEngine.snapshot().map { ($0.file.path, $0.status.rawValue, $0.token, $0.error) }); receiverLog=\(receiver.diagnostics); senderLog=\(sender.diagnostics); trace=\(await server.trace)"
    }) { receiver.transfers.contains { $0.file.path == result.file.path && $0.status == .transferring && $0.transferred > 0 } }
    await sender.setTransfersSuspended(upload: true, true)
    #expect(await sender.transferEngine.sockets.isEmpty)
    #expect(await sender.transferEngine.uploadSources.isEmpty == false)
    await sender.setTransfersSuspended(upload: true, false)
    try await feedbackWait("completion") { receiver.transfers.filter { $0.status == .completed }.count == 2 }
    let complete = try #require(receiver.transfers.first { $0.file.path == result.file.path })
    #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(complete.destination))) == content)
    await receiver.shutdown(); await sender.shutdown(); await server.stop()
}
