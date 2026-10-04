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
    public static let incompleteFolder = ".arpeggio-incomplete"

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

    /// Plans where a download will finish and where its bytes collect meanwhile. Nothing is created
    /// below the root until the file completes, so cancelled downloads leave no empty folders.
    public static func plan(root: URL, user: String, remotePath: String, layout: DownloadLayout = DownloadLayout()) throws -> (destination: URL, partial: URL) {
        let parts = try relativeComponents(user: user, remotePath: remotePath, layout: layout)
        let base = root.standardizedFileURL
        guard base.path == base.resolvingSymlinksInPath().path else { throw FileSafetyError.symbolicLink }
        let incomplete = base.appendingPathComponent(incompleteFolder, isDirectory: true)
        try ensureDirectory(incomplete)
        let destination = parts.reduce(base) { $0.appendingPathComponent($1) }
        let hash = SHA256.hash(data: Data((user + "\0" + remotePath).utf8)).map { String(format: "%02x", $0) }.joined()
        let partial = incomplete.appendingPathComponent("\(hash).partial")
        if FileManager.default.fileExists(atPath: partial.path) {
            let values = try partial.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw FileSafetyError.symbolicLink }
        }
        return (destination, partial)
    }

    /// Moves a finished file into place, creating its folder and picking "Name (2).ext" if the name is taken.
    public static func publish(_ source: URL, to destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try ensureDirectory(directory)
        let target = available(destination)
        try FileManager.default.moveItem(at: source, to: target)
        return target
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
