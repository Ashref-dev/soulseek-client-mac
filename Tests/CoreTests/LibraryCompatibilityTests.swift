import Foundation
import Testing
import SoulseekCore

@Test func duplicateFolderSectionsMergeFilesInsteadOfDiscardingEarlierSection() throws {
    var writer = WireWriter(); writer.uint(2)
    for name in ["one.txt", "two.txt"] {
        writer.string("Music"); writer.uint(1)
        PeerCodec.writeFile(SharedFile(path: name, size: 1), to: &writer)
    }
    let library = try PeerCodec.library(user: "fixture", data: Zlib.deflate(writer.data))
    #expect(library.folders["Music"]?.map(\.name) == ["one.txt", "two.txt"])
}

@Test func explicitLargeLibraryBudgetSupportsNormalLargeCatalogAndStillBoundsExpansion() throws {
    let path = "Music\\" + String(repeating: "a", count: 1000)
    let files = (0..<30_000).map { SharedFile(path: path + "\\\($0).txt", size: 1) }
    let payload = try PeerCodec.libraryReply([path: files])
    #expect(throws: ProtocolError.self) { try PeerCodec.library(user: "fixture", data: payload) }
    let library = try PeerCodec.library(user: "fixture", data: payload, limits: .large)
    #expect(library.folders[path]?.count == 30_000)
    #expect(throws: ProtocolError.self) { try PeerCodec.validateFolders([path: files], limits: LibraryLimits(expandedBytes: 1024, modelBytes: 1024)) }
}

@Test func repeatedLibrarySectionsHaveBoundedWorkAndDeduplicateWithinSections() throws {
    var writer = WireWriter(); writer.uint(100_000)
    for index in 0..<100_000 {
        writer.string("M"); writer.uint(2)
        let file = SharedFile(path: "\(index).txt", size: 1)
        PeerCodec.writeFile(file, to: &writer); PeerCodec.writeFile(file, to: &writer)
    }
    var reader = WireReader(writer.data)
    let start = ContinuousClock.now
    let folders = try PeerCodec.readFolders(&reader, limits: .large)
    #expect(folders["M"]?.count == 100_000)
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test func unsupportedLargeFileDoesNotHideOtherSharedFiles() throws {
    let payload = try PeerCodec.libraryReply(["Music": [
        SharedFile(path: "Music\\small.txt", size: 70),
        SharedFile(path: "Music\\large.bin", size: 17 * 1024 * 1024 * 1024)
    ]])
    let library = try PeerCodec.library(user: "fixture", data: payload)
    #expect(library.folders["Music"]?.map(\.name) == ["small.txt"])
}
