import Foundation
import Testing
import SoulseekCore
import Persistence
import ShareIndexer
import TransferEngine
@testable import ArpeggioServices

/// Large workloads run only with ARPEGGIO_PERF=1. Ordinary runs check the same deterministic counts at a
/// small size. Timings are recorded for this machine only, never asserted as universal thresholds.
private let perfEnabled = ProcessInfo.processInfo.environment["ARPEGGIO_PERF"] == "1"

private func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func record(_ name: String, _ values: [String: Any]) throws {
    guard let base = ProcessInfo.processInfo.environment["ARPEGGIO_PERF_OUTPUT"] else { return }
    var output = values
    output["test"] = name
    output["machine"] = MachineInfo.current
    try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        .write(to: URL(fileURLWithPath: base + ".\(name).json"))
}

enum MachineInfo {
    static var current: [String: Any] {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return ["model": sysctl("hw.model") ?? "unknown", "cpu": sysctl("machdep.cpu.brand_string") ?? "unknown",
                "cores": ProcessInfo.processInfo.activeProcessorCount,
                "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                "os": ProcessInfo.processInfo.operatingSystemVersionString]
    }
}

/// A generated tree of tiny files: every fourth file has an audio extension. Nothing is read from real libraries.
private struct SyntheticShare {
    let root: URL
    let share: URL
    let files: Int
    let audio: Int

