import Foundation

public enum TransferQueueWait: String, Codable, Sendable {
    case offline, directionPaused, localSlots, remoteQueue, peerBackoff, accountingRecovery, stopping
}

public struct TransferRetrySchedule: Codable, Sendable, Equatable {
    public let identity: UUID
    public let deadline: Date
    public init(identity: UUID, deadline: Date) { self.identity = identity; self.deadline = deadline }
}

public struct TransferRuntimeState: Codable, Sendable, Equatable {
    public let holdsLocalSlot: Bool
    public let localSlotsInUse: Int
    public let localSlots: Int
    public let connected: Bool
    public let directionSuspended: Bool
    public let queueWait: TransferQueueWait?
    public let peerBlockedUntil: Date?
    public let pendingRetry: TransferRetrySchedule?
    public init(holdsLocalSlot: Bool, localSlotsInUse: Int, localSlots: Int, connected: Bool,
                directionSuspended: Bool, queueWait: TransferQueueWait?, peerBlockedUntil: Date?,
                pendingRetry: TransferRetrySchedule?) {
        self.holdsLocalSlot = holdsLocalSlot; self.localSlotsInUse = localSlotsInUse; self.localSlots = localSlots
        self.connected = connected; self.directionSuspended = directionSuspended; self.queueWait = queueWait
        self.peerBlockedUntil = peerBlockedUntil; self.pendingRetry = pendingRetry
    }
}

struct TransferRetryWork: Sendable {
    let schedule: TransferRetrySchedule
    let task: Task<Void, Never>
}

extension TransferEngine {
    func holdsLocalSlot(_ item: Transfer) -> Bool {
        !item.isPreview && [.negotiating, .transferring].contains(item.status) && (item.upload || !remoteQueued.contains(item.id))
    }

    func runtimeSnapshot() -> [Transfer] {
        let downloads = transfers.filter { !$0.upload && holdsLocalSlot($0) }.count
        let uploads = transfers.filter { $0.upload && holdsLocalSlot($0) }.count
        let now = Date()
        return transfers.map { original in
            var item = original
            let suspended = item.upload ? uploadsSuspended : downloadsSuspended
            let slots = item.upload ? uploadSlots : downloadSlots
            let inUse = item.upload ? uploads : downloads
            let blocked = item.upload && item.status == .queued ? uploadBlockedUntil[item.user].flatMap { $0 > now ? $0 : nil } : nil
            var wait: TransferQueueWait?
            if accountingBlocked { wait = .accountingRecovery }
            else if closing.contains(item.id) { wait = .stopping }
            else if [.queued, .negotiating].contains(item.status) {
                if suspended { wait = .directionPaused }
                else if !connected { wait = .offline }
                else if !item.upload && remoteQueued.contains(item.id) { wait = .remoteQueue }
                else if blocked != nil { wait = .peerBackoff }
                else if item.status == .queued && !item.isPreview && inUse >= slots { wait = .localSlots }
            }
            let retry = retryTasks[item.id].flatMap { !$0.task.isCancelled && item.status == .failed ? $0.schedule : nil }
            item.runtimeState = TransferRuntimeState(holdsLocalSlot: holdsLocalSlot(item), localSlotsInUse: inUse,
                localSlots: slots, connected: connected, directionSuspended: suspended, queueWait: wait,
                peerBlockedUntil: blocked, pendingRetry: retry)
            return item
        }
    }

    func cancelRetry(_ id: String) {
        retryTasks.removeValue(forKey: id)?.task.cancel()
        failureRevisions.removeValue(forKey: id)
    }

    func scheduleRetry(_ id: String, delay: Int) {
        retryTasks.removeValue(forKey: id)?.task.cancel()
        let schedule = TransferRetrySchedule(identity: UUID(), deadline: Date().addingTimeInterval(Double(delay)))
        let sleep = retrySleep
        let task = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation() }
            catch { await self?.retireRetry(id, identity: schedule.identity); return }
            guard let self else { return }
            await self.retryIfFailed(id, identity: schedule.identity)
        }
        retryTasks[id] = TransferRetryWork(schedule: schedule, task: task)
    }

    func retireRetry(_ id: String, identity: UUID) {
        guard retryTasks[id]?.schedule.identity == identity else { return }
        retryTasks.removeValue(forKey: id); publish()
    }

    func scheduleUploadBackoff(_ user: String) {
        clearUploadBackoff(user)
        let schedule = TransferRetrySchedule(identity: UUID(), deadline: Date().addingTimeInterval(60))
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)); try Task.checkCancellation() } catch { return }
            await self?.finishUploadBackoff(user, identity: schedule.identity)
        }
        uploadBlockedUntil[user] = schedule.deadline
        uploadBackoffTasks[user] = TransferRetryWork(schedule: schedule, task: task)
    }

    func clearUploadBackoff(_ user: String) {
        uploadBackoffTasks.removeValue(forKey: user)?.task.cancel()
        uploadBlockedUntil.removeValue(forKey: user)
    }

    private func finishUploadBackoff(_ user: String, identity: UUID) async {
        guard uploadBackoffTasks[user]?.schedule.identity == identity else { return }
        uploadBackoffTasks.removeValue(forKey: user); uploadBlockedUntil.removeValue(forKey: user)
        await pumpUploads()
    }
}
