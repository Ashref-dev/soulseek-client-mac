import Foundation
import Testing
@testable import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices
import Persistence
import AVFoundation
import UniformTypeIdentifiers

@Test func nativePreviewClassifierRoutesContainersAndRejectsUnsupportedCodecs() {
    for name in ["track.MP3", "track.flac", "track.wav", "track.aiff"] { #expect(PreviewFormat.classify(name) == .streamingAudio) }
    for name in ["track.m4a", "track.m4b", "track.aac", "track.caf", "track.ac3"] { #expect(PreviewFormat.classify(name) == .audio) }
    for name in ["clip.mp4", "clip.mov", "clip.m4v", "clip.avi"] { #expect(PreviewFormat.classify(name) == .video) }
    for name in ["cover.jpg", "cover.jpeg", "cover.png", "cover.heic", "cover.tiff", "cover.gif", "cover.bmp"] { #expect(PreviewFormat.classify(name) == .image) }
    #expect(PreviewFormat.classify("book.PDF") == .pdf)
    for name in ["file.exe", "file.zip", "clip.mkv", "no-extension"] { #expect(PreviewFormat.classify(name) == nil) }
    for ext in ["ogg", "opus", "mp2", "amr"] {
        let native = UTType(filenameExtension: ext).map { type in AVURLAsset.audiovisualContentTypes.contains { type.conforms(to: $0) } } ?? false
        #expect(PreviewFormat.classify("song." + ext) == (native ? .audio : nil))
    }
}

@Test func previewsAreSizeBoundedSingleOwnerAndDeadlineCleansPartialBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
    await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
    func result(_ name: String, size: UInt64 = 5) -> SearchResult { SearchResult(user: "peer", file: SharedFile(path: "Folder\\" + name, size: size), freeSlot: true, speed: 0, queue: 0) }
    for value in [result("huge.pdf", size: PreviewFormat.maximumBytes + 1), result("zero.mp3", size: 0), result("unsupported.exe")] {
        await #expect(throws: (any Error).self) { try await engine.preview(value) }
    }
    let first = try await engine.preview(result("first.png"))
    let partial = try #require(await engine.snapshot().first?.partial)
    try Data([1, 2]).write(to: URL(fileURLWithPath: partial))
    let second = try await engine.preview(result("second.pdf"))
    #expect(await engine.snapshot().map(\.id) == [second])
    #expect(!FileManager.default.fileExists(atPath: partial))
    #expect(await engine.previewDeadlines[first] == nil)
    let secondPartial = try #require(await engine.snapshot().first?.partial)
    try Data([1]).write(to: URL(fileURLWithPath: secondPartial))
    await engine.expirePreview(second)
    #expect(await engine.snapshot().first?.status == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: secondPartial))
    await engine.discardPreview(second)
    #expect(await engine.snapshot().isEmpty)
    await engine.shutdown(); await db.close()
}

@Test @MainActor func completedDocumentPreviewAndKeptFileSurviveClosing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root.appendingPathComponent("state")); await model.start()
    model.settings.downloadDirectory = root.appendingPathComponent("Downloads").path; await model.saveSettings()
    let file = SharedFile(path: "Folder\\book.pdf", size: 5)
    let id = try await model.transferEngine.preview(SearchResult(user: "peer", file: file, freeSlot: true, speed: 0, queue: 0))
    let cached = try #require(await model.transferEngine.snapshot().first?.destination)
    let partial = try #require(await model.transferEngine.snapshot().first?.partial)
    try Data("bytes".utf8).write(to: URL(fileURLWithPath: partial))
    _ = try SafeDestination.publish(URL(fileURLWithPath: partial), to: URL(fileURLWithPath: cached))
    await model.transferEngine.markCompletedForTest(id)
    model.documentPreview = DocumentPreview(id: UUID(), title: "book.pdf", transferID: id, status: "Fetching")
    model.refreshDocumentPreview(await model.transferEngine.snapshot())
    #expect(model.documentPreview?.url?.path == cached)
    await model.keepDocumentPreview()
    let kept = try #require(await model.transferEngine.snapshot().first?.destination)
    await model.closeDocumentPreview()
    #expect(model.documentPreview == nil)
    #expect(FileManager.default.fileExists(atPath: kept))
    #expect(await model.transferEngine.snapshot().first?.isPreview == false)
    model.previewLocal(URL(fileURLWithPath: kept), title: "book.pdf"); await model.closeDocumentPreview()
    #expect(FileManager.default.fileExists(atPath: kept))
    await model.shutdown()
}

@Test func crashRestoreDropsDocumentsButNeverDeletesKeptFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
    await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
    let result = SearchResult(user: "peer", file: SharedFile(path: "Folder\\movie.mov", size: 5), freeSlot: true, speed: 0, queue: 0)
    _ = try await engine.preview(result)
    let partial = try #require(await engine.snapshot().first?.partial); try Data([1]).write(to: URL(fileURLWithPath: partial))
    await engine.shutdown()
    let restored = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
    await restored.setPreviewRoot(root.appendingPathComponent("Previews")); try await restored.restore(); await restored.purgePreviewCache()
    #expect(await restored.snapshot().isEmpty); #expect(!FileManager.default.fileExists(atPath: partial))
    await restored.shutdown(); await db.close()
}
