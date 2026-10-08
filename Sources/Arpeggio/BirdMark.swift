import SwiftUI
import AppKit
import CoreGraphics
import ArpeggioServices

/// The presence bird: the classic Soulseek pixel bird, upright. Wings open means Available, wings folded
/// means Away, and a red folded bird means offline. The menu bar can show it too (Settings > General).
enum BirdPose: Sendable, Equatable { case extended, folded }

struct BirdState: Sendable, Equatable {
    let pose: BirdPose
    let offline: Bool

    init(pose: BirdPose, offline: Bool) { self.pose = pose; self.offline = offline }

    init(presence: Presence) {
        switch presence {
        case .available: self.init(pose: .extended, offline: false)
        case .away: self.init(pose: .folded, offline: false)
        case .offline: self.init(pose: .folded, offline: true)
        }
    }

    var label: String {
        switch (pose, offline) {
        case (_, true): "Offline"
        case (.extended, false): "Available"
        case (.folded, false): "Away"
        }
    }
}

/// A bitmap of filled cells, row-major, y pointing down.
struct PixelGrid: Sendable, Equatable {
    let width: Int
    let height: Int
    let cells: [Bool]

    init(rows: [String]) {
        let width = rows.map(\.count).max() ?? 0
        self.width = width
        height = rows.count
        cells = rows.flatMap { row in Array(row).map { $0 == "#" } + Array(repeating: false, count: width - row.count) }
    }

    init(width: Int, height: Int, cells: [Bool]) { self.width = width; self.height = height; self.cells = cells }

    subscript(x: Int, y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && cells[y * width + x] }

    var filledCount: Int { cells.filter { $0 }.count }

    /// Empty cells not reachable from the border through empty cells (4-connected): the eye, the wing fold.
    var enclosedHoles: Set<Int> {
        var outside = Set<Int>(), queue: [Int] = []
        for y in 0..<height { for x in 0..<width where (x == 0 || y == 0 || x == width - 1 || y == height - 1) && !self[x, y] {
            if outside.insert(y * width + x).inserted { queue.append(y * width + x) }
        } }
        while let next = queue.popLast() {
            let x = next % width, y = next / width
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height && !self[nx, ny] {
                if outside.insert(ny * width + nx).inserted { queue.append(ny * width + nx) }
            }
        }
        return Set((0..<cells.count).filter { !cells[$0] && !outside.contains($0) })
    }

    /// Half resolution for 1x screens where a whole device pixel per cell does not fit. A 2x2 block is
    /// filled when at least two of its cells are, unless it holds an enclosed hole, so the eye and the
    /// wing fold survive the reduction.
    func halved() -> PixelGrid {
        let holes = enclosedHoles, w = (width + 1) / 2, h = (height + 1) / 2
        var out = [Bool](repeating: false, count: w * h)
        for by in 0..<h { for bx in 0..<w {
            let block = [(bx * 2, by * 2), (bx * 2 + 1, by * 2), (bx * 2, by * 2 + 1), (bx * 2 + 1, by * 2 + 1)]
            let count = block.filter { self[$0.0, $0.1] }.count
            let hole = block.contains { $0.0 < width && $0.1 < height && holes.contains($0.1 * width + $0.0) }
            out[by * w + bx] = count >= 2 && !hole
        } }
        return PixelGrid(width: w, height: h, cells: out)
    }

    /// The smallest box of cells holding ink: (minX, minY, width, height) in cells.
    var inkBounds: (x: Int, y: Int, width: Int, height: Int) {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where self[x, y] {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? (0, 0, 0, 0) : (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Fills cells of `cell` points from `origin` (points) into a context whose user space is device pixels,
    /// rounding every cell edge to a whole pixel so the art stays sharp at any size, without blur.
    func fillSnapped(in context: CGContext, origin: CGPoint, cell: CGFloat, scale: CGFloat) {
        context.saveGState()
        context.setShouldAntialias(false)
        let edge = { (start: CGFloat, index: Int) in ((start + CGFloat(index) * cell) * scale).rounded() }
        for y in 0..<height { for x in 0..<width where self[x, y] {
            let left = edge(origin.x, x), right = edge(origin.x, x + 1), top = edge(origin.y, y), bottom = edge(origin.y, y + 1)
            if right > left, bottom > top { context.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top)) }
        } }
        context.fillPath()
        context.restoreGState()
    }

    /// Fills each cell as a `cell`-sized square from `origin`, in the context's current user space.
    /// Callers pass device-pixel multiples so edges land on whole pixels; antialiasing is off.
    func fill(in context: CGContext, origin: CGPoint, cell: CGFloat) {
        context.saveGState()
        context.setShouldAntialias(false)
        for y in 0..<height { for x in 0..<width where self[x, y] {
            context.addRect(CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell, height: cell))
        } }
        context.fillPath()
        context.restoreGState()
    }
}

