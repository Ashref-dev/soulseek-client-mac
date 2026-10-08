import Foundation
import Testing
import SoulseekCore
import Persistence
import ShareIndexer
@testable import TransferEngine

@Test func indexingCanonicalPathsPrivacyAndSymlinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let publicRoot = root.appendingPathComponent("Collection")
    let privateRoot = root.appendingPathComponent("Rare")
    try FileManager.default.createDirectory(at: publicRoot.appendingPathComponent("Björk"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
    try Data("own test content".utf8).write(to: publicRoot.appendingPathComponent("Björk/日本語.txt"))
    try Data().write(to: publicRoot.appendingPathComponent(".hidden"))
    try Data("private".utf8).write(to: privateRoot.appendingPathComponent("private.txt"))
    try FileManager.default.createSymbolicLink(at: publicRoot.appendingPathComponent("linked.txt"), withDestinationURL: privateRoot.appendingPathComponent("private.txt"))
    let index = ShareIndex()
    let stats = await index.scan(folders: [(URL(fileURLWithPath: publicRoot.path), false), (privateRoot, true)])
    #expect(stats.0 == 2)
    #expect(await index.library().values.flatMap { $0 }.count == 1)
    #expect(await index.search("private").isEmpty)
    #expect(await index.resolve("Rare\\private.txt") == nil)
    #expect(await index.resolve("Rare\\private.txt", allowPrivate: true) != nil)
    let file = try #require(await index.resolve("Collection\\Björk\\日本語.txt"))
    #expect(try Data(contentsOf: file.localURL) == Data("own test content".utf8))
}

@Test func duplicatesAndPartialNamesAreStable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let (destination, partial) = try SafeDestination.plan(root: root, user: "listener", remotePath: "Björk\\日本語.txt")
    #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
    try Data("completed".utf8).write(to: partial)
    let first = try SafeDestination.publish(partial, to: destination)
    #expect(first == destination)
    let (duplicate, samePartial) = try SafeDestination.plan(root: root, user: "listener", remotePath: "Björk\\日本語.txt")
    #expect(samePartial == partial); #expect(duplicate == destination)
    try Data("again".utf8).write(to: samePartial)
    let second = try SafeDestination.publish(samePartial, to: duplicate)
    #expect(second.lastPathComponent == "日本語 (2).txt")
    #expect(try Data(contentsOf: destination) == Data("completed".utf8))
}

@Test func unfinishedFilesWaitInVisibleIncompleteFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let (first, firstPartial) = try SafeDestination.plan(root: root, user: "listener", remotePath: "Music\\Album\\01 Song.flac")
    let (_, otherPeer) = try SafeDestination.plan(root: root, user: "someone", remotePath: "Music\\Album\\01 Song.flac")
    let (second, secondPartial) = try SafeDestination.plan(root: root, user: "listener", remotePath: "Music\\Album\\.hidden.flac")
    let incomplete = root.appendingPathComponent("Incomplete")
    #expect(firstPartial.deletingLastPathComponent() == incomplete)
    #expect(firstPartial.lastPathComponent.wholeMatch(of: /01 Song \[[0-9a-f]{16}\]\.flac\.partial/) != nil)
    #expect(otherPeer != firstPartial)
    let collidingAtEightHex = try ["Album6002\\Song.flac", "Album34331\\Song.flac"].map { try SafeDestination.plan(root: root, user: "peer", remotePath: $0).partial }
    #expect(collidingAtEightHex[0] != collidingAtEightHex[1])
    #expect(!secondPartial.lastPathComponent.hasPrefix("."))
    let long = String(repeating: "é", count: 117) + ".flac"
    let longPartial = try SafeDestination.plan(root: root, user: "listener", remotePath: "Album\\" + long).partial
    #expect(longPartial.lastPathComponent.utf8.count <= 255)
    try Data().write(to: longPartial); try FileManager.default.removeItem(at: longPartial)

    try Data("one".utf8).write(to: firstPartial); try Data("two".utf8).write(to: secondPartial)
    _ = try SafeDestination.publish(firstPartial, to: first)
    #expect(FileManager.default.fileExists(atPath: secondPartial.path))
    try Data().write(to: incomplete.appendingPathComponent(".DS_Store"))
    _ = try SafeDestination.publish(secondPartial, to: second)
    #expect(!FileManager.default.fileExists(atPath: incomplete.path))
    #expect(try Data(contentsOf: first) == Data("one".utf8))
}

