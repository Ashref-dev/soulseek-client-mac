import Foundation
import Testing
import Persistence
@testable import SoulseekCore
@testable import TransferEngine

private actor FailureGate {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func awaitFailureEvidence(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("Failure ownership evidence timed out") }
        await Task.yield()
    }
}

extension TransferEngine {
    fileprivate func installFailureAttempt(_ id: String, attempt: UUID) { attempts[id] = attempt }
    fileprivate func gateFailurePersistence(_ gate: FailureGate) {
        beforePersistence = { _ in await gate.wait() }
    }
    fileprivate func clearFailurePersistenceGate() { beforePersistence = nil }
}

extension SoulseekSession {
    fileprivate func authorizeFailureFixturePeer() { addresses["fixture"] = ("127.0.0.1", 1) }
}

struct FailureJoinTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func previewCleanupWaitsForFailureOwnedWriter(discard: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        await engine.setPreviewRoot(root.appendingPathComponent("Previews"))
        let result = SearchResult(user: "fixture", file: SharedFile(path: "book.pdf", size: 10), freeSlot: true, speed: 0, queue: 0)
        let id = try await engine.preview(result)
        let partial = URL(fileURLWithPath: try #require(await engine.snapshot().first?.partial))
        let bytes = Data("partial".utf8); try bytes.write(to: partial)
        let gate = FailureGate(), worker = Task { await gate.wait() }
        await engine.installPreviewJoiningTask(id, task: worker)
        try await awaitFailureEvidence { await gate.entered }
        let failure = Task { await engine.fail(id, error: FileSafetyError.sizeMismatch) }
        try await awaitFailureEvidence { await engine.closing.contains(id) }
        if discard { await engine.discardPreview(id) } else { await engine.expirePreview(id) }
        #expect(worker.isCancelled)
        #expect(await engine.tasks[id] != nil)
        #expect(await engine.previewTerminalOwners[id] == nil)
        #expect(try Data(contentsOf: partial) == bytes)
        #expect(await engine.partialOwner(partial.path)?.id == id)
        await gate.release(); await failure.value; await worker.value
        await engine.joinDeferredPreviewCleanup()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!(await engine.closing.contains(id)))
        if discard {
            #expect(await engine.snapshot().isEmpty)
            #expect(try await db.get(Transfer.self, collection: "transfers", id: id) == nil)
        } else {
            #expect(await engine.snapshot().first?.status == .cancelled)
        }
        await engine.shutdown(); await db.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func actualDownloadWorkerSafetyFailureClosesBeforeRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db")), session = SoulseekSession()
        let engine = TransferEngine(session: session, database: db, root: root)
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 10))
        item.status = .negotiating; item.token = 321
        let id = item.id, persistence = FailureGate()
        await engine.seed(item)
        await engine.gateFailurePersistence(persistence)
        await session.authorizeFailureFixturePeer()
        let port = try unusedPort()
        try await session.startListener(port: port)
        let incoming = Task {
            for await envelope in session.events {
                if case .fileConnection(let user, let connection) = envelope.event {
                    await engine.acceptFile(user: user, connection: connection)
                    return
                }
            }
        }
        let sender = try TCPConnection(host: "127.0.0.1", port: port)
        try await sender.start()
        var handshake = WireWriter(); handshake.string("fixture"); handshake.string("F"); handshake.uint(0)
        try await sender.send(WireWriter.frame(code: 1, payload: handshake.data, narrow: true))
        var token = WireWriter(); token.uint(321); try await sender.send(token.data)
        await incoming.value
        try await awaitFailureEvidence { await persistence.entered }
        let worker = try #require(await engine.tasks[id])
        #expect(await engine.closing.contains(id))
        #expect(await engine.snapshot().first?.error == FileSafetyError.unsafePath.localizedDescription)
        #expect(await engine.retryTasks.isEmpty)
        if await engine.closing.contains(id) { await engine.resume(id) }
        #expect(await engine.snapshot().first?.status == .failed)
        await persistence.release(); await worker.value
        await engine.clearFailurePersistenceGate()
        #expect(await engine.tasks[id] == nil)
        #expect(!(await engine.closing.contains(id)))
        #expect(try await db.get(Transfer.self, collection: "transfers", id: id)?.status == .failed)
        try await awaitFailureEvidence { await session.fileConnections.isEmpty }
        await engine.setConnected(false); await engine.resume(id)
        #expect(await engine.snapshot().first?.status == .queued)
        sender.cancel(); await session.shutdown(); await engine.shutdown(); await db.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func externalFailureOwnsWriterThroughJoinAndPersistence(matchingAttempt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 10))
        let partial = root.appendingPathComponent("partial").path
        item.status = .transferring; item.partial = partial
        let id = item.id, attempt = UUID()
        let writerGate = FailureGate(), persistenceGate = FailureGate()
        let writer = Task { await writerGate.wait() }
        await engine.seed(item, task: writer)
        await engine.installFailureAttempt(id, attempt: attempt)
        await engine.gateFailurePersistence(persistenceGate)
        try await awaitFailureEvidence { await writerGate.entered }
        await engine.fail(id, error: ProtocolError.disconnected, attempt: UUID())
        await engine.failFromWorker(id, error: ProtocolError.disconnected, attempt: UUID())
        #expect(await engine.snapshot().first?.status == .transferring)
        #expect(!writer.isCancelled)
        #expect(await engine.tasks[id] != nil)
        let failure = Task { await engine.fail(id, error: FileSafetyError.sizeMismatch, attempt: matchingAttempt ? attempt : nil) }
        try await awaitFailureEvidence { await engine.snapshot().first?.status == .failed }
        #expect(writer.isCancelled)
        #expect(await engine.tasks[id] != nil)
        #expect(await engine.closing.contains(id))
        #expect(!(await persistenceGate.entered), "Persistence must follow writer join, even with an explicit matching attempt")
        if await engine.closing.contains(id) {
            await engine.resume(id); await engine.pause(id); await engine.cancel(id)
            #expect(await engine.snapshot().first?.status == .failed)
            do { try await engine.removeTransfers([id]); Issue.record("Removal must reject a failure-owned writer") } catch { }
        }
        #expect(await engine.partialOwner(partial)?.id == id)
        await writerGate.release(); await writer.value
        try await awaitFailureEvidence { await persistenceGate.entered }
        #expect(await engine.closing.contains(id), "Join barrier must last through failed-state persistence")
        if await engine.closing.contains(id) { await engine.clearFailed(upload: false) }
        #expect(await engine.snapshot().contains { $0.id == id })
        await persistenceGate.release(); await failure.value
        await engine.clearFailurePersistenceGate()
        #expect(await engine.tasks[id] == nil)
        #expect(!(await engine.closing.contains(id)))
        #expect(try await db.get(Transfer.self, collection: "transfers", id: id)?.status == .failed)
        await engine.setConnected(false); await engine.resume(id)
        #expect(await engine.snapshot().first?.status == .queued)
        await engine.shutdown(); await db.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func actualUploadWorkerFailureCannotSelfJoinOrReleasePersistenceOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(url: root.appendingPathComponent("db"))
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
        var item = Transfer(user: "fixture", file: SharedFile(path: "song", size: 10), upload: true)
        item.status = .negotiating; item.token = 123
        let id = item.id, authorization = FailureGate(), persistence = FailureGate()
        await engine.seed(item, source: root.appendingPathComponent("song"))
        await engine.setUploadAuthorizer { _, _, _ in await authorization.wait(); return false }
        await engine.gateFailurePersistence(persistence)
        var response = WireWriter(); response.uint(123); response.byte(1)
        try await engine.peerMessage(user: "fixture", code: 41, payload: response.data)
        try await awaitFailureEvidence { await authorization.entered }
        let worker = try #require(await engine.tasks[id])
        await authorization.release()
        // This is the actual production Task catch, not a test calling fail on behalf of it.
        try await awaitFailureEvidence { await persistence.entered }
        #expect(await engine.snapshot().first?.status == .failed)
        #expect(await engine.snapshot().first?.error == "File is no longer shared with this user.")
        #expect(await engine.tasks[id] != nil)
        #expect(await engine.closing.contains(id))
        if await engine.closing.contains(id) { await engine.clearFailed(upload: true) }
        #expect(await engine.snapshot().contains { $0.id == id })
        await persistence.release(); await worker.value
        await engine.clearFailurePersistenceGate()
        #expect(await engine.tasks[id] == nil)
        #expect(!(await engine.closing.contains(id)))
        #expect(try await db.get(Transfer.self, collection: "transfers", id: id)?.status == .failed)
        #expect(await engine.queueUpload(user: "fixture", file: item.file, localURL: root.appendingPathComponent("song"), start: false))
        #expect(await engine.snapshot().count == 2, "A fresh upload may be queued after failure finalization")
        await engine.shutdown(); await db.close()
    }
}
