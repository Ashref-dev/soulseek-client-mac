import Foundation
import Testing
import ShareIndexer
import ArpeggioServices

@Test func playerAllocationsReserveMetadataAndNeverOverlapControls() {
    for width in [600.0, 660, 880, 1280, 2000] {
        let layout = PlayerWidthAllocation(width: width)
        #expect(layout.transport + layout.actions + 16 <= layout.content)
        #expect(layout.content == width - 32)
        #expect(layout.transport >= 400)
        #expect(layout.actions == (width >= 800 ? 240 : 120))
    }
    #expect(!PlayerWidthAllocation(width: 660).showsMetadataChips)
    #expect(PlayerWidthAllocation(width: 880).showsMetadataChips)
    #expect(PlayerWidthAllocation(width: 799).actions == 120)
    #expect(PlayerWidthAllocation(width: 800).actions == 240)
    #expect(PlayerWidthAllocation(width: .nan).content == 0)
}

@Test func menuGlyphGeometryHasBalancedMarginsAndContainedBadge() {
    #expect(MenuGlyphGeometry.mark.midX == MenuGlyphGeometry.canvas.width / 2)
    #expect(MenuGlyphGeometry.mark.midY == MenuGlyphGeometry.canvas.height / 2)
    #expect(CGRect(origin: .zero, size: MenuGlyphGeometry.canvas).contains(MenuGlyphGeometry.badge))
    #expect(MenuGlyphGeometry.canvas.width < 25)
}

@Test func indexingPublishesRealFileCountsAndKeepsCommittedIndexOnCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for i in 0..<260 { try Data([1]).write(to: root.appendingPathComponent("\(i).txt")) }
    let index = ShareIndex()
    let count = await index.scan(folders: [(root, false)])
    #expect(count.0 == 260)
    var iterator = index.progress.makeAsyncIterator()
    let completed = try #require(await iterator.next())
    #expect(completed.phase == .completed); #expect(completed.filesProcessed == 260)
    #expect(completed.folder != nil); #expect(!completed.description.contains("%"))
    let cancelled = Task { await index.scan(folders: [(root, false)], exclusions: ["*.txt"]) }
    cancelled.cancel(); _ = await cancelled.value
    #expect(await index.library().values.flatMap { $0 }.count == 260)
    let status = try #require(await iterator.next())
    #expect(status.phase == .cancelled); #expect(status.revision > completed.revision)
}

@Test func overlappingScansOnlyNewestRevisionCanCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for i in 0..<300 { try Data([1]).write(to: root.appendingPathComponent("\(i).txt")) }
    let index = ShareIndex()
    async let first = index.scan(folders: [(root, false)])
    await Task.yield()
    _ = await index.scan(folders: [], exclusions: [])
    _ = await first
    _ = await index.scan(folders: [])
    #expect(await index.library().isEmpty)
    var iterator = index.progress.makeAsyncIterator()
    let final = await iterator.next()
    #expect(final?.phase == .completed); #expect(final?.revision == 3); #expect(final?.filesProcessed == 0)
}
