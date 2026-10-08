import Foundation
import CZlib

public enum ProtocolError: Error, LocalizedError, Sendable {
    case truncated, oversized, invalid(String), disconnected
    public var errorDescription: String? {
        switch self {
        case .truncated: "Incomplete network message."
        case .oversized: "The peer sent a message exceeding the safety limit."
        case .invalid(let reason): reason
        case .disconnected: "The connection closed."
        }
    }
}

/// The server answered the login and refused it (wrong password, invalid name, full server). Retrying the
/// same credentials automatically cannot help, unlike a network failure.
public struct LoginRejected: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct WireWriter: Sendable {
    public private(set) var data = Data()
    public init() {}
    public mutating func byte(_ value: UInt8) { data.append(value) }
    public mutating func uint(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    public mutating func ulong(_ value: UInt64) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    public mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        uint(UInt32(bytes.count)); data.append(bytes)
    }
    public mutating func bytes(_ value: Data) { data.append(value) }
    public static func frame(code: UInt32, payload: Data, narrow: Bool = false) -> Data {
        var writer = WireWriter()
        writer.uint(UInt32(payload.count + (narrow ? 1 : 4)))
        if narrow { writer.byte(UInt8(truncatingIfNeeded: code)) } else { writer.uint(code) }
        writer.bytes(payload)
        return writer.data
    }
}

public struct WireReader: Sendable {
    private let data: Data
    public private(set) var offset = 0
    public var remaining: Int { data.count - offset }
    public init(_ data: Data) { self.data = data }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ProtocolError.truncated }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }
    public mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.truncated }
        defer { offset += 1 }; return data[data.startIndex + offset]
    }
    public mutating func uint() throws -> UInt32 {
        let value = try bytes(4)
        return value.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }
    public mutating func ulong() throws -> UInt64 {
        let value = try bytes(8)
        return value.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
    public mutating func string() throws -> String {
        let length = try uint()
        guard length <= 1_048_576 else { throw ProtocolError.oversized }
        let bytes = try bytes(Int(length))
        if let value = String(data: bytes, encoding: .utf8) { return value }
        guard let value = String(data: bytes, encoding: .isoLatin1) else {
            throw ProtocolError.invalid("Invalid string encoding.")
        }
        return value
    }
    public mutating func count(limit: UInt32 = 1_000_000) throws -> Int {
        let value = try uint()
        guard value <= limit else { throw ProtocolError.oversized }
        return Int(value)
    }
}

public enum Zlib {
    public static func inflate(_ data: Data, limit: Int = 64 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ProtocolError.invalid("Could not initialize decompression.")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(source.count)
            var output = Data()
            var block = [UInt8](repeating: 0, count: 65_536)
            while true {
                let status = block.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = block.count - Int(stream.avail_out)
                guard output.count + produced <= limit else { throw ProtocolError.oversized }
                output.append(contentsOf: block.prefix(produced))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else {
                    throw ProtocolError.invalid("Malformed compressed peer message.")
                }
            }
        }
    }
    public static func deflate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &length,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw ProtocolError.invalid("Compression failed.") }
        output.count = Int(length); return output
    }
}
