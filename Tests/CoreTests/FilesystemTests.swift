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
