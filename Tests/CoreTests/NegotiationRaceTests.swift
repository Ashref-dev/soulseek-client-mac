import Foundation
import Testing
import Persistence
import SoulseekCore
@testable import TransferEngine

private actor NegotiationCalls {
    var codes: [UInt32] = []
    var tokens: UInt32 = 0
    func record(_ code: UInt32) -> Int { codes.append(code); return codes.count }
    func token() -> UInt32 { tokens += 1; return tokens }
}

extension TransferEngine {
    func racePersistence(_ hook: @escaping @Sendable (String) async -> Void) { beforePersistence = hook }
    func racePeerSend(_ send: @escaping @Sendable (String, UInt32, Data) async throws -> Void) {
        sendPeer = { user, code, payload, _ in try await send(user, code, payload) }
    }
    func raceToken(_ token: @escaping @Sendable () async -> UInt32) { nextNegotiationToken = token }
    func raceConnected() { connected = true }
}

private func negotiationEngine(_ root: URL, upload: Bool) async throws -> (TransferEngine, Database, String) {
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    let item = Transfer(user: "peer", file: SharedFile(path: "Music\\song.mp3", size: 10), upload: upload)
    await engine.seed(item, source: upload ? root.appendingPathComponent("song.mp3") : nil)
    return (engine, db, item.id)
}

@Test(.timeLimit(.minutes(1)))
func oldUploadSendFailureCannotFailResumedNegotiation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db, id) = try await negotiationEngine(root, upload: true)
    let gate = RaceGate(); let calls = NegotiationCalls()
    await engine.racePeerSend { _, code, _ in
        if await calls.record(code) == 1 { await gate.wait(); throw ProtocolError.disconnected }
    }
    let oldPump = Task { await engine.startQueuedUploads() }
    try await raceWait { await gate.arrivals == 1 }
    let oldToken = await engine.snapshot().first?.token
    await engine.setSuspended(upload: true, true)
    await engine.setSuspended(upload: true, false)
    let resumed = try #require(await engine.snapshot().first)
    #expect(resumed.status == .negotiating); #expect(resumed.token != oldToken)
    await gate.release(); await oldPump.value
    let final = try #require(await engine.snapshot().first)
    #expect(final.status == .negotiating); #expect(final.token == resumed.token); #expect(final.error == nil)
    #expect(await calls.codes == [40, 40])
    #expect(await engine.negotiations[id] != nil)
    await engine.shutdown(); await db.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func downloadPumpCannotSendAfterPauseAcrossPersistence(resumeBeforeRelease: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db, id) = try await negotiationEngine(root, upload: false)
    let gate = RaceGate(); let calls = NegotiationCalls()
    await engine.racePersistence { _ in if await gate.arrivals == 0 { await gate.wait() } }
    await engine.racePeerSend { _, code, _ in _ = await calls.record(code) }
    let oldPump = Task { await engine.pump() }
    try await raceWait { await gate.arrivals == 1 }
    let oldIdentity = await engine.negotiations[id]
    await engine.setSuspended(upload: false, true)
    #expect(await calls.codes.isEmpty)
    if resumeBeforeRelease { await engine.setSuspended(upload: false, false) }
    await gate.release(); await oldPump.value
    #expect(await calls.codes == (resumeBeforeRelease ? [43, 51] : []))
    #expect(await engine.snapshot().first?.status == (resumeBeforeRelease ? .negotiating : .queued))
    if let oldIdentity { await engine.expireNegotiation(id, token: nil, identity: oldIdentity) }
    #expect(await engine.snapshot().first?.error == nil)
    await engine.shutdown(); await db.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func oldDownloadSendCannotContinueOrFailNewNegotiation(throwsAfterJoin: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db, _) = try await negotiationEngine(root, upload: false)
    let gate = RaceGate(); let calls = NegotiationCalls()
    await engine.racePeerSend { _, code, _ in
        if await calls.record(code) == 1 {
            await gate.wait()
            if throwsAfterJoin { throw ProtocolError.disconnected }
        }
    }
    let oldPump = Task { await engine.pump() }
    try await raceWait { await gate.arrivals == 1 }
    await engine.setSuspended(upload: false, true); await engine.setSuspended(upload: false, false)
    await gate.release(); await oldPump.value
    #expect(await calls.codes == [43, 43, 51])
    #expect(await engine.snapshot().first?.status == .negotiating)
    #expect(await engine.snapshot().first?.error == nil)
    await engine.shutdown(); await db.close()
}

@Test(.timeLimit(.minutes(1)))
func oldUploadTokenContinuationCannotReserveResumedQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db, _) = try await negotiationEngine(root, upload: true)
    let gate = RaceGate(); let calls = NegotiationCalls()
    await engine.raceToken {
        let token = await calls.token()
        if token == 1 { await gate.wait() }
        return token
    }
    await engine.racePeerSend { _, code, _ in _ = await calls.record(code) }
    let oldPump = Task { await engine.startQueuedUploads() }
    try await raceWait { await gate.arrivals == 1 }
    await engine.setSuspended(upload: true, true); await engine.setSuspended(upload: true, false)
    await gate.release(); await oldPump.value
    #expect(await engine.snapshot().first?.token == 2)
    #expect(await calls.codes == [40])
    await engine.shutdown(); await db.close()
}

@Test(.timeLimit(.minutes(1)))
func pausedDownloadOfferCannotSendApprovalAfterPersistence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (engine, db, _) = try await negotiationEngine(root, upload: false)
    let gate = RaceGate(); let calls = NegotiationCalls()
    await engine.racePersistence { _ in if await gate.arrivals == 0 { await gate.wait() } }
    await engine.racePeerSend { _, code, _ in _ = await calls.record(code) }
    var offer = WireWriter(); offer.uint(1); offer.uint(7); offer.string("Music\\song.mp3"); offer.ulong(10)
    let payload = offer.data
    let approval = Task { try await engine.peerMessage(user: "peer", code: 40, payload: payload) }
    try await raceWait { await gate.arrivals == 1 }
    await engine.setSuspended(upload: false, true)
    await gate.release(); try await approval.value
    #expect(await calls.codes.isEmpty); #expect(await engine.snapshot().first?.token == nil)
    await engine.shutdown(); await db.close()
}
