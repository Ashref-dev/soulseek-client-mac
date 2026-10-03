import Foundation
import Testing
@testable import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices
import Persistence

@Test func retransmittedOfferCannotReplaceAcceptedDownloadToken() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    var item = Transfer(user: "fixture", file: SharedFile(path: "Music\\test.txt", size: 10))
    item.status = .negotiating; item.token = 7
    await engine.seed(item)
    var offer = WireWriter(); offer.uint(1); offer.uint(8); offer.string(item.file.path); offer.ulong(10)
    do { try await engine.peerMessage(user: "fixture", code: 40, payload: offer.data) } catch { }
    #expect(await engine.transfers.first?.token == 7)
    await engine.shutdown(); await db.close()
}

@Test @MainActor func legacyDownloadRequestEntersAuthorizedUploadQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let share = root.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    try Data("original test data".utf8).write(to: share.appendingPathComponent("test.txt"))
    let model = try AppModel(dataDirectory: root.appendingPathComponent("state")); await model.start()
    model.settings.sharedFolders = [ShareFolder(path: share.path)]; await model.saveSettings()
    var request = WireWriter(); request.uint(0); request.uint(7); request.string("Music\\test.txt")
    do { try await model.handlePeer(user: "fixture", code: 40, payload: request.data) } catch { }
    #expect(await model.transferEngine.transfers.contains { $0.upload && $0.user == "fixture" && $0.file.path == "Music\\test.txt" })
    await model.shutdown()
}
