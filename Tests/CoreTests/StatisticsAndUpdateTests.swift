import Foundation
import Testing
@testable import SoulseekCore
@testable import TransferEngine
@testable import ArpeggioServices
import Persistence

private func transfer(_ id: String, upload: Bool, bytes: UInt64, status: TransferStatus, size: UInt64 = 100, user: String = "peer") -> Transfer {
    var item = Transfer(user: user, file: SharedFile(path: "A\\\(id).flac", size: size), upload: upload)
    item.id = id; item.transferred = bytes; item.bytesMoved = bytes; item.status = status
    return item
}

@Test func statisticsCountBytesOnceAndIgnoreHistoryInTheFirstSnapshot() {
    var stats = TransferStatistics()
    var seen: [String: TransferStatistics.Progress] = [:]
    stats.ingest([transfer("old", upload: true, bytes: 100, status: .completed)], seen: &seen, baseline: true)
    #expect(stats.uploadedBytes == 0); #expect(stats.uploadsCompleted == 0)

    stats.ingest([transfer("old", upload: true, bytes: 100, status: .completed),
                  transfer("up", upload: true, bytes: 40, status: .transferring, user: "fan")], seen: &seen, baseline: false)
    #expect(stats.uploadedBytes == 40)
    stats.ingest([transfer("up", upload: true, bytes: 100, status: .completed, user: "fan"),
                  transfer("down", upload: false, bytes: 100, status: .completed, user: "source")], seen: &seen, baseline: false)
    #expect(stats.uploadedBytes == 100); #expect(stats.uploadsCompleted == 1); #expect(stats.listeners == ["fan"])
    #expect(stats.downloadedBytes == 100); #expect(stats.downloadsCompleted == 1); #expect(stats.sources == ["source"])

    let changed = stats.ingest([transfer("up", upload: true, bytes: 100, status: .completed, user: "fan")], seen: &seen, baseline: false)
    #expect(!changed); #expect(stats.uploadsCompleted == 1)

    var preview = transfer("preview", upload: false, bytes: 100, status: .completed); preview.preview = true
    stats.ingest([preview], seen: &seen, baseline: false)
    #expect(stats.downloadsCompleted == 1); #expect(stats.downloadedBytes == 200)
    preview.preview = nil
    stats.ingest([preview], seen: &seen, baseline: false)
    #expect(stats.downloadsCompleted == 2); #expect(stats.downloadedBytes == 200)

    var resumed = transfer("resumed", upload: true, bytes: 100, status: .completed, user: "late"); resumed.bytesMoved = 0
    stats.ingest([resumed], seen: &seen, baseline: false)
    #expect(stats.uploadedBytes == 100); #expect(stats.uploadsCompleted == 2)
}

@Test func routerDiscoveryOnlyTalksToTheAnsweringDevice() {
    #expect(PortMapper.isDeviceURL(URL(string: "http://192.168.1.1:5000/desc.xml")!, host: "192.168.1.1"))
    #expect(!PortMapper.isDeviceURL(URL(string: "http://127.0.0.1:8080/admin")!, host: "192.168.1.1"))
    #expect(!PortMapper.isDeviceURL(URL(string: "https://example.com/x")!, host: "192.168.1.1"))
    #expect(!PortMapper.isDeviceURL(URL(string: "file:///etc/passwd")!, host: "192.168.1.1"))
}

@Test @MainActor func invalidImportedSettingsAreRejectedWithoutChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root)
    await model.start()
    var bad = AppSettings(); bad.uploadSlots = -1
    let file = root.appendingPathComponent("bad.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(ConfigurationExport(settings: bad, users: [], wishlist: [])).write(to: file)
    await #expect(throws: (any Error).self) { try await model.importConfiguration(from: file) }
    #expect(model.settings.uploadSlots == AppSettings().uploadSlots)
    await model.shutdown()
}

