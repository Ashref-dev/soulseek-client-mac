import Foundation
import Testing
import SoulseekCore
@testable import ArpeggioServices
@testable import Arpeggio

/// Holds a build open until the test releases it, so tests control exactly when preparation finishes.
private actor Gate {
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<Int> = []
    private(set) var entered: [Int] = []
    func wait(_ value: Int) async {
        entered.append(value)
        if opened.contains(value) { return }
        await withCheckedContinuation { waiters[value] = $0 }
    }
    func open(_ value: Int) { opened.insert(value); waiters.removeValue(forKey: value)?.resume() }
    func hasEntered(_ value: Int) -> Bool { entered.contains(value) }
}

@MainActor private func until(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition not reached")
}

private func results(_ count: Int, users: Int = 400, folders: Int = 5) -> [SearchResult] {
    (0..<count).map { index in
        let user = "user\(index % users)"
        let folder = "Music\\Artist \(index % 37)\\Album \(index % folders)"
        let ext = index % 4 == 0 ? "flac" : "mp3"
        return SearchResult(user: user, file: SharedFile(path: "\(folder)\\\(index).\(ext)", size: UInt64(1000 + index), attributes: [0: UInt32(128 + index % 4 * 64)]),
                            freeSlot: index % 3 == 0, speed: UInt32(index % 997), queue: UInt32(index % 11))
    }
}

@Suite(.serialized) @MainActor struct SearchPipelineTests {
    @Test func idlePipelineDoesNoWork() async throws {
        let builds = PipelineCounter()
        let pipeline = SearchPipeline<Int, Int> { value in await builds.increment(); return value }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await builds.value == 0)
        #expect(pipeline.counters == .init())
        pipeline.submit(1)
        await pipeline.idle()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await builds.value == 1)
        #expect(pipeline.counters.started == 1)
        #expect(!pipeline.isRunning); #expect(!pipeline.hasPending)
    }

    @Test func burstsCoalesceIntoOneRunningAndTheLatestPending() async throws {
        let gate = Gate()
        let pipeline = SearchPipeline<Int, Int> { value in await gate.wait(value); return value }
        pipeline.submit(1)
        await until { await gate.hasEntered(1) }
        for value in 2...50 { pipeline.submit(value) }
        #expect(pipeline.isRunning); #expect(pipeline.hasPending)
        #expect(pipeline.counters.coalesced == 48)
        await gate.open(1)
        await until { await gate.hasEntered(50) }
        #expect(pipeline.output == 1)
        await gate.open(50)
        await pipeline.idle()
        #expect(pipeline.output == 50)
        #expect(pipeline.counters.started == 2)
        #expect(pipeline.counters.published == 2)
        #expect(pipeline.counters.maxRunning == 1)
        #expect(await gate.entered == [1, 50])
    }

    @Test func staleGenerationNeverPublishes() async throws {
        let gate = Gate()
        let pipeline = SearchPipeline<Int, Int> { value in await gate.wait(value); return value }
        pipeline.reset(generation: 1)
        pipeline.submit(10)
        await until { await gate.hasEntered(10) }
        pipeline.submit(11)
        pipeline.reset(generation: 2)
        #expect(!pipeline.hasPending)
        pipeline.submit(20)
        #expect(pipeline.hasPending)
        await gate.open(10)
        await until { await gate.hasEntered(20) }
        #expect(pipeline.output == nil)
        await gate.open(20)
        await pipeline.idle()
        #expect(pipeline.output == 20)
        #expect(pipeline.outputGeneration == 2)
        #expect(pipeline.counters.rejectedStale == 1)
        #expect(pipeline.counters.maxRunning == 1)
        #expect(await !gate.hasEntered(11))
    }

    @Test func cancellationStopsDetachedWork() async throws {
        let checks = PipelineCounter()
        let pipeline = SearchPipeline<Int, Int> { _ in
            while true {
                try Task.checkCancellation()
                await checks.increment()
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        pipeline.submit(1)
        await until { await checks.value > 3 }
        pipeline.cancel()
        await pipeline.idle()
        let stopped = await checks.value
        try await Task.sleep(for: .milliseconds(60))
        #expect(await checks.value <= stopped + 1)
        #expect(pipeline.output == nil)
        #expect(pipeline.failure == nil)
        #expect(pipeline.counters.cancelled == 1)
    }

    @Test func clearingDropsVisibleOutputButKeepingRetainsPartialResults() async throws {
        let pipeline = SearchPipeline<Int, Int> { $0 }
        pipeline.submit(7)
        await pipeline.idle()
        pipeline.reset(generation: 1)
        #expect(pipeline.output == 7)
        pipeline.reset(generation: 2, clear: true)
        #expect(pipeline.output == nil)
    }

    @Test func failuresOfTheCurrentGenerationAreReported() async throws {
        struct Broken: LocalizedError { var errorDescription: String? { "broken input" } }
        let pipeline = SearchPipeline<Int, Int> { _ in throw Broken() }
        pipeline.submit(1)
        await pipeline.idle()
        #expect(pipeline.failure == "broken input")
        #expect(pipeline.counters.failed == 1)
    }

    @Test func fiftyThousandResultsPrepareCorrectlyWithBoundedRebuilds() async throws {
        let source = results(50_000)
        let pipeline = SearchPreparation.pipeline()
        var filters = ResultFilters()
        filters.text = "flac"
        let order = [KeyPathComparator(\SearchResult.slotRank), KeyPathComparator(\SearchResult.speed, order: .reverse)]
        let started = ContinuousClock.now
        for count in stride(from: 5_000, through: 50_000, by: 5_000) {
            pipeline.submit(SearchSnapshot(results: Array(source.prefix(count)), filters: filters, order: order))
        }
        await pipeline.idle()
        let elapsed = ContinuousClock.now - started
        let output = try #require(pipeline.output)
        let expected = source.filter { filters.matches($0) }
        #expect(output.projection.rows.count == expected.count)
        #expect(output.projection.rows.count == 12_500)
        #expect(Set(output.projection.rows.map(\.id)) == Set(expected.map(\.id)))
        #expect(output.hierarchy.tracks.count == expected.count)
        #expect(output.hierarchy.users.reduce(0) { $0 + $1.fileCount } == expected.count)
        #expect(output.projection.rows.first?.freeSlot == true)
        #expect(pipeline.counters.started <= 2)
        #expect(pipeline.counters.coalesced >= 8)
        #expect(pipeline.counters.maxRunning == 1)
        let folderIDs = Set(output.hierarchy.users.flatMap { $0.folders.map(\.id) })
        #expect(folderIDs.count == output.hierarchy.folders.count)
        if let path = ProcessInfo.processInfo.environment["ARPEGGIO_PERF_OUTPUT"] {
            let record: [String: Any] = ["test": "search-pipeline-50k", "results": 50_000, "matching": expected.count,
                                         "submitted": pipeline.counters.submitted, "started": pipeline.counters.started,
                                         "coalesced": pipeline.counters.coalesced, "seconds": elapsed.pipelineSeconds]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path + ".search.json"))
        }
    }
}

private actor PipelineCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private extension Duration {
    var pipelineSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
