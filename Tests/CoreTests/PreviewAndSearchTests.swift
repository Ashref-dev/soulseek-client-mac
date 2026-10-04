import Foundation
import Testing
@testable import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices
import Persistence

private func makeEngine(_ root: URL) async throws -> (TransferEngine, Database) {
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
    await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
    return (engine, db)
}

private let track = SearchResult(user: "peer", file: SharedFile(path: "Music\\Album\\01 Song.mp3", size: 5), freeSlot: true, speed: 1, queue: 0)

@Test func previewLivesInCacheAndKeepMovesItIntoDownloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db) = try await makeEngine(root)
    let id = try await engine.preview(track)
    var item = try #require(await engine.transfers.first { $0.id == id })
    #expect(item.isPreview)
    #expect(item.destination?.hasPrefix(root.appendingPathComponent("Previews").path) == true)
    #expect(try await engine.preview(track) == id)

    try await engine.keep(id)
    item = try #require(await engine.transfers.first { $0.id == id })
    #expect(!item.isPreview)
    #expect(item.destination?.hasPrefix(root.appendingPathComponent("Downloads").path) == true)
    #expect(item.partial?.hasPrefix(root.appendingPathComponent("Previews").path) == true)
    await engine.shutdown(); await db.close()
}

@Test func keepingAFinishedPreviewMovesTheFileAndDiscardRemovesEverything() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db) = try await makeEngine(root)
    let id = try await engine.preview(track)
    let cached = try #require(await engine.transfers.first { $0.id == id }?.destination)
    let incoming = try #require(await engine.transfers.first { $0.id == id }?.partial)
    try Data("audio".utf8).write(to: URL(fileURLWithPath: incoming))
    _ = try SafeDestination.publish(URL(fileURLWithPath: incoming), to: URL(fileURLWithPath: cached))
    await engine.markCompletedForTest(id)
    try await engine.keep(id)
    let kept = try #require(await engine.transfers.first { $0.id == id }?.destination)
    #expect(FileManager.default.fileExists(atPath: kept))
    #expect(!FileManager.default.fileExists(atPath: cached))

    let other = SearchResult(user: "peer", file: SharedFile(path: "Music\\Album\\02 Other.mp3", size: 5), freeSlot: true, speed: 1, queue: 0)
    let discarded = try await engine.preview(other)
    let partial = try #require(await engine.transfers.first { $0.id == discarded }?.partial)
    try Data("ab".utf8).write(to: URL(fileURLWithPath: partial))
    await engine.discardPreview(discarded)
    #expect(await engine.transfers.contains { $0.id == discarded } == false)
    #expect(!FileManager.default.fileExists(atPath: partial))
    await engine.shutdown(); await db.close()
}

@Test func downloadingAPreviewedTrackKeepsItInsteadOfDuplicatingAndRelaunchDropsPreviews() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db) = try await makeEngine(root)
    let id = try await engine.preview(track)
    try await engine.enqueue([track])
    let items = await engine.transfers
    #expect(items.count == 1); #expect(items.first?.id == id); #expect(items.first?.isPreview == false)

    let other = SearchResult(user: "peer", file: SharedFile(path: "Music\\Album\\03 Abandoned.mp3", size: 5), freeSlot: true, speed: 1, queue: 0)
    _ = try await engine.preview(other)
    await engine.shutdown(); await db.close()
    let (restored, db2) = try await makeEngine(root)
    try await restored.restore()
    #expect(await restored.transfers.map(\.id) == [id])
    await restored.shutdown(); await db2.close()
}

@Test func settingsSavedByOlderVersionsDecodeWithSensibleDefaults() throws {
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any] ?? [:]
    old.removeValue(forKey: "autoConnect"); old.removeValue(forKey: "searchIdleSeconds")
    let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(settings.connectsAutomatically)
    #expect(settings.searchAutoStopSeconds == 15)
}

@Test func qualityPresetsFilterLosslessHiResAndBitrate() {
    func result(_ name: String, _ attributes: [UInt32: UInt32]) -> SearchResult {
        SearchResult(user: "u", file: SharedFile(path: "A\\" + name, size: 1, attributes: attributes), freeSlot: true, speed: 0, queue: 0)
    }
    let flac16 = result("a.flac", [4: 44_100, 5: 16])
    let flac24 = result("b.flac", [4: 96_000, 5: 24])
    let mp3320 = result("c.mp3", [0: 320])
    let mp3192 = result("d.mp3", [0: 192])
    var filters = ResultFilters()
    filters.apply(.lossless)
    #expect([flac16, flac24, mp3320, mp3192].filter(filters.matches) == [flac16, flac24])
    filters.apply(.hiRes)
    #expect([flac16, flac24, mp3320, mp3192].filter(filters.matches) == [flac24])
    filters.apply(.kbps320)
    #expect([flac16, flac24, mp3320, mp3192].filter(filters.matches) == [flac16, flac24, mp3320])
    #expect(filters.preset == .kbps320)
    filters.apply(.any)
    #expect(!filters.isActive)
    filters.text = "-flac"
    #expect([flac16, mp3192].filter(filters.matches) == [mp3192])
}