@Test func statisticsSeedFromEarlierHistory() {
    let stats = TransferStatistics.seeded(from: [transfer("a", upload: true, bytes: 100, status: .completed),
                                                 transfer("b", upload: false, bytes: 30, status: .failed),
                                                 transfer("c", upload: false, bytes: 100, status: .completed, size: 250)])
    #expect(stats.uploadedBytes == 100); #expect(stats.downloadedBytes == 250)
    #expect(stats.uploadsCompleted == 1); #expect(stats.downloadsCompleted == 1)
}

@Test func semanticVersionsCompareNumerically() {
    #expect(Updater.isNewer("0.10.0", than: "0.9.9"))
    #expect(Updater.isNewer("v1.0.0", than: "0.5.0"))
    #expect(!Updater.isNewer("0.5.0", than: "0.5.0"))
    #expect(!Updater.isNewer("0.4.9", than: "0.5.0"))
    #expect(Updater.isNewer("0.6.0", than: "0.6.0-beta.1"))
    #expect(!Updater.isNewer("0.6.0-beta.1", than: "0.6.0"))
    #expect(Updater.isNewer("0.5.1", than: "0.5"))
}

@Test func releasePayloadPicksTheAppArchive() throws {
    let json = """
    {"tag_name":"v0.6.0","body":"Notes","html_url":"https://github.com/a/b/releases/tag/v0.6.0",
     "assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/c"},
               {"name":"Arpeggio-0.6.0.zip","browser_download_url":"https://example.com/a.zip"}]}
    """
    let release = try Updater.parse(Data(json.utf8))
    #expect(release.version == "0.6.0"); #expect(release.asset.absoluteString == "https://example.com/a.zip")
    #expect(throws: UpdateError.self) { try Updater.parse(Data(#"{"tag_name":"v1","html_url":"https://x.y","assets":[]}"#.utf8)) }
}

@Test func uploadQueuePerUserIsLimited() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    await engine.configure(root: root, downloads: 3, uploads: 2, uploadQueueLimit: 2)
    let url = root.appendingPathComponent("x")
    for index in 0..<2 { #expect(await engine.queueUpload(user: "greedy", file: SharedFile(path: "S\\\(index)", size: 1), localURL: url, start: false)) }
    #expect(await !engine.queueUpload(user: "greedy", file: SharedFile(path: "S\\2", size: 1), localURL: url, start: false))
    #expect(await engine.queueUpload(user: "greedy", file: SharedFile(path: "S\\0", size: 1), localURL: url, start: false))
    #expect(await engine.queueUpload(user: "polite", file: SharedFile(path: "S\\2", size: 1), localURL: url, start: false))
    await engine.shutdown(); await db.close()
}

@Test func previewCacheKeepsOnlyFilesStillInUse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let previews = root.appendingPathComponent("Previews")
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
    await engine.setPreviewRoot(previews)
    let id = try await engine.preview(SearchResult(user: "peer", file: SharedFile(path: "M\\A\\song.mp3", size: 5), freeSlot: true, speed: 0, queue: 0))
    let partial = try #require(await engine.transfers.first { $0.id == id }?.partial)
    try Data("ab".utf8).write(to: URL(fileURLWithPath: partial))
    let stale = previews.appendingPathComponent("Old Album/leftover.mp3")
    try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: stale)
    await engine.purgePreviewCache()
    #expect(FileManager.default.fileExists(atPath: partial))
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(!FileManager.default.fileExists(atPath: stale.deletingLastPathComponent().path))
    await engine.shutdown(); await db.close()
}

@Test func newSettingsHaveFriendlyDefaults() throws {
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any] ?? [:]
    for key in ["userFolders", "fullRemotePaths", "awayWhenIdle", "portMapping", "menuBarIcon", "queuedUploadsPerUser", "checkForUpdates"] { old.removeValue(forKey: key) }
    let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(settings.downloadLayout == DownloadLayout())
    #expect(settings.goesAwayWhenIdle); #expect(settings.mapsPorts); #expect(settings.showsMenuBarIcon)
    #expect(settings.uploadQueueLimit == 200); #expect(settings.checksForUpdates); #expect(settings.onboardingVersion == nil)
}
