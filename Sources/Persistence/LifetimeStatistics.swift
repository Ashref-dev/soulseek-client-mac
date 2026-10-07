import Foundation

/// The frozen statistics/main JSON shape, shared without a Persistence -> TransferEngine dependency.
public struct LifetimeStatistics: Codable, Sendable, Equatable {
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
}
