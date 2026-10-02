import Foundation

public struct SessionEvent: Sendable {
    public let generation: UInt64
    public let account: String
    public let event: SoulseekEvent
}

actor EventChannel {
    private var queued: [SessionEvent] = []
    private var receiver: CheckedContinuation<SessionEvent?, Never>?
    private var senders: [(UUID, SessionEvent, CheckedContinuation<Void, Never>)] = []
    private var closed = false
    func send(_ event: SessionEvent) async {
        guard !closed else { closeFile(event); return }
        if let receiver { self.receiver = nil; receiver.resume(returning: event); return }
        if queued.count < 32 { queued.append(event); return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { closeFile(event); continuation.resume() }
                else { senders.append((id, event, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func next() async -> SessionEvent? {
        if !queued.isEmpty {
            let event = queued.removeFirst()
            if !senders.isEmpty {
                let sender = senders.removeFirst(); queued.append(sender.1); sender.2.resume()
            }
            return event
        }
        guard !closed else { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }
    func close() {
        closed = true
        for event in queued { closeFile(event) }
        queued.removeAll()
        for sender in senders { closeFile(sender.1); sender.2.resume() }
        senders.removeAll(); receiver?.resume(returning: nil); receiver = nil
    }
    private func cancel(_ id: UUID) {
        guard let index = senders.firstIndex(where: { $0.0 == id }) else { return }
        let sender = senders.remove(at: index); closeFile(sender.1); sender.2.resume()
    }
    private func closeFile(_ event: SessionEvent) {
        if case .fileConnection(_, let connection) = event.event { connection.socket.cancel() }
    }
}
