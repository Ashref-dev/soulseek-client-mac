import Foundation

actor StartupTestSignal {
    struct Timeout: Error {}
    private(set) var isSet = false
    private(set) var waiterCount = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func signal() {
        isSet = true
        let pending = waiters.values
        waiters.removeAll()
        waiterCount = 0
        for waiter in pending { waiter.resume(returning: true) }
    }

    func wait(until deadline: ContinuousClock.Instant) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.wait() }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw Timeout()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func wait() async throws {
        let id = UUID()
        let signalled = await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { register($0, id: id) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if !signalled { throw CancellationError() }
    }

    // Only a deliberately held scanner cleanup uses this: shutdown must join it,
    // and the test must explicitly release it on both success and failure paths.
    func waitForCleanupRelease() async {
        _ = await withCheckedContinuation { register($0, id: UUID()) }
    }

    private func register(_ waiter: CheckedContinuation<Bool, Never>, id: UUID) {
        if isSet { waiter.resume(returning: true) }
        else { waiters[id] = waiter; waiterCount = waiters.count }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
        waiterCount = waiters.count
    }
}

actor InitialScanGate {
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var finished = false
    let startedEvent = StartupTestSignal()
    let cancelledEvent = StartupTestSignal()
    let finishedEvent = StartupTestSignal()
    private let releaseEvent = StartupTestSignal()
    private let cleanupRelease = StartupTestSignal()
    private let holdsCleanup: Bool

    init(holdsCleanup: Bool = false) { self.holdsCleanup = holdsCleanup }

    func wait() async {
        started = true
        await startedEvent.signal()
        do { try await releaseEvent.wait() }
        catch {
            cancelled = true
            await cancelledEvent.signal()
            if holdsCleanup { await cleanupRelease.waitForCleanupRelease() }
        }
    }

    func finish() async {
        finished = true
        await finishedEvent.signal()
    }

    func release() async {
        await releaseEvent.signal()
        await cleanupRelease.signal()
    }
}