@Test func restoreMovesLegacyHiddenPartialsIntoIncompleteFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent(".arpeggio-incomplete")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let old = legacy.appendingPathComponent("0123abcd.partial")
    try Data(repeating: 7, count: 40).write(to: old)
    let database = try Database(url: root.appendingPathComponent("state.sqlite"))
    var item = Transfer(user: "listener", file: SharedFile(path: "Music\\Album\\Track.flac", size: 100))
    item.status = .paused; item.partial = old.path; item.destination = root.appendingPathComponent("Album/Track.flac").path
    try await database.put(item, collection: "transfers", id: item.id)
    let engine = TransferEngine(session: SoulseekSession(), database: database, root: root)
    try await engine.restore()
    let moved = URL(fileURLWithPath: try #require(await engine.snapshot().first?.partial))
    #expect(moved.deletingLastPathComponent() == root.appendingPathComponent("Incomplete"))
    #expect(try Data(contentsOf: moved) == Data(repeating: 7, count: 40))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    await engine.shutdown()
    #expect(try await database.get(Transfer.self, collection: "transfers", id: item.id)?.partial == moved.path)
    await database.close()
}

@Test func partialFilesAreNeverShared() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let incomplete = root.appendingPathComponent("Downloads/Incomplete")
    try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: incomplete.appendingPathComponent("Song [0123abcd].flac.partial"))
    try Data("done".utf8).write(to: root.appendingPathComponent("Downloads/Done.flac"))
    let index = ShareIndex()
    _ = await index.scan(folders: [(root.appendingPathComponent("Downloads"), false)])
    #expect(await index.resolve("Downloads\\Done.flac") != nil)
    #expect(await index.resolve("Downloads\\Incomplete\\Song [0123abcd].flac.partial") == nil)
}

@Test func destinationSymlinkCannotEscapeRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Album"), withDestinationURL: root.appendingPathComponent("outside"))
    let (destination, partial) = try SafeDestination.plan(root: root, user: "listener", remotePath: "Music\\Album\\file.txt")
    try Data("x".utf8).write(to: partial)
    #expect(throws: FileSafetyError.self) { try SafeDestination.publish(partial, to: destination) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside/file.txt").path))
}

@Test func downloadsKeepOnlyTheAlbumFolderByDefault() throws {
    let path = "Music\\Lossless\\Capcom\\Monster Hunter Rise OST\\Disc 2\\01 Song.flac"
    #expect(try SafeDestination.relativeComponents(user: "peer", remotePath: path, layout: DownloadLayout()) == ["Monster Hunter Rise OST", "Disc 2", "01 Song.flac"])
    #expect(try SafeDestination.relativeComponents(user: "peer", remotePath: "Music\\Album\\01.mp3", layout: DownloadLayout()) == ["Album", "01.mp3"])
    #expect(try SafeDestination.relativeComponents(user: "peer", remotePath: "loose.mp3", layout: DownloadLayout()) == ["loose.mp3"])
    #expect(try SafeDestination.relativeComponents(user: "peer", remotePath: "Music\\Album\\01.mp3", layout: DownloadLayout(userFolders: true)) == ["peer", "Album", "01.mp3"])
    #expect(try SafeDestination.relativeComponents(user: "peer", remotePath: path, layout: DownloadLayout(fullPaths: true)).count == 6)
    #expect(SafeDestination.isDiscFolder("CD1")); #expect(SafeDestination.isDiscFolder("disc 03 - bonus")); #expect(!SafeDestination.isDiscFolder("Discovery"))
}

@Test func interruptedStateRestoresAsQueueAndPausedStaysPaused() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try Database(url: root.appendingPathComponent("state.sqlite"))
    var active = Transfer(user: "listener", file: SharedFile(path: "Music\\test.txt", size: 100))
    active.status = .transferring; active.transferred = 40
    var paused = Transfer(user: "listener", file: SharedFile(path: "Music\\paused.txt", size: 100)); paused.status = .paused
    try await database.put(active, collection: "transfers", id: active.id)
    try await database.put(paused, collection: "transfers", id: paused.id)
    let engine = TransferEngine(session: SoulseekSession(), database: database, root: root)
    try await engine.restore()
    var iterator = engine.updates.makeAsyncIterator()
    let state = try #require(await iterator.next())
    #expect(state.first { $0.id == active.id }?.status == .queued)
    #expect(state.first { $0.id == paused.id }?.status == .paused)
    await database.close()
}
