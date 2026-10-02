import Foundation
import SoulseekCore
import Darwin

public struct IndexedFile: Sendable {
    public let file: SharedFile
    public let localURL: URL
    public let buddyOnly: Bool
    public let modified: Date?
}

public actor ShareIndex {
    private var files: [String: IndexedFile] = [:]
    private var scanRevision: UInt64 = 0
    public private(set) var errors: [String] = []
    public init() {}
    public func scan(folders: [(URL, Bool)], exclusions: [String] = []) async -> (Int, UInt64) {
        scanRevision &+= 1; let revision = scanRevision
        var next: [String: IndexedFile] = [:]
        errors = []
        var total: UInt64 = 0
        var processed = 0
        let manager = FileManager.default
        for (root, privateShare) in folders {
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isReadableKey, .contentModificationDateKey]
            guard let enumerator = manager.enumerator(at: resolved, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                errors.append("Cannot read \(root.path)"); continue
            }
            while let url = enumerator.nextObject() as? URL {
                processed += 1
                if processed % 128 == 0 { await Task.yield() }
                guard revision == scanRevision else { return (files.count, files.values.reduce(0) { $0 + $1.file.size }) }
                if Task.isCancelled { return (files.count, files.values.reduce(0) { $0 + $1.file.size }) }
                do {
                    if exclusions.contains(where: { fnmatch($0, url.lastPathComponent, FNM_CASEFOLD) == 0 }) {
                        enumerator.skipDescendants(); continue
                    }
                    let values = try url.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard values.isRegularFile == true, values.isReadable == true else { continue }
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                    guard canonical.path.hasPrefix(resolved.path + "/") else { continue }
                    let relative = String(canonical.path.dropFirst(resolved.path.count + 1)).replacingOccurrences(of: "/", with: "\\")
                    let path = resolved.lastPathComponent + "\\" + relative
                    guard next[path] == nil else { errors.append("Duplicate share path: \(path)"); continue }
                    let size = UInt64(max(0, values.fileSize ?? 0))
                    let attributes: [UInt32: UInt32]
                    if let previous = files[path], previous.file.size == size, previous.modified == values.contentModificationDate {
                        attributes = previous.file.attributes
                    } else { attributes = AudioMetadata.read(canonical, size: size) }
                    next[path] = IndexedFile(file: SharedFile(path: path, size: size, attributes: attributes), localURL: canonical,
                                             buddyOnly: privateShare, modified: values.contentModificationDate)
                    total += size
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        files = next
        return (files.count, total)
    }
    public func library(allowPrivate: Bool = false, configuredFolders: [(URL, Bool)]? = nil) -> [String: [SharedFile]] {
        Dictionary(grouping: files.values.filter { allowed($0, privateAccess: allowPrivate, folders: configuredFolders) }.map(\.file), by: \.folder)
    }
    public func search(_ query: String, allowPrivate: Bool = false, limit: Int = 500, configuredFolders: [(URL, Bool)]? = nil) -> [SharedFile] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return Array(files.values.lazy.filter { item in
            self.allowed(item, privateAccess: allowPrivate, folders: configuredFolders) && terms.allSatisfy { term in
                if term.hasPrefix("-") { return !item.file.path.lowercased().contains(term.dropFirst()) }
                return item.file.path.lowercased().contains(term.replacingOccurrences(of: "*", with: ""))
            }
        }.prefix(limit).map(\.file))
    }
    public func resolve(_ path: String, allowPrivate: Bool = false, configuredFolders: [(URL, Bool)]? = nil) -> IndexedFile? {
        guard let item = files[path], allowed(item, privateAccess: allowPrivate, folders: configuredFolders) else { return nil }
        return item
    }
    private func allowed(_ item: IndexedFile, privateAccess: Bool, folders: [(URL, Bool)]?) -> Bool {
        guard let folders else { return privateAccess || !item.buddyOnly }
        let matches = folders.filter { item.localURL.path.hasPrefix($0.0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
        guard let specific = matches.max(by: { $0.0.path.count < $1.0.path.count }) else { return false }
        return privateAccess || !specific.1
    }
}
