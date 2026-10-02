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
    public static func search(_ data: Data) throws -> (UInt32, [SearchResult]) {
        var reader = WireReader(try Zlib.inflate(data, limit: 16 * 1024 * 1024))
        let user = try reader.string()
        guard user.utf8.count <= 256 else { throw ProtocolError.oversized }
        let token = try reader.uint()
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
    public static func library(user: String, data: Data) throws -> RemoteLibrary {
        var reader = WireReader(try Zlib.inflate(data))
        let folders = try readFolders(&reader)
        return RemoteLibrary(user: user, folders: folders)
    }
    public static func readFolders(_ reader: inout WireReader) throws -> [String: [SharedFile]] {
        let count = try reader.count(limit: 100_000)
        var folders: [String: [SharedFile]] = [:]
        var total = 0
        var materializedBytes = 0
        for _ in 0..<count {
            let folder = try reader.string()
            guard folder.utf8.count <= 4096 else { throw ProtocolError.oversized }
            let depth = folder.split(separator: "\\").count
            guard depth <= 64 else { throw ProtocolError.oversized }
            materializedBytes += (folder.utf8.count + 128) * max(1, depth)
            guard materializedBytes <= 32 * 1024 * 1024 else { throw ProtocolError.oversized }
            let fileCount = try reader.count()
            total += fileCount
            guard total <= 1_000_000 else { throw ProtocolError.oversized }
            var files = [SharedFile](); files.reserveCapacity(fileCount)
            for _ in 0..<fileCount {
                let file = try readFile(&reader, folder: folder)
                materializedBytes += file.path.utf8.count + 128
                guard materializedBytes <= 32 * 1024 * 1024 else { throw ProtocolError.oversized }
                files.append(file)
            }
            folders[folder] = files
        }
        return folders
    }
    public static func libraryReply(_ folders: [String: [SharedFile]]) throws -> Data {
        var writer = WireWriter(); writeFolders(folders, to: &writer)
        writer.uint(0); writer.uint(0)
        return try Zlib.deflate(writer.data)
    }
    public static func writeFolders(_ folders: [String: [SharedFile]], to writer: inout WireWriter) {
        writer.uint(UInt32(folders.count))
        for (folder, files) in folders.sorted(by: { $0.key < $1.key }) {
            writer.string(folder); writer.uint(UInt32(files.count))
            for file in files { writeFile(file, to: &writer, basename: true) }
        }
    }
}
