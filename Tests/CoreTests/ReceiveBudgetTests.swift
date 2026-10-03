import Foundation
import Testing
@testable import SoulseekCore

@Test func concurrentReceiveReservationsCannotMultiplyAllowance() throws {
    let budget = ReceiveBudget(limit: 100)
    try budget.reserve(70)
    #expect(throws: ProtocolError.self) { try budget.reserve(31) }
    try budget.reserve(30)
    budget.release(70)
    try budget.reserve(70)
    budget.release(100)
    try budget.reserve(100)
}

@Test func largePeerResponsesRequireOutstandingRequestsAtHeaderAdmission() async throws {
    let session = SoulseekSession()
    let connection = FramedConnection(try TCPConnection(host: "127.0.0.1", port: 1))
    await session.installFixturePeer(connection)
    for code: UInt32 in [5, 37, 16] {
        do {
            try await session.admitPeerResponse(code, user: "fixture", connection: connection, generation: 0)
            Issue.record("Unsolicited response was accepted: \(code)")
        } catch is ProtocolError { }
    }
    await session.expectFixtureResponses()
    for code: UInt32 in [5, 37, 16] {
        try await session.admitPeerResponse(code, user: "fixture", connection: connection, generation: 0)
    }
    await session.shutdown()
}

extension SoulseekSession {
    func installFixturePeer(_ connection: FramedConnection) { peers["fixture"] = connection }
    func expectFixtureResponses() {
        expectedLibraries.insert("fixture"); expectedUserInfo.insert("fixture")
        expectedFolders["fixture"] = [1]
    }
}
