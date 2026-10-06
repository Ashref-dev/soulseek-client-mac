import Foundation
import Testing
import Persistence
@testable import ArpeggioServices

@Suite struct ShareStatusTests {
    private func resolve(configured: Int = 1, missing: Int = 0, indexing: Bool = false, current: Bool = true,
                         files: Int = 0, unreadable: Int = 0, processed: Int = 0) -> ShareStatus {
        .resolve(configuredFolders: configured, missingFolders: missing, indexing: indexing, indexedCurrentConfiguration: current,
                 files: files, bytes: UInt64(files) * 10, unreadableItems: unreadable, filesProcessed: processed)
    }

    @Test func zeroFilesNeverMeansNoFoldersWhileFoldersAreConfigured() {
        #expect(resolve(indexing: true, current: false, processed: 5278) == .indexing(filesProcessed: 5278))
        #expect(resolve(indexing: true, current: false).headline == "Indexing your shared folders…")
        #expect(resolve(indexing: true, current: false).headline != ShareStatus.noFolders.headline)
        #expect(resolve(current: false) == .pending)
        #expect(resolve() == .empty(missingFolders: 0, unreadableItems: 0))
        #expect(resolve(unreadable: 3).detail?.contains("3 items couldn’t be read") == true)
        #expect(resolve(missing: 1) == .empty(missingFolders: 1, unreadableItems: 0))
        #expect(resolve(missing: 1).detail?.contains("missing or disconnected") == true)
        #expect(resolve(configured: 0, indexing: true) == .noFolders)
        #expect(resolve(configured: 0, files: 9) == .noFolders)
    }

    @Test func readyReportsCountsAndOutstandingProblems() {
        let ready = resolve(configured: 2, missing: 1, files: 4, unreadable: 2)
        #expect(ready == .ready(files: 4, bytes: 40, missingFolders: 1, unreadableItems: 2))
        #expect(ready.isSharing && !ready.isIndexing)
        #expect(ready.headline.hasPrefix("Sharing 4 files"))
        #expect(ready.detail?.contains("See Shared Files") == true)
        #expect(resolve(files: 4).detail == nil)
        #expect(resolve(missing: 5, files: 1) == .ready(files: 1, bytes: 10, missingFolders: 1, unreadableItems: 0))
    }

    @Test func copyAvoidsDashes() {
        let all: [ShareStatus] = [.noFolders, .pending, .indexing(filesProcessed: 0), .indexing(filesProcessed: 3),
                                  .empty(missingFolders: 2, unreadableItems: 1), .ready(files: 1, bytes: 1, missingFolders: 1, unreadableItems: 1)]
        for status in all {
            let text = status.headline + (status.detail ?? "")
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
        }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func modelStatusTracksConfiguredIndexingEmptyMissingAndReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music"), empty = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: music.appendingPathComponent("track.txt"))
        let model = try AppModel(dataDirectory: root.appendingPathComponent("profile"))
        model.settings.checkForUpdates = false; model.settings.notifications = false
        model.settings.downloadDirectory = root.appendingPathComponent("downloads").path
        #expect(model.shareStatus == .noFolders)

        model.settings.sharedFolders = [ShareFolder(path: music.path)]
        #expect(model.shareStatus == .pending)

        let gate = ScanGate()
        let realScan = model.scanShares
        model.scanShares = { model, folders, exclusions in
            await gate.wait()
            return await realScan(model, folders, exclusions)
        }
        let saving = Task { await model.saveSettings() }
        for _ in 0..<400 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.sharedCount == 0)
        if case .indexing = model.shareStatus {} else { Issue.record("expected indexing, got \(model.shareStatus)") }
        await gate.release(); await saving.value
        #expect(model.shareStatus == .ready(files: 1, bytes: 3, missingFolders: 0, unreadableItems: 0))

        model.settings.sharedFolders = [ShareFolder(path: empty.path)]
        await model.saveSettings()
        #expect(model.shareStatus == .empty(missingFolders: 0, unreadableItems: 0))

        try FileManager.default.removeItem(at: empty)
        await model.rescanShares()
        #expect(model.shareStatus == .empty(missingFolders: 1, unreadableItems: model.shareErrors.count))
        await model.shutdown()
    }
}

private actor ScanGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
