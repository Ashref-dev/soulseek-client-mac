import Foundation
import Testing
@testable import SoulseekCore
@testable import TransferEngine
import Persistence
import ShareIndexer
import ProtocolFixtures
@testable import ArpeggioServices

@Test func rejectsAmplifiedLibrariesAndBranchOverflow() throws {
    var writer = WireWriter(); writer.uint(1); writer.string(String(repeating: "a", count: 4000)); writer.uint(10_000)
    for _ in 0..<10_000 { PeerCodec.writeFile(SharedFile(path: "f", size: 1), to: &writer) }
    let compressed = try Zlib.deflate(writer.data)
    #expect(throws: ProtocolError.self) { try PeerCodec.library(user: "hostile", data: compressed) }
    #expect(throws: ProtocolError.self) { try PeerCodec.nextBranchLevel(UInt32.max) }
    #expect(try PeerCodec.nextBranchLevel(0) == 1)
    #expect(throws: FileSafetyError.self) { try SafeDestination.components(user: "hostile", remotePath: "Music\\.arpeggio-collision.partial") }
}

@Test func criticalEventsBackpressureInsteadOfDropping() async throws {
    let channel = EventChannel()
    let producer = Task {
        for index in 0..<200 {
            await channel.send(SessionEvent(generation: 1, account: "fixture", event: .roomMessage(room: "test", user: "fixture", text: String(index))))
        }
    }
    for index in 0..<200 {
        let item = try #require(await channel.next())
        guard case .roomMessage(_, _, let text) = item.event else { Issue.record("Unexpected event"); continue }
        #expect(text == String(index))
    }
    await producer.value; await channel.close()
    #expect(await channel.next() == nil)
}

@Test func decodesTenThousandResultsWithinInteractiveBudget() throws {
    let files = (0..<10_000).map { SharedFile(path: "Music\\Release\\Track \($0).flac", size: UInt64($0 + 1), attributes: [4: 96000, 5: 24]) }
    let encoded = try PeerCodec.searchReply(user: "fixture", token: 7, files: files, slots: true, speed: 1_000_000, queue: 0)
    let start = ContinuousClock.now
    let results = try PeerCodec.search(encoded)
    let elapsed = start.duration(to: .now)
    #expect(results.1.count == 10_000); #expect(elapsed < .seconds(2))
}

private actor Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func entered() -> Bool { continuation != nil }
}

extension TransferEngine {
    func seed(_ item: Transfer, source: URL? = nil, task: Task<Void, Never>? = nil) {
        transfers.append(item)
        if let source { uploadSources[item.id] = source }
        if let task { tasks[item.id] = task }
        connected = true
    }
}

@Test func lateApprovalCannotRestartCancelledUpload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    var item = Transfer(user: "fixture", file: SharedFile(path: "Music\\file.txt", size: 10), upload: true)
    item.status = .cancelled; item.token = 123
    await engine.seed(item, source: root.appendingPathComponent("file.txt"))
    var response = WireWriter(); response.uint(123); response.byte(1)
    try await engine.peerMessage(user: "fixture", code: 41, payload: response.data)
    #expect(await engine.tasks.isEmpty)
    #expect(await engine.transfers.first?.status == .cancelled)
    await engine.shutdown(); await db.close()
}

@Test func cancelAndClearCannotInvalidateSuspendedArrayIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    var item = Transfer(user: "fixture", file: SharedFile(path: "Music\\file.txt", size: 10), upload: true); item.status = .transferring
    let gate = Gate()
    let task = Task { await gate.wait() }
    await engine.seed(item, task: task)
    while !(await gate.entered()) { await Task.yield() }
    let cancellation = Task { await engine.cancel(item.id) }
    while await engine.transfers.first?.status != .cancelled { await Task.yield() }
    await engine.clearFinished(upload: true)
    await gate.release(); await cancellation.value
    await engine.clearFinished(upload: true)
    #expect(await engine.transfers.isEmpty)
    await engine.shutdown(); await db.close()
}

@Test func currentSharingSettingsRevokeStaleIndexWithoutRescan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("private".utf8).write(to: folder.appendingPathComponent("file.txt"))
    let index = ShareIndex(); _ = await index.scan(folders: [(folder, false)])
    #expect(await index.library().count == 1)
    #expect(await index.library(configuredFolders: []).isEmpty)
    #expect(await index.resolve("Music\\file.txt", configuredFolders: [(folder, true)]) == nil)
    #expect(await index.resolve("Music\\file.txt", allowPrivate: true, configuredFolders: [(folder, true)]) != nil)
}

@Test func duplicateApprovalCannotCreateTwoUploadTasks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    var item = Transfer(user: "fixture", file: SharedFile(path: "Music\\file.txt", size: 10), upload: true)
    item.status = .negotiating; item.token = 123
    let gate = Gate()
    await engine.setUploadAuthorizer { _, _, _ in await gate.wait(); return true }
    await engine.seed(item, source: root.appendingPathComponent("file.txt"))
    var response = WireWriter(); response.uint(123); response.byte(1)
    try await engine.peerMessage(user: "fixture", code: 41, payload: response.data)
    while !(await gate.entered()) { await Task.yield() }
    try await engine.peerMessage(user: "fixture", code: 41, payload: response.data)
    #expect(await engine.tasks.count == 1)
    await gate.release(); await engine.shutdown(); await db.close()
}

