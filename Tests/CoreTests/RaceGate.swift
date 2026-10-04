import Foundation
import SoulseekCore

actor RaceGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

func raceWait(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("Race gate timed out") }
        await Task.yield()
    }
}
