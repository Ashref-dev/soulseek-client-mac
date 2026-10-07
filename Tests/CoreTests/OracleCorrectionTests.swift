import AppKit
import Foundation
import SwiftUI
import Testing
import SoulseekCore
import Persistence
@testable import TransferEngine
@testable import ArpeggioServices
@testable import Arpeggio

private func row(_ status: TransferStatus, user: String = "peer", upload: Bool = false, token: UInt32? = nil, position: UInt32 = 0,
                 retries: Int = 0, error: String? = nil, runtime: TransferRuntimeState? = nil) -> Transfer {
    var transfer = Transfer(user: user, file: SharedFile(path: "Music\\Album\\\(UUID().uuidString).flac", size: 1000), upload: upload)
    transfer.status = status; transfer.token = token; transfer.queuePosition = position; transfer.retries = retries
    transfer.error = error; transfer.runtimeState = runtime
    return transfer
}

private func runtime(_ wait: TransferQueueWait?, inUse: Int = 0, slots: Int = 2, holds: Bool = false,
                     blockedUntil: Date? = nil, retry: TransferRetrySchedule? = nil) -> TransferRuntimeState {
    TransferRuntimeState(holdsLocalSlot: holds, localSlotsInUse: inUse, localSlots: slots, connected: true, directionSuspended: false,
                         queueWait: wait, peerBlockedUntil: blockedUntil, pendingRetry: retry)
}

/// Queue and retry wording must follow what the scheduler actually does, not what a row's history suggests.
@Suite struct QueueTruthTests {
    @Test func tokenlessRequestsHoldDownloadSlotsLikeTheScheduler() {
        let transfers = [row(.negotiating), row(.negotiating), row(.queued)]
        let context = TransferQueueContext.make(transfers, upload: false, connected: true, suspended: false, slots: 2)
        #expect(context.inUse == 2)
        #expect(TransferExplanation.reason(for: transfers[2], in: context) == .waitingForLocalSlot(inUse: 2, slots: 2))
        #expect(TransferQueueBanner.make(transfers, context: context) == .queued(remote: 0, local: 1))
        var preview = row(.negotiating); preview.preview = true
        #expect(TransferQueueContext.make([preview, row(.queued)], upload: false, connected: true, suspended: false, slots: 1).inUse == 0)
        let remote = row(.negotiating, position: 4)
        let behindRemote = TransferQueueContext.make([remote, row(.queued)], upload: false, connected: true, suspended: false, slots: 1)
        #expect(behindRemote.inUse == 0)
        #expect(TransferExplanation.reason(for: remote, in: behindRemote) == .remoteQueue(user: "peer", position: 4))
    }

    @Test func publishedSchedulerStateWinsOverInference() {
        let queued = row(.queued, runtime: runtime(.localSlots, inUse: 3, slots: 3))
        let context = TransferQueueContext.make([queued], upload: false, connected: true, suspended: false, slots: 3)
        #expect(context.inUse == 3)
        #expect(TransferExplanation.reason(for: queued, in: context) == .waitingForLocalSlot(inUse: 3, slots: 3))
        let remote = row(.negotiating, runtime: runtime(.remoteQueue, inUse: 0, slots: 3))
        #expect(TransferExplanation.reason(for: remote, in: context) == .remoteQueue(user: "peer", position: 0))
        #expect(TransferExplanation.label(.remoteQueue(user: "peer", position: 0)) == "In their queue")
    }

    @Test func deferredUploadWithNoActiveUploadsIsNotASlotWait() {
        let until = Date(timeIntervalSince1970: 2_000)
        let deferred = row(.queued, upload: true, runtime: runtime(.peerBackoff, inUse: 0, slots: 2, blockedUntil: until))
        let context = TransferQueueContext.make([deferred], upload: true, connected: true, suspended: false, slots: 2)
        let reason = TransferExplanation.reason(for: deferred, in: context)
        #expect(reason != .waitingForLocalSlot(inUse: 0, slots: 2))
        #expect(TransferExplanation.label(reason) == "Asked to wait")
        #expect(TransferQueueBanner.make([deferred], context: context) == .queued(remote: 1, local: 0))
        let inferred = row(.queued, upload: true)
        let idle = TransferQueueContext.make([inferred], upload: true, connected: true, suspended: false, slots: 2)
        #expect(TransferExplanation.label(TransferExplanation.reason(for: inferred, in: idle)) == "Waiting to start")
        #expect(TransferQueueBanner.make([inferred], context: idle) == nil)
        let busy = [row(.transferring, upload: true), row(.negotiating, upload: true), row(.queued, upload: true)]
        let full = TransferQueueContext.make(busy, upload: true, connected: true, suspended: false, slots: 2)
        #expect(TransferExplanation.reason(for: busy[2], in: full) == .waitingForLocalSlot(inUse: 2, slots: 2))
    }

