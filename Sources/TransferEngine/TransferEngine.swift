import Foundation
import SoulseekCore
import Persistence

public actor TransferEngine {
    public nonisolated let updates: AsyncStream<[Transfer]>
    let continuation: AsyncStream<[Transfer]>.Continuation
    let session: SoulseekSession
    let database: Database
    var transfers: [Transfer] = []
    var tasks: [String: Task<Void, Never>] = [:]
    var sockets: [String: TCPConnection] = [:]
    var uploadSources: [String: URL] = [:]
    var downloadRoot: URL
    var downloadSlots = 3
    var uploadSlots = 2
    var downloadLimit: Double = 0
    var uploadLimit: Double = 0
    var connected = false
    var remoteQueued: Set<String> = []
    var retryTasks: [String: Task<Void, Never>] = [:]
    var uploadBlockedUntil: [String: Date] = [:]
    var attempts: [String: UUID] = [:]
    var closing: Set<String> = []
    var negotiationTasks: [String: Task<Void, Never>] = [:]
    var uploadAuthorizer: (@Sendable (String, SharedFile, URL) async -> Bool)?
    public init(session: SoulseekSession, database: Database, root: URL) {
        self.session = session; self.database = database; downloadRoot = root
        let pair = AsyncStream<[Transfer]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream; continuation = pair.continuation
    }
    public func restore() async throws {
        transfers = try await database.all(Transfer.self, collection: "transfers")
        for index in transfers.indices where [.transferring, .negotiating, .queued].contains(transfers[index].status) {
            transfers[index].status = transfers[index].upload ? .failed : .queued
            transfers[index].speed = 0; transfers[index].token = nil
        }
        publish()
    }
    public func configure(root: URL, downloads: Int, uploads: Int, downloadLimitKB: Int = 0, uploadLimitKB: Int = 0) {
        downloadRoot = root; downloadSlots = max(1, min(20, downloads)); uploadSlots = max(1, min(20, uploads))
        downloadLimit = Double(max(0, min(1_000_000, downloadLimitKB))) * 1024
        uploadLimit = Double(max(0, min(1_000_000, uploadLimitKB))) * 1024
    }
    public func setConnected(_ value: Bool) async {
        connected = value
        if !value {
            let ownedTasks = Array(tasks.values)
            let ids = transfers.filter { [.transferring, .negotiating].contains($0.status) }.map(\.id)
            var checkpoints: [Transfer] = []
            for id in ids {
                guard let index = transfers.firstIndex(where: { $0.id == id }) else { continue }
                transfers[index].status = transfers[index].upload ? .failed : .queued
                transfers[index].speed = 0; transfers[index].token = nil
                checkpoints.append(transfers[index])
            }
            attempts.removeAll(); remoteQueued.removeAll()
            for task in negotiationTasks.values { task.cancel() }; negotiationTasks.removeAll()
            for task in retryTasks.values { task.cancel() }; retryTasks.removeAll()
            for socket in sockets.values { socket.cancel() }
            for task in tasks.values { task.cancel() }
            sockets.removeAll(); tasks.removeAll()
            for task in ownedTasks { await task.value }
            for checkpoint in checkpoints { await save(checkpoint) }
        }
        publish(); await pump()
    }
    public func shutdown() async { await setConnected(false); continuation.finish() }
    public func setUploadAuthorizer(_ authorizer: @escaping @Sendable (String, SharedFile, URL) async -> Bool) { uploadAuthorizer = authorizer }
    public func revalidateUploads() async {
        let active = transfers.filter { $0.upload && [.queued, .negotiating, .transferring].contains($0.status) }
        for item in active {
            guard let source = uploadSources[item.id], let uploadAuthorizer else { await cancel(item.id); continue }
            if !(await uploadAuthorizer(item.user, item.file, source)) { await cancel(item.id) }
        }
    }
    public func enqueue(_ results: [SearchResult]) async throws {
        for result in results {
            guard result.file.size <= 16 * 1024 * 1024 * 1024 else { throw ProtocolError.oversized }
            if transfers.contains(where: { !$0.upload && $0.user == result.user && $0.file.path == result.file.path && (![.cancelled, .completed].contains($0.status) || closing.contains($0.id)) }) { continue }
            let (destination, partial) = try SafeDestination.prepare(root: downloadRoot, user: result.user, remotePath: result.file.path)
            var transfer = Transfer(user: result.user, file: result.file)
            transfer.destination = destination.path; transfer.partial = partial.path
            transfers.append(transfer); try await database.put(transfer, collection: "transfers", id: transfer.id)
        }
        publish(); await pump()
    }
    public func pause(_ id: String) async { await change(id, to: .paused) }
    public func cancel(_ id: String) async { await change(id, to: .cancelled) }
    public func resume(_ id: String) async {
        guard !closing.contains(id), let index = transfers.firstIndex(where: { $0.id == id }), !transfers[index].upload, [.paused, .failed, .cancelled].contains(transfers[index].status) else { return }
        transfers[index].status = .queued; transfers[index].error = nil; transfers[index].token = nil
        remoteQueued.remove(id)
        await save(transfers[index]); publish(); await pump()
    }
    public func clearFinished(upload: Bool) async {
        let removed = transfers.filter { $0.upload == upload && [.completed, .cancelled].contains($0.status) && !closing.contains($0.id) }
        transfers.removeAll { item in removed.contains { $0.id == item.id } }
        for item in removed { try? await database.remove(collection: "transfers", id: item.id) }
        publish()
    }
    public func clearFailed(upload: Bool) async {
        let removed = transfers.filter { $0.upload == upload && $0.status == .failed && !closing.contains($0.id) }
        for item in removed {
            retryTasks.removeValue(forKey: item.id)?.cancel()
            try? await database.remove(collection: "transfers", id: item.id)
        }
        let ids = Set(removed.map(\.id)); transfers.removeAll { ids.contains($0.id) }; publish()
    }
    func change(_ id: String, to status: TransferStatus) async {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].status != .completed else { return }
        transfers[index].status = status; transfers[index].speed = 0
        transfers[index].token = nil; attempts.removeValue(forKey: id)
        remoteQueued.remove(id); retryTasks.removeValue(forKey: id)?.cancel()
        negotiationTasks.removeValue(forKey: id)?.cancel()
        let snapshot = transfers[index]
        let task = tasks.removeValue(forKey: id)
        closing.insert(id)
        task?.cancel(); sockets.removeValue(forKey: id)?.cancel()
        await task?.value
        if transfers.contains(where: { $0.id == id }) { await save(snapshot) }
        closing.remove(id)
        publish(); await pump()
    }
    func pump() async {
        guard connected else { return }
        let active = transfers.filter { !$0.upload && [.negotiating, .transferring].contains($0.status) && !remoteQueued.contains($0.id) }.count
        let queued = transfers.filter { !$0.upload && $0.status == .queued }.prefix(max(0, downloadSlots - active))
        for transfer in queued {
            guard let index = transfers.firstIndex(where: { $0.id == transfer.id }), transfers[index].status == .queued else { continue }
            transfers[index].status = .negotiating
            startNegotiationDeadline(transfer.id, token: nil)
            await save(transfers[index])
            do {
                var writer = WireWriter(); writer.string(transfer.file.path)
                try await session.peerSend(user: transfer.user, code: 43, payload: writer.data)
                try await session.peerSend(user: transfer.user, code: 51, payload: writer.data)
            } catch { await fail(transfer.id, error: error) }
        }
        publish()
    }
    func publish() { continuation.yield(transfers) }
    func save(_ transfer: Transfer) async {
        do { try await database.put(transfer, collection: "transfers", id: transfer.id) }
        catch { if let index = transfers.firstIndex(where: { $0.id == transfer.id }) { transfers[index].error = "Could not save transfer state: \(error.localizedDescription)" } }
    }
    func fail(_ id: String, error: Error, attempt: UUID? = nil) async {
        if let attempt, attempts[id] != attempt { return }
        guard let index = transfers.firstIndex(where: { $0.id == id }), ![.paused, .cancelled, .completed].contains(transfers[index].status) else { return }
        transfers[index].status = .failed; transfers[index].error = error.localizedDescription; transfers[index].speed = 0
        transfers[index].token = nil
        attempts.removeValue(forKey: id); remoteQueued.remove(id); negotiationTasks.removeValue(forKey: id)?.cancel()
        sockets.removeValue(forKey: id)?.cancel(); tasks.removeValue(forKey: id)?.cancel()
        let retry = connected && !transfers[index].upload && transfers[index].retries < 3 && !(error is FileSafetyError)
        var delay = 0
        if retry {
            transfers[index].retries += 1
            delay = 10 * (1 << transfers[index].retries)
        }
        let snapshot = transfers[index]
        await save(snapshot); publish()
        if retry {
            retryTasks[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
                guard let self else { return }; await self.retryIfFailed(id)
            }
        }
    }
    func startNegotiationDeadline(_ id: String, token: UInt32?) {
        negotiationTasks.removeValue(forKey: id)?.cancel()
        negotiationTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)); try Task.checkCancellation() } catch { return }
            await self?.expireNegotiation(id, token: token)
        }
    }
    func expireNegotiation(_ id: String, token: UInt32?) async {
        guard let item = transfers.first(where: { $0.id == id }), item.status == .negotiating, item.token == token, !remoteQueued.contains(id) else { return }
        await fail(id, error: ProtocolError.invalid("This user didn’t respond to the transfer request. Retry when they are available."))
        await pump(); await pumpUploads()
    }
    func retryIfFailed(_ id: String) async {
        guard let item = transfers.first(where: { $0.id == id }), item.status == .failed else { return }
        await resume(id)
    }
    public func peerUnavailable(_ user: String) async {
        for item in transfers where item.user == user && item.status == .negotiating {
            await fail(item.id, error: ProtocolError.invalid("Couldn’t connect to this user. They may be offline or unable to accept incoming connections."))
        }
        await pump()
    }
}
