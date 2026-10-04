import Foundation
import SoulseekCore

extension TransferEngine {
    func beginNegotiation(_ id: String) -> UUID {
        invalidateNegotiation(id)
        let identity = UUID(); negotiations[id] = identity; negotiationLeases[id] = SendLease()
        return identity
    }
    func invalidateNegotiation(_ id: String) {
        negotiationLeases.removeValue(forKey: id)?.invalidate()
        negotiations.removeValue(forKey: id)
    }
    func sendNegotiation(_ id: String, identity: UUID, user: String, code: UInt32, payload: Data) async throws {
        guard negotiationIsCurrent(id, identity: identity), let lease = negotiationLeases[id] else { throw CancellationError() }
        try await sendPeer(user, code, payload, lease)
    }
    func negotiationIsCurrent(_ id: String, identity: UUID) -> Bool {
        guard negotiations[id] == identity, connected, !closing.contains(id),
              let transfer = transfers.first(where: { $0.id == id }), transfer.status == .negotiating else { return false }
        return transfer.upload ? !uploadsSuspended : !downloadsSuspended
    }
}
