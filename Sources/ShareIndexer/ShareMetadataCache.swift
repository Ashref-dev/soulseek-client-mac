import Foundation
import SoulseekCore

/// Metadata hints only, never an advertised library or upload authorization.
/// Each hint is reused only after enumeration validates source URL, size and mtime.
/// Legacy RemoteLibrary records have no provenance and cannot populate this cache.
public struct ShareMetadataCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let file: SharedFile
        public let sourceURL: URL
        public let modified: Date?
    }
    public let version: Int
    public let entries: [Entry]
}
