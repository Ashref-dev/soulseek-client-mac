import Foundation
import SoulseekCore

struct ProjectionKey: Equatable {
    let token: UInt32?
    let count: Int
    let filters: ResultFilters
    let grouping: ResultGrouping
    let sort: [KeyPathComparator<SearchResult>]
}

struct SearchProjection: Sendable {
    var rows: [SearchResult] = []
    var groups: [ResultGroup] = []
    var formats: [String] = []
    nonisolated static func make(_ source: [SearchResult], filters: ResultFilters, order: [KeyPathComparator<SearchResult>], grouping: ResultGrouping) -> Self {
        let rows = source.filter(filters.matches).sorted(using: order)
        let formats = Array(Set(source.lazy.map(\.file.format).filter { !$0.isEmpty })).sorted()
        if grouping == .none { return Self(rows: rows, groups: [ResultGroup(id: "all", title: "", items: rows)], formats: formats) }
        var keys: [String] = []; var buckets: [String: [SearchResult]] = [:]
        for row in rows {
            let key = grouping == .user ? row.user : row.user + "\0" + row.folder
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(row)
        }
        let groups = keys.compactMap { key -> ResultGroup? in
            guard let items = buckets[key], let first = items.first else { return nil }
            let title = grouping == .user ? key : "\(first.user) · \(first.folder.split(separator: "\\").suffix(2).joined(separator: " › "))"
            return ResultGroup(id: key, title: title, items: items)
        }
        return Self(rows: rows, groups: groups, formats: formats)
    }
}