    @Test func retryableFailureThenFileSafetyFailureNeverClaimsAnAutomaticRetry() {
        let message = "The file size didn’t match what the sharer announced."
        let online = TransferQueueContext(upload: false, connected: true, suspended: false, slots: 3, inUse: 0)
        for retries in [1, 2] {
            #expect(TransferExplanation.reason(for: row(.failed, retries: retries, error: message), in: online) == .failed(message))
            let reported = row(.failed, retries: retries, error: message, runtime: runtime(nil, retry: nil))
            #expect(TransferExplanation.reason(for: reported, in: online) == .failed(message))
        }
        let scheduled = row(.failed, retries: 1, error: "Timed out.",
                            runtime: runtime(nil, retry: TransferRetrySchedule(identity: UUID(), deadline: Date(timeIntervalSince1970: 3_000))))
        #expect(TransferExplanation.reason(for: scheduled, in: online) == .retrying(attempt: 1, limit: 3))
    }
}

/// Folder and track identities in the search outline must never merge different people or paths.
@Suite struct SearchIdentityTreeTests {
    private func result(_ user: String, _ path: String, size: UInt64) -> SearchResult {
        SearchResult(user: user, file: SharedFile(path: path, size: size), freeSlot: true, speed: 1, queue: 0)
    }

    @Test @MainActor func delimiterContainingUsersAndPathsKeepDistinctOwners() throws {
        let unitFolder = result("a", "b\u{1F}c\\x.flac", size: 1)
        let unitUser = result("a\u{1F}b", "c\\x.flac", size: 2)
        let nulFolder = result("a", "b\u{0}c\\y.flac", size: 3)
        let nulUser = result("a\u{0}b", "c\\y.flac", size: 4)
        let rows = [unitFolder, unitUser, nulFolder, nulUser]
        let tree = try ResultHierarchy.make(rows)
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(tree.tracks.count == 4)
        #expect(tree.users.count == 3)
        #expect(tree.folders.count == 4)
        for row in rows {
            let folder = try #require(tree.folders[ResultHierarchy.folderID(user: row.user, path: row.file.folder)])
            #expect(folder.user == row.user)
            #expect(folder.path == row.file.folder)
            #expect(folder.tracks.map(\.id) == [row.id])
            let track = try #require(tree.tracks[row.id])
            #expect(track.user == row.user); #expect(track.file.path == row.file.path); #expect(track.file.size == row.file.size)
        }
        for user in tree.users {
            #expect(user.folders.allSatisfy { $0.user == user.user })
            #expect(user.fileCount == rows.filter { $0.user == user.user }.count)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = SearchResultActions(model: try AppModel(dataDirectory: root), hierarchy: tree)
        let resolved = actions.resolve([.track(unitUser.id), .folder(ResultHierarchy.folderID(user: "a", path: "b\u{1F}c"))])
        #expect(resolved.tracks.map(\.user) == ["a\u{1F}b"])
        #expect(resolved.folders.map(\.user) == ["a"])
        let owning = actions.folders(for: [.track(unitUser.id)])
        #expect(owning.map(\.user) == ["a\u{1F}b"]); #expect(owning.map(\.path) == ["c"])
    }
}

/// Finished downloads are re-checked on disk at the moment someone uses them, and never fetched from the peer again.
@Suite struct MissingFileTruthTests {
    private func file() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Track.flac")
        try Data([1, 2, 3]).write(to: url)
        return (folder, url)
    }

    @Test func finishedDownloadsWithoutAFileAreMissingIncludingNoSavedLocation() throws {
        let (folder, url) = try file()
        defer { try? FileManager.default.removeItem(at: folder) }
        var present = row(.completed); present.destination = url.path
        var deleted = row(.completed); deleted.destination = folder.appendingPathComponent("gone.flac").path
        var nowhere = row(.completed); nowhere.destination = nil
        let active = row(.transferring)
        let upload = row(.completed, upload: true)
        #expect(TransferLocalFiles.missing([present, deleted, nowhere, active, upload]) == [deleted.id, nowhere.id])
    }

    @Test func explicitInteractionRechecksTheFileAndNeverFetchesFinishedFilesFromThePeer() throws {
        let (folder, url) = try file()
        defer { try? FileManager.default.removeItem(at: folder) }
        var done = row(.completed); done.destination = url.path
        #expect(TransferLocalFiles.action(for: done) == .openLocal(url))
        try FileManager.default.removeItem(at: url)
        #expect(TransferLocalFiles.action(for: done) == .missing)
        var nowhere = done; nowhere.destination = nil
        #expect(TransferLocalFiles.action(for: nowhere) == .missing)
        #expect(TransferLocalFiles.action(for: row(.transferring)) == .streamFromPeer)
        #expect(TransferLocalFiles.action(for: row(.completed, upload: true)) == .unavailable)
    }
}

@MainActor @Observable private final class ChromeState {
    var showsPlayer = false
    var showsBanner = false
    var showsToast = false
}

@MainActor private final class ChromeRecorder {
    var heights: [Double] = []
    var modes: [PlayerLayout.Mode] = []
    func mode(_ mode: PlayerLayout.Mode) -> PlayerLayout.Mode { modes.append(mode); return mode }
}

