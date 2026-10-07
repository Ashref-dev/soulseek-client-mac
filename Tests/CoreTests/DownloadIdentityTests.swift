import Foundation
import Testing
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices
@testable import Arpeggio

/// Derived user/path lookups must never let one person's file stand in for another's.
@Suite @MainActor struct DownloadIdentityTests {
    @Test func collidingUserPathPairsKeepTheirOwnDownloadState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-ids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        var first = Transfer(user: "a", file: SharedFile(path: "b\u{1F}c", size: 10))
        first.status = .completed; first.destination = "/synthetic/first.flac"
        var second = Transfer(user: "a\u{1F}b", file: SharedFile(path: "c", size: 20))
        second.status = .transferring; second.destination = "/synthetic/second.flac"
        var third = Transfer(user: "x", file: SharedFile(path: "y\u{0}z", size: 1)); third.status = .queued
        var fourth = Transfer(user: "x\u{0}y", file: SharedFile(path: "z", size: 2)); fourth.status = .failed
        model.indexDownloads([first, second, third, fourth])
        #expect(model.downloadIndex.count == 4)
        let one = try #require(model.downloadState(user: "a", path: "b\u{1F}c"))
        #expect(one.id == first.id); #expect(one.status == .completed); #expect(one.destination == "/synthetic/first.flac")
        let two = try #require(model.downloadState(user: "a\u{1F}b", path: "c"))
        #expect(two.id == second.id); #expect(two.status == .transferring); #expect(two.destination == "/synthetic/second.flac")
        #expect(model.downloadState(user: "x", path: "y\u{0}z")?.id == third.id)
        #expect(model.downloadState(user: "x\u{0}y", path: "z")?.id == fourth.id)
        #expect(model.downloadState(user: "a", path: "c") == nil)
    }

    @Test func folderGroupingKeepsDelimiterContainingFoldersApart() throws {
        let rows = [SearchResult(user: "a", file: SharedFile(path: "b\u{0}c\\x.flac", size: 1), freeSlot: true, speed: 1, queue: 0),
                    SearchResult(user: "a\u{0}b", file: SharedFile(path: "c\\x.flac", size: 2), freeSlot: true, speed: 1, queue: 0)]
        let projection = try SearchProjection.make(rows, filters: ResultFilters(), order: [KeyPathComparator(\SearchResult.size)], grouping: .folder)
        #expect(projection.groups.count == 2)
        #expect(Set(projection.groups.map { $0.items.map(\.user) }) == [["a"], ["a\u{0}b"]])
    }
}
