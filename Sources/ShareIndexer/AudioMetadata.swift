import AVFoundation
import Foundation

enum AudioMetadata {
    static func read(_ url: URL, size: UInt64) -> [UInt32: UInt32] {
        let ext = url.pathExtension.lowercased()
        guard ["flac", "wav", "aiff", "aif", "mp3", "m4a", "aac", "alac"].contains(ext),
              let audio = try? AVAudioFile(forReading: url) else { return [:] }
        let format = audio.fileFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, rate <= Double(UInt32.max) else { return [:] }
        let duration = Double(audio.length) / rate
        var attributes: [UInt32: UInt32] = [:]
        if duration.isFinite, duration > 0, duration <= Double(UInt32.max) { attributes[1] = UInt32(duration) }
        if ["flac", "wav", "aiff", "aif", "alac"].contains(ext) {
            attributes[4] = UInt32(rate)
            let depth = format.streamDescription.pointee.mBitsPerChannel
            if depth >= 8, depth <= 64 { attributes[5] = depth }
        } else if duration > 0 {
            let bitrate = Double(size) * 8 / duration / 1000
            if bitrate.isFinite, bitrate > 0, bitrate <= Double(UInt32.max) { attributes[0] = UInt32(bitrate.rounded()) }
        }
        return attributes
    }
}
