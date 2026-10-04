import Foundation
import UniformTypeIdentifiers
import AVFoundation

public enum PreviewFormat: Sendable, Equatable {
    case streamingAudio, audio, video, image, pdf
    public static let maximumBytes: UInt64 = 512 * 1024 * 1024
    private static let nativeMediaTypes = AVURLAsset.audiovisualContentTypes
    public static func classify(_ name: String) -> PreviewFormat? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["mp3", "flac", "wav", "wave", "aif", "aiff", "aifc"].contains(ext) { return .streamingAudio }
        if ["m4a", "m4b", "aac", "caf", "ac3", "mp4a", "au", "snd"].contains(ext) { return .audio }
        if ["mp4", "m4v", "mov", "mpeg", "mpg", "avi", "3gp", "3g2"].contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .image }
        if let type = UTType(filenameExtension: ext), nativeMediaTypes.contains(where: { type.conforms(to: $0) }) {
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) { return .video }
        }
        return nil
    }
    public var isAudio: Bool { self == .streamingAudio || self == .audio }
}
