import Foundation
import Observation

/// Event-driven preparation of search results off the main actor.
///
/// Nothing runs while idle. Exactly one preparation runs at a time, including one that is still winding down
/// after cancellation; snapshots that arrive meanwhile collapse into a single latest pending snapshot. A new
/// `generation` (another search, filter or sort order) cancels the running preparation and drops the pending
/// one, and output from an older generation is never published.
@MainActor @Observable
public final class SearchPipeline<Input: Sendable, Output: Sendable> {
    public struct Counters: Sendable, Equatable {
        public var submitted = 0
        public var started = 0
        public var published = 0
        /// Pending snapshots replaced by a newer one before they started.
        public var coalesced = 0
        /// Finished preparations discarded because their generation was no longer current.
        public var rejectedStale = 0
        public var cancelled = 0
        public var failed = 0
        public var maxRunning = 0
        public init() {}
    }

    public typealias Build = @Sendable (Input) async throws -> Output

    public private(set) var output: Output?
    /// Generation of the published output.
    public private(set) var outputGeneration: UInt64?
    public private(set) var failure: String?
    @ObservationIgnored public private(set) var counters = Counters()
    @ObservationIgnored public private(set) var generation: UInt64 = 0
    @ObservationIgnored private let build: Build
    @ObservationIgnored private var running: (job: UInt64, task: Task<Void, Never>)?
    @ObservationIgnored private var nextJob: UInt64 = 0
    @ObservationIgnored private var live = 0
    @ObservationIgnored private var pending: Input?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(build: @escaping Build) { self.build = build }

    public var isRunning: Bool { running != nil }
    public var hasPending: Bool { pending != nil }

    /// Starts a new generation: cancels running work and drops pending input. The old output stays visible
    /// until the new generation publishes unless `clear` is set.
    public func reset(generation: UInt64, clear: Bool = false) {
        if clear { output = nil; outputGeneration = nil; failure = nil }
        guard generation != self.generation else { return }
        self.generation = generation
        pending = nil
        if let running, !running.task.isCancelled { running.task.cancel(); counters.cancelled += 1 }
        resumeIdleWaitersIfIdle()
    }

    /// Offers a snapshot for the current generation. Starts work only when nothing is running.
    public func submit(_ input: Input) {
        counters.submitted += 1
        guard running == nil else {
            if pending != nil { counters.coalesced += 1 }
            pending = input
            return
        }
        start(input)
    }

    /// Stops everything, for example when the view disappears.
    public func cancel() {
        pending = nil
        if let running, !running.task.isCancelled { running.task.cancel(); counters.cancelled += 1 }
        resumeIdleWaitersIfIdle()
    }

    /// Returns once nothing is running or pending. For tests and drivers.
    public func idle() async {
        guard running != nil || pending != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func start(_ input: Input) {
        let generation = generation, build = build
        nextJob &+= 1; let job = nextJob
        counters.started += 1
        live += 1; counters.maxRunning = max(counters.maxRunning, live)
        let task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try await build(input) }
            let result: Result<Output, any Error>
            do { result = .success(try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }) }
            catch { result = .failure(error) }
            self?.finish(result, generation: generation, job: job)
        }
        running = (job, task)
    }

    private func finish(_ result: Result<Output, any Error>, generation: UInt64, job: UInt64) {
        live -= 1
        guard running?.job == job else { return }
        let cancelled = running?.task.isCancelled ?? true
        running = nil
        switch result {
        case .success(let value):
            if generation == self.generation, !cancelled {
                output = value; outputGeneration = generation; failure = nil; counters.published += 1
            } else { counters.rejectedStale += 1 }
        case .failure(let error):
            if !(error is CancellationError), !cancelled, generation == self.generation {
                failure = error.localizedDescription; counters.failed += 1
            }
        }
        if let next = pending {
            pending = nil
            start(next)
            return
        }
        resumeIdleWaitersIfIdle()
    }

    private func resumeIdleWaitersIfIdle() {
        guard running == nil, pending == nil, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters; idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
