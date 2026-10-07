import SwiftUI
import AppKit
import CoreGraphics
import ArpeggioServices

/// The presence bird: an original geometric songbird built from ellipses, curves and a forked tail.
/// Wings extended means Available, wings folded means Away, and a muted folded bird means offline.
/// It marks presence only; the app icon and the menu bar icon stay the Arpeggio mark.
enum BirdPose: Sendable, Equatable { case extended, folded }

struct BirdState: Sendable, Equatable {
    let pose: BirdPose
    let muted: Bool

    init(pose: BirdPose, muted: Bool) { self.pose = pose; self.muted = muted }

    init(presence: Presence) {
        switch presence {
        case .available: self.init(pose: .extended, muted: false)
        case .away: self.init(pose: .folded, muted: false)
        case .offline: self.init(pose: .folded, muted: true)
        }
    }

    var label: String {
        switch (pose, muted) {
        case (_, true): "Offline"
        case (.extended, false): "Available"
        case (.folded, false): "Away"
        }
    }
}

/// Paths live in a unit square with y pointing down, facing right. Both poses share the body, head and tail,
/// so switching state moves only the wings. The eye is a counter: fill with the nonzero rule after the unions.
enum BirdMark {
    nonisolated(unsafe) static let extended = make(.extended)
    nonisolated(unsafe) static let folded = make(.folded)

    static func path(_ pose: BirdPose) -> CGPath { pose == .extended ? extended : folded }

    /// Maps the unit square onto the largest centred square inside `rect`.
    static func transform(into rect: CGRect) -> CGAffineTransform {
        let side = min(rect.width, rect.height)
        return CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2).scaledBy(x: side, y: side)
    }

    static func path(_ pose: BirdPose, in rect: CGRect) -> CGPath {
        var transform = transform(into: rect)
        return path(pose).copy(using: &transform) ?? path(pose)
    }

    private static func make(_ pose: BirdPose) -> CGPath {
        let body = ellipse(center: CGPoint(x: 0.48, y: 0.63), width: 0.50, height: 0.30, degrees: -22)
        let head = CGPath(ellipseIn: CGRect(x: 0.587, y: 0.317, width: 0.236, height: 0.236), transform: nil)
        let beak = CGMutablePath()
        beak.move(to: CGPoint(x: 0.80, y: 0.385))
        beak.addQuadCurve(to: CGPoint(x: 0.95, y: 0.44), control: CGPoint(x: 0.90, y: 0.40))
        beak.addLine(to: CGPoint(x: 0.80, y: 0.48))
        beak.closeSubpath()
        let tail = CGMutablePath()
        tail.addLines(between: [CGPoint(x: 0.34, y: 0.62), CGPoint(x: 0.08, y: 0.66), CGPoint(x: 0.15, y: 0.735),
                                CGPoint(x: 0.10, y: 0.81), CGPoint(x: 0.36, y: 0.73)])
        tail.closeSubpath()
        var shape = body.union(head).union(beak).union(tail)
        switch pose {
        case .extended:
            let near = CGMutablePath()
            near.move(to: CGPoint(x: 0.62, y: 0.52))
            near.addQuadCurve(to: CGPoint(x: 0.17, y: 0.08), control: CGPoint(x: 0.53, y: 0.15))
            near.addQuadCurve(to: CGPoint(x: 0.36, y: 0.60), control: CGPoint(x: 0.20, y: 0.42))
            near.closeSubpath()
            let far = CGMutablePath()
            far.move(to: CGPoint(x: 0.67, y: 0.49))
            far.addQuadCurve(to: CGPoint(x: 0.55, y: 0.04), control: CGPoint(x: 0.71, y: 0.19))
            far.addQuadCurve(to: CGPoint(x: 0.48, y: 0.55), control: CGPoint(x: 0.45, y: 0.30))
            far.closeSubpath()
            shape = shape.union(near).union(far)
        case .folded:
            let wing = CGMutablePath()
            wing.move(to: CGPoint(x: 0.66, y: 0.47))
            wing.addQuadCurve(to: CGPoint(x: 0.13, y: 0.70), control: CGPoint(x: 0.36, y: 0.38))
            wing.addQuadCurve(to: CGPoint(x: 0.63, y: 0.60), control: CGPoint(x: 0.36, y: 0.71))
            wing.closeSubpath()
            // A tapered crescent under the folded wing keeps it readable inside the body silhouette.
            let fold = CGMutablePath()
            fold.move(to: CGPoint(x: 0.64, y: 0.585))
            fold.addQuadCurve(to: CGPoint(x: 0.15, y: 0.705), control: CGPoint(x: 0.37, y: 0.68))
            fold.addQuadCurve(to: CGPoint(x: 0.64, y: 0.585), control: CGPoint(x: 0.38, y: 0.76))
            fold.closeSubpath()
            shape = shape.union(wing).subtracting(fold)
        }
        let eye = CGPath(ellipseIn: CGRect(x: 0.71, y: 0.38, width: 0.06, height: 0.06), transform: nil)
        return shape.subtracting(eye)
    }

    private static func ellipse(center: CGPoint, width: CGFloat, height: CGFloat, degrees: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), transform: &transform)
    }
}

/// Bitmaps of the bird for menus and tests. Brand purple for Available and Away, a quiet grey for offline.
enum BirdGlyph {
    static func color(_ state: BirdState) -> CGColor {
        let tone = state.muted ? BrandTone.muted : BrandTone.purple
        return CGColor(srgbRed: tone.red, green: tone.green, blue: tone.blue, alpha: 1)
    }

    /// A non-template menu image, so the purple survives inside menus. Offline uses the dynamic secondary
    /// label colour, resolved at draw time for light and dark menus.
    @MainActor static func image(_ state: BirdState, side: CGFloat = 16) -> NSImage {
        let image = NSImage(size: CGSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(BirdMark.path(state.pose, in: rect))
            context.setFillColor(state.muted ? NSColor.secondaryLabelColor.cgColor : color(state))
            context.fillPath()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.label
        return image
    }

    /// Renders the bird into a transparent square bitmap of `pixels` per side with fixed colours.
    static func render(_ state: BirdState, pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = CGFloat(pixels)
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.addPath(BirdMark.path(state.pose, in: CGRect(x: 0, y: 0, width: side, height: side)))
        context.setFillColor(color(state))
        context.fillPath()
        return context.makeImage()
    }
}

struct BirdShape: Shape {
    var pose: BirdPose
    func path(in rect: CGRect) -> Path { Path(BirdMark.path(pose, in: rect)) }
}

/// The bird as a SwiftUI presence indicator, sized like a symbol.
struct PresenceBird: View {
    let presence: Presence
    var size: CGFloat = 18
    /// Hide from VoiceOver when adjacent text already names the status.
    var decorative = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = BirdState(presence: presence)
        BirdShape(pose: state.pose)
            .fill(state.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.arpeggio))
            .frame(width: size, height: size)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: state)
            .accessibilityElement()
            .accessibilityLabel("Status: \(state.label)")
            .accessibilityHidden(decorative)
    }
}
