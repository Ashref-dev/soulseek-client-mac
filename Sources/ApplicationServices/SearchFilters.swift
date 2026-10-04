import Foundation
import SoulseekCore

extension SharedFile {
    public var bitrate: UInt32 { attributes[0] ?? 0 }
    public var length: UInt32 { attributes[1] ?? 0 }
    public var sampleRate: UInt32 { attributes[4] ?? 0 }
    public var bitDepth: UInt32 { attributes[5] ?? 0 }
    public var isAudio: Bool { ["FLAC", "MP3", "OGG", "OPUS", "M4A", "AAC", "WAV", "AIFF", "AIF", "ALAC", "APE", "WV"].contains(format) }
    public var isLossless: Bool { ["FLAC", "WAV", "AIFF", "AIF", "ALAC", "APE", "WV"].contains(format) || (isAudio && attributes[5] != nil) }
}

public enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
    case any, lossless, hiRes, kbps320, kbps256
    public var id: Self { self }
    public var title: String {
        switch self {
        case .any: "Any Quality"
        case .lossless: "Lossless"
        case .hiRes: "Hi-Res Lossless"
        case .kbps320: "320 kbps or Better"
        case .kbps256: "256 kbps or Better"
        }
    }
    public var detail: String {
        switch self {
        case .any: "Show everything"
        case .lossless: "FLAC, WAV, ALAC, AIFF, APE, WavPack"
        case .hiRes: "Lossless at 24-bit or more"
        case .kbps320: "Top MP3/AAC quality, or lossless"
        case .kbps256: "High-quality lossy, or lossless"
        }
    }
    public var symbol: String {
        switch self {
        case .any: "dial.low"
        case .lossless: "waveform"
        case .hiRes: "waveform.badge.plus"
        case .kbps320, .kbps256: "dial.high"
        }
    }
}

public struct ResultFilters: Equatable, Sendable {
    public var text = ""
    public var format = "Any"
    public var minBitrate = 0
    public var freeSlotsOnly = false
    public var audioOnly = false
    public var losslessOnly = false
    public var minimumSampleRate = 0
    public var minimumBitDepth = 0
    public var maximumMegabytes = 0
    public init() {}

    public var isActive: Bool { self != ResultFilters(text: text) || !text.isEmpty }
    public var hasAdvancedValues: Bool { audioOnly || minimumSampleRate > 0 || maximumMegabytes > 0 || preset == nil }

    init(text: String) { self.text = text }

    public var preset: QualityPreset? {
        switch (losslessOnly, minimumBitDepth, minBitrate, minimumSampleRate) {
        case (false, 0, 0, _): .any
        case (true, 0, 0, _): .lossless
        case (true, 24, 0, _): .hiRes
        case (false, 0, 320, _): .kbps320
        case (false, 0, 256, _): .kbps256
        default: nil
        }
    }

    public mutating func apply(_ preset: QualityPreset) {
        losslessOnly = [.lossless, .hiRes].contains(preset)
        minimumBitDepth = preset == .hiRes ? 24 : 0
        minBitrate = preset == .kbps320 ? 320 : preset == .kbps256 ? 256 : 0
    }

    public func matches(_ result: SearchResult) -> Bool {
        let file = result.file
        if freeSlotsOnly && !result.freeSlot { return false }
        if audioOnly && !file.isAudio { return false }
        if losslessOnly && !file.isLossless { return false }
        if format != "Any" && file.format != format { return false }
        if minBitrate > 0 && !file.isLossless && file.bitrate < minBitrate { return false }
        if minimumSampleRate > 0 && file.sampleRate < minimumSampleRate { return false }
        if minimumBitDepth > 0 && file.bitDepth < minimumBitDepth { return false }
        if maximumMegabytes > 0 && file.size > UInt64(maximumMegabytes) * 1_000_000 { return false }
        if !text.isEmpty {
            let haystack = file.path.lowercased() + " " + result.user.lowercased()
            for term in text.lowercased().split(separator: " ") {
                if term.hasPrefix("-") { if term.count > 1, haystack.contains(term.dropFirst()) { return false } }
                else if !haystack.contains(term) { return false }
            }
        }
        return true
    }
}

public enum SearchAutoStop {
    public static let maximumSeconds: Double = 120
    public static func shouldStop(started: Date, lastActivity: Date, now: Date, idleSeconds: Int) -> Bool {
        guard idleSeconds > 0 else { return false }
        return now.timeIntervalSince(lastActivity) >= Double(idleSeconds)
            || now.timeIntervalSince(started) >= max(maximumSeconds, Double(idleSeconds))
    }
}
