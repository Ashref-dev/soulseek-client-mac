import Foundation
import SoulseekCore

extension TransferEngine {
    public func removeTransfers(_ ids: Set<String>) async throws {
        try requireAccountingInitialization()
        var awaited = Set<UUID>()
        for id in ids {
            if let (identity, job) = removalJobs[id], awaited.insert(identity).inserted { try await job.value }
        }
        let remaining = ids.intersection(Set(transfers.map(\.id)))
        guard !remaining.isEmpty else { return }
        let identity = UUID()
        let job = Task { try await self.performRemoval(remaining) }
        for id in remaining { removalJobs[id] = (identity, job) }
        defer { for id in remaining where removalJobs[id]?.0 == identity { removalJobs.removeValue(forKey: id) } }
        try await job.value
    }

    private func performRemoval(_ ids: Set<String>) async throws {
        try requireAccountingInitialization()
        let selected = transfers.filter { ids.contains($0.id) }
        for item in selected where closing.contains(item.id) { throw ProtocolError.invalid("Transfer is still stopping. Retry removal.") }
        for item in selected { closing.insert(item.id) }
        defer { for item in selected { finishClosing(item.id) } }
        for item in selected {
            invalidateNegotiation(item.id); attempts.removeValue(forKey: item.id)
            cancelRetry(item.id); negotiationTasks.removeValue(forKey: item.id)?.cancel()
            sockets.removeValue(forKey: item.id)?.cancel()
            tasks[item.id]?.cancel()
            if let index = transfers.firstIndex(where: { $0.id == item.id }), !transfers[index].status.isTerminal {
                transfers[index].status = .cancelled; transfers[index].speed = 0; transfers[index].token = nil
            }
        }
        for item in selected { await tasks[item.id]?.value; tasks.removeValue(forKey: item.id) }
        let current = transfers.filter { ids.contains($0.id) }
        do { try await checkpoint(current, removing: ids) }
        catch {
            for index in transfers.indices where ids.contains(transfers[index].id) { transfers[index].error = "Removal was not saved. Retry: \(error.localizedDescription)" }
            publish(); throw error
        }
        for item in current {
            if item.isPreview { removePreviewFiles(item) }
            previewDeadlines.removeValue(forKey: item.id)?.cancel()
            uploadSources.removeValue(forKey: item.id); attemptBase.removeValue(forKey: item.id)
            remoteQueued.remove(item.id)
        }
        transfers.removeAll { ids.contains($0.id) }
        publish()
    }

    func partialOwner(_ path: String, excluding id: String? = nil) -> Transfer? {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        return transfers.first { item in
            item.id != id && !item.upload && item.partial.map { URL(fileURLWithPath: $0).standardizedFileURL.path == key } == true &&
            (item.status != .completed || tasks[item.id] != nil || closing.contains(item.id)) && !partialConflicts.contains(item.id)
        }
    }

    func workerFinished(_ id: String, attempt: UUID) {
        if attempts[id] == nil || attempts[id] == attempt { tasks.removeValue(forKey: id) }
    }
}
