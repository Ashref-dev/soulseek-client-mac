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
    var layout = DownloadLayout()
    var uploadQueueLimit = 200
    var previewRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ArpeggioPreviews", isDirectory: true)
    var previewDeadlines: [String: Task<Void, Never>] = [:]
    var previewTerminalOwners: [String: UUID] = [:]
    var previewCleanupJobs: [String: PreviewCleanupRequest] = [:]
    var closingWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var downloadSlots = 3
    var uploadSlots = 2
    var downloadLimit: Double = 0
    var uploadLimit: Double = 0
    var connected = false
    var downloadsSuspended = false
    var uploadsSuspended = false
    var remoteQueued: Set<String> = []
    var retryTasks: [String: TransferRetryWork] = [:]
    var failureRevisions: [String: UUID] = [:]
    var retrySleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var uploadBlockedUntil: [String: Date] = [:]
    var uploadBackoffTasks: [String: TransferRetryWork] = [:]
    var attempts: [String: UUID] = [:]
    var attemptBase: [String: (moved: UInt64, offset: UInt64)] = [:]
    var closing: Set<String> = []
    var partialConflicts: Set<String> = []
    var progressPublication: Task<Void, Never>?
    var checkpointTask: Task<Void, Never>?
    var dirtyCheckpoints: Set<String> = []
    var removalJobs: [String: (UUID, Task<Void, Error>)] = [:]
    public private(set) var publicationCount = 0
    public internal(set) var accountingReady = false
    var accountingBaseline: [Transfer]?
    var accountingBlocked: Bool { accountingBaseline != nil && !accountingReady }
    var negotiationTasks: [String: Task<Void, Never>] = [:]
    var negotiations: [String: UUID] = [:]
    var negotiationLeases: [String: SendLease] = [:]
    var downloadNegotiationRevision: UInt64 = 0
    var uploadNegotiationRevision: UInt64 = 0
    var beforePersistence: (@Sendable (String) async -> Void)?
    var sendPeer: @Sendable (String, UInt32, Data, SendLease) async throws -> Void
    var nextNegotiationToken: @Sendable () async -> UInt32
    var uploadAuthorizer: (@Sendable (String, SharedFile, URL) async -> Bool)?
    public init(session: SoulseekSession, database: Database, root: URL) {
        self.session = session; self.database = database; downloadRoot = root
        sendPeer = { user, code, payload, lease in try await session.peerSend(user: user, code: code, payload: payload, lease: lease) }
        nextNegotiationToken = { await session.nextToken() }
        let pair = AsyncStream<[Transfer]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream; continuation = pair.continuation
    }
    public func restore() async throws {
        for id in Array(retryTasks.keys) { cancelRetry(id) }
        failureRevisions.removeAll()
        accountingReady = false; accountingBaseline = []
        transfers = try await database.transferRecords(Transfer.self)
        var seen = Set<String>()
        transfers.removeAll { !seen.insert($0.id).inserted }
        accountingBaseline = transfers
        do { try await initializeAccounting() }
        catch {
            for index in transfers.indices { transfers[index].error = "Accounting unavailable: \(error.localizedDescription)" }
            publish(); return
        }
        for item in transfers where item.isPreview { removePreviewFiles(item); try? await database.remove(collection: "transfers", id: item.id) }
        transfers.removeAll(where: \.isPreview)
        for index in transfers.indices where !transfers[index].upload && transfers[index].status != .completed {
            guard let path = transfers[index].partial,
                  let moved = SafeDestination.migrateLegacyPartial(URL(fileURLWithPath: path), user: transfers[index].user, remotePath: transfers[index].file.path) else { continue }
            transfers[index].partial = moved.path
            scheduleCheckpoint(transfers[index].id)
        }
        for index in transfers.indices where [.transferring, .negotiating, .queued].contains(transfers[index].status) {
            transfers[index].status = transfers[index].upload ? .failed : .queued
            transfers[index].speed = 0; transfers[index].token = nil
        }
        var owners: [String: String] = [:]
        for index in transfers.indices where !transfers[index].upload && transfers[index].status != .completed {
            guard let path = transfers[index].partial else { continue }
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            if owners[key] != nil {
                partialConflicts.insert(transfers[index].id); transfers[index].status = .failed
                transfers[index].error = "Another transfer owns this partial file. Remove this duplicate row before retrying."
            } else { owners[key] = transfers[index].id }
        }
        publish()
    }
    public func retryAccountingInitialization() async throws {
        guard accountingBlocked else { return }
        try await restore()
        try requireAccountingInitialization()
    }
    public func configure(root: URL, downloads: Int, uploads: Int, downloadLimitKB: Int = 0, uploadLimitKB: Int = 0,
                          layout: DownloadLayout = DownloadLayout(), uploadQueueLimit: Int = 200) {
        downloadRoot = root; downloadSlots = max(1, min(20, downloads)); uploadSlots = max(1, min(20, uploads))
        self.layout = layout; self.uploadQueueLimit = max(0, uploadQueueLimit)
        downloadLimit = Double(max(0, min(1_000_000, downloadLimitKB))) * 1024
        uploadLimit = Double(max(0, min(1_000_000, uploadLimitKB))) * 1024
    }
    public func setConnected(_ value: Bool) async {
        guard !accountingBlocked else { connected = false; return }
        connected = value
        if !value {
            downloadNegotiationRevision &+= 1; uploadNegotiationRevision &+= 1
            for id in Array(negotiations.keys) { invalidateNegotiation(id) }
            let ownedTasks = Array(tasks.values)
            let joining = Set(tasks.keys)
            closing.formUnion(joining)
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
            for id in Array(retryTasks.keys) { cancelRetry(id) }
            failureRevisions.removeAll()
            for user in Array(uploadBlockedUntil.keys) { clearUploadBackoff(user) }
            for socket in sockets.values { socket.cancel() }
            for task in tasks.values { task.cancel() }
            sockets.removeAll(); tasks.removeAll()
            for task in ownedTasks { await task.value }
            for checkpoint in checkpoints { await save(checkpoint) }
            for id in joining { finishClosing(id) }
        }
        publish(); await pump()
    }
    public func shutdown() async {
        checkpointTask?.cancel(); checkpointTask = nil
        await flushCheckpoints()
        progressPublication?.cancel(); progressPublication = nil
        for task in previewDeadlines.values { task.cancel() }; previewDeadlines.removeAll()
        await setConnected(false)
        await joinDeferredPreviewCleanup()
        continuation.finish()
    }
    public func setUploadAuthorizer(_ authorizer: @escaping @Sendable (String, SharedFile, URL) async -> Bool) { uploadAuthorizer = authorizer }
    public func revalidateUploads() async {
        let active = transfers.filter { $0.upload && [.queued, .negotiating, .transferring].contains($0.status) }
        for item in active {
            guard let source = uploadSources[item.id], let uploadAuthorizer else { await cancel(item.id); continue }
            if !(await uploadAuthorizer(item.user, item.file, source)) { await cancel(item.id) }
        }
    }
    public func enqueue(_ results: [SearchResult]) async throws {
        try requireAccountingInitialization()
        var known = Dictionary(transfers.filter { !$0.upload && $0.status != .completed }.map { ("\($0.user)\u{0}\($0.file.path)", $0.id) }, uniquingKeysWith: { first, _ in first })
        var existingIDs = Set(transfers.map(\.id))
        var existingIndices = Dictionary(uniqueKeysWithValues: transfers.enumerated().map { ($0.element.id, $0.offset) })
        var partialPaths = Set(transfers.filter { $0.status != .completed || tasks[$0.id] != nil || closing.contains($0.id) }.compactMap(\.partial))
        var previews = Dictionary(transfers.filter { $0.isPreview && $0.status != .cancelled }.map { ("\($0.user)\u{0}\($0.file.path)", $0.id) }, uniquingKeysWith: { first, _ in first })
        known.merge(previews) { first, _ in first }
        var pending: [Transfer] = []
        for result in results {
            guard result.file.size <= 16 * 1024 * 1024 * 1024 else { throw ProtocolError.oversized }
            if let preview = previews["\(result.user)\u{0}\(result.file.path)"] {
                try await keep(preview)
                try requireAccountingInitialization()
                let currentKnown = Dictionary(transfers.filter { !$0.upload && $0.status != .completed }.map { ("\($0.user)\u{0}\($0.file.path)", $0.id) }, uniquingKeysWith: { first, _ in first })
                pending.removeAll { item in
                    !existingIDs.contains(item.id) && (currentKnown["\(item.user)\u{0}\(item.file.path)"] != nil || item.partial.map { partialOwner($0) != nil } == true)
                }
                known.merge(currentKnown) { _, current in current }
                existingIDs.formUnion(transfers.map(\.id))
                existingIndices = Dictionary(uniqueKeysWithValues: transfers.enumerated().map { ($0.element.id, $0.offset) })
                partialPaths = Set(transfers.filter { $0.status != .completed || tasks[$0.id] != nil || closing.contains($0.id) }.compactMap(\.partial))
                partialPaths.formUnion(pending.compactMap(\.partial))
                previews = Dictionary(transfers.filter { $0.isPreview && $0.status != .cancelled }.map { ("\($0.user)\u{0}\($0.file.path)", $0.id) }, uniquingKeysWith: { first, _ in first })
                continue
            }
            let key = "\(result.user)\u{0}\(result.file.path)"
            if let id = known[key] {
                if let index = existingIndices[id], transfers[index].status == .cancelled, !closing.contains(id), !partialConflicts.contains(id),
                   transfers[index].partial.map({ partialOwner($0, excluding: id) == nil }) ?? true {
                    transfers[index].status = .queued; transfers[index].error = nil; pending.append(transfers[index])
                }
                continue
            }
            let (destination, partial) = try SafeDestination.plan(root: downloadRoot, user: result.user, remotePath: result.file.path, layout: layout)
            var transfer = Transfer(user: result.user, file: result.file)
            transfer.destination = destination.path; transfer.partial = partial.path
            guard partialPaths.insert(partial.path).inserted else { continue }
            pending.append(transfer); known[key] = transfer.id
        }
        pending = pending.compactMap { item in
            guard existingIDs.contains(item.id) else { return item }
            return existingIndices[item.id].map { transfers[$0] }
        }
        let inserts = pending.filter { !existingIDs.contains($0.id) }
        transfers.append(contentsOf: inserts)
        do { try await checkpoint(pending) }
        catch { let ids = Set(inserts.map(\.id)); transfers.removeAll { ids.contains($0.id) }; throw error }
        publish(); await pump()
    }
    public func pause(_ id: String) async { await change(id, to: .paused) }
    public func cancel(_ id: String) async { await change(id, to: .cancelled) }
    public func resume(_ id: String) async {
        guard !accountingBlocked, !closing.contains(id), let index = transfers.firstIndex(where: { $0.id == id }), !transfers[index].upload, [.paused, .failed, .cancelled].contains(transfers[index].status) else { return }
        if let path = transfers[index].partial, partialOwner(path, excluding: id) != nil {
            transfers[index].status = .failed; transfers[index].error = "Another transfer owns this partial file."; partialConflicts.insert(id); publish(); return
        }
        partialConflicts.remove(id)
        cancelRetry(id)
        transfers[index].status = .queued; transfers[index].error = nil; transfers[index].token = nil
        remoteQueued.remove(id)
        await save(transfers[index]); publish(); await pump()
    }
    public func clearFinished(upload: Bool) async {
        let removed = transfers.filter { $0.upload == upload && !$0.isPreview && [.completed, .cancelled].contains($0.status) && !closing.contains($0.id) }
        try? await removeTransfers(Set(removed.map(\.id)))
    }
    public func clearFailed(upload: Bool) async {
        let removed = transfers.filter { $0.upload == upload && !$0.isPreview && $0.status == .failed && !closing.contains($0.id) }
        try? await removeTransfers(Set(removed.map(\.id)))
    }
    func change(_ id: String, to status: TransferStatus) async {
        guard !accountingBlocked, !closing.contains(id), let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].status != .completed else { return }
        transfers[index].status = status; transfers[index].speed = 0
        transfers[index].token = nil; attempts.removeValue(forKey: id)
        invalidateNegotiation(id)
        remoteQueued.remove(id); cancelRetry(id)
        negotiationTasks.removeValue(forKey: id)?.cancel()
        let task = tasks.removeValue(forKey: id)
        closing.insert(id)
        task?.cancel(); sockets.removeValue(forKey: id)?.cancel()
        await task?.value
        if let current = transfers.first(where: { $0.id == id }) { await save(current) }
        finishClosing(id)
        publish(); await pump()
    }
    func pump() async {
        guard !accountingBlocked, connected, !downloadsSuspended else { return }
        let revision = downloadNegotiationRevision
        let active = transfers.filter { !$0.upload && holdsLocalSlot($0) }.count
        let previews = transfers.filter { !$0.upload && $0.isPreview && $0.status == .queued }
        let queued = previews + transfers.filter { !$0.upload && !$0.isPreview && $0.status == .queued }.prefix(max(0, downloadSlots - active))
        for transfer in queued {
            guard revision == downloadNegotiationRevision, connected, !downloadsSuspended, let index = transfers.firstIndex(where: { $0.id == transfer.id }), transfers[index].status == .queued, !closing.contains(transfer.id) else { continue }
            transfers[index].status = .negotiating
            let identity = beginNegotiation(transfer.id)
            startNegotiationDeadline(transfer.id, token: nil)
            await save(transfers[index], negotiation: identity)
            guard negotiationIsCurrent(transfer.id, identity: identity) else { continue }
            do {
                var writer = WireWriter(); writer.string(transfer.file.path)
                try await sendNegotiation(transfer.id, identity: identity, user: transfer.user, code: 43, payload: writer.data)
                guard negotiationIsCurrent(transfer.id, identity: identity) else { continue }
                try await sendNegotiation(transfer.id, identity: identity, user: transfer.user, code: 51, payload: writer.data)
            } catch { await fail(transfer.id, error: error, negotiation: identity) }
        }
        publish()
    }
    func publish() { progressPublication?.cancel(); progressPublication = nil; publicationCount += 1; continuation.yield(runtimeSnapshot()) }
    func publishProgress() {
        guard progressPublication == nil else { return }
        progressPublication = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() } catch { return }
            await self?.publish()
        }
    }
    func save(_ transfer: Transfer, negotiation: UUID? = nil) async {
        if let beforePersistence { await beforePersistence(transfer.id) }
        if let negotiation, !negotiationIsCurrent(transfer.id, identity: negotiation) { return }
        guard let current = transfers.first(where: { $0.id == transfer.id }) else { return }
        dirtyCheckpoints.remove(current.id)
        do { try await checkpoint([current]) }
        catch {
            dirtyCheckpoints.insert(current.id)
            if let negotiation, !negotiationIsCurrent(transfer.id, identity: negotiation) { return }
            if let index = transfers.firstIndex(where: { $0.id == transfer.id }) { transfers[index].error = "Could not save transfer state: \(error.localizedDescription)" }
        }
    }
    func fail(_ id: String, error: Error, attempt: UUID? = nil, negotiation: UUID? = nil) async {
        await finalizeFailure(id, error: error, attempt: attempt, negotiation: negotiation, joiningWorker: true)
    }
    func failFromWorker(_ id: String, error: Error, attempt: UUID) async {
        await finalizeFailure(id, error: error, attempt: attempt, joiningWorker: false)
    }
    private func finalizeFailure(_ id: String, error: Error, attempt: UUID? = nil, negotiation: UUID? = nil, joiningWorker: Bool) async {
        if let attempt, attempts[id] != attempt { return }
        if let negotiation, !negotiationIsCurrent(id, identity: negotiation) { return }
        guard !accountingBlocked, !closing.contains(id), let index = transfers.firstIndex(where: { $0.id == id }), ![.paused, .cancelled, .completed].contains(transfers[index].status) else { return }
        var ownsClosing = tasks[id] != nil
        if ownsClosing { closing.insert(id) }
        defer {
            if ownsClosing {
                if !joiningWorker, let attempt { workerFinished(id, attempt: attempt) }
                finishClosing(id)
            }
        }
        cancelRetry(id)
        let failure = UUID(); failureRevisions[id] = failure
        transfers[index].status = .failed; transfers[index].error = error.localizedDescription; transfers[index].speed = 0
        transfers[index].token = nil
        invalidateNegotiation(id)
        attempts.removeValue(forKey: id); remoteQueued.remove(id); negotiationTasks.removeValue(forKey: id)?.cancel()
        sockets.removeValue(forKey: id)?.cancel(); tasks[id]?.cancel()
        if joiningWorker, let task = tasks[id] {
            await task.value; tasks.removeValue(forKey: id)
        }
        guard let currentIndex = transfers.firstIndex(where: { $0.id == id }) else { return }
        let retry = connected && !transfers[currentIndex].upload && transfers[currentIndex].retries < 3 && !(error is FileSafetyError)
        var delay = 0
        if retry {
            transfers[currentIndex].retries += 1
            delay = 10 * (1 << transfers[currentIndex].retries)
        }
        let snapshot = transfers[currentIndex]
        await save(snapshot)
        if ownsClosing {
            if !joiningWorker, let attempt { workerFinished(id, attempt: attempt) }
            finishClosing(id); ownsClosing = false
        }
        if retry, connected, !downloadsSuspended, failureRevisions[id] == failure,
           transfers.contains(where: { $0.id == id && $0.status == .failed && $0.retries == snapshot.retries }) { scheduleRetry(id, delay: delay) }
        publish()
    }
    func startNegotiationDeadline(_ id: String, token: UInt32?) {
        let identity = negotiations[id]
        negotiationTasks.removeValue(forKey: id)?.cancel()
        negotiationTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)); try Task.checkCancellation() } catch { return }
            await self?.expireNegotiation(id, token: token, identity: identity)
        }
    }
    func expireNegotiation(_ id: String, token: UInt32?, identity: UUID? = nil) async {
        if let identity, !negotiationIsCurrent(id, identity: identity) { return }
        guard let item = transfers.first(where: { $0.id == id }), item.status == .negotiating, item.token == token, !remoteQueued.contains(id) else { return }
        await fail(id, error: ProtocolError.invalid("This user didn’t respond to the transfer request. Retry when they are available."), negotiation: identity)
        await pump(); await pumpUploads()
    }
    func retryIfFailed(_ id: String, identity: UUID) async {
        guard retryTasks[id]?.schedule.identity == identity else { return }
        retryTasks.removeValue(forKey: id); failureRevisions.removeValue(forKey: id)
        guard let item = transfers.first(where: { $0.id == id }), item.status == .failed else { publish(); return }
        await resume(id)
    }
    public func peerUnavailable(_ user: String) async {
        for item in transfers where item.user == user && item.status == .negotiating {
            await fail(item.id, error: ProtocolError.invalid("Couldn’t connect to this user. They may be offline or unable to accept incoming connections."))
        }
        await pump()
    }
}
