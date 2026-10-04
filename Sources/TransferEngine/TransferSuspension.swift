import Foundation

extension TransferEngine {
    public func setSuspended(upload: Bool, _ suspended: Bool) async {
        if upload { uploadsSuspended = suspended } else { downloadsSuspended = suspended }
        if upload, !suspended { uploadBlockedUntil.removeAll() }
        if suspended {
            if upload { uploadNegotiationRevision &+= 1 } else { downloadNegotiationRevision &+= 1 }
            let ids = transfers.filter { $0.upload == upload && [.negotiating, .transferring].contains($0.status) }.map(\.id)
            var joins: [(String, Task<Void, Never>?)] = []
            for id in ids {
                guard let index = transfers.firstIndex(where: { $0.id == id }) else { continue }
                transfers[index].status = .queued; transfers[index].speed = 0; transfers[index].token = nil
                attempts.removeValue(forKey: id); remoteQueued.remove(id)
                invalidateNegotiation(id)
                negotiationTasks.removeValue(forKey: id)?.cancel(); retryTasks.removeValue(forKey: id)?.cancel()
                closing.insert(id)
                let task = tasks.removeValue(forKey: id)
                task?.cancel(); sockets.removeValue(forKey: id)?.cancel()
                joins.append((id, task))
            }
            for (id, task) in joins {
                await task?.value
                if let current = transfers.first(where: { $0.id == id }) { await save(current) }
                closing.remove(id)
            }
        }
        publish(); await pump(); await pumpUploads()
    }
    public func suspensionState() -> (downloads: Bool, uploads: Bool) { (downloadsSuspended, uploadsSuspended) }
}
