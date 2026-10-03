import Foundation
import SoulseekCore

/// Selection identity for the results outline. IDs are opaque and stable across live updates:
/// a folder is keyed by user plus its *full* remote path, so equal basenames never merge.
public enum ResultNodeID: Hashable, Sendable {
    case user(String)
    case folder(String)
    case track(SearchResult.ID)
}

public struct ResultFolderNode: Identifiable, Sendable {
    public let id: String
    public let user: String
    public let path: String
    public let title: String
    public let breadcrumb: String
    public let tracks: [SearchResult]
    public let bytes: UInt64
    public let seconds: UInt64
    public let quality: String
}

public struct ResultUserNode: Identifiable, Sendable {
    public var id: String { user }
    public let user: String
    public let folders: [ResultFolderNode]
    public let fileCount: Int
    public let bytes: UInt64
    public let freeSlot: Bool
    public let speed: UInt32
    public let queue: UInt32
}

/// USER → FOLDER/RELEASE → TRACKS, built off the main actor from already filtered and ranked rows.
/// Users and folders keep the order of their best-ranked row; tracks within a release use natural filename order.
public struct ResultHierarchy: Sendable {
    public var users: [ResultUserNode] = []
    public var folders: [String: ResultFolderNode] = [:]
    public var tracks: [SearchResult.ID: SearchResult] = [:]
    public init() {}

    public static func folderID(user: String, path: String) -> String { user + "\u{1F}" + path }

    public nonisolated static func make(_ rows: [SearchResult]) throws -> Self {
        try Task.checkCancellation()
        var userOrder: [String] = []
        var folderOrder: [String: [String]] = [:]
        var buckets: [String: [SearchResult]] = [:]
        var tracks: [SearchResult.ID: SearchResult] = [:]
        tracks.reserveCapacity(rows.count)
        for (offset, row) in rows.prefix(50_000).enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            guard tracks[row.id] == nil else { continue }
            let key = folderID(user: row.user, path: row.file.folder)
            if folderOrder[row.user] == nil { userOrder.append(row.user) }
            if buckets[key] == nil { folderOrder[row.user, default: []].append(key) }
            buckets[key, default: []].append(row)
            tracks[row.id] = row
        }
        var output = Self(); output.tracks = tracks
        output.users.reserveCapacity(userOrder.count)
        for user in userOrder {
            try Task.checkCancellation()
            var nodes: [ResultFolderNode] = []
            for key in folderOrder[user] ?? [] {
                try Task.checkCancellation()
                guard let items = buckets[key], let first = items.first else { continue }
                let node = try folderNode(id: key, user: user, path: first.file.folder, items: items)
                nodes.append(node); output.folders[key] = node
            }
            let all = nodes.lazy.flatMap(\.tracks)
            let best = all.first { $0.freeSlot } ?? all.first
            output.users.append(ResultUserNode(
                user: user, folders: nodes, fileCount: nodes.reduce(0) { $0 + $1.tracks.count },
                bytes: nodes.reduce(0) { $0 &+ $1.bytes }, freeSlot: best?.freeSlot ?? false,
                speed: best?.speed ?? 0, queue: best?.queue ?? 0))
        }
        return output
    }

    private static func folderNode(id: String, user: String, path: String, items: [SearchResult]) throws -> ResultFolderNode {
        try Task.checkCancellation()
        let parts = path.split(separator: "\\").map(String.init)
        let named = items.map { (result: $0, name: $0.file.name) }
        let tracks = named.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.result)
        try Task.checkCancellation()
        return ResultFolderNode(
            id: id, user: user, path: path,
            title: parts.last ?? "Shared Root",
            breadcrumb: parts.dropLast().suffix(2).joined(separator: " › "),
            tracks: tracks,
            bytes: items.reduce(0) { $0 &+ $1.file.size },
            seconds: items.reduce(0) { $0 &+ UInt64($1.file.attributes[1] ?? 0) },
            quality: summary(items))
    }

    /// "FLAC · 24-bit / 96.0 kHz", "MP3 · 320 kbps", or "FLAC, MP3" when a folder is mixed.
    private static func summary(_ items: [SearchResult]) -> String {
        let formats = Array(Set(items.map(\.file.format).filter { !$0.isEmpty })).sorted()
        let qualities = Set(items.map(\.file.quality))
        if formats.count == 1, qualities.count == 1, let format = formats.first, let quality = qualities.first {
            return quality == format ? format : "\(format) · \(quality)"
        }
        return formats.prefix(3).joined(separator: ", ") + (formats.count > 3 ? "…" : "")
    }
}
