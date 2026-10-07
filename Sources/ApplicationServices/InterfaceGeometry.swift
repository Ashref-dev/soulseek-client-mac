import Foundation
import CoreGraphics

public struct PlayerWidthAllocation: Sendable, Equatable {
    public let content: Double
    public let transport: Double
    public let actions: Double
    public let showsMetadataChips: Bool
    public init(width: Double) {
        content = max(0, width.isFinite ? width - 32 : 0)
        actions = content >= 768 ? 240 : min(120, content * 0.3)
        transport = max(0, content - actions - 16)
        showsMetadataChips = content >= 640
    }
}

/// Chooses the player's form from the detail area it sits in. Short windows get a single-row player so the
/// content above keeps most of the height; taller windows keep the two-row player with metadata.
public struct PlayerLayout: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case regular, compact }
    public static let regularHeight: Double = 160
    public static let compactHeight: Double = 60
    /// Detail areas shorter than this use the compact player. The 880 x 560 minimum window leaves about 500.
    public static let compactBelowHeight: Double = 640
    public let mode: Mode
    public var height: Double { mode == .compact ? Self.compactHeight : Self.regularHeight }

    public init(detailHeight: Double) {
        mode = detailHeight.isFinite && detailHeight >= Self.compactBelowHeight ? .regular : .compact
    }
}

/// Widths for the single-row player: cover, title, transport, scrubber and actions side by side.
public struct CompactPlayerAllocation: Sendable, Equatable {
    public static let padding: Double = 16
    public static let spacing: Double = 12
    public static let cover: Double = 36
    public static let transport: Double = 96
    public static let minimumScrubber: Double = 80
    public let content: Double
    public let actions: Double
    public let info: Double
    public let scrubber: Double
    public let showsInfo: Bool
    public let showsTimes: Bool

    public init(width: Double) {
        content = max(0, width.isFinite ? width - 2 * Self.padding : 0)
        actions = content >= 840 ? 240 : 96
        let available = max(0, content - Self.cover - Self.transport - actions - 4 * Self.spacing)
        let preferred = min(280, max(140, available * 0.42))
        info = max(0, min(preferred, available - Self.minimumScrubber))
        scrubber = available - info
        showsInfo = info >= 100
        showsTimes = scrubber >= 220
    }

    public var used: Double { Self.cover + Self.transport + actions + info + scrubber + 4 * Self.spacing }
}

/// Where the confirmation toast sits: above the measured player, never over it.
public enum ToastGeometry {
    public static let gap: Double = 18
    /// Upper bound of the toast capsule: a 22 pt symbol or two text lines plus 10 pt padding above and below.
    public static let maximumHeight: Double = 52

    public static func bottomPadding(playerHeight: Double?) -> Double {
        guard let playerHeight, playerHeight.isFinite, playerHeight > 0 else { return gap }
        return playerHeight + gap
    }

    /// True when a toast of `toastHeight` fits between the player and the top of a detail area of `detailHeight`.
    public static func fits(detailHeight: Double, playerHeight: Double?, toastHeight: Double = maximumHeight) -> Bool {
        bottomPadding(playerHeight: playerHeight) + toastHeight <= detailHeight
    }
}

public enum MenuGlyphGeometry {
    public static let canvas = CGSize(width: 20, height: 18)
    public static let mark = CGRect(x: 2.5, y: 1.5, width: 15, height: 15)
    public static let badge = CGRect(x: 14, y: 11, width: 5.5, height: 5.5)
}
