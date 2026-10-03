import Foundation

/// Shared across peer sockets so declared frame sizes cannot multiply the receive allowance.
final class ReceiveBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var used = 0
    let limit: Int

    init(limit: Int = 256 * 1024 * 1024) { self.limit = limit }

    func reserve(_ bytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= limit - used else { throw ProtocolError.oversized }
        used += bytes
    }

    func release(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        used -= bytes
    }
}
