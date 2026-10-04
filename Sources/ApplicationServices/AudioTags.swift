import Foundation

public struct TrackMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: String?
    public var artwork: Data?
    /// True once tag reading finished, so a missing value means "not in the file" rather than "not read yet".
    public var resolved = false
    public init() {}
    mutating func fill(from other: TrackMetadata) {
        title = title ?? other.title; artist = artist ?? other.artist
        album = album ?? other.album; year = year ?? other.year; artwork = artwork ?? other.artwork
    }
}

/// Reads Vorbis comments and embedded pictures from the FLAC header. AVFoundation doesn't surface
/// FLAC picture blocks reliably, and the header sits at the start of the file, so a stream can be read early.
public enum FLACTags {
    public enum Outcome: Equatable, Sendable { case notFLAC, needMoreData, parsed(TrackMetadata) }

    public static func parse(_ data: Data) -> Outcome {
        guard data.count >= 4 else { return .needMoreData }
        guard data.prefix(4) == Data("fLaC".utf8) else { return .notFLAC }
        var tags = TrackMetadata()
        var cover: (type: UInt32, data: Data)?
        var offset = 4
        while true {
            guard offset + 4 <= data.count else { return .needMoreData }
            let header = data[data.startIndex + offset]
            let last = header & 0x80 != 0
            let type = header & 0x7F
            let length = Int(data[data.startIndex + offset + 1]) << 16 | Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
            offset += 4
            guard offset + length <= data.count else { return .needMoreData }
            let block = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + length)
            if type == 4 { comments(block, into: &tags) }
            if type == 6, let picture = picture(block), cover == nil || (picture.type == 3 && cover?.type != 3) { cover = picture }
            offset += length
            if last || type == 127 { break }
        }
        tags.artwork = cover?.data
        tags.resolved = true
        return .parsed(tags)
    }

    private static func comments(_ block: Data, into tags: inout TrackMetadata) {
        var reader = ByteReader(block)
        guard let vendor = reader.uint32LE(), reader.skip(Int(vendor)), let count = reader.uint32LE() else { return }
        for _ in 0..<min(count, 4096) {
            guard let length = reader.uint32LE(), let bytes = reader.bytes(Int(length)),
                  let entry = String(data: bytes, encoding: .utf8), let equals = entry.firstIndex(of: "=") else { return }
            let key = entry[..<equals].uppercased(); let value = String(entry[entry.index(after: equals)...])
            guard !value.isEmpty else { continue }
            switch key {
            case "TITLE": tags.title = tags.title ?? value
            case "ARTIST", "ALBUMARTIST": tags.artist = tags.artist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case "DATE", "YEAR": tags.year = tags.year ?? String(value.prefix(4))
            default: break
            }
        }
    }

    private static func picture(_ block: Data) -> (type: UInt32, data: Data)? {
        var reader = ByteReader(block)
        guard let type = reader.uint32BE(), let mime = reader.uint32BE(), reader.skip(Int(mime)),
              let description = reader.uint32BE(), reader.skip(Int(description)), reader.skip(16),
              let length = reader.uint32BE(), let bytes = reader.bytes(Int(length)), !bytes.isEmpty else { return nil }
        return (type, bytes)
    }
}

private struct ByteReader {
    let data: Data
    var position = 0
    init(_ data: Data) { self.data = data }
    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, position + count <= data.count else { return nil }
        defer { position += count }
        return data.subdata(in: data.startIndex + position ..< data.startIndex + position + count)
    }
    mutating func skip(_ count: Int) -> Bool { bytes(count) != nil }
    mutating func uint32LE() -> UInt32? { bytes(4).map { $0.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } } }
    mutating func uint32BE() -> UInt32? { bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } } }
}
