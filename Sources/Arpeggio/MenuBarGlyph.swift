import SwiftUI
import AppKit
import ArpeggioServices
import Persistence

/// The menu bar icon: the Arpeggio mark as a template image, one static glyph per MenuBarState.
/// Offline dims the mark and Away adds a small crescent. While bytes move, the chord fills in and the
/// arpeggio line takes the notation arrow for its roll: down for downloading, up for uploading, or both.
enum MenuBarGlyph {
    /// Every variant uses the plain mark's placement, so changing state never moves or rescales the mark.
    private static let placement = ArpeggioMark.transform(into: MenuGlyphGeometry.mark, fit: true)

    struct Key: Hashable { let style: MenuBarIconStyle; let state: MenuBarState }
    @MainActor private static var images: [Key: NSImage] = [:]

    /// The image for `state` in `style`, built once per pair and reused, so the label never redraws paths.
    /// Arpeggio is a template image; the classic bird keeps its colours.
    @MainActor static func image(_ state: MenuBarState, style: MenuBarIconStyle = .arpeggio) -> NSImage {
        let key = Key(style: style, state: state)
        if let image = images[key] { return image }
        let image = NSImage(size: MenuGlyphGeometry.canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            switch style {
            case .arpeggio: draw(state, in: context)
            case .classicBird: ClassicBirdGlyph.draw(state, in: context, scale: abs(context.userSpaceToDeviceSpaceTransform.a))
            }
            return true
        }
        image.isTemplate = style == .arpeggio
        image.accessibilityDescription = state.accessibilityLabel
        images[key] = image
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

/// The classic Soulseek bird in the menu bar, in colour: purple with wings open while available or moving
/// bytes, folded while away, red and folded while offline. Transfers add a small pixel arrow at the bottom
/// right: down, up, or both. One static glyph per state, on the same canvas as the Arpeggio style.
enum ClassicBirdGlyph {
    /// The bird's 13 by 12 point box. Whole points, so it lands on whole pixels at 1x and 2x.
    static let bird = CGRect(x: 3, y: 3, width: 13, height: 12)
    /// 1x arrows use one point per cell; 2x arrows use one device pixel per cell, matching the bird's grain.
    static let downArrow = PixelGrid(rows: ["..#..", "..#..", "#####", ".###.", "..#.."])
    static let upArrow = PixelGrid(rows: ["..#..", ".###.", "#####", "..#..", "..#.."])
    static let bothArrow = PixelGrid(rows: ["..#..", ".###.", "#####", "..#..", "#####", ".###.", "..#.."])
    static let fineDownArrow = PixelGrid(rows: ["...##...", "...##...", "...##...", "...##...", "########", ".######.", "..####..", "...##..."])
    static let fineUpArrow = PixelGrid(rows: ["...##...", "..####..", ".######.", "########", "...##...", "...##...", "...##...", "...##..."])
    static let fineBothArrow = PixelGrid(rows: ["...##...", "..####..", ".######.", "########", "...##...", "...##...", "...##...",
                                                "########", ".######.", "..####..", "...##..."])

    /// The arrow for `state` at `scale` and the size of one of its cells in points.
    static func arrow(_ state: MenuBarState, scale: CGFloat) -> (grid: PixelGrid, cell: CGFloat)? {
        let fine = scale >= 2
        switch (state.isDownloading, state.isUploading) {
        case (true, true): return fine ? (fineBothArrow, 1 / scale) : (bothArrow, 1)
        case (true, false): return fine ? (fineDownArrow, 1 / scale) : (downArrow, 1)
        case (false, true): return fine ? (fineUpArrow, 1 / scale) : (upArrow, 1)
        case (false, false): return nil
        }
    }

    /// The arrow's top-left corner in points: right edge at 19 pt, bottom one point above the canvas edge.
    static func arrowOrigin(_ grid: PixelGrid, cell: CGFloat) -> CGPoint {
        CGPoint(x: 19 - CGFloat(grid.width) * cell, y: 17 - CGFloat(grid.height) * cell)
    }

    static func birdState(_ state: MenuBarState) -> BirdState {
        switch state {
        case .offline: BirdState(presence: .offline)
        case .away: BirdState(presence: .away)
        case .available, .downloading, .uploading, .downloadingAndUploading: BirdState(presence: .available)
        }
    }

    static func draw(_ state: MenuBarState, in context: CGContext, scale: CGFloat) {
        let bird = birdState(state)
        context.setFillColor(BirdGlyph.color(bird))
        BirdMark.draw(bird.pose, in: context, rect: Self.bird, scale: max(1, scale))
        if let arrow = arrow(state, scale: scale) { arrow.grid.fill(in: context, origin: arrowOrigin(arrow.grid, cell: arrow.cell), cell: arrow.cell) }
    }

    static func render(_ state: MenuBarState, scale: CGFloat) -> CGImage? {
        let width = Int((MenuGlyphGeometry.canvas.width * scale).rounded()), height = Int((MenuGlyphGeometry.canvas.height * scale).rounded())
        guard scale > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(state, in: context, scale: scale)
        return context.makeImage()
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
