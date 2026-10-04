import Foundation
import Testing
import ProtocolFixtures
@testable import SoulseekCore
@testable import ArpeggioServices

@Test(.timeLimit(.minutes(1)))
func lookupTimeoutCannotReplaceCancellationInsensitiveSendAfterCooldown() async throws {
    let policy = SharingPolicy(); let gate = RaceGate(); let now = Date()
    #expect(await policy.permits(user: "peer", required: true, timeout: .zero, now: now) { await gate.wait() })
    try await raceWait { await gate.arrivals == 1 }
    for offset in [4.0, 100, 1000] {
        #expect(await policy.permits(user: "peer", required: true, timeout: .zero, now: now.addingTimeInterval(offset)) { await gate.wait() })
    }
    #expect(await policy.requestState().count == 1); #expect(await gate.arrivals == 1)
    await policy.reset()
    #expect(await policy.permits(user: "peer", required: true, timeout: .zero) { await gate.wait() })
    #expect(await policy.requestState().count == 1)
    await gate.release()
    try await raceWait { await policy.requestState().count == 0 }
    #expect(await policy.permits(user: "peer", required: true, timeout: .zero) { await gate.wait() })
    try await raceWait { await gate.arrivals == 2 }
    await gate.release(); try await raceWait { await policy.requestState().count == 0 }
}

@Test(.timeLimit(.minutes(1)))
func lookupActualInFlightCapIncludesOldGenerationBlockedSends() async throws {
    let policy = SharingPolicy(maximumInFlight: 2); let gate = RaceGate()
    for user in ["one", "two", "three"] {
        #expect(await policy.permits(user: user, required: true, timeout: .zero) { await gate.wait() })
    }
    try await raceWait { await gate.arrivals == 2 }
    #expect(await policy.requestState().count == 2)
    await policy.reset()
    #expect(await policy.permits(user: "new-generation", required: true, timeout: .zero) { await gate.wait() })
    #expect(await policy.requestState().count == 2); #expect(await gate.arrivals == 2)
    await gate.release(); try await raceWait { await policy.requestState().count == 0 }
    #expect(await policy.permits(user: "new-generation", required: true, timeout: .zero) { await gate.wait() })
    try await raceWait { await gate.arrivals == 3 }
    await gate.release(); try await raceWait { await policy.requestState().count == 0 }
}

@Test(.timeLimit(.minutes(1)))
func freshSharingDecisionDoesNotUnregisterAnUnfinishedSend() async throws {
    let policy = SharingPolicy(); let gate = RaceGate()
    _ = await policy.permits(user: "peer", required: true, timeout: .zero) { await gate.wait() }
    try await raceWait { await gate.arrivals == 1 }
    await policy.observe(user: "peer", files: 0)
    #expect(await policy.permits(user: "peer", required: true) {} == false)
    #expect(await policy.requestState().count == 1)
    await gate.release(); try await raceWait { await policy.requestState().count == 0 }
}

private actor ScopedSendResult {
    var rejected = false
    func reject() { rejected = true }
}

@Test(.timeLimit(.minutes(1)))
func delayedStatsSendCannotWriteIntoReplacementSessionGeneration() async throws {
    let fixture = try await MockSoulseekServer.start(); let port = try await fixture.port()
    let session = SoulseekSession(); let policy = SharingPolicy(); let gate = RaceGate(); let result = ScopedSendResult()
    try await session.connect(host: "127.0.0.1", port: port, user: "old-stats", password: "fixture-only", listeningPort: try unusedPort())
    let generation = await session.currentGeneration()
    _ = await policy.permits(user: "peer", required: true, timeout: .zero) {
        await gate.wait()
        var writer = WireWriter(); writer.string("peer")
        do { try await session.send(code: 36, payload: writer.data, generation: generation) }
        catch { await result.reject() }
    }
    try await raceWait { await gate.arrivals == 1 }
    await policy.reset()
    try await session.connect(host: "127.0.0.1", port: port, user: "new-stats", password: "fixture-only", listeningPort: try unusedPort())
    await gate.release(); try await raceWait { await policy.requestState().count == 0 }
    #expect(await result.rejected)
    #expect(await fixture.trace.contains("new-stats:36") == false)
    await session.shutdown(); await fixture.stop()
}
