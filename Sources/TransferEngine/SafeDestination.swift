import Foundation
import CryptoKit
import Persistence

public enum FileSafetyError: Error, LocalizedError {
    case unsafePath, symbolicLink, sizeMismatch
    public var errorDescription: String? {
        switch self {
        case .unsafePath: "This file has an unsafe name or path and cannot be downloaded."
        case .symbolicLink: "The destination contains a symbolic link. Choose another download folder."
        case .sizeMismatch: "The file size changed. Remove the partial file before retrying."
        }
    }
}

public enum SafeDestination {
    public static let incompleteFolder = "Incomplete"
    /// Hidden folder used before 0.6.1. Its partial files move to `incompleteFolder` on restore.
    static let legacyIncompleteFolder = ".arpeggio-incomplete"
    public static let partialExtension = "partial"

    public static func components(user: String, remotePath: String) throws -> [String] {
        guard !remotePath.hasPrefix("/"), !remotePath.hasPrefix("\\"), !remotePath.contains(":") else { throw FileSafetyError.unsafePath }
        let parts = remotePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let all = [user] + parts
        guard !parts.isEmpty, all.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && component.utf8.count <= 240 &&
            !component.lowercased().hasPrefix(".arpeggio-") &&
            !component.contains("/") && !component.contains("\\") && !component.contains(":") &&
            !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw FileSafetyError.unsafePath }
        return all
    }

    /// Path below the download folder. By default only the album folder is kept (plus its parent for
    /// "Disc 1"-style folders), so downloads don't recreate the sharer's whole directory tree.
    public static func relativeComponents(user: String, remotePath: String, layout: DownloadLayout) throws -> [String] {
        let all = try components(user: user, remotePath: remotePath)
        let folders = Array(all.dropFirst().dropLast())
        let kept: [String]
        if layout.fullPaths || folders.count < 2 { kept = folders }
        else if isDiscFolder(folders[folders.count - 1]) { kept = Array(folders.suffix(2)) }
        else { kept = [folders[folders.count - 1]] }
        return (layout.userFolders ? [user] : []) + kept + [all[all.count - 1]]
    }

    static func isDiscFolder(_ name: String) -> Bool {
        name.lowercased().wholeMatch(of: /(cd|dis[ck]|side|vol(ume)?)[\s._-]*([0-9]{1,2}|[a-d])\b.*/) != nil
    }

    /// Plans where a download will finish and where its bytes collect meanwhile. Unfinished bytes live in the
    /// visible Incomplete folder; the album folder is only created when the file completes.
    public static func plan(root: URL, user: String, remotePath: String, layout: DownloadLayout = DownloadLayout()) throws -> (destination: URL, partial: URL) {
        let parts = try relativeComponents(user: user, remotePath: remotePath, layout: layout)
        let base = root.standardizedFileURL
        guard base.path == base.resolvingSymlinksInPath().path else { throw FileSafetyError.symbolicLink }
        let incomplete = base.appendingPathComponent(incompleteFolder, isDirectory: true)
        try ensureDirectory(incomplete)
        let destination = parts.reduce(base) { $0.appendingPathComponent($1) }
        let partial = incomplete.appendingPathComponent(partialName(user: user, remotePath: remotePath, fileName: parts[parts.count - 1]))
        if FileManager.default.fileExists(atPath: partial.path) {
            let values = try partial.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw FileSafetyError.symbolicLink }
        }
        return (destination, partial)
    }

    /// Readable partial name, "Song [1a2b3c4d5e6f7a8b].flac.partial". The tag comes from the peer and remote path,
    /// so two people's copies of the same song never share a partial file.
    static func partialName(user: String, remotePath: String, fileName: String) -> String {
        let hash = SHA256.hash(data: Data((user + "\0" + remotePath).utf8)).map { String(format: "%02x", $0) }.joined()
        var stem = (fileName as NSString).deletingPathExtension
        var ext = (fileName as NSString).pathExtension
        if ext.utf8.count > 16 { stem = fileName; ext = "" }
        while stem.hasPrefix(".") { stem.removeFirst() }
        let suffix = " [\(hash.prefix(16))]" + (ext.isEmpty ? "" : "." + ext) + "." + partialExtension
        while (stem + suffix).decomposedStringWithCanonicalMapping.utf8.count > 250 && !stem.isEmpty { stem.removeLast() }
        return (stem.isEmpty ? "Download" : stem) + suffix
    }

    /// Moves a partial file left in the pre-0.6.1 hidden folder next to it into the visible Incomplete folder.
    /// Returns the new location, or nil when the path is not a legacy partial or it cannot move safely.
    static func migrateLegacyPartial(_ partial: URL, user: String, remotePath: String) -> URL? {
        let legacy = partial.deletingLastPathComponent()
        guard legacy.lastPathComponent == legacyIncompleteFolder,
              let parts = try? relativeComponents(user: user, remotePath: remotePath, layout: DownloadLayout()) else { return nil }
        let incomplete = legacy.deletingLastPathComponent().appendingPathComponent(incompleteFolder, isDirectory: true)
        let target = incomplete.appendingPathComponent(partialName(user: user, remotePath: remotePath, fileName: parts[parts.count - 1]))
        let manager = FileManager.default
        let oldExists = manager.fileExists(atPath: partial.path), newExists = manager.fileExists(atPath: target.path)
        defer { removeIncompleteFolderIfEmpty(legacy) }
        if !oldExists && newExists { return target }
        guard oldExists && !newExists else { return nil }
        do {
            try ensureDirectory(incomplete)
            try manager.moveItem(at: partial, to: target)
            return target
        } catch { return nil }
    }

    /// Moves a finished file into place, creating its folder and picking "Name (2).ext" if the name is taken.
    /// An Incomplete folder left empty by the move is removed, so it only exists while something is unfinished.
    public static func publish(_ source: URL, to destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try ensureDirectory(directory)
        let target = available(destination)
        try FileManager.default.moveItem(at: source, to: target)
        removeIncompleteFolderIfEmpty(source.deletingLastPathComponent())
        return target
    }

    /// Removes an Incomplete folder holding nothing but Finder's .DS_Store. rmdir refuses non-empty folders,
    /// so a partial file created meanwhile is never lost.
    static func removeIncompleteFolderIfEmpty(_ folder: URL) {
        guard [incompleteFolder, legacyIncompleteFolder].contains(folder.lastPathComponent),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              names.allSatisfy({ $0 == ".DS_Store" }) else { return }
        for name in names { unlink(folder.appendingPathComponent(name).path) }
        rmdir(folder.path)
    }

    public static func available(_ destination: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return destination }
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 2
        var candidate = destination
        repeat {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : "." + ext))
            suffix += 1
        } while manager.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Creates missing folders one level at a time, refusing to pass through symbolic links.
    static func ensureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        var existing = directory.standardizedFileURL
        var missing: [String] = []
        while !manager.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            let parent = existing.deletingLastPathComponent()
            guard parent != existing else { break }
            existing = parent
        }
        guard existing.resolvingSymlinksInPath().path == existing.path,
              (try? existing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw FileSafetyError.symbolicLink }
        for name in missing {
            existing.appendPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: existing, withIntermediateDirectories: false)
        }
    }
}
