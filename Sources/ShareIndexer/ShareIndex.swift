import Foundation
import SoulseekCore
import Darwin

public struct IndexedFile: Sendable {
    public let file: SharedFile
    public let localURL: URL
    public let buddyOnly: Bool
    public let modified: Date?
    let localPath: String
}

public struct ShareRootSummary: Sendable, Equatable {
    public var files = 0
    public var bytes: UInt64 = 0
    public var audioFiles = 0
    public var folders = 0
}

public struct ShareScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, scanning, completed, cancelled }
    public var revision: UInt64 = 0
    public var phase: Phase = .idle
    public var folder: String?
    public var filesProcessed = 0
    public init() {}
    public var description: String {
        let location = folder.map { " · \($0)" } ?? ""
        return "\(phase == .scanning ? "Indexing" : phase.rawValue.capitalized) · \(filesProcessed.formatted()) files processed\(location)"
    }
}

public actor ShareIndex {
    public nonisolated let progress: AsyncStream<ShareScanProgress>
    private let progressContinuation: AsyncStream<ShareScanProgress>.Continuation
    private var files: [String: IndexedFile] = [:]
    /// Word index answering the network's constant stream of searches without scanning every file.
    private var entries: [IndexedFile] = []
    private var postings: [String: [Int]] = [:]
    private var scanRevision: UInt64 = 0
    public private(set) var queryRootResolutions = 0
    public private(set) var metadataReads = 0
    private var metadataHints: [URL: ShareMetadataCache.Entry] = [:]
    private let metadataReader: @Sendable (URL, UInt64) -> [UInt32: UInt32]
    public private(set) var errors: [String] = []
    public private(set) var summaries: [String: ShareRootSummary] = [:]
    public init(metadataReader: (@Sendable (URL, UInt64) -> [UInt32: UInt32])? = nil) {
        self.metadataReader = metadataReader ?? { AudioMetadata.read($0, size: $1) }
        let pair = AsyncStream<ShareScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        progress = pair.stream; progressContinuation = pair.continuation
    }
    public func metadataCache() -> ShareMetadataCache {
        ShareMetadataCache(version: 1, entries: files.values.map {
            ShareMetadataCache.Entry(file: $0.file, sourceURL: $0.localURL, modified: $0.modified)
        })
    }
    public func restoreMetadataCache(_ cache: ShareMetadataCache) {
        guard cache.version == 1 else { return }
        // Do not hydrate files: a missing external mount must remain unadvertised.
        for entry in cache.entries { metadataHints[entry.sourceURL] = entry }
    }
    public func scan(folders: [(URL, Bool)], exclusions: [String] = []) async -> (Int, UInt64) {
        scanRevision &+= 1; let revision = scanRevision
        var next: [String: IndexedFile] = [:]
        var errors: [String] = []
        var status = ShareScanProgress(); status.revision = revision; status.phase = .scanning
        progressContinuation.yield(status)
        var lastUpdate = ContinuousClock.now
        var lastYield = ContinuousClock.now
        var total: UInt64 = 0
        var processed = 0
        var summaries: [String: ShareRootSummary] = [:]
        let manager = FileManager.default
        for (root, privateShare) in folders {
            status.folder = root.path; progressContinuation.yield(status)
            var summary = ShareRootSummary()
            var folderNames = Set<String>()
            defer { summary.folders = folderNames.count; summaries[root.path] = summary }
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isReadableKey, .contentModificationDateKey]
            guard let enumerator = manager.enumerator(at: resolved, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                errors.append("Cannot read \(root.path)"); continue
            }
            while let url = enumerator.nextObject() as? URL {
                processed += 1
                if processed % 128 == 0 || ContinuousClock.now - lastYield >= .milliseconds(8) {
                    await Task.yield(); lastYield = .now
                }
                guard revision == scanRevision else { return (files.count, files.values.reduce(0) { $0 + $1.file.size }) }
                if Task.isCancelled {
                    status.phase = .cancelled; progressContinuation.yield(status)
                    return (files.count, files.values.reduce(0) { $0 + $1.file.size })
                }
                do {
                    if exclusions.contains(where: { fnmatch($0, url.lastPathComponent, FNM_CASEFOLD) == 0 }) {
                        enumerator.skipDescendants(); continue
                    }
                    let values = try url.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard values.isRegularFile == true, values.isReadable == true, url.pathExtension.lowercased() != "partial" else { continue }
                    status.filesProcessed += 1
                    if ContinuousClock.now - lastUpdate >= .milliseconds(100) {
                        status.folder = url.deletingLastPathComponent().path
                        progressContinuation.yield(status); lastUpdate = .now
                    }
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                    guard canonical.path.hasPrefix(resolved.path + "/") else { continue }
                    let relative = String(canonical.path.dropFirst(resolved.path.count + 1)).replacingOccurrences(of: "/", with: "\\")
                    let path = resolved.lastPathComponent + "\\" + relative
                    guard next[path] == nil else { errors.append("Duplicate share path: \(path)"); continue }
                    let size = UInt64(max(0, values.fileSize ?? 0))
                    let attributes: [UInt32: UInt32]
                    if let previous = files[path], previous.localURL == canonical, previous.file.size == size,
                       let modified = values.contentModificationDate, previous.modified == modified {
                        attributes = previous.file.attributes
                    } else if let hint = metadataHints[canonical], hint.file.path == path, hint.file.size == size,
                              let modified = values.contentModificationDate, hint.modified == modified {
                        attributes = hint.file.attributes
                    } else if !AudioMetadata.isAudio(name: canonical.lastPathComponent) {
                        attributes = [:]
                    } else {
                        metadataReads += 1
                        let reader = metadataReader
                        let read = Task.detached(priority: .utility) { reader(canonical, size) }
                        attributes = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
                        guard revision == scanRevision, !Task.isCancelled else { break }
                    }
                    let file = SharedFile(path: path, size: size, attributes: attributes)
                    next[path] = IndexedFile(file: file, localURL: canonical, buddyOnly: privateShare,
                                             modified: values.contentModificationDate, localPath: canonical.path)
                    total += size
                    summary.files += 1; summary.bytes += size; folderNames.insert(file.folder)
                    if AudioMetadata.isAudio(name: canonical.lastPathComponent) { summary.audioFiles += 1 }
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        guard revision == scanRevision, !Task.isCancelled else {
            if revision == scanRevision { status.phase = .cancelled; progressContinuation.yield(status) }
            return (files.count, files.values.reduce(0) { $0 + $1.file.size })
        }
        files = next; self.errors = errors
        rebuildWordIndex()
        metadataHints.removeAll()
        self.summaries = summaries
        status.phase = .completed; progressContinuation.yield(status)
        return (files.count, total)
    }
    public func library(allowPrivate: Bool = false, configuredFolders: [(URL, Bool)]? = nil) -> [String: [SharedFile]] {
        let roots = normalizedRoots(configuredFolders)
        return Dictionary(grouping: files.values.filter { allowed($0, privateAccess: allowPrivate, roots: roots) }.map(\.file), by: \.folder)
    }
    /// Soulseek-style matching: every plain term must be a whole word of the shared path, `-term` excludes
    /// files containing that word, and `*term` matches any word containing it.
    public func search(_ query: String, allowPrivate: Bool = false, limit: Int = 500, configuredFolders: [(URL, Bool)]? = nil) -> [SharedFile] {
        var required: [[Int]] = [], excluded = Set<Int>()
        for term in query.lowercased().split(whereSeparator: \.isWhitespace) {
            if term.hasPrefix("-") {
                for word in Self.words(term.dropFirst()) { excluded.formUnion(postings[word] ?? []) }
            } else if term.hasPrefix("*") {
                for part in Self.words(term.drop(while: { $0 == "*" })) {
                    var matches = Set<Int>()
                    for (word, list) in postings where word.contains(part) { matches.formUnion(list) }
                    required.append(matches.sorted())
                }
            } else {
                for word in Self.words(term) { required.append(postings[word] ?? []) }
            }
        }
        guard !required.isEmpty else { return [] }
        required.sort { $0.count < $1.count }
        var candidates = required[0]
        for list in required.dropFirst() where !candidates.isEmpty { candidates = Self.intersect(candidates, list) }
        guard candidates.contains(where: { !excluded.contains($0) }) else { return [] }
        let roots = normalizedRoots(configuredFolders)
        var output: [SharedFile] = []
        for index in candidates where !excluded.contains(index) {
            guard output.count < limit else { break }
            if allowed(entries[index], privateAccess: allowPrivate, roots: roots) { output.append(entries[index].file) }
        }
        return output
    }
    static func words<S: StringProtocol>(_ text: S) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
    private static func intersect(_ a: [Int], _ b: [Int]) -> [Int] {
        var output: [Int] = [], i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { output.append(a[i]); i += 1; j += 1 } else if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return output
    }
    private func rebuildWordIndex() {
        entries = Array(files.values)
        var next: [String: [Int]] = [:]
        for (index, item) in entries.enumerated() {
            for word in Set(Self.words(item.file.path)) { next[word, default: []].append(index) }
        }
        postings = next
    }
    public func resolve(_ path: String, allowPrivate: Bool = false, configuredFolders: [(URL, Bool)]? = nil) -> IndexedFile? {
        guard let item = files[path], allowed(item, privateAccess: allowPrivate, roots: normalizedRoots(configuredFolders)) else { return nil }
        return item
    }
    private func normalizedRoots(_ folders: [(URL, Bool)]?) -> [(String, Bool, Bool)]? {
        folders.map { folders in folders.map { root, buddyOnly in
            queryRootResolutions += 1
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            return (resolved.path + "/", buddyOnly, values?.isDirectory == true && values?.isReadable == true)
        } }
    }
    private func allowed(_ item: IndexedFile, privateAccess: Bool, roots: [(String, Bool, Bool)]?) -> Bool {
        guard let roots else { return privateAccess || !item.buddyOnly }
        let matches = roots.filter { item.localPath.hasPrefix($0.0) }
        guard let specific = matches.max(by: { $0.0.count < $1.0.count }) else { return false }
        return specific.2 && (privateAccess || !specific.1)
    }
}
