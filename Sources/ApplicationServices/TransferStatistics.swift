import Foundation
import TransferEngine

public struct TransferStatistics: Codable, Sendable, Equatable {
    public var since = Date()
    public var downloadedBytes: UInt64 = 0
    public var uploadedBytes: UInt64 = 0
    public var downloadsCompleted = 0
    public var uploadsCompleted = 0
    public var peakDownloadSpeed: Double = 0
    public var peakUploadSpeed: Double = 0
    public var sources: Set<String> = []
    public var listeners: Set<String> = []
    public init(since: Date = Date()) { self.since = since }

    public struct Progress: Sendable, Equatable {
        var bytes: UInt64
        var completed: Bool
    }

    /// Seeds totals from transfer history recorded before statistics existed.
    public static func seeded(from history: [Transfer]) -> TransferStatistics {
        var stats = TransferStatistics(since: history.map(\.date).min() ?? Date())
        for item in history where item.status == .completed && !item.isPreview {
            if item.upload {
                stats.uploadedBytes += item.file.size; stats.uploadsCompleted += 1; stats.insert(item.user, into: \.listeners)
            } else {
                stats.downloadedBytes += item.file.size; stats.downloadsCompleted += 1; stats.insert(item.user, into: \.sources)
            }
        }
        return stats
    }

    /// Adds bytes moved and transfers finished since the previous snapshot. Transfers present in the
    /// first snapshot only set a baseline, so history isn't counted twice.
    @discardableResult
    public mutating func ingest(_ transfers: [Transfer], seen: inout [String: Progress], baseline: Bool) -> Bool {
        let before = self
        var current: [String: Progress] = [:]
        current.reserveCapacity(transfers.count)
        for item in transfers {
            let moved = item.bytesMoved ?? 0
            let now = Progress(bytes: moved, completed: item.status == .completed && !item.isPreview)
            current[item.id] = now
            guard !baseline else { continue }
            let previous = seen[item.id] ?? Progress(bytes: 0, completed: false)
            if moved > previous.bytes {
                let delta = moved - previous.bytes
                if item.upload { uploadedBytes &+= delta } else { downloadedBytes &+= delta }
            }
            if item.status == .transferring {
                if item.upload { peakUploadSpeed = max(peakUploadSpeed, item.speed) } else { peakDownloadSpeed = max(peakDownloadSpeed, item.speed) }
            }
            if now.completed, !previous.completed {
                if item.upload { uploadsCompleted += 1; insert(item.user, into: \.listeners) }
                else { downloadsCompleted += 1; insert(item.user, into: \.sources) }
            }
        }
        seen = current
        return self != before
    }

    private mutating func insert(_ user: String, into set: WritableKeyPath<TransferStatistics, Set<String>>) {
        if self[keyPath: set].count < 50_000 { self[keyPath: set].insert(user) }
    }
}

public struct ReceivedSearch: Identifiable, Sendable {
    public let id = UUID()
    public let user: String
    public let query: String
    public let results: Int
    public let date: Date
}