@Test func searchesStopAfterIdlePeriodOrHardCap() {
    let start = Date(timeIntervalSince1970: 0)
    #expect(!SearchAutoStop.shouldStop(started: start, lastActivity: start.addingTimeInterval(10), now: start.addingTimeInterval(20), idleSeconds: 15))
    #expect(SearchAutoStop.shouldStop(started: start, lastActivity: start.addingTimeInterval(10), now: start.addingTimeInterval(25), idleSeconds: 15))
    #expect(SearchAutoStop.shouldStop(started: start, lastActivity: start.addingTimeInterval(119), now: start.addingTimeInterval(120), idleSeconds: 15))
    #expect(!SearchAutoStop.shouldStop(started: start, lastActivity: start, now: start.addingTimeInterval(500), idleSeconds: 0))
}

@Test func streamWindowServesOnlyBytesAlreadyOnDisk() {
    #expect(StreamWindow.readable(from: 0, to: 1000, available: 0) == nil)
    #expect(StreamWindow.readable(from: 0, to: 1000, available: 400).map { [$0.offset, Int64($0.count)] } == [0, 400])
    #expect(StreamWindow.readable(from: 400, to: 1000, available: 400) == nil)
    #expect(StreamWindow.readable(from: 0, to: 10_000_000, available: 10_000_000)?.count == StreamWindow.chunk)
    #expect(StreamWindow.end(offset: 0, length: 5_000, toEnd: false, size: 1_000) == 1_000)
    #expect(StreamWindow.end(offset: 900, length: 500, toEnd: false, size: 1_000) == 1_000)
    #expect(StreamWindow.end(offset: 1_000, length: 10, toEnd: false, size: 1_000) == 1_000)
    #expect(StreamWindow.end(offset: 0, length: 0, toEnd: true, size: 1_000) == 1_000)
}

@Test func clearingDownloadHistoryNeverTouchesHiddenPreviews() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db) = try await makeEngine(root)
    let id = try await engine.preview(track)
    await engine.markCompletedForTest(id)
    await engine.clearFinished(upload: false)
    await engine.clearFailed(upload: false)
    #expect(await engine.transfers.contains { $0.id == id })
    await engine.shutdown(); await db.close()
}

extension TransferEngine {
    func markCompletedForTest(_ id: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = .completed; transfers[index].transferred = transfers[index].file.size
    }
}

@Test func flacHeaderYieldsTagsCoverAndWaitsForTruncatedStreams() {
    func block(_ type: UInt8, last: Bool, _ body: Data) -> Data {
        var data = Data([type | (last ? 0x80 : 0)]); let n = body.count
        data.append(contentsOf: [UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]); data.append(body); return data
    }
    func le(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]) }
    func be(_ value: Int) -> Data { Data(le(value).reversed()) }
    var comments = le(3) + Data("abc".utf8) + le(3)
    for entry in ["TITLE=Lady of Lightning", "ARTIST=Miwako Chinone", "ALBUM=Monster Hunter Rise"] { comments += le(entry.utf8.count) + Data(entry.utf8) }
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    let picture = be(3) + be(10) + Data("image/jpeg".utf8) + be(0) + Data(count: 16) + be(jpeg.count) + jpeg
    let file = Data("fLaC".utf8) + block(0, last: false, Data(count: 34)) + block(4, last: false, comments) + block(6, last: true, picture) + Data([0xFF, 0xF8])
    guard case .parsed(let tags) = FLACTags.parse(file) else { Issue.record("not parsed"); return }
    #expect(tags.title == "Lady of Lightning"); #expect(tags.artist == "Miwako Chinone"); #expect(tags.album == "Monster Hunter Rise")
    #expect(tags.artwork == jpeg); #expect(tags.resolved)
    #expect(FLACTags.parse(file.prefix(60)) == .needMoreData)
    #expect(FLACTags.parse(Data("ID3x".utf8)) == .notFLAC)
}
