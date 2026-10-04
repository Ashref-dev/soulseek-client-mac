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

public enum MenuGlyphGeometry {
    public static let canvas = CGSize(width: 20, height: 18)
    public static let mark = CGRect(x: 2.5, y: 1.5, width: 15, height: 15)
    public static let badge = CGRect(x: 14, y: 11, width: 5.5, height: 5.5)
}
