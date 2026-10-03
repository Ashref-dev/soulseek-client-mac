import Foundation

public enum PeerCodec {
    public static func nextBranchLevel(_ level: UInt32) throws -> UInt32 {
        guard level < 1000 else { throw ProtocolError.invalid("Invalid distributed branch level.") }
        return level + 1
    }
    public static func readFile(_ reader: inout WireReader, folder: String? = nil) throws -> SharedFile {
        _ = try reader.byte()
        let name = try reader.string()
        guard name.utf8.count <= 4096 else { throw ProtocolError.oversized }
        let size = try reader.ulong()
        guard size <= 16 * 1024 * 1024 * 1024 else { throw ProtocolError.oversized }
        _ = try reader.string()
        let count = try reader.count(limit: 64)
        var attributes: [UInt32: UInt32] = [:]
        for _ in 0..<count { let key = try reader.uint(); attributes[key] = try reader.uint() }
        let path = folder.map { $0 + "\\" + name } ?? name
        guard path.utf8.count <= 8192 else { throw ProtocolError.oversized }
        guard path.split(separator: "\\").count <= 64 else { throw ProtocolError.oversized }
        return SharedFile(path: path, size: size, attributes: attributes)
    }
    public static func writeFile(_ file: SharedFile, to writer: inout WireWriter, basename: Bool = false) {
        writer.byte(1); writer.string(basename ? file.name : file.path); writer.ulong(file.size)
        writer.string((file.name as NSString).pathExtension)
        writer.uint(UInt32(file.attributes.count))
        for (key, value) in file.attributes.sorted(by: { $0.key < $1.key }) { writer.uint(key); writer.uint(value) }
    }
    public static func search(_ data: Data, allowedTokens: Set<UInt32>? = nil) throws -> (UInt32, [SearchResult]) {
        var reader = WireReader(try Zlib.inflate(data, limit: 16 * 1024 * 1024))
        let user = try reader.string()
        guard user.utf8.count <= 256 else { throw ProtocolError.oversized }
        let token = try reader.uint()
        if let allowedTokens, !allowedTokens.contains(token) { return (token, []) }
        let count = try reader.count(limit: 20_000)
        var files = [SharedFile](); files.reserveCapacity(count)
        for _ in 0..<count { files.append(try readFile(&reader)) }
        let free = try reader.byte() != 0
        let speed = try reader.uint()
        let queue = try reader.uint()
        return (token, files.map { SearchResult(user: user, file: $0, freeSlot: free, speed: speed, queue: queue) })
    }
    public static func searchReply(user: String, token: UInt32, files: [SharedFile], slots: Bool, speed: UInt32, queue: UInt32) throws -> Data {
        var writer = WireWriter()
        writer.string(user); writer.uint(token); writer.uint(UInt32(files.count))
        for file in files { writeFile(file, to: &writer) }
        writer.byte(slots ? 1 : 0); writer.uint(speed); writer.uint(queue); writer.uint(0); writer.uint(0)
        return try Zlib.deflate(writer.data)
    }
    public static func library(user: String, data: Data, limits: LibraryLimits = .standard) throws -> RemoteLibrary {
        var reader = WireReader(try Zlib.inflate(data, limit: limits.expandedBytes))
        let folders = try readFolders(&reader, limits: limits)
        return RemoteLibrary(user: user, folders: folders)
    }
    public static func readFolders(_ reader: inout WireReader, limits: LibraryLimits = .standard) throws -> [String: [SharedFile]] {
        let count = try reader.count(limit: 100_000)
        var folders: [String: [SharedFile]] = [:]
        var knownPaths: [String: Set<String>] = [:]
        var total = 0
        var materializedBytes = 0
        for _ in 0..<count {
            let folder = try reader.string()
            guard folder.utf8.count <= 4096 else { throw ProtocolError.oversized }
            let depth = folder.split(separator: "\\").count
            guard depth <= 64 else { throw ProtocolError.oversized }
            materializedBytes += (folder.utf8.count + 128) * max(1, depth)
            guard materializedBytes <= limits.modelBytes else { throw ProtocolError.invalid("The library hierarchy exceeds the \(limits.modelBytes / 1024 / 1024) MB memory budget.") }
            let fileCount = try reader.count()
            total += fileCount
            guard total <= 1_000_000 else { throw ProtocolError.oversized }
            if folders[folder] == nil { folders[folder] = []; knownPaths[folder] = [] }
            for _ in 0..<fileCount {
                let file = try readFile(&reader, folder: folder)
                materializedBytes += file.path.utf8.count + 128
                guard materializedBytes <= limits.modelBytes else { throw ProtocolError.invalid("The library file paths exceed the \(limits.modelBytes / 1024 / 1024) MB memory budget.") }
                if knownPaths[folder, default: []].insert(file.path).inserted {
                    folders[folder, default: []].append(file)
                }
            }
        }
        return folders
    }
    public static func libraryReply(_ folders: [String: [SharedFile]]) throws -> Data {
        let folders = folders.mapValues { $0.filter { $0.size <= 16 * 1024 * 1024 * 1024 } }
        try validateFolders(folders)
        var writer = WireWriter(); writeFolders(folders, to: &writer)
        writer.uint(0); writer.uint(0)
        return try Zlib.deflate(writer.data)
    }
    public static func validateFolders(_ folders: [String: [SharedFile]], limits: LibraryLimits = .large) throws {
        guard folders.count <= 100_000 else { throw ProtocolError.oversized }
        var count = 0; var bytes = 0
        for (path, files) in folders {
            let depth = path.split(separator: "\\").count
            guard path.utf8.count <= 4096, depth <= 64 else { throw ProtocolError.oversized }
            count += files.count; bytes += (path.utf8.count + 128) * max(1, depth)
            for file in files {
                guard file.path.utf8.count <= 8192, file.size <= 16 * 1024 * 1024 * 1024, file.attributes.count <= 64 else { throw ProtocolError.oversized }
                bytes += file.path.utf8.count + 128
            }
            guard count <= 1_000_000, bytes <= limits.modelBytes else { throw ProtocolError.oversized }
        }
    }
    public static func writeFolders(_ folders: [String: [SharedFile]], to writer: inout WireWriter) {
        writer.uint(UInt32(folders.count))
        for (folder, files) in folders.sorted(by: { $0.key < $1.key }) {
            writer.string(folder); writer.uint(UInt32(files.count))
            for file in files { writeFile(file, to: &writer, basename: true) }
        }
    }
}