private struct ChromeFixture: View {
    let state: ChromeState
    let recorder: ChromeRecorder

    var body: some View {
        DetailChrome(showsPlayer: state.showsPlayer, onMeasure: { recorder.heights.append($0) }) {
            Color.clear
        } banners: {
            if state.showsBanner { Color.orange.frame(height: 44) }
        } player: { layout in
            Color.gray.frame(height: recorder.mode(layout.mode) == .compact ? PlayerLayout.compactHeight : PlayerLayout.regularHeight)
        } toast: { padding in
            if state.showsToast { Color.purple.frame(width: 200, height: 40).padding(.bottom, padding) }
        }
    }
}

/// The real detail chrome, hosted offscreen at the compact threshold, while the player, a banner and a toast come and go.
@Suite(.serialized) @MainActor struct DetailChromeGeometryTests {
    @Test(arguments: [639.0, 640.0, 641.0])
    func playerFormSettlesAndTheMeasurementIgnoresInsets(height: Double) throws {
        let state = ChromeState(), recorder = ChromeRecorder()
        let size = CGSize(width: 600, height: height)
        let host = NSHostingView(rootView: ChromeFixture(state: state, recorder: recorder).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func settle() { for _ in 0..<10 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        settle()
        try #require(!recorder.heights.isEmpty, "the detail column was never measured")
        let expected: PlayerLayout.Mode = height < PlayerLayout.compactBelowHeight ? .compact : .regular
        let steps: [(String, @MainActor (ChromeState) -> Void)] = [
            ("player appears", { $0.showsPlayer = true }), ("banner appears", { $0.showsBanner = true }),
            ("toast appears", { $0.showsToast = true }), ("player disappears", { $0.showsPlayer = false }),
            ("player returns", { $0.showsPlayer = true }), ("banner and toast go", { $0.showsBanner = false; $0.showsToast = false })]
        for (name, change) in steps {
            let start = recorder.modes.count
            change(state)
            settle()
            let seen = Array(recorder.modes[start...])
            if state.showsPlayer {
                #expect(recorder.modes.last == expected, "\(name): \(seen)")
                #expect(seen.allSatisfy { $0 == expected }, "\(name) changed form: \(seen)")
            }
            #expect(recorder.heights.allSatisfy { abs($0 - height) < 0.5 }, "\(name): \(recorder.heights)")
            if name == "toast appears", let directory = ProcessInfo.processInfo.environment["ARPEGGIO_UI_RENDER_OUTPUT"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(Int(height)).png"))
            }
        }
        let heights = recorder.heights.count, modes = recorder.modes.count
        settle()
        #expect(recorder.heights.count == heights, "measurement kept changing after layout settled")
        #expect(recorder.modes[modes...].allSatisfy { $0 == expected })
    }
}

extension TransferEngine {
    func deferUploads(to user: String, until date: Date) { uploadBlockedUntil[user] = date }
}

/// The real engine's published snapshot, not synthetic state, fed through the same wording the Transfers list uses.
@Suite struct EngineQueueTruthTests {
    @Test func realSchedulerSnapshotsDriveTheWording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("state.sqlite"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.configure(root: root, downloads: 2, uploads: 2)
        let message = "The file size didn’t match what the sharer announced."
        let first = row(.negotiating), second = row(.negotiating), waiting = row(.queued)
        let deferred = row(.queued, user: "listener", upload: true)
        let failed = row(.failed, retries: 1, error: message)
        for item in [first, second, waiting, deferred, failed] { await engine.seed(item) }
        await engine.deferUploads(to: "listener", until: Date().addingTimeInterval(60))
        let snapshot = await engine.snapshot()
        func published(_ id: String) throws -> Transfer { try #require(snapshot.first { $0.id == id }) }
        #expect(snapshot.allSatisfy { $0.runtimeState != nil })
        let downloads = TransferQueueContext.make(snapshot, upload: false, connected: true, suspended: false, slots: 2)
        #expect(downloads.inUse == 2)
        #expect(TransferExplanation.reason(for: try published(waiting.id), in: downloads) == .waitingForLocalSlot(inUse: 2, slots: 2))
        #expect(TransferQueueBanner.make(snapshot, context: downloads) == .queued(remote: 0, local: 1))
        let uploads = TransferQueueContext.make(snapshot, upload: true, connected: true, suspended: false, slots: 2)
        #expect(uploads.inUse == 0)
        let deferredReason = TransferExplanation.reason(for: try published(deferred.id), in: uploads)
        #expect(TransferExplanation.label(deferredReason) == "Asked to wait")
        #expect(TransferQueueBanner.make(snapshot, context: uploads) == .queued(remote: 1, local: 0))
        #expect(try published(failed.id).runtimeState?.pendingRetry == nil)
        #expect(TransferExplanation.reason(for: try published(failed.id), in: downloads) == .failed(message))
        await engine.shutdown(); await db.close()
    }
}
