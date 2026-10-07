import Foundation
import SoulseekCore
import ArpeggioServices

struct ProjectionKey: Equatable {
    let token: UInt32?
    let filters: ResultFilters
    let sort: [KeyPathComparator<SearchResult>]
}

/// One immutable snapshot of results with the filters and order to apply.
struct SearchSnapshot: Sendable {
    let results: [SearchResult]
    let filters: ResultFilters
    let order: [KeyPathComparator<SearchResult>]
}

/// Filtered, sorted rows and the user, folder and track outline built from them, prepared off the main actor.
struct SearchPreparation: Sendable {
    let projection: SearchProjection
    let hierarchy: ResultHierarchy

    nonisolated static func make(_ snapshot: SearchSnapshot) throws -> Self {
        try Task.checkCancellation()
        let projection = try SearchProjection.make(snapshot.results, filters: snapshot.filters, order: snapshot.order, grouping: .none)
        try Task.checkCancellation()
        return Self(projection: projection, hierarchy: try ResultHierarchy.make(projection.rows))
    }

    @MainActor static func pipeline() -> SearchPipeline<SearchSnapshot, SearchPreparation> {
        SearchPipeline { snapshot in try make(snapshot) }
    }
}

struct SearchProjection: Sendable {
    var rows: [SearchResult] = []
    var groups: [ResultGroup] = []
    var formats: [String] = []
    nonisolated static func make(_ source: [SearchResult], filters: ResultFilters, order: [KeyPathComparator<SearchResult>], grouping: ResultGrouping) throws -> Self {
        var rows: [SearchResult] = []; var availableFormats = Set<String>()
        rows.reserveCapacity(source.count)
        for (index, row) in source.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            if filters.matches(row) { rows.append(row) }
            if !row.file.format.isEmpty { availableFormats.insert(row.file.format) }
        }
        try Task.checkCancellation(); rows.sort(using: order); try Task.checkCancellation()
        let formats = availableFormats.sorted()
        if grouping == .none { return Self(rows: rows, groups: [ResultGroup(id: "all", title: "", items: rows)], formats: formats) }
        var keys: [String] = []; var buckets: [String: [SearchResult]] = [:]
        for row in rows {
            let key = grouping == .user ? row.user : SearchIdentity.key(user: row.user, path: row.folder)
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
