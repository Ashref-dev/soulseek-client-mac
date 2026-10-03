import Foundation

public struct LibraryLimits: Sendable {
    public let expandedBytes: Int
    public let modelBytes: Int
    public static let standard = LibraryLimits(expandedBytes: 64 * 1024 * 1024, modelBytes: 32 * 1024 * 1024)
    public static let large = LibraryLimits(expandedBytes: 256 * 1024 * 1024, modelBytes: 256 * 1024 * 1024)
    public init(expandedBytes: Int, modelBytes: Int) { self.expandedBytes = expandedBytes; self.modelBytes = modelBytes }
}
