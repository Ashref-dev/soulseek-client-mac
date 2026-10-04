import Foundation
import Testing
@testable import SoulseekCore

extension SoulseekSession {
    func seedPendingLease(_ lease: SendLease, user: String) {
        pending[user] = [PendingPeerMessage(code: 43, payload: Data([1]), lease: lease), PendingPeerMessage(code: 51, payload: Data([2]), lease: lease), PendingPeerMessage(code: 4, payload: Data(), lease: nil)]
    }
}

@Test func invalidatedNegotiationCannotFlushQueuedPeerFrames() async {
    let session = SoulseekSession(); let lease = SendLease()
    await session.seedPendingLease(lease, user: "peer")
    lease.invalidate()
    #expect(await session.takePendingPeerMessages("peer").map(\.code) == [4])
    #expect(await session.pending.isEmpty)
    await session.shutdown()
}

@Test func invalidatedSendLeaseRejectsAtActualSocketWriteBoundary() async throws {
    let lease = SendLease(); lease.invalidate()
    let socket = try TCPConnection(host: "127.0.0.1", port: 1)
    await #expect(throws: CancellationError.self) { try await socket.send(Data([1]), lease: lease) }
    socket.cancel()
}
