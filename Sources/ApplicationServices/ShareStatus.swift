import Foundation

/// What Arpeggio can honestly say about sharing. A zero file count alone never means "no folders".
public enum ShareStatus: Equatable, Sendable {
    case noFolders
    case pending
    case indexing(filesProcessed: Int)
    case empty(missingFolders: Int, unreadableItems: Int)
    case ready(files: Int, bytes: UInt64, missingFolders: Int, unreadableItems: Int)

    public static func resolve(configuredFolders: Int, missingFolders: Int, indexing: Bool, indexedCurrentConfiguration: Bool,
                               files: Int, bytes: UInt64, unreadableItems: Int, filesProcessed: Int) -> ShareStatus {
        guard configuredFolders > 0 else { return .noFolders }
        if indexing { return .indexing(filesProcessed: max(0, filesProcessed)) }
        guard indexedCurrentConfiguration else { return .pending }
        let missing = min(max(0, missingFolders), configuredFolders), unreadable = max(0, unreadableItems)
        guard files > 0 else { return .empty(missingFolders: missing, unreadableItems: unreadable) }
        return .ready(files: files, bytes: bytes, missingFolders: missing, unreadableItems: unreadable)
    }

    public var isSharing: Bool { if case .ready = self { true } else { false } }
    public var isIndexing: Bool { if case .indexing = self { true } else { false } }

    public var headline: String {
        switch self {
        case .noFolders: "You aren’t sharing any folders yet"
        case .pending: "Shared folders are waiting to be indexed"
        case .indexing: "Indexing your shared folders…"
        case .empty: "No readable files in your shared folders"
        case .ready(let files, let bytes, _, _): "Sharing \(files.formatted()) files · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))"
        }
    }

    public var detail: String? {
        switch self {
        case .noFolders: return "Add a folder in Shared Files so people can browse and download from you."
        case .pending: return "Arpeggio indexes them automatically. People see your files once indexing finishes."
        case .indexing(let processed): return processed > 0 ? "\(processed.formatted()) files processed so far." : "Starting…"
        case .empty(let missing, let unreadable):
            let issues = Self.issues(missing: missing, unreadable: unreadable)
            return (issues ?? "The folders are empty, or every file is hidden or excluded.") + " See Shared Files for details."
        case .ready(_, _, let missing, let unreadable):
            return Self.issues(missing: missing, unreadable: unreadable).map { $0 + " See Shared Files for details." }
        }
    }

    public var symbol: String {
        switch self {
        case .noFolders: "externaldrive.badge.plus"
        case .pending, .indexing: "externaldrive.badge.timemachine"
        case .empty: "externaldrive.badge.exclamationmark"
        case .ready: "externaldrive.fill.badge.checkmark"
        }
    }

    static func issues(missing: Int, unreadable: Int) -> String? {
        var parts: [String] = []
        if missing > 0 { parts.append(missing == 1 ? "1 folder is missing or disconnected." : "\(missing.formatted()) folders are missing or disconnected.") }
        if unreadable > 0 { parts.append(unreadable == 1 ? "1 item couldn’t be read." : "\(unreadable.formatted()) items couldn’t be read.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

extension AppModel {
    public var shareStatus: ShareStatus {
        let folders = settings.sharedFolders
        return .resolve(configuredFolders: folders.count,
                        missingFolders: folders.filter { !FileManager.default.fileExists(atPath: $0.path) }.count,
                        indexing: indexing,
                        indexedCurrentConfiguration: indexedFolders == folders && indexedExclusions == (settings.shareExclusions ?? []),
                        files: sharedCount, bytes: sharedBytes, unreadableItems: shareErrors.count,
                        filesProcessed: shareProgress.filesProcessed)
    }
}