@Test(.timeLimit(.minutes(1))) func staleConnectCannotDisconnectNewSession() async throws {
    let fixture = try await MockSoulseekServer.start(loginDelay: .milliseconds(150))
    let port = try await fixture.port(); let session = SoulseekSession()
    let firstPort = try unusedPort(); let secondPort = try unusedPort()
    let first = Task { try await session.connect(host: "127.0.0.1", port: port, user: "old-account", password: "fixture", listeningPort: firstPort) }
    try await Task.sleep(for: .milliseconds(40))
    try await session.connect(host: "127.0.0.1", port: port, user: "new-account", password: "fixture", listeningPort: secondPort)
    do { try await first.value; Issue.record("Old login should have been superseded") } catch { }
    #expect(await session.username == "new-account"); #expect(await session.server != nil)
    await session.shutdown(); await fixture.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor func editingAccountDuringLoginDoesNotBindWrongIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await MockSoulseekServer.start(loginDelay: .milliseconds(150))
    let model = try AppModel(dataDirectory: root); await model.start()
    model.settings.server = "127.0.0.1"; model.settings.port = try await fixture.port()
    model.settings.listeningPort = try unusedPort(); model.settings.username = "old-account"
    let login = Task { await model.login(password: "fixture", remember: false) }
    try await Task.sleep(for: .milliseconds(40)); model.settings.username = "new-account"
    await login.value
    #expect(model.activeAccount != "old-account")
    #expect(model.error == "Account settings changed while signing in. Please reconnect.")
    await model.shutdown(); await fixture.stop()
}

@Test(.timeLimit(.minutes(1))) func fullQueueShutdownDoesNotNeedAConsumer() async {
    let session = SoulseekSession()
    for _ in 0..<32 { await session.emit(.diagnostic("fixture")) }
    let start = ContinuousClock.now
    await session.shutdown()
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func staleAttemptCannotCompleteNewOrCancelledTransfer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    var item = Transfer(user: "fixture", file: SharedFile(path: "Music\\file.txt", size: 10)); item.status = .transferring
    await engine.seed(item)
    await engine.complete(item.id, bytes: 10, attempt: UUID())
    #expect(await engine.transfers.first?.status == .transferring)
    await engine.cancel(item.id)
    await engine.complete(item.id, bytes: 10, attempt: UUID())
    #expect(await engine.transfers.first?.status == .cancelled)
    await engine.shutdown(); await db.close()
}

@Test func failureCancelsTrackedWriterInsteadOfLeavingItUnowned() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite"))
    let engine = TransferEngine(session: SoulseekSession(), database: db, root: root)
    var item = Transfer(user: "fixture", file: SharedFile(path: "Music\\file.txt", size: 10)); item.status = .transferring
    let gate = Gate(); let task = Task { await gate.wait() }
    await engine.seed(item, task: task)
    while !(await gate.entered()) { await Task.yield() }
    let id = item.id
    let failure = Task { await engine.fail(id, error: ProtocolError.disconnected) }
    while await engine.transfers.first?.status != .failed { await Task.yield() }
    #expect(task.isCancelled)
    #expect(await engine.tasks[item.id] != nil)
    #expect(await engine.closing.contains(item.id))
    await engine.resume(item.id)
    #expect(await engine.transfers.first?.status == .failed)
    await gate.release(); await failure.value; await task.value
    #expect(await engine.tasks[item.id] == nil)
    #expect(!(await engine.closing.contains(item.id)))
    await engine.shutdown(); await db.close()
}

extension SoulseekSession {
    func registerFixtureConnection(_ connection: FramedConnection) { fileConnections[ObjectIdentifier(connection)] = connection }
}

@Test func preHandleFileFailureReleasesRegisteredConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("state.sqlite")); let session = SoulseekSession()
    let engine = TransferEngine(session: session, database: db, root: root)
    let connection = FramedConnection(try TCPConnection(host: "127.0.0.1", port: 1))
    await session.registerFixtureConnection(connection)
    do { try await engine.download("missing", connection: connection, attempt: UUID()); Issue.record("Expected rejected transfer") } catch { }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await session.fileConnections.isEmpty), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await session.fileConnections.isEmpty)
    await session.shutdown(); await engine.shutdown(); await db.close()
}

@Test @MainActor func serverMessageIDsAreScopedToTheReceivingAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root); await model.start()
    for account in ["account-a", "account-b"] {
        await model.handle(.privateMessage(id: 42, user: "fixture", text: account, timestamp: 1234), account: account, generation: 0)
    }
    let saved = try await model.database.all(ChatMessage.self, collection: "messages")
    #expect(saved.count == 2); #expect(Set(saved.map(\.id)).count == 2)
    #expect(Set(saved.compactMap(\.account)) == ["account-a", "account-b"])
    await model.shutdown()
}
