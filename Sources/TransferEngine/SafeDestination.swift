import Foundation
import CryptoKit

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
    public static func prepare(root: URL, user: String, remotePath: String) throws -> (URL, URL) {
        let parts = try components(user: user, remotePath: remotePath)
        let manager = FileManager.default
        let base = root.standardizedFileURL
        guard base == base.resolvingSymlinksInPath() else { throw FileSafetyError.symbolicLink }
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        var directory = base
        for part in parts.dropLast() {
            directory.appendPathComponent(part, isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { throw FileSafetyError.symbolicLink }
            } else { try manager.createDirectory(at: directory, withIntermediateDirectories: false) }
        }
        guard let name = parts.last else { throw FileSafetyError.unsafePath }
        var destination = directory.appendingPathComponent(name)
        if manager.fileExists(atPath: destination.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var suffix = 2
            repeat {
                destination = directory.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : "." + ext))
                suffix += 1
            } while manager.fileExists(atPath: destination.path)
        }
        let hash = SHA256.hash(data: Data((user + "\0" + remotePath).utf8)).map { String(format: "%02x", $0) }.joined()
        let partial = directory.appendingPathComponent(".arpeggio-\(hash).partial")
        if manager.fileExists(atPath: partial.path) {
            let values = try partial.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw FileSafetyError.symbolicLink }
        }
        return (destination, partial)
    }
}
