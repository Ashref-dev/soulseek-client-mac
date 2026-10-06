import Foundation
import Testing
import Persistence
@testable import ArpeggioServices

@Suite struct ShareWatcherRescanTests {
    @Test(.timeLimit(.minutes(1))) @MainActor
    func secondWatcherEventCannotCancelActiveScanOrLoseChangedExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Collection")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("keep.txt"))
        try Data([1, 2]).write(to: folder.appendingPathComponent("exclude.wav"))
        let model = try AppModel(dataDirectory: root.appendingPathComponent("profile"))
        model.settings.sharedFolders = [ShareFolder(path: folder.path)]
        model.settings.downloadDirectory = root.appendingPathComponent("downloads").path
        let gate = WatcherScanGate()
        var configurations: [[String]] = []
        model.scanShares = { model, folders, exclusions in
            configurations.append(exclusions)
            if configurations.count == 1 { await gate.wait() }
            return await model.shareIndex.scan(folders: folders.map { (URL(fileURLWithPath: $0.path), $0.buddyOnly) }, exclusions: exclusions)
        }
        let firstEvent = model.scheduleShareRescan(after: .zero)
        await gate.entered()
        model.settings.shareExclusions = ["*.wav"]
        await model.saveSettings()
        let secondEvent = model.scheduleShareRescan(after: .zero)
        await secondEvent.value
        let activeOwnerCancelled = firstEvent.isCancelled
        let invalidationPending = model.rescanPending
        #expect(activeOwnerCancelled == false)
        #expect(invalidationPending == true)
        await gate.release(); await firstEvent.value
        #expect(configurations == [[], ["*.wav"]])
        let appliedExclusions = model.indexedExclusions
        let pending = model.rescanPending
        let indexing = model.indexing
        let count = model.sharedCount
        let bytes = model.sharedBytes
        #expect(appliedExclusions == ["*.wav"])
        #expect(pending == false)
        #expect(indexing == false)
        #expect(count == 1)
        #expect(bytes == 1)
        let committed = await model.shareIndex.library(configuredFolders: model.currentShareFolders)
        #expect(committed.values.flatMap { $0 }.map(\.name) == ["keep.txt"])
        let visible = model.sharedLibrary
        #expect(visible == committed)
        #expect(await model.shareIndex.search("exclude", configuredFolders: model.currentShareFolders).isEmpty)
        let debounceCleared = model.shareChangeTask == nil
        #expect(debounceCleared)
        await model.shutdown()
    }

    @Test @MainActor func newerWatcherEventStillCancelsPendingDebounce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        var scans = 0
        model.scanShares = { _, _, _ in scans += 1; return (0, 0) }
        let pending = model.scheduleShareRescan(after: .seconds(60))
        let current = model.scheduleShareRescan(after: .zero)
        await pending.value; await current.value
        #expect(pending.isCancelled)
        #expect(scans == 1)
        await model.shutdown()
    }

    @Test @MainActor func cancelledOldDebounceCannotClearReplacementAndExplicitCancellationDoesNotScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        var scans = 0
        model.scanShares = { _, _, _ in scans += 1; return (0, 0) }
        let old = model.scheduleShareRescan(after: .seconds(60))
        let current = model.scheduleShareRescan(after: .seconds(60))
        await old.value
        let replacementPending = model.shareChangeTask != nil
        #expect(old.isCancelled)
        #expect(replacementPending)
        #expect(!current.isCancelled)
        current.cancel(); await current.value
        let debounceCleared = model.shareChangeTask == nil
        #expect(debounceCleared)
        #expect(scans == 0)
        await model.shutdown()
    }
}

private actor WatcherScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
