import Foundation
import Testing
import ShareIndexer

@Suite struct ShareSearchIndexTests {
    private func share(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Music")
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        return root
    }

    @Test func matchesWholeWordsWithExclusionsAndWildcards() async throws {
        let root = try share(["The Beatles/Abbey Road/01 Come Together.flac", "The Beatles/Help/02 Help (Remix).mp3",
                              "Beat Happening/01 Indian Summer.flac", "AC-DC/Back in Black.flac", "Björk/Post/01 Army of Me.flac"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let index = ShareIndex()
        _ = await index.scan(folders: [(root, false)])
        func names(_ query: String) async -> Set<String> { Set(await index.search(query, configuredFolders: [(root, false)]).map(\.name)) }
        #expect(await names("beatles") == ["01 Come Together.flac", "02 Help (Remix).mp3"])
        #expect(await names("BEAT") == ["01 Indian Summer.flac"])
        #expect(await names("beatles -remix") == ["01 Come Together.flac"])
        #expect(await names("*eatles help") == ["02 Help (Remix).mp3"])
        #expect(await names("ac/dc black") == ["Back in Black.flac"])
        #expect(await names("bjo\u{308}rk") == ["01 Army of Me.flac"])
        #expect(await names("flac -beatles -beat -björk") == ["Back in Black.flac"])
        #expect(await names("-beatles").isEmpty)
        #expect(await names("nothing here").isEmpty)
        #expect(await names("   ").isEmpty)
    }

    @Test func busyDistributedSearchLoadIsCheap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Music")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for album in 0..<100 {
            let folder = root.appendingPathComponent("Artist\(album)/Album \(album)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for track in 0..<50 { try Data([1]).write(to: folder.appendingPathComponent("\(track) Song Title \(album)-\(track).flac")) }
        }
        let index = ShareIndex()
        _ = await index.scan(folders: [(root, false)])
        let folders = [(root, false)]
        let queries = (0..<2_000).map { $0 % 10 == 0 ? "artist\($0 % 100) song" : "unrelated query \($0)" }
        let start = ContinuousClock.now
        var hits = 0
        for query in queries { hits += await index.search(query, configuredFolders: folders).count }
        let elapsed = ContinuousClock.now - start
        #expect(hits == 200 * 50)
        print("Share search benchmark: 5000 files, 2000 queries, \(hits) results, \(elapsed)")
        #expect(elapsed < .seconds(2))
    }
}
