import CoreGraphics

/// The Arpeggio mark: the arpeggio sign from sheet music (a wavy line) beside a three-note chord.
/// Paths live in a unit square with y pointing down. The app icon (scripts/icon), the menu bar glyph and
/// the in-app logo all draw these paths, so they can't drift apart. Notes have counters: fill even-odd.
enum ArpeggioMark {
    /// Shifts the whole mark so its optical centre, between the box centre and the ink centroid, sits at 0.5.
    static let offset: CGFloat = -0.017
    static let noteCenters: [CGFloat] = [0.24, 0.5, 0.76]

    static var wave: CGPath {
        let x = 0.2 + offset, amplitude: CGFloat = 0.058, width: CGFloat = 0.075
        // The wave spans exactly the height of the chord, ending at its centre line at both ends.
        let top: CGFloat = 0.168, bottom: CGFloat = 0.832, waves: CGFloat = 4.5
        let points = (0...360).map { i -> CGPoint in
            let t = CGFloat(i) / 360
            return CGPoint(x: x + amplitude * sin(2 * .pi * waves * t), y: top + (bottom - top) * t)
        }
        let line = CGMutablePath()
        line.addLines(between: points)
        let body = line.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10).normalized()
        let ends = CGMutablePath()
        for point in [points[0], points[360]] {
            ends.addEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
        }
        return body.union(ends, using: .winding)
    }

    static var notes: [CGPath] {
        noteCenters.map { y in
            let note = CGMutablePath()
            note.addPath(ellipse(center: CGPoint(x: 0.64 + offset, y: y), width: 0.44, height: 0.215, degrees: -6))
            note.addPath(ellipse(center: CGPoint(x: 0.64 + offset, y: y), width: 0.19, height: 0.1, degrees: -42))
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
