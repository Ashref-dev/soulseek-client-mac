import CoreGraphics

/// The Arpeggio mark: the arpeggio sign from sheet music (a wavy line) beside a three-note chord.
/// Paths live in a unit square with y pointing down. The app icon (scripts/icon), the menu bar glyph and
/// the in-app logo all draw these paths, so they can't drift apart. Notes have counters: fill even-odd.
enum ArpeggioMark {
    /// Shifts the whole mark so its optical centre, between the box centre and the ink centroid, sits at 0.5.
    static let offset: CGFloat = -0.017
    static let noteCenters: [CGFloat] = [0.24, 0.5, 0.76]

    /// The wave's centre line, swing and stroke. It spans exactly the height of the chord, ending at its
    /// centre line at both ends.
    private static let waveX: CGFloat = 0.2 + offset
    private static let amplitude: CGFloat = 0.058
    private static let waveWidth: CGFloat = 0.075
    private static let waveTop: CGFloat = 0.168
    private static let waveBottom: CGFloat = 0.832
    private static let waves: CGFloat = 4.5

    static var wave: CGPath {
        let points = (0...360).map { i -> CGPoint in
            let t = CGFloat(i) / 360
            return CGPoint(x: waveX + amplitude * sin(2 * .pi * waves * t), y: waveTop + (waveBottom - waveTop) * t)
        }
        let line = CGMutablePath()
        line.addLines(between: points)
        let body = line.copy(strokingWithWidth: waveWidth, lineCap: .butt, lineJoin: .round, miterLimit: 10).normalized()
        let ends = CGMutablePath()
        for point in [points[0], points[360]] {
            ends.addEllipse(in: CGRect(x: point.x - waveWidth / 2, y: point.y - waveWidth / 2, width: waveWidth, height: waveWidth))
        }
        return body.union(ends, using: .winding)
    }

    /// The wave with arrowheads, as notation marks the direction an arpeggio rolls. Near an arrow the wiggle
    /// eases into a straight shaft. Each tip reaches `arrowReach` past the plain wave's end, into the margin
    /// around the mark, so callers can keep the plain mark's place and scale for every variant.
    static func wave(arrowUp: Bool, arrowDown: Bool) -> CGPath {
        guard arrowUp || arrowDown else { return wave }
        let shaft = arrowLength - arrowReach
        let start = arrowUp ? waveTop + shaft : waveTop
        let end = arrowDown ? waveBottom - shaft : waveBottom
        let points = (0...480).map { i -> CGPoint in
            let y = start + (end - start) * CGFloat(i) / 480
            var envelope: CGFloat = 1
            if arrowUp { envelope = min(envelope, (y - start) / arrowTaper) }
            if arrowDown { envelope = min(envelope, (end - y) / arrowTaper) }
            envelope = min(1, max(0, envelope))
            envelope = envelope * envelope * (3 - 2 * envelope)
            let phase = 2 * .pi * waves * (y - waveTop) / (waveBottom - waveTop)
            return CGPoint(x: waveX + amplitude * envelope * sin(phase), y: y)
        }
        let line = CGMutablePath()
        line.addLines(between: points)
        let body = line.copy(strokingWithWidth: waveWidth, lineCap: .butt, lineJoin: .round, miterLimit: 10).normalized()
        let ends = CGMutablePath()
        if arrowUp {
            ends.addPath(arrowhead(tip: CGPoint(x: waveX, y: waveTop - arrowReach), pointing: -1))
        } else {
            ends.addEllipse(in: CGRect(x: points[0].x - waveWidth / 2, y: points[0].y - waveWidth / 2, width: waveWidth, height: waveWidth))
        }
        if arrowDown {
            ends.addPath(arrowhead(tip: CGPoint(x: waveX, y: waveBottom + arrowReach), pointing: 1))
        } else {
            ends.addEllipse(in: CGRect(x: points[480].x - waveWidth / 2, y: points[480].y - waveWidth / 2, width: waveWidth, height: waveWidth))
        }
        return body.union(ends, using: .winding)
    }

    private static let arrowWidth: CGFloat = 0.22
    private static let arrowLength: CGFloat = 0.17
    private static let arrowReach: CGFloat = 0.075
    private static let arrowTaper: CGFloat = 0.11

    /// A solid triangle with its tip at `tip`, pointing down for +1 and up for -1.
    private static func arrowhead(tip: CGPoint, pointing direction: CGFloat) -> CGPath {
        let base = tip.y - direction * arrowLength
        let head = CGMutablePath()
        head.addLines(between: [tip, CGPoint(x: tip.x + arrowWidth / 2, y: base), CGPoint(x: tip.x - arrowWidth / 2, y: base)])
        head.closeSubpath()
        return head
    }

    static var notes: [CGPath] { notes(filled: false) }

    /// The chord. Open noteheads keep their counters; filled ones are solid, the chord sounding.
    static func notes(filled: Bool) -> [CGPath] {
        noteCenters.map { y in
            let note = CGMutablePath()
            note.addPath(ellipse(center: CGPoint(x: 0.64 + offset, y: y), width: 0.44, height: 0.215, degrees: -6))
            if !filled { note.addPath(ellipse(center: CGPoint(x: 0.64 + offset, y: y), width: 0.19, height: 0.1, degrees: -42)) }
            return note
        }
    }

    static var combined: CGPath {
        let path = CGMutablePath()
        path.addPath(wave)
        for note in notes { path.addPath(note) }
        return path
    }

    static var bounds: CGRect { combined.boundingBoxOfPath }

    /// Maps the unit square onto `rect`, or with `fit`, scales the mark's own bounds to fill `rect`.
    static func transform(into rect: CGRect, fit: Bool = false) -> CGAffineTransform {
        let source = fit ? bounds : CGRect(x: 0, y: 0, width: 1, height: 1)
        let scale = min(rect.width / source.width, rect.height / source.height)
        let x = rect.midX - source.midX * scale, y = rect.midY - source.midY * scale
        return CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
    }

    private static func ellipse(center: CGPoint, width: CGFloat, height: CGFloat, degrees: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), transform: &transform)
    }
}
