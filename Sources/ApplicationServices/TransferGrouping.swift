import Foundation
import TransferEngine

/// How Downloads or Uploads arrange their rows. Each direction remembers its own choice; a stored value
/// this version does not know falls back to Folders.
public enum TransferLayout: String, CaseIterable, Identifiable, Sendable {
    case flat, folders, users

    public var id: Self { self }
    public static let fallback = TransferLayout.folders

    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? Self.fallback }

    /// Separate keys, so Downloads and Uploads never share a layout by accident.
    public static func preferenceKey(upload: Bool) -> String {
        upload ? "Arpeggio.TransferLayout.uploads" : "Arpeggio.TransferLayout.downloads"
    }

    public var title: String {
        switch self {
        case .flat: "Flat"
        case .folders: "Folders"
        case .users: "Users"
        }
    }

    public var detail: String {
        switch self {
        case .flat: "Every file in one list"
        case .folders: "Files grouped by folder"
        case .users: "People, then folders, then files"
        }
    }

    public var symbol: String {
        switch self {
        case .flat: "list.bullet"
        case .folders: "folder"
        case .users: "person.2"
        }
    }

    public var hasGroups: Bool { self != .flat }
}

/// Opaque, stable row identity. A folder is keyed by its user plus the full remote folder path, so equal
/// album names from different people, or equal basenames in different paths, never merge.
public enum TransferNodeID: Hashable, Sendable {
    case user(String)
    case folder(user: String, path: String)
    case transfer(String)
}

/// Aggregate figures for a group row. Leaves carry the same figures for their single transfer.
public struct TransferSummary: Sendable, Equatable {
    public var files = 0
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
    public var transferring = 0
    public var waiting = 0
    public var paused = 0
    public var totalBytes: UInt64 = 0
    public var doneBytes: UInt64 = 0
    public var speed: Double = 0
    public var rank = Int.max
    public var latest = Date.distantPast

    public init() {}

    public var isFinished: Bool { files > 0 && completed + cancelled == files }
    public var isTransferring: Bool { transferring > 0 }
    public var remainingBytes: UInt64 { totalBytes - min(doneBytes, totalBytes) }
    public var progress: Double { totalBytes == 0 ? (isFinished ? 1 : 0) : min(1, Double(doneBytes) / Double(totalBytes)) }
    public var eta: Double? { speed > 0 ? Double(remainingBytes) / speed : nil }

    mutating func add(_ transfer: Transfer) {
        files += 1
        switch transfer.status {
        case .completed: completed += 1
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        case .transferring: transferring += 1; speed += transfer.speed
        case .queued, .negotiating: waiting += 1
        case .paused: paused += 1
        }
        totalBytes &+= transfer.file.size
        doneBytes &+= transfer.status == .completed ? transfer.file.size : min(transfer.transferred, transfer.file.size)
        rank = min(rank, TransferTree.rank(transfer.status))
        latest = max(latest, transfer.date)
    }

    mutating func merge(_ other: TransferSummary) {
        files += other.files; completed += other.completed; failed += other.failed; cancelled += other.cancelled
        transferring += other.transferring; waiting += other.waiting; paused += other.paused
        totalBytes &+= other.totalBytes; doneBytes &+= other.doneBytes; speed += other.speed
        rank = min(rank, other.rank); latest = max(latest, other.latest)
    }
}

/// One row of the transfers outline: a person, a folder or a single transfer.
public struct TransferNode: Identifiable, Sendable {
    public enum Kind: Sendable { case user, folder, file }
    public let id: TransferNodeID
    public let kind: Kind
    public let user: String
    /// Full remote folder path; empty for loose files shared from a share root.
    public let folder: String
    public let title: String
    /// Short context: the parent folder for a release, the folder for a flat file.
    public let context: String?
    public let transfer: Transfer?
    /// `nil` for leaves, as SwiftUI outlines expect.
    public let children: [TransferNode]?
    public let summary: TransferSummary
}

/// Builds the outline for one layout in a single pass over the transfers, and maps any selection, including
/// parent rows, to the exact transfers underneath. Leaves of every node are a contiguous run of `leaves`,
/// in display order, so selection mapping never walks the tree again.
public struct TransferTree: Sendable {
    public let layout: TransferLayout
    public let roots: [TransferNode]
    /// Every transfer in display order.
    public let leaves: [Transfer]
    /// Transfers looked at plus group nodes built: a bound on work per publication.
    public let visits: Int
    private let ranges: [TransferNodeID: Range<Int>]

    public init() { layout = .folders; roots = []; leaves = []; visits = 0; ranges = [:] }

    private init(layout: TransferLayout, roots: [TransferNode], leaves: [Transfer], visits: Int, ranges: [TransferNodeID: Range<Int>]) {
        self.layout = layout; self.roots = roots; self.leaves = leaves; self.visits = visits; self.ranges = ranges
    }

    /// Lower ranks sort first: work in progress, then waiting, then finished history.
    public static func rank(_ status: TransferStatus) -> Int {
        switch status {
        case .transferring: 0
        case .negotiating: 1
        case .queued: 2
        case .paused: 3
        case .failed: 4
        case .completed: 5
        case .cancelled: 6
        }
    }

    /// Group IDs that can expand or collapse, for Expand All and Collapse All.
    public var groupIDs: [TransferNodeID] {
        ranges.keys.filter { if case .transfer = $0 { return false }; return true }
    }

    public func contains(_ id: TransferNodeID) -> Bool { ranges[id] != nil }

