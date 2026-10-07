import Foundation
import Testing
import SoulseekCore
import Persistence
@testable import TransferEngine
@testable import ArpeggioServices

@MainActor private final class StopBridge: RemoteCommandBridge {
    final class Token {}
    var handlers: [RemoteCommand: @MainActor (RemoteCommandEvent) -> Bool] = [:]
    func addTarget(_ command: RemoteCommand, handler: @escaping @MainActor (RemoteCommandEvent) -> Bool) -> AnyObject {
        handlers[command] = handler; return Token()
    }
    func removeTarget(_ token: AnyObject, from command: RemoteCommand) { handlers[command] = nil }
    func setEnabled(_ enabled: Bool, for command: RemoteCommand) {}
    func setNowPlaying(_ info: NowPlayingInfo?) {}
    @discardableResult func send(_ command: RemoteCommand) -> Bool { handlers[command]?(.command(command)) ?? false }
}

private func silence(in folder: URL, _ name: String) throws -> URL {
    let rate = 8000, samples = 8000 * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2)); data.append(Data(count: samples * 2))
    let url = folder.appendingPathComponent("\(name).wav")
    try data.write(to: url)
    return url
}

/// A system Stop accepted for one track must not stop a track selected before the stop's task ran.
@Suite(.serialized) @MainActor struct RemoteStopOwnershipTests {
    @Test func stopAcceptedForTheOldTrackLeavesTheNewTrackPlaying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try silence(in: root, "A"), second = try silence(in: root, "B")
        let model = try AppModel(dataDirectory: root.appendingPathComponent("state"))
        let bridge = StopBridge()
        model.playback.volume = 0
        model.playback.remoteCommands = RemoteCommandRouter(bridge: bridge)
        model.playback.remoteStop = model.remoteStopHandler()
        model.play(file: first, title: "A", subtitle: "fixture")
        #expect(bridge.send(.stop))
        model.play(file: second, title: "B", subtitle: "fixture")
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.playback.item?.fileURL == second, "the stop accepted for A stopped B")
        #expect(bridge.send(.stop))
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.playback.item == nil, "a stop with nothing new selected must still stop")
    }
}

extension TransferEngine {
    func acceptSendsWithoutNetwork() { sendPeer = { _, _, _, _ in }; nextNegotiationToken = { 1 } }
}

/// Published scheduler state that says "no wait" is authoritative; an old queue position is not a remote queue.
@Suite struct AuthoritativeNoWaitTests {
    private func download(_ status: TransferStatus, position: UInt32, runtime: TransferRuntimeState? = nil) -> Transfer {
        var transfer = Transfer(user: "peer", file: SharedFile(path: "Music\\Album\\\(UUID().uuidString).flac", size: 1000))
        transfer.status = status; transfer.queuePosition = position; transfer.runtimeState = runtime
        return transfer
    }

    @Test func presentStateWithNoWaitIgnoresAStaleQueuePosition() {
        let state = TransferRuntimeState(holdsLocalSlot: true, localSlotsInUse: 1, localSlots: 2, connected: true, directionSuspended: false,
                                         queueWait: nil, peerBlockedUntil: nil, pendingRetry: nil)
        let fresh = download(.negotiating, position: 7, runtime: state)
        let context = TransferQueueContext.make([fresh], upload: false, connected: true, suspended: false, slots: 2)
        #expect(TransferExplanation.reason(for: fresh, in: context) == .connecting(user: "peer"))
        #expect(TransferQueueBanner.make([fresh], context: context) == nil)
        let legacy = download(.negotiating, position: 7)
        let inferred = TransferQueueContext.make([legacy], upload: false, connected: true, suspended: false, slots: 2)
        #expect(TransferExplanation.reason(for: legacy, in: inferred) == .remoteQueue(user: "peer", position: 7))
    }

    @Test func realPauseResumeKeepsAStalePositionButTheEngineSaysNoWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-nowait-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("state.sqlite"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.configure(root: root, downloads: 2, uploads: 2)
        await engine.acceptSendsWithoutNetwork()
        let item = download(.queued, position: 5)
        await engine.seed(item)
        await engine.pause(item.id)
        await engine.resume(item.id)
        let snapshot = await engine.snapshot()
        let published = try #require(snapshot.first { $0.id == item.id })
        #expect(published.status == .negotiating)
        #expect(published.queuePosition == 5)
        let state = try #require(published.runtimeState)
        #expect(state.queueWait == nil); #expect(state.holdsLocalSlot)
        let context = TransferQueueContext.make(snapshot, upload: false, connected: true, suspended: false, slots: 2)
        #expect(TransferExplanation.reason(for: published, in: context) == .connecting(user: "peer"))
        #expect(TransferQueueBanner.make(snapshot, context: context) == nil)
        await engine.shutdown(); await db.close()
    }
}
