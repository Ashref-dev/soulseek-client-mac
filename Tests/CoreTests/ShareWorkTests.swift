import Foundation
import Testing
import ShareIndexer
import SoulseekCore
import Persistence
@testable import ArpeggioServices

@Suite struct ShareWorkTests {
    @Test @MainActor func unchangedSettingsDoNotQueueScanWhileCapturedConfigurationIsInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.sharedFolders = [ShareFolder(path: root.appendingPathComponent("Collection").path)]
        let gate = ShareWorkGate()
        var calls = 0
        model.scanShares = { _, _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return (0, 0)
        }
        let scanning = Task { await model.rescanShares() }
        await gate.entered()
        for _ in 0..<10 { await model.saveSettings() }
        let pending = model.rescanPending
        #expect(pending == false)
        await gate.release(); await scanning.value
        #expect(calls == 1)
        await model.saveSettings()
        #expect(calls == 1)
        await model.shutdown()
    }

    @Test func queryNormalizesRootsOnceNotOncePerFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<256 { try Data([1]).write(to: root.appendingPathComponent("track-\(i).txt")) }
        let index = ShareIndex()
        _ = await index.scan(folders: [(root, false)])
        #expect(await index.library(configuredFolders: [(root, false)]).values.flatMap { $0 }.count == 256)
        let libraryWork = await index.queryRootResolutions
        #expect(libraryWork == 1)
        #expect(await index.search("track", configuredFolders: [(root, false)]).count == 256)
        let searchWork = await index.queryRootResolutions
        #expect(searchWork == 2)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            _ = await index.library(configuredFolders: [(root, false)])
            _ = await index.search("track", configuredFolders: [(root, false)])
        }
        let batchWork = await index.queryRootResolutions - searchWork
        #expect(batchWork == 40)
        print("Share query benchmark: 20 library/search pairs, 256 files, 1 root, \(batchWork) root resolutions, elapsed \(ContinuousClock.now - start)")
    }

    @Test func validatedRelaunchReusesMetadataButDoesNotPublishUnvalidatedCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<32 { try Data([1]).write(to: root.appendingPathComponent("track-\(i).wav")) }
        let index = ShareIndex(metadataReader: { _, _ in [1: 123] })
        _ = await index.scan(folders: [(root, false)])
        let encoded = try JSONEncoder().encode(await index.metadataCache())
        let fresh = ShareIndex(metadataReader: { _, _ in [1: 456] })
        await fresh.restoreMetadataCache(try JSONDecoder().decode(ShareMetadataCache.self, from: encoded))
        #expect(await fresh.library().isEmpty)
        _ = await fresh.scan(folders: [(root, true)])
        let work = await fresh.metadataReads
        #expect(work == 0)
        #expect(await fresh.library().isEmpty)
        let tracks = await fresh.library(allowPrivate: true).values.flatMap { $0 }
        #expect(tracks.count == 32)
        #expect(tracks.allSatisfy { $0.attributes[1] == 123 })
    }

    @Test func sameVirtualPathSizeAndMtimeCannotReuseDifferentSourceMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a/Collection")
        let b = root.appendingPathComponent("b/Collection")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("track.wav")
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        let index = ShareIndex(metadataReader: { url, _ in url.path.contains("/a/") ? [1: 123] : [1: 456] })
        _ = await index.scan(folders: [(a, false)])
        _ = await index.scan(folders: [(b, false)])
        let file = try #require(await index.resolve("Collection\\track.wav"))
        #expect(file.file.attributes[1] == 456)
    }

    @Test(arguments: [false, true]) @MainActor func configurationChangesAndFilesystemInvalidationsCoalesceWithoutBeingLost(filesystemEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.sharedFolders = [ShareFolder(path: root.appendingPathComponent("Collection").path)]
        let gate = ShareWorkGate()
        var exclusionsSeen: [[String]] = []
        model.scanShares = { _, _, exclusions in
            exclusionsSeen.append(exclusions)
            if exclusionsSeen.count == 1 { await gate.wait() }
            return (0, 0)
        }
        let scanning = Task { await model.rescanShares() }
        await gate.entered()
        model.settings.shareExclusions = ["*.wav"]
        await model.saveSettings()
        if filesystemEvents { for _ in 0..<10 { await model.rescanShares() } }
        let pending = model.rescanPending
        #expect(pending == filesystemEvents)
        await gate.release(); await scanning.value
        #expect(exclusionsSeen == [[], ["*.wav"]])
        await model.shutdown()
    }

    @Test func cacheRejectsChangedMissingExcludedAndSymlinkSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["size", "mtime", "missing", "linked", "excluded", "valid"] {
            try Data([1]).write(to: root.appendingPathComponent(name + ".wav"))
        }
        let index = ShareIndex(metadataReader: { _, _ in [1: 123] })
        _ = await index.scan(folders: [(root, false)])
        let cache = await index.metadataCache()
        try Data([1, 2]).write(to: root.appendingPathComponent("size.wav"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("mtime.wav").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("missing.wav"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("linked.wav"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.wav"), withDestinationURL: root.appendingPathComponent("valid.wav"))
        let fresh = ShareIndex(metadataReader: { _, _ in [1: 456] })
        await fresh.restoreMetadataCache(cache)
        _ = await fresh.scan(folders: [(root, false)], exclusions: ["excluded.*"])
        let work = await fresh.metadataReads
        #expect(work == 2)
        let tracks = await fresh.library().values.flatMap { $0 }
        #expect(tracks.count == 3)
        #expect(tracks.first { $0.name == "valid.wav" }?.attributes[1] == 123)
        #expect(tracks.filter { $0.name != "valid.wav" }.allSatisfy { $0.attributes[1] == 456 })
        try FileManager.default.removeItem(at: root)
        let missingMount = ShareIndex()
        await missingMount.restoreMetadataCache(cache)
        _ = await missingMount.scan(folders: [(root, false)])
        #expect(await missingMount.library().isEmpty)
        #expect(await fresh.library(configuredFolders: [(root, false)]).isEmpty)
    }

    @Test @MainActor func isolatedStartupLoadsPersistedMetadataWithoutAdvertisingBeforeValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Collection")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<4 { try Data([1]).write(to: folder.appendingPathComponent("track-\(i).wav")) }
        let profile = root.appendingPathComponent("profile")
        let first = try AppModel(dataDirectory: profile)
        first.settings.sharedFolders = [ShareFolder(path: folder.path)]
        first.settings.checkForUpdates = false; first.settings.notifications = false
        first.settings.downloadDirectory = root.appendingPathComponent("downloads").path
        await first.saveSettings()
        let coldReads = await first.shareIndex.metadataReads
        #expect(coldReads == 4)
        await first.shutdown()
        let fresh = try AppModel(dataDirectory: profile)
        #expect(await fresh.shareIndex.library().isEmpty)
        await fresh.start()
        await fresh.initialShareTask?.value
        let warmReads = await fresh.shareIndex.metadataReads
        #expect(warmReads == 0)
        #expect(fresh.sharedCount == 4)
        #expect(fresh.connection == .offline)
        await fresh.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func metadataReadDoesNotOccupyIndexActorAndCancellationPreservesCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("existing.txt"))
        let gate = BlockingShareMetadata()
        let index = ShareIndex(metadataReader: { url, _ in
            if url.pathExtension == "wav" { return gate.read() }
            return [:]
        })
        _ = await index.scan(folders: [(root, false)])
        try Data([1]).write(to: root.appendingPathComponent("new.wav"))
        let scanning = Task { await index.scan(folders: [(root, false)]) }
        var iterator = gate.started.makeAsyncIterator()
        _ = await iterator.next()
        let committed = await index.library().values.flatMap { $0 }
        #expect(committed.count == 1)
        scanning.cancel(); gate.release()
        _ = await scanning.value
        #expect(await index.library().values.flatMap { $0 }.count == 1)
        var progress = index.progress.makeAsyncIterator()
        #expect(await progress.next()?.phase == .cancelled)
    }
}

private final class BlockingShareMetadata: Sendable {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let semaphore = DispatchSemaphore(value: 0)
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = pair.stream; continuation = pair.continuation
    }
    func read() -> [UInt32: UInt32] {
        continuation.yield(()); semaphore.wait()
        return [1: 123]
    }
    func release() { semaphore.signal() }
}

private actor ShareWorkGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation {
            blocked = $0
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func entered() async {
        if blocked != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}