    /// The exact transfers under the selected rows, without duplicates, in display order.
    /// IDs that no longer exist (a removed transfer, a group that emptied) are ignored.
    public func transfers(for selection: Set<TransferNodeID>) -> [Transfer] {
        guard !selection.isEmpty else { return [] }
        var covered = IndexSet()
        for id in selection { if let range = ranges[id] { covered.insert(integersIn: range) } }
        return covered.map { leaves[$0] }
    }

    public func transferIDs(for selection: Set<TransferNodeID>) -> [String] { transfers(for: selection).map(\.id) }

    /// Transfers must already be in the order files should appear inside a folder.
    public static func make(_ transfers: [Transfer], layout: TransferLayout) -> TransferTree {
        var visits = 0
        var leaves: [Transfer] = []; leaves.reserveCapacity(transfers.count)
        var ranges: [TransferNodeID: Range<Int>] = [:]; ranges.reserveCapacity(transfers.count + transfers.count / 4)

        if layout == .flat {
            var roots: [TransferNode] = []; roots.reserveCapacity(transfers.count)
            for transfer in transfers {
                visits += 1
                let id = TransferNodeID.transfer(transfer.id)
                guard ranges[id] == nil else { continue }
                ranges[id] = leaves.count..<(leaves.count + 1)
                leaves.append(transfer)
                let folder = transfer.file.folder
                roots.append(leaf(transfer, folder: folder, context: Self.lastComponent(folder)))
            }
            return TransferTree(layout: layout, roots: roots, leaves: leaves, visits: visits, ranges: ranges)
        }

        // One pass: bucket by user, then by full folder path, keeping first-seen order.
        struct Bucket { var folder: String; var items: [Transfer] = []; var summary = TransferSummary() }
        var userOrder: [String] = []
        var folderOrder: [String: [String]] = [:]
        var buckets: [String: [String: Bucket]] = [:]
        var seen = Set<String>(); seen.reserveCapacity(transfers.count)
        for transfer in transfers {
            visits += 1
            guard seen.insert(transfer.id).inserted else { continue }
            let folder = transfer.file.folder
            if buckets[transfer.user] == nil { userOrder.append(transfer.user); buckets[transfer.user] = [:] }
            if buckets[transfer.user]?[folder] == nil {
                folderOrder[transfer.user, default: []].append(folder)
                buckets[transfer.user]?[folder] = Bucket(folder: folder)
            }
            buckets[transfer.user]?[folder]?.items.append(transfer)
            buckets[transfer.user]?[folder]?.summary.add(transfer)
        }

        func folderNodes(_ user: String) -> [(node: TransferNode, items: [Transfer])] {
            var output: [(node: TransferNode, items: [Transfer])] = []
            for folder in folderOrder[user] ?? [] {
                guard let bucket = buckets[user]?[folder] else { continue }
                visits += 1
                let id = TransferNodeID.folder(user: user, path: folder)
                let children = bucket.items.map { leaf($0, folder: folder, context: nil) }
                let parts = folder.split(separator: "\\")
                let node = TransferNode(id: id, kind: .folder, user: user, folder: folder,
                                        title: parts.last.map(String.init) ?? "Loose Files",
                                        context: parts.dropLast().last.map(String.init),
                                        transfer: nil, children: children, summary: bucket.summary)
                output.append((node, bucket.items))
            }
            return output.sorted { order($0.node.summary, $1.node.summary) }
        }

        func place(_ node: TransferNode, items: [Transfer]) {
            let start = leaves.count
            for item in items { ranges[.transfer(item.id)] = leaves.count..<(leaves.count + 1); leaves.append(item) }
            ranges[node.id] = start..<leaves.count
        }

        var roots: [TransferNode] = []
        if layout == .folders {
            var all: [(node: TransferNode, items: [Transfer])] = []
            for user in userOrder { all.append(contentsOf: folderNodes(user)) }
            all.sort { order($0.node.summary, $1.node.summary) }
            for entry in all { place(entry.node, items: entry.items); roots.append(entry.node) }
        } else {
            var users: [(node: TransferNode, folders: [(node: TransferNode, items: [Transfer])])] = []
            for user in userOrder {
                visits += 1
                let folders = folderNodes(user)
                var summary = TransferSummary()
                for folder in folders { summary.merge(folder.node.summary) }
                let node = TransferNode(id: .user(user), kind: .user, user: user, folder: "", title: user, context: nil,
                                        transfer: nil, children: folders.map(\.node), summary: summary)
                users.append((node, folders))
            }
            users.sort { order($0.node.summary, $1.node.summary) }
            for user in users {
                let start = leaves.count
                for folder in user.folders { place(folder.node, items: folder.items) }
                ranges[user.node.id] = start..<leaves.count
                roots.append(user.node)
            }
        }
        return TransferTree(layout: layout, roots: roots, leaves: leaves, visits: visits, ranges: ranges)
    }

    /// Unfinished groups first, then the most urgent status, then the most recent activity.
    static func order(_ a: TransferSummary, _ b: TransferSummary) -> Bool {
        if a.isFinished != b.isFinished { return !a.isFinished }
        if a.rank != b.rank { return a.rank < b.rank }
        return a.latest > b.latest
    }

    private static func leaf(_ transfer: Transfer, folder: String, context: String?) -> TransferNode {
        var summary = TransferSummary(); summary.add(transfer)
        return TransferNode(id: .transfer(transfer.id), kind: .file, user: transfer.user, folder: folder,
                            title: transfer.file.name, context: context, transfer: transfer, children: nil, summary: summary)
    }

    private static func lastComponent(_ folder: String) -> String? {
        folder.split(separator: "\\").last.map(String.init)
    }
}
