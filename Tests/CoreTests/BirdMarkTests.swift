import AppKit
import Foundation
import Testing
@testable import ArpeggioServices
@testable import Arpeggio

/// Reads a rendered bird back as straight-alpha sRGB pixels.
private struct Pixels {
    let side: Int
    let rgba: [UInt8]

    init(_ image: CGImage) throws {
        side = image.width
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let context = try #require(CGContext(data: &buffer, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        rgba = buffer
    }

    /// Alpha at column `x`, row `y` counted from the top.
    func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * side + x) * 4 + 3] }
    func inked(_ x: Int, _ y: Int) -> Bool { alpha(x, y) > 127 }
    var inkedCount: Int { (0..<side).reduce(0) { total, y in total + (0..<side).filter { inked($0, y) }.count } }
    var topInkRow: Int? { (0..<side).first { y in (0..<side).contains { inked($0, y) } } }
    func inkedRows(_ rows: Range<Int>) -> Int { rows.reduce(0) { total, y in total + (0..<side).filter { inked($0, y) }.count } }

    /// Average un-premultiplied colour of fully covered pixels.
    var meanColor: (red: Double, green: Double, blue: Double) {
        var sum = (0.0, 0.0, 0.0), count = 0.0
        for index in stride(from: 0, to: rgba.count, by: 4) where rgba[index + 3] == 255 {
            sum.0 += Double(rgba[index]); sum.1 += Double(rgba[index + 1]); sum.2 += Double(rgba[index + 2]); count += 1
        }
        return count == 0 ? (0, 0, 0) : (sum.0 / count / 255, sum.1 / count / 255, sum.2 / count / 255)
    }

    var borderIsClear: Bool {
        (0..<side).allSatisfy { !inked($0, 0) && !inked($0, side - 1) && !inked(0, $0) && !inked(side - 1, $0) }
    }
}

private func render(_ presence: Presence, pixels: Int = 32) throws -> (CGImage, Pixels) {
    let image = try #require(BirdGlyph.render(BirdState(presence: presence), pixels: pixels))
    return (image, try Pixels(image))
}

@Suite struct BirdMarkTests {
    @Test func presenceMapsToPoseToneAndLabel() {
        #expect(BirdState(presence: .available) == BirdState(pose: .extended, muted: false))
        #expect(BirdState(presence: .away) == BirdState(pose: .folded, muted: false))
        #expect(BirdState(presence: .offline) == BirdState(pose: .folded, muted: true))
        #expect(BirdState(presence: .available).label == "Available")
        #expect(BirdState(presence: .away).label == "Away")
        #expect(BirdState(presence: .offline).label == "Offline")
    }

    @Test func vectorGeometryStaysInsideTheUnitSquareAndSharesTheBody() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let extended = BirdMark.path(.extended).boundingBoxOfPath, folded = BirdMark.path(.folded).boundingBoxOfPath
        #expect(unit.insetBy(dx: 0.02, dy: 0.02).contains(extended))
        #expect(unit.insetBy(dx: 0.02, dy: 0.02).contains(folded))
        #expect(extended.minY < 0.1)
        #expect(folded.minY > 0.3)
        #expect(extended.height > folded.height * 1.4)
        for point in [CGPoint(x: 0.48, y: 0.63), CGPoint(x: 0.66, y: 0.47), CGPoint(x: 0.12, y: 0.70)] {
            #expect(BirdMark.path(.extended).contains(point))
            #expect(BirdMark.path(.folded).contains(point))
        }
        let eye = CGPoint(x: 0.74, y: 0.41)
        #expect(!BirdMark.path(.extended).contains(eye)); #expect(!BirdMark.path(.folded).contains(eye))
    }

    @Test func availableSpreadsWingsAboveTheHeadAndAwayFoldsThem() throws {
        let (_, available) = try render(.available)
        let (_, away) = try render(.away)
        let (_, offline) = try render(.offline)
        #expect(try #require(available.topInkRow) <= 3)
        #expect(try #require(away.topInkRow) >= 9)
        #expect(available.inkedRows(0..<9) > 40)
        #expect(away.inkedRows(0..<9) == 0)
        #expect(available.inkedCount > away.inkedCount)
        #expect(away.inkedCount > 150)
        #expect(offline.inkedCount == away.inkedCount)
        for pixels in [available, away, offline] { #expect(pixels.borderIsClear) }
    }

    @Test func purpleForPresenceAndQuietGreyOffline() throws {
        let purple = try render(.available).1.meanColor
        #expect(purple.blue > purple.red); #expect(purple.red > purple.green)
        #expect(abs(purple.red - BrandTone.purple.red) < 0.02)
        #expect(abs(purple.blue - BrandTone.purple.blue) < 0.02)
        #expect(max(purple.red, purple.green, purple.blue) - min(purple.red, purple.green, purple.blue) > 0.3)
        let away = try render(.away).1.meanColor
        #expect(abs(away.blue - purple.blue) < 0.02)
        let grey = try render(.offline).1.meanColor
        #expect(max(grey.red, grey.green, grey.blue) - min(grey.red, grey.green, grey.blue) < 0.05)
    }

    /// The bird is a separate presence mark: its silhouette must not resemble the Arpeggio logo.
    @Test func birdIsDistinctFromTheArpeggioMark() throws {
        let side = 32
        let (_, bird) = try render(.available)
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let context = try #require(CGContext(data: &buffer, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(side)); context.scaleBy(x: 1, y: -1)
        var transform = ArpeggioMark.transform(into: CGRect(x: 0, y: 0, width: side, height: side), fit: true)
        context.addPath(try #require(ArpeggioMark.combined.copy(using: &transform)))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath(using: .evenOdd)
        let mark = try Pixels(try #require(context.makeImage()))
        var both = 0, either = 0
        for y in 0..<side { for x in 0..<side {
            let a = bird.inked(x, y), b = mark.inked(x, y)
            if a && b { both += 1 }; if a || b { either += 1 }
        } }
        #expect(Double(both) / Double(either) < 0.5)
    }

    @Test @MainActor func menuImagesKeepTheirColourAndDescribeTheStatus() throws {
        for presence in [Presence.available, .away, .offline] {
            let image = BirdGlyph.image(BirdState(presence: presence))
            #expect(!image.isTemplate)
            #expect(image.size == CGSize(width: 16, height: 16))
            #expect(image.accessibilityDescription == BirdState(presence: presence).label)
        }
    }

    @Test func writesSyntheticRendersWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["ARPEGGIO_BIRD_OUTPUT"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (presence, name) in [(Presence.available, "available"), (.away, "away"), (.offline, "offline")] {
            for pixels in [32, 256] {
                let image = try #require(BirdGlyph.render(BirdState(presence: presence), pixels: pixels))
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("bird-\(name)-\(pixels).png"))
            }
        }
    }
}
