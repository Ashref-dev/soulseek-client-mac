import Foundation
import Testing
import SoulseekCore
import ArpeggioServices

@Test func groupsByUserAndFullFolderWithoutMergingEqualAlbumNames() throws {
    let rows = [
        SearchResult(user: "one", file: SharedFile(path: "Music\\Artist A\\Album\\02 song.flac", size: 10), freeSlot: true, speed: 1, queue: 0),
        SearchResult(user: "one", file: SharedFile(path: "Music\\Artist A\\Album\\01 song.flac", size: 20), freeSlot: true, speed: 1, queue: 0),
        SearchResult(user: "one", file: SharedFile(path: "Music\\Artist B\\Album\\song.flac", size: 30), freeSlot: true, speed: 1, queue: 0),
        SearchResult(user: "two", file: SharedFile(path: "Music\\Artist A\\Album\\song.flac", size: 40), freeSlot: false, speed: 2, queue: 1)
    ]
    let tree = try ResultHierarchy.make(rows + [rows[0]])
    #expect(tree.users.count == 2); #expect(tree.folders.count == 3); #expect(tree.tracks.count == 4)
    #expect(tree.users.first?.folders.first?.tracks.map(\.file.name) == ["01 song.flac", "02 song.flac"])
    #expect(tree.users.first?.bytes == 60)
}

@Test func fiftyThousandRowsRemainBoundedAndHaveStableIdentities() throws {
    let rows = (0..<50_000).map { index in
        SearchResult(user: "user\(index / 500)", file: SharedFile(path: "Music\\Album\(index / 25)\\\(index).flac", size: UInt64(index + 1)), freeSlot: true, speed: 100, queue: 0)
    }
    let start = ContinuousClock.now
    let tree = try ResultHierarchy.make(rows)
    #expect(tree.tracks.count == 50_000); #expect(tree.users.count == 100); #expect(tree.folders.count == 2000)
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(tree.users.first?.folders.first?.id == ResultHierarchy.folderID(user: "user0", path: "Music\\Album0"))
}

@Test func cancelledHierarchyBuildStopsBeforePublishingRows() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try ResultHierarchy.make([])
    }
    do { _ = try await task.value; Issue.record("Cancelled work must not publish a snapshot") } catch is CancellationError { } catch { Issue.record("Unexpected cancellation error") }
}

@Test func oneHugeFolderDoesNotProduceDuplicateRowsOrUnboundedHierarchyNodes() throws {
    let rows = (0..<50_000).map { index in
        SearchResult(user: "fixture", file: SharedFile(path: "Music\\Album\\\(index).flac", size: 1), freeSlot: true, speed: 1, queue: 0)
    }
    let start = ContinuousClock.now
    let tree = try ResultHierarchy.make(rows)
    #expect(tree.users.count == 1); #expect(tree.folders.count == 1)
    #expect(tree.users.first?.folders.first?.tracks.count == 50_000)
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test func oneUserWithManyFoldersKeepsEveryFolderIdentityUnique() throws {
    let rows = (0..<50_000).map { index in
        SearchResult(user: "fixture", file: SharedFile(path: "Music\\Folder\(index)\\track.flac", size: 1), freeSlot: true, speed: 1, queue: 0)
    }
    let start = ContinuousClock.now
    let tree = try ResultHierarchy.make(rows)
    #expect(tree.users.count == 1); #expect(tree.folders.count == 50_000)
    #expect(Set(tree.users[0].folders.map(\.id)).count == 50_000)
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test func retiredSearchTokenSkipsMalformedFileListInsteadOfDecodingIt() throws {
    var writer = WireWriter(); writer.string("fixture"); writer.uint(7); writer.uint(UInt32.max)
    let compressed = try Zlib.deflate(writer.data)
    let (token, rows) = try PeerCodec.search(compressed, allowedTokens: [8])
    #expect(token == 7); #expect(rows.isEmpty)
    #expect(throws: ProtocolError.self) { try PeerCodec.search(compressed, allowedTokens: [7]) }
}
