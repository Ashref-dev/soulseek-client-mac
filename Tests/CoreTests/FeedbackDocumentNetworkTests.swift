import Foundation
import Testing
@testable import ArpeggioServices
import SoulseekCore
import Persistence
import ProtocolFixtures

@Test(.timeLimit(.minutes(1))) @MainActor func remoteDocumentsFetchBeforePreviewAndCloseRemovesOnlyTemporaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Documents"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pdf = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF".utf8)
    let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII="))
    try pdf.write(to: folder.appendingPathComponent("book.pdf")); try image.write(to: folder.appendingPathComponent("image.png"))
    let server = try await MockSoulseekServer.start()
    let sender = try AppModel(dataDirectory: root.appendingPathComponent("sender")); await sender.start()
    let receiver = try AppModel(dataDirectory: root.appendingPathComponent("receiver")); await receiver.start()
    for model in [sender, receiver] {
        model.settings.server = "127.0.0.1"; model.settings.port = try await server.port(); model.settings.listeningPort = try unusedPort()
        model.settings.portMapping = false; model.settings.downloadDirectory = root.appendingPathComponent("Downloads").path
    }
    sender.settings.username = "document-sender"; receiver.settings.username = "document-receiver"
    sender.settings.sharedFolders = [ShareFolder(path: folder.path)]
    await sender.saveSettings(); await receiver.saveSettings()
    await sender.login(password: "fixture-only", remember: false); await receiver.login(password: "fixture-only", remember: false)
    for (name, bytes) in [("book.pdf", pdf), ("image.png", image)] {
        let result = SearchResult(user: "document-sender", file: SharedFile(path: "Documents\\" + name, size: UInt64(bytes.count)), freeSlot: true, speed: 0, queue: 0)
        await receiver.listen(to: result)
        #expect(receiver.documentPreview != nil); #expect(receiver.playback.item == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while receiver.documentPreview?.url == nil {
            guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("Document fetch timed out: \(receiver.documentPreview?.failure ?? receiver.documentPreview?.status ?? "missing")") }
            try await Task.sleep(for: .milliseconds(25))
        }
        let url = try #require(receiver.documentPreview?.url)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(receiver.documentPreview?.status == "Ready")
        await receiver.closeDocumentPreview()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        #expect(await receiver.transferEngine.snapshot().isEmpty)
    }
    await receiver.shutdown(); await sender.shutdown(); await server.stop()
}
