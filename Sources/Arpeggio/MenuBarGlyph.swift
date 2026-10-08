import SwiftUI
import AppKit
import ArpeggioServices

/// The menu bar icon: the Arpeggio mark as a template image, one static glyph per MenuBarState.
/// Offline dims the mark and Away adds a small crescent. While bytes move, the chord fills in and the
/// arpeggio line takes the notation arrow for its roll: down for downloading, up for uploading, or both.
enum MenuBarGlyph {
    /// Every variant uses the plain mark's placement, so changing state never moves or rescales the mark.
    private static let placement = ArpeggioMark.transform(into: MenuGlyphGeometry.mark, fit: true)

    @MainActor private static var images: [MenuBarState: NSImage] = [:]

    /// The template image for `state`, built once per state and reused, so the label never redraws paths.
    @MainActor static func image(_ state: MenuBarState) -> NSImage {
        if let image = images[state] { return image }
        let image = NSImage(size: MenuGlyphGeometry.canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        images[state] = image
        return image
    }

    /// Draws `state` in black on the canvas, in points with y pointing down.
    static func draw(_ state: MenuBarState, in context: CGContext) {
        var transform = placement
        let wave = ArpeggioMark.wave(arrowUp: state.isUploading, arrowDown: state.isDownloading)
        context.setFillColor(CGColor(gray: 0, alpha: state == .offline ? 0.4 : 1))
        context.addPath(wave.copy(using: &transform) ?? wave)
        context.fillPath()
        for note in ArpeggioMark.notes(filled: state.isTransferring) { context.addPath(note.copy(using: &transform) ?? note) }
        context.fillPath(using: .evenOdd)
        guard state == .away else { return }
        let moon = crescent(in: MenuGlyphGeometry.badge)
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(MenuGlyphGeometry.badgeHalo * 2)
        context.addPath(moon)
        context.strokePath()
        context.restoreGState()
        context.addPath(moon)
        context.fillPath()
    }

    /// The template's alpha, rendered at `scale` pixels per point, for tests and offscreen previews.
    static func render(_ state: MenuBarState, scale: CGFloat) -> CGImage? {
        let width = Int((MenuGlyphGeometry.canvas.width * scale).rounded()), height = Int((MenuGlyphGeometry.canvas.height * scale).rounded())
        guard scale > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(state, in: context)
        return context.makeImage()
    }

    private static func crescent(in rect: CGRect) -> CGPath {
        let disc = CGPath(ellipseIn: rect, transform: nil)
        let shade = CGPath(ellipseIn: rect.offsetBy(dx: rect.width * 0.38, dy: -rect.height * 0.28), transform: nil)
        return disc.subtracting(shade)
    }
}

/// The Arpeggio mark as a SwiftUI view, coloured by the foreground style.
struct ArpeggioLogo: View {
    var body: some View {
        ArpeggioMarkShape()
            .fill(style: FillStyle(eoFill: true))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct ArpeggioMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var transform = ArpeggioMark.transform(into: rect, fit: true)
        return Path(ArpeggioMark.combined.copy(using: &transform) ?? ArpeggioMark.combined)
    }
}
