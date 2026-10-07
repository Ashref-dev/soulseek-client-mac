import Foundation

struct PreviewCleanupRequest {
    let identity: UUID
    let discard: Bool
    let task: Task<Void, Never>
    var running = false
}

extension TransferEngine {
    func finishClosing(_ id: String) {
        closing.remove(id)
        if let waiters = closingWaiters.removeValue(forKey: id) {
            for waiter in waiters.values { waiter.resume() }
        }
    }

    func cancelDeferredPreviewCleanup(_ id: String) {
        guard let request = previewCleanupJobs.removeValue(forKey: id) else { return }
        request.task.cancel()
        closingWaiters[id]?.removeValue(forKey: request.identity)?.resume()
        if closingWaiters[id]?.isEmpty == true { closingWaiters.removeValue(forKey: id) }
    }

    func deferPreviewCleanup(_ id: String, discard: Bool) {
        let previous = previewCleanupJobs[id]
        if let previous, !previous.running, previous.discard || !discard { return }
        cancelDeferredPreviewCleanup(id)
        let identity = UUID(), shouldDiscard = discard || previous?.discard == true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDeferredPreviewCleanup(id, identity: identity)
        }
        previewCleanupJobs[id] = PreviewCleanupRequest(identity: identity, discard: shouldDiscard, task: task)
    }

    private func runDeferredPreviewCleanup(_ id: String, identity: UUID) async {
        if closing.contains(id), !Task.isCancelled {
            await withCheckedContinuation { closingWaiters[id, default: [:]][identity] = $0 }
        }
        guard !Task.isCancelled, previewCleanupJobs[id]?.identity == identity else { return }
        previewCleanupJobs[id]?.running = true
        defer { if previewCleanupJobs[id]?.identity == identity { previewCleanupJobs.removeValue(forKey: id) } }
        if previewCleanupJobs[id]?.discard == true { await discardPreview(id, deferredIdentity: identity) }
        else { await expirePreview(id, deferredIdentity: identity) }
    }

    func joinDeferredPreviewCleanup() async {
        while !previewCleanupJobs.isEmpty {
            let jobs = previewCleanupJobs.values.map(\.task)
            for job in jobs { await job.value }
        }
    }
}
