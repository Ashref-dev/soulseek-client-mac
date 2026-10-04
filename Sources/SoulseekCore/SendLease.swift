import Foundation

public final class SendLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public var isValid: Bool { lock.withLock { valid } }
    public func invalidate() { lock.withLock { valid = false } }
    func perform(_ send: () -> Void) throws {
        try lock.withLock {
            guard valid else { throw CancellationError() }
            send()
        }
    }
}

struct PendingPeerMessage: Sendable {
    let code: UInt32
    let payload: Data
    let lease: SendLease?
}
