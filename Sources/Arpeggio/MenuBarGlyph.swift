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
        let image: NSImage
        switch style {
        case .arpeggio:
            image = NSImage(size: MenuGlyphGeometry.canvas, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                draw(state, in: context)
                return true
            }
        case .classicBird:
            image = ClassicBirdGlyph.image(state)
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
/// right: down, up, or both. One static glyph per state, centred on its ink in its own canvas.
enum ClassicBirdGlyph {
    static let canvas = CGSize(width: 22, height: 18)
    /// Points per grid cell: the 24-row bird stands 16 points tall, close to the system menu bar symbols.
    static let cell: CGFloat = 2.0 / 3.0

    /// 1x arrows use one point per cell; 2x and 3x arrows use finer cells, matching the bird's grain.
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
        case (true, true): return fine ? (fineBothArrow, 0.5) : (bothArrow, 1)
        case (true, false): return fine ? (fineDownArrow, 0.5) : (downArrow, 1)
        case (false, true): return fine ? (fineUpArrow, 0.5) : (upArrow, 1)
        case (false, false): return nil
        }
    }

    /// The arrow's top-left corner in points: right edge at 21 pt, bottom one point above the canvas edge.
    static func arrowOrigin(_ grid: PixelGrid, cell: CGFloat) -> CGPoint {
        CGPoint(x: 21 - CGFloat(grid.width) * cell, y: 17 - CGFloat(grid.height) * cell)
    }

    static func birdState(_ state: MenuBarState) -> BirdState {
        switch state {
        case .offline: BirdState(presence: .offline)
        case .away: BirdState(presence: .away)
        case .available, .downloading, .uploading, .downloadingAndUploading: BirdState(presence: .available)
        }
    }

    /// Draws into a bitmap context whose user space is device pixels with y pointing down.
    static func draw(_ state: MenuBarState, in context: CGContext, scale: CGFloat) {
        let bird = birdState(state)
        let halve = cell * scale < 1
        let grid = halve ? BirdMark.half(bird.pose) : BirdMark.grid(bird.pose)
        let size = halve ? cell * 2 : cell
        let ink = grid.inkBounds
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        let origin = CGPoint(x: snap(center.x - (CGFloat(ink.x) + CGFloat(ink.width) / 2) * size),
                             y: snap(center.y - (CGFloat(ink.y) + CGFloat(ink.height) / 2) * size))
        context.setFillColor(BirdGlyph.color(bird))
        grid.fillSnapped(in: context, origin: origin, cell: size, scale: scale)
        if let arrow = arrow(state, scale: scale) {
            arrow.grid.fillSnapped(in: context, origin: arrowOrigin(arrow.grid, cell: arrow.cell), cell: arrow.cell, scale: scale)
        }
    }

    static func render(_ state: MenuBarState, scale: CGFloat) -> CGImage? {
        let width = Int((canvas.width * scale).rounded()), height = Int((canvas.height * scale).rounded())
        guard scale > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(state, in: context, scale: scale)
        return context.makeImage()
    }

    /// Explicit 1x, 2x and 3x bitmaps, so AppKit picks an exact one for each screen and never resamples.
    static func image(_ state: MenuBarState) -> NSImage {
        let image = NSImage(size: canvas)
        for scale in [1, 2, 3] {
            guard let bitmap = render(state, scale: CGFloat(scale)) else { continue }
            let rep = NSBitmapImageRep(cgImage: bitmap)
            rep.size = canvas
            image.addRepresentation(rep)
        }
        return image
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
