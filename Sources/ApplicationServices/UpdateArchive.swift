import Foundation
import Compression

public enum UpdateArchive {
    public static let compressedLimit = 128 * 1024 * 1024
    public static let expandedLimit = 512 * 1024 * 1024
    public static let entryLimit = 5_000

    /// Validate central AND local ZIP headers before allowing ditto to see attacker-controlled input.
    static func validate(_ archive: URL) throws -> String {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= compressedLimit else { throw UpdateError.unsafeArchive }
        return try validate(Data(contentsOf: archive, options: .mappedIfSafe))
    }

    static func validate(_ data: Data) throws -> String {
        guard data.count <= compressedLimit, data.count >= 22 else { throw UpdateError.unsafeArchive }
        func number(_ offset: Int, _ bytes: Int) throws -> UInt64 {
            guard offset >= 0, offset <= data.count - bytes else { throw UpdateError.unsafeArchive }
            return (0..<bytes).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func validateExtra(_ offset: Int, length: Int) throws {
            let end = offset + length
            var cursor = offset
            while cursor < end {
                guard cursor + 4 <= end else { throw UpdateError.unsafeArchive }
                let tag = try number(cursor, 2), size = Int(try number(cursor + 2, 2))
                guard [UInt64(0x5855), 0x5455, 0x7875, 0x000a].contains(tag), cursor + 4 + size <= end else { throw UpdateError.unsafeArchive }
                cursor += 4 + size
            }
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x06054b50, offset + 22 + Int(try number(offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw UpdateError.unsafeArchive }
        let count = Int(try number(end + 10, 2)), centralSize = Int(try number(end + 12, 4)), start = Int(try number(end + 16, 4))
        guard count > 0, count <= entryLimit, try number(end + 8, 2) == UInt64(count), start + centralSize == end else { throw UpdateError.unsafeArchive }
        let deadline = Date().addingTimeInterval(30)
        var cursor = start, expanded: UInt64 = 0, names = Set<String>(), roots = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard Date() < deadline else { throw UpdateError.timedOut }
            guard try number(cursor, 4) == 0x02014b50 else { throw UpdateError.unsafeArchive }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4)
            let compressed = try number(cursor + 20, 4), uncompressed = try number(cursor + 24, 4)
            let length = Int(try number(cursor + 28, 2)), extra = Int(try number(cursor + 30, 2)), comment = Int(try number(cursor + 32, 2))
            let attributes = try number(cursor + 38, 4), local = Int(try number(cursor + 42, 4))
            let nameStart = cursor + 46, next = nameStart + length + extra + comment
            guard next <= end, length > 0, flags & ~UInt64(0x080e) == 0,
                  method == 0 || method == 8, compressed != UInt32.max, uncompressed != UInt32.max,
                  try number(cursor + 34, 2) == 0,
                  let name = String(data: data[nameStart..<(nameStart + length)], encoding: .utf8) else { throw UpdateError.unsafeArchive }
            let mode = (attributes >> 16) & 0xf000
            try validateExtra(nameStart + length, length: extra)
            guard mode == 0 || mode == 0x8000 || mode == 0x4000,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !name.contains("\0"), names.insert(name.lowercased()).inserted else { throw UpdateError.unsafeArchive }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(".."), !components.contains("."), !components.dropLast().contains(""), let first = components.first,
                  first.hasSuffix(".app"), !components.dropFirst().contains(where: { $0.hasSuffix(".app") }) else { throw UpdateError.unsafeArchive }
            roots.insert(String(first))
            expanded += uncompressed
            guard expanded <= expandedLimit,
                  try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method,
                  try number(local + 26, 2) == UInt64(length) else { throw UpdateError.unsafeArchive }
            let localExtra = Int(try number(local + 28, 2)), localName = local + 30, body = localName + length + localExtra
            var bodyEnd = body + Int(compressed)
            guard bodyEnd <= start, localName + length <= data.count,
                  data[localName..<(localName + length)] == data[nameStart..<(nameStart + length)] else { throw UpdateError.unsafeArchive }
            try validateExtra(localName + length, length: localExtra)
            let localCRC = try number(local + 14, 4), localCompressed = try number(local + 18, 4), localExpanded = try number(local + 22, 4)
            if flags & 8 != 0 {
                guard (localCRC == 0 || localCRC == crc), (localCompressed == 0 || localCompressed == compressed),
                      (localExpanded == 0 || localExpanded == uncompressed), bodyEnd + 16 <= start,
                      try number(bodyEnd, 4) == 0x08074b50, try number(bodyEnd + 4, 4) == crc,
                      try number(bodyEnd + 8, 4) == compressed, try number(bodyEnd + 12, 4) == uncompressed else { throw UpdateError.unsafeArchive }
                bodyEnd += 16
            } else {
                guard localCRC == crc, localCompressed == compressed, localExpanded == uncompressed else { throw UpdateError.unsafeArchive }
            }
            if method == 0 {
                guard compressed == uncompressed else { throw UpdateError.unsafeArchive }
            } else {
                try validateDeflate(Data(data[body..<(body + Int(compressed))]), expectedSize: Int(uncompressed), deadline: deadline)
            }
            ranges.append(local..<bodyEnd)
            cursor = next
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard cursor == end, roots.count == 1, let root = roots.first,
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { throw UpdateError.unsafeArchive }
        return root
    }

    private static func validateDeflate(_ data: Data, expectedSize: Int, deadline: Date) throws {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        try data.withUnsafeBytes { source in
            try buffer.withUnsafeMutableBufferPointer { output in
                guard let destination = output.baseAddress, let input = source.bindMemory(to: UInt8.self).baseAddress else { throw UpdateError.unsafeArchive }
                var stream = compression_stream(dst_ptr: destination, dst_size: output.count, src_ptr: input, src_size: data.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw UpdateError.unsafeArchive }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = input; stream.src_size = data.count
                var count = 0
                while true {
                    guard Date() < deadline else { throw UpdateError.timedOut }
                    stream.dst_ptr = destination; stream.dst_size = output.count
                    let previous = stream.src_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = output.count - stream.dst_size
                    count += produced
                    guard count <= expectedSize else { throw UpdateError.unsafeArchive }
                    if status == COMPRESSION_STATUS_END {
                        guard stream.src_size == 0, count == expectedSize else { throw UpdateError.unsafeArchive }
                        return
                    }
                    guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size < previous else { throw UpdateError.unsafeArchive }
                }
            }
        }
    }
}

enum UpdateProcess {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 30) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                guard Date() < deadline else { throw UpdateError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard process.terminationStatus == 0 else { throw UpdateError.unreadable }
        } catch {
            if process.isRunning { process.terminate(); try? await Task.sleep(for: .milliseconds(100)); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            throw error
        }
    }
}
