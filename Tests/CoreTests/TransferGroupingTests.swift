import Foundation
import Testing
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices
@testable import Arpeggio

private func transfer(_ user: String, _ path: String, upload: Bool = false, status: TransferStatus = .queued, size: UInt64 = 100,
                      transferred: UInt64 = 0, id: String? = nil) -> Transfer {
    var item = Transfer(user: user, file: SharedFile(path: path, size: size), upload: upload)
    if let id { item.id = id }
    item.status = status; item.transferred = transferred
    return item
}

private func fixture(upload: Bool = false) -> [Transfer] {
    [transfer("alice", "Music\\Album\\01 Intro.flac", upload: upload, id: "a1"),
     transfer("alice", "Music\\Album\\02 Song.flac", upload: upload, id: "a2"),
     transfer("alice", "loose.mp3", upload: upload, id: "a3"),
     transfer("bob", "Other\\Album\\01 Intro.flac", upload: upload, id: "b1"),
     transfer("bob", "Music\\Album\\03 Outro.flac", upload: upload, id: "b2")]
}

@Suite struct TransferGroupingTests {
    @Test func unknownStoredLayoutFallsBackToFoldersAndDirectionsUseSeparateKeys() {
        #expect(TransferLayout(stored: nil) == .folders)
        #expect(TransferLayout(stored: "grid") == .folders)
        #expect(TransferLayout(stored: "") == .folders)
        #expect(TransferLayout(stored: "flat") == .flat)
        #expect(TransferLayout(stored: "users") == .users)
        #expect(TransferLayout.preferenceKey(upload: false) != TransferLayout.preferenceKey(upload: true))
        for layout in TransferLayout.allCases { #expect(TransferLayout(stored: layout.rawValue) == layout) }
    }

    @Test(arguments: [false, true]) func everyLayoutKeepsEveryTransferExactlyOnce(upload: Bool) {
        let items = fixture(upload: upload)
        for layout in TransferLayout.allCases {
            let tree = TransferTree.make(items, layout: layout)
            #expect(tree.leaves.count == items.count)
            #expect(Set(tree.leaves.map(\.id)) == Set(items.map(\.id)))
            #expect(tree.leaves.allSatisfy { $0.upload == upload })
        }
    }

    @Test func flatLayoutHasOnlyLeaves() {
        let tree = TransferTree.make(fixture(), layout: .flat)
        #expect(tree.roots.count == 5)
        #expect(tree.roots.allSatisfy { $0.kind == .file && $0.children == nil })
        #expect(tree.groupIDs.isEmpty)
    }

    @Test func foldersNeverMergeAcrossPeopleOrPaths() throws {
        let tree = TransferTree.make(fixture(), layout: .folders)
        let ids = Set(tree.roots.map(\.id))
        #expect(ids == [.folder(user: "alice", path: "Music\\Album"), .folder(user: "alice", path: ""),
                        .folder(user: "bob", path: "Other\\Album"), .folder(user: "bob", path: "Music\\Album")])
        let loose = try #require(tree.roots.first { $0.id == .folder(user: "alice", path: "") })
        #expect(loose.title == "Loose Files")
        #expect(loose.children?.map(\.id) == [.transfer("a3")])
        let albums = tree.roots.filter { $0.title == "Album" }
        #expect(albums.count == 3)
    }

    @Test func usersLayoutNestsFoldersThenFiles() throws {
        let tree = TransferTree.make(fixture(), layout: .users)
        #expect(Set(tree.roots.map(\.id)) == [.user("alice"), .user("bob")])
        let alice = try #require(tree.roots.first { $0.id == .user("alice") })
        #expect(alice.kind == .user)
        #expect(alice.summary.files == 3)
        let folders = try #require(alice.children)
        #expect(folders.allSatisfy { $0.kind == .folder && $0.user == "alice" })
        #expect(folders.flatMap { $0.children ?? [] }.allSatisfy { $0.kind == .file })
    }

    @Test func parentSelectionMapsToExactLeavesWithoutDuplicates() {
        let tree = TransferTree.make(fixture(), layout: .users)
        #expect(Set(tree.transferIDs(for: [.folder(user: "alice", path: "Music\\Album")])) == ["a1", "a2"])
        #expect(Set(tree.transferIDs(for: [.user("bob")])) == ["b1", "b2"])
        let overlapping = tree.transferIDs(for: [.user("alice"), .folder(user: "alice", path: "Music\\Album"), .transfer("a1")])
        #expect(overlapping.count == 3)
        #expect(Set(overlapping) == ["a1", "a2", "a3"])
        #expect(tree.transferIDs(for: [.transfer("gone"), .user("nobody")]).isEmpty)
        #expect(tree.transferIDs(for: []).isEmpty)
        #expect(tree.transferIDs(for: [.folder(user: "bob", path: "Music\\Album")]) == ["b2"])
    }

    @Test func identitiesStayStableAcrossProgressAndStatusChanges() {
        var items = fixture()
        let before = TransferTree.make(items, layout: .users)
        items[0].status = .transferring; items[0].transferred = 50; items[0].speed = 1000
        items[3].status = .completed; items[3].transferred = 100
        items[4].status = .failed
        let after = TransferTree.make(items, layout: .users)
        func allIDs(_ nodes: [TransferNode]) -> Set<TransferNodeID> {
            Set(nodes.flatMap { [$0.id] + allIDs($0.children ?? []) })
        }
        #expect(allIDs(before.roots) == allIDs(after.roots))
        let selection: Set<TransferNodeID> = [.folder(user: "alice", path: "Music\\Album")]
        #expect(Set(before.transferIDs(for: selection)) == Set(after.transferIDs(for: selection)))
    }

    @Test func summariesAggregateProgressAndOrderUnfinishedFirst() throws {
        var items = fixture()
        items[0].status = .transferring; items[0].transferred = 50; items[0].speed = 10
        items[1].status = .completed; items[1].transferred = 100
        items[3].status = .completed; items[4].status = .completed
        let tree = TransferTree.make(items, layout: .users)
        #expect(tree.roots.first?.id == .user("alice"))
        let alice = try #require(tree.roots.first)
        #expect(alice.summary.totalBytes == 300)
        #expect(alice.summary.doneBytes == 150)
        #expect(alice.summary.transferring == 1)
        #expect(alice.summary.speed == 10)
        let bob = try #require(tree.roots.last)
        #expect(bob.summary.isFinished)
        #expect(bob.summary.progress == 1)
    }

    @Test func groupingAThousandRowsVisitsEachRowOnce() {
        var items: [Transfer] = []
        for index in 0..<1000 {
            items.append(transfer("user\(index % 50)", "Music\\Artist\\Album \((index / 50) % 4)\\\(index).flac", status: index % 3 == 0 ? .transferring : .queued))
        }
        for layout in TransferLayout.allCases {
            let tree = TransferTree.make(items, layout: layout)
            let groups = tree.groupIDs.count
            #expect(tree.leaves.count == 1000)
            #expect(tree.visits == 1000 + groups)
            #expect(tree.visits <= 1500)
        }
        let users = TransferTree.make(items, layout: .users)
        #expect(users.roots.count == 50)
        #expect(Set(users.transferIDs(for: Set(users.roots.map(\.id)))) == Set(items.map(\.id)))
    }

    @Test func duplicateTransferIDsAreShownOnce() {
        let items = fixture() + [transfer("alice", "Music\\Album\\01 Intro.flac", id: "a1")]
        for layout in TransferLayout.allCases { #expect(TransferTree.make(items, layout: layout).leaves.count == 5) }
    }

    @Test func removalWordingNeverPromisesToDeleteFiles() {
        var active = transfer("alice", "Music\\Album\\01.flac", status: .transferring)
        let finished = transfer("alice", "Music\\Album\\02.flac", status: .completed)
        #expect(TransferRemoval.needsConfirmation([active]))
        #expect(!TransferRemoval.needsConfirmation([finished]))
        #expect(TransferRemoval.title([active, finished]).hasPrefix("Stop and remove"))
        #expect(TransferRemoval.confirmTitle([active]) == "Stop and Remove")
        #expect(TransferRemoval.confirmTitle([finished]) == "Remove from List")
        for upload in [false, true] {
            let message = TransferRemoval.message([active, finished], upload: upload)
            #expect(message.contains("not deleted") || message.contains("not touched"))
            #expect(message.contains("Statistics totals stay the same"))
        }
        active.status = .paused
        #expect(TransferRemoval.needsConfirmation([active]))
        #expect(TransferRemoval.activeCount([active]) == 0)
        for title in [TransferRemoval.confirmTitle([active]), TransferRemoval.confirmTitle([finished])] {
            #expect(!title.localizedCaseInsensitiveContains("delete"))
        }
    }
}