    static func make(files: Int, perFolder: Int = 100) throws -> SyntheticShare {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-scale-\(UUID().uuidString)").resolvingSymlinksInPath()
        let share = root.appendingPathComponent("Library")
        let manager = FileManager.default
        let byte = Data([0x41])
        var audio = 0
        for folder in 0..<((files + perFolder - 1) / perFolder) {
            let directory = share.appendingPathComponent("Artist \(folder / 10)/Album \(folder)")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<min(perFolder, files - folder * perFolder) {
                let number = folder * perFolder + index
                let isAudio = number % 4 == 0
                if isAudio { audio += 1 }
                guard manager.createFile(atPath: directory.appendingPathComponent("Track \(number).\(isAudio ? "flac" : "txt")").path, contents: byte) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        return SyntheticShare(root: root, share: share, files: files, audio: audio)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private let fixedMetadata: @Sendable (URL, UInt64) -> [UInt32: UInt32] = { _, _ in [1: 180, 4: 44_100, 5: 16] }

private struct IndexWorkload {
    var cold = 0.0, warm = 0.0, restored = 0.0, query = 0.0
    var coldReads = 0, warmReads = 0, restoredReads = 0, queryRootResolutions = 0, queryResults = 0
    var maxActorWait = 0.0, keptAfterCancel = 0

    static func run(_ synthetic: SyntheticShare, queries: Int) async throws -> IndexWorkload {
        var output = IndexWorkload()
        let folders = [(synthetic.share, false)]
        let index = ShareIndex(metadataReader: fixedMetadata)
        let probe = Task {
            var worst = 0.0
            while !Task.isCancelled {
                let start = ContinuousClock.now
                _ = await index.summaries
                worst = max(worst, elapsed(start))
                try? await Task.sleep(for: .milliseconds(5))
            }
            return worst
        }
        var start = ContinuousClock.now
        let cold = await index.scan(folders: folders)
        output.cold = elapsed(start)
        probe.cancel(); output.maxActorWait = await probe.value
        #expect(cold.0 == synthetic.files)
        output.coldReads = await index.metadataReads
        start = ContinuousClock.now
        let warm = await index.scan(folders: folders)
        output.warm = elapsed(start)
        #expect(warm.0 == synthetic.files)
        output.warmReads = await index.metadataReads - output.coldReads

        let restoredIndex = ShareIndex(metadataReader: fixedMetadata)
        await restoredIndex.restoreMetadataCache(await index.metadataCache())
        start = ContinuousClock.now
        let restored = await restoredIndex.scan(folders: folders)
        output.restored = elapsed(start)
        #expect(restored.0 == synthetic.files)
        output.restoredReads = await restoredIndex.metadataReads

        let before = await index.queryRootResolutions
        start = ContinuousClock.now
        for number in 0..<queries {
            output.queryResults += await index.search("track \(number * 7 % max(1, synthetic.files))", configuredFolders: folders).count
        }
        output.query = elapsed(start) / Double(max(1, queries))
        output.queryRootResolutions = await index.queryRootResolutions - before

        let cancelled = Task { await index.scan(folders: folders, exclusions: ["*.flac"]) }
        cancelled.cancel(); _ = await cancelled.value
        output.keptAfterCancel = await index.library().values.reduce(0) { $0 + $1.count }
        return output
    }

    var json: [String: Any] {
        ["coldSeconds": cold, "warmSeconds": warm, "restoredCacheSeconds": restored, "querySecondsEach": query,
         "coldMetadataReads": coldReads, "warmMetadataReads": warmReads, "restoredMetadataReads": restoredReads,
         "queryRootResolutions": queryRootResolutions, "queryResults": queryResults,
         "maxActorWaitDuringColdScanSeconds": maxActorWait, "filesKeptAfterCancelledRescan": keptAfterCancel]
    }
}

@Suite(.serialized) struct ShareIndexScaleTests {
    @Test func metadataIsReadOnceAndReusedWarmAndFromCache() async throws {
        let synthetic = try SyntheticShare.make(files: 2_000)
        defer { synthetic.remove() }
        let result = try await IndexWorkload.run(synthetic, queries: 20)
        #expect(result.coldReads == synthetic.audio)
        #expect(result.warmReads == 0)
        #expect(result.restoredReads == 0)
        #expect(result.queryRootResolutions == 20)
        #expect(result.keptAfterCancel == synthetic.files)
    }

    @Test(.enabled(if: perfEnabled), .timeLimit(.minutes(10)))
    func hundredThousandFilesColdWarmAndQuery() async throws {
        let start = ContinuousClock.now
        let synthetic = try SyntheticShare.make(files: 100_000)
        let generation = elapsed(start)
        defer { synthetic.remove() }
        let result = try await IndexWorkload.run(synthetic, queries: 50)
        #expect(result.coldReads == 25_000)
        #expect(result.warmReads == 0)
        #expect(result.restoredReads == 0)
        #expect(result.queryRootResolutions == 50)
        #expect(result.keptAfterCancel == 100_000)
        var json = result.json
        json["files"] = synthetic.files; json["audioFiles"] = synthetic.audio; json["generationSeconds"] = generation
        try record("share-index-100k", json)
    }
}

@Suite(.serialized) struct TransferWorkloadScaleTests {
    @Test(.enabled(if: perfEnabled), .timeLimit(.minutes(5)))
    func thousandTransfersBatchSnapshotGroupingAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-transfers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite")
        let db = try Database(url: url)
        let engine = TransferEngine(session: SoulseekSession(), database: db, root: root.appendingPathComponent("Downloads"))
        let requests = (0..<1000).map { index in
            SearchResult(user: "peer\(index % 40)", file: SharedFile(path: "Music\\Artist \(index % 9)\\Album \(index % 25)\\\(index).flac", size: 1_000_000),
                         freeSlot: true, speed: 0, queue: 0)
        }
        let publicationsBefore = await engine.publicationCount
        let transactionsBefore = await db.transactionCount
        var start = ContinuousClock.now
        try await engine.enqueue(requests + requests)
        let enqueue = elapsed(start)
        let publications = await engine.publicationCount - publicationsBefore
        let transactions = await db.transactionCount - transactionsBefore
        start = ContinuousClock.now
        var snapshot: [Transfer] = []
        for _ in 0..<100 { snapshot = await engine.snapshot() }
        let snapshotEach = elapsed(start) / 100
        #expect(snapshot.count == 1000)
        var grouping: [String: Any] = [:]
        for layout in TransferLayout.allCases {
            start = ContinuousClock.now
            let tree = TransferTree.make(snapshot, layout: layout)
            grouping[layout.rawValue] = ["seconds": elapsed(start), "visits": tree.visits, "groups": tree.groupIDs.count]
            #expect(tree.leaves.count == 1000)
        }
        await engine.shutdown(); await db.close()
        let reopened = try Database(url: url)
        let restoredEngine = TransferEngine(session: SoulseekSession(), database: reopened, root: root.appendingPathComponent("Downloads"))
        start = ContinuousClock.now
        try await restoredEngine.restore()
        let restore = elapsed(start)
        #expect(await restoredEngine.snapshot().count == 1000)
        await restoredEngine.shutdown(); await reopened.close()
        try record("transfers-1k", ["requests": 2000, "unique": 1000, "enqueueSeconds": enqueue, "publications": publications,
                                    "transactions": transactions, "snapshotSecondsEach": snapshotEach, "grouping": grouping,
                                    "restoreSeconds": restore])
    }
}