/// The approved grids, identical to docs/bird/available.txt and away.txt (26 by 24, '#' filled).
enum BirdMark {
    static let availableRows = [
        "...........#..............",
        "...........###............",
        ".........######...........",
        "...........#####..........",
        "...........###.##.........",
        "...........######.........",
        "#..........######.......##",
        "#..........####.##....####",
        "####.......####.....######",
        ".########.######..#######.",
        ".#######################..",
        "..#####################...",
        "..####################....",
        "...##################.....",
        "....################......",
        ".....##############.......",
        ".......###########........",
        ".........########.........",
        "..........######..........",
        "..........#####...........",
        ".........####.............",
        "......######..............",
        ".....#####................",
        "........#.................",
    ]
    static let awayRows = [
        "...........#..............",
        "...........###............",
        ".........######...........",
        "...........#####..........",
        "...........###.##.........",
        "...........######.........",
        "...........######.........",
        "...........####.##........",
        "..........#####...........",
        ".........#######..........",
        "........#########.........",
        ".......####.######........",
        ".......#####.#####........",
        ".......######.####........",
        "........######.###........",
        "........#######.#.........",
        ".........########.........",
        ".........########.........",
        "..........######..........",
        "..........#####...........",
        ".........####.............",
        "......######..............",
        ".....#####................",
        "........#.................",
    ]
    static let extendedGrid = PixelGrid(rows: availableRows)
    static let foldedGrid = PixelGrid(rows: awayRows)
    static let extendedHalf = extendedGrid.halved()
    static let foldedHalf = foldedGrid.halved()

    static func grid(_ pose: BirdPose) -> PixelGrid { pose == .extended ? extendedGrid : foldedGrid }
    static func half(_ pose: BirdPose) -> PixelGrid { pose == .extended ? extendedHalf : foldedHalf }

    nonisolated(unsafe) static let extended = make(.extended)
    nonisolated(unsafe) static let folded = make(.folded)

    /// The grid as a vector path in a unit square, y down, centred; cells are squares.
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
        let grid = grid(pose), cell = 1 / CGFloat(max(grid.width, grid.height))
        let origin = CGPoint(x: (1 - CGFloat(grid.width) * cell) / 2, y: (1 - CGFloat(grid.height) * cell) / 2)
        let path = CGMutablePath()
        for y in 0..<grid.height { for x in 0..<grid.width where grid[x, y] {
            path.addRect(CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell, height: cell))
        } }
        return path.union(CGMutablePath(), using: .winding)
    }

    /// Device pixels per cell for a bird drawn in `side` points at `scale`: the largest whole number that
    /// fits, or 0 when the grid must be halved (1x at menu sizes).
    static func cellPixels(side: CGFloat, scale: CGFloat) -> Int {
        Int((side * scale / 26).rounded(.down))
    }

    /// Draws the bird pixel-exact inside `rect` (user space, y down) for a context with `scale` pixels per point.
    static func draw(_ pose: BirdPose, in context: CGContext, rect: CGRect, scale: CGFloat) {
        let pixels = cellPixels(side: min(rect.width, rect.height), scale: scale)
        let grid = pixels >= 1 ? grid(pose) : half(pose)
        let cell = CGFloat(max(1, pixels)) / scale
        let width = CGFloat(grid.width) * cell, height = CGFloat(grid.height) * cell
        let snap = { (value: CGFloat) in (value * scale).rounded(.down) / scale }
        grid.fill(in: context, origin: CGPoint(x: snap(rect.midX - width / 2), y: snap(rect.midY - height / 2)), cell: cell)
    }
}

/// Bitmaps of the bird for menus and tests: brand purple for Available and Away, red for offline.
enum BirdGlyph {
    static let offlineRed = (red: 0.90, green: 0.22, blue: 0.21)

    static func color(_ state: BirdState) -> CGColor {
        let tone = state.offline ? offlineRed : BrandTone.purple
        return CGColor(srgbRed: tone.red, green: tone.green, blue: tone.blue, alpha: 1)
    }

    @MainActor private static var images: [String: NSImage] = [:]

    /// A non-template image, so the colour survives in menus. Drawn per destination scale with whole
    /// device pixels per cell, so it stays sharp on 1x and 2x screens.
    @MainActor static func image(_ state: BirdState, side: CGFloat = 16) -> NSImage {
        let key = "\(state.pose)-\(state.offline)-\(side)"
        if let image = images[key] { return image }
        let image = NSImage(size: CGSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(color(state))
            BirdMark.draw(state.pose, in: context, rect: rect, scale: abs(context.userSpaceToDeviceSpaceTransform.a))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.label
        images[key] = image
        return image
    }

    /// Renders the bird into a transparent square bitmap of `pixels` per side (one pixel per point).
    static func render(_ state: BirdState, pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = CGFloat(pixels)
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(color(state))
        BirdMark.draw(state.pose, in: context, rect: CGRect(x: 0, y: 0, width: side, height: side), scale: 1)
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
        Image(nsImage: BirdGlyph.image(state, side: size))
            .interpolation(.none)
            .frame(width: size, height: size)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: state)
            .accessibilityElement()
            .accessibilityLabel("Status: \(state.label)")
            .accessibilityHidden(decorative)
    }
}
