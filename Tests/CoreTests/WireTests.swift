import Testing
import Foundation
@testable import SoulseekCore
import Persistence
import TransferEngine
import ShareIndexer

@Test func wireRoundTrip() throws {
    var writer = WireWriter(); writer.uint(0x12345678); writer.ulong(UInt64.max); writer.string("Björk 日本語")
    var reader = WireReader(writer.data)
    #expect(try reader.uint() == 0x12345678)
    #expect(try reader.ulong() == UInt64.max)
    #expect(try reader.string() == "Björk 日本語")
    #expect(reader.remaining == 0)
}
@Test func truncatedAndBombsRejected() throws {
    var reader = WireReader(Data([1, 2, 3]))
    #expect(throws: ProtocolError.self) { try reader.uint() }
    var writer = WireWriter(); writer.uint(UInt32.max)
    var stringReader = WireReader(writer.data)
    #expect(throws: ProtocolError.self) { try stringReader.string() }
    let compressed = try Zlib.deflate(Data(repeating: 0, count: 200_000))
    #expect(throws: ProtocolError.self) { try Zlib.inflate(compressed, limit: 1000) }
}
@Test func peerSearchAndBrowse() throws {
    let file = SharedFile(path: "Music\\Björk\\01 Jóga.flac", size: 5_000_000_000, attributes: [4: 96000, 5: 24])
    let response = try PeerCodec.searchReply(user: "listener", token: 42, files: [file], slots: true, speed: 1234, queue: 0)
    let (token, results) = try PeerCodec.search(response)
    #expect(token == 42); #expect(results.first?.file == file); #expect(results.first?.freeSlot == true)
    let library = try PeerCodec.library(user: "listener", data: PeerCodec.libraryReply([file.folder: [file]]))
    #expect(library.folders[file.folder]?.first == file)
}
@Test func traversalRejected() throws {
    for path in ["..\\escape", "Music/../../escape", "/etc/passwd", "Music\\\\file", "C:\\escape", "Music\\.\\file", "Music\\bad\0file"] {
        #expect(throws: FileSafetyError.self) { try SafeDestination.components(user: "listener", remotePath: path) }
    }
    #expect(try SafeDestination.components(user: "listener", remotePath: "Björk\\日本語.flac") == ["listener", "Björk", "日本語.flac"])
}
@Test func databaseRestoration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("state.sqlite")
    let db = try Database(url: url)
    var user = UserRecord(username: "listener"); user.note = "Rare records"; user.trusted = true
    try await db.put(user, collection: "users", id: user.id); await db.close()
    let reopened = try Database(url: url)
    let restored = try await reopened.all(UserRecord.self, collection: "users")
    #expect(restored.first?.note == user.note); #expect(restored.first?.trusted == true)
    await reopened.close()
}
