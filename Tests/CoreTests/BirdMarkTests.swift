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
        #expect(BirdState(presence: .available) == BirdState(pose: .extended, offline: false))
        #expect(BirdState(presence: .away) == BirdState(pose: .folded, offline: false))
        #expect(BirdState(presence: .offline) == BirdState(pose: .folded, offline: true))
        #expect(BirdState(presence: .available).label == "Available")
        #expect(BirdState(presence: .away).label == "Away")
        #expect(BirdState(presence: .offline).label == "Offline")
    }

    @Test func gridsMatchTheApprovedFilesExactly() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/bird")
        let available = try String(contentsOf: docs.appendingPathComponent("available.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let away = try String(contentsOf: docs.appendingPathComponent("away.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(BirdMark.availableRows == available)
        #expect(BirdMark.awayRows == away)
        for grid in [BirdMark.extendedGrid, BirdMark.foldedGrid] { #expect(grid.width == 26); #expect(grid.height == 24) }
        #expect(BirdMark.extendedGrid.filledCount == 239)
        #expect(BirdMark.foldedGrid.filledCount == 149)
        #expect(BirdMark.extendedGrid.enclosedHoles.count == 1)
        #expect(BirdMark.foldedGrid.enclosedHoles.count == 6)
    }

    @Test func halvedGridKeepsTheEyeAndNeverInventsInk() {
        for pose in [BirdPose.extended, .folded] {
            let full = BirdMark.grid(pose), half = BirdMark.half(pose)
            #expect(half.width == 13); #expect(half.height == 12)
            for y in 0..<12 { for x in 0..<13 where half[x, y] {
                #expect([(0, 0), (1, 0), (0, 1), (1, 1)].contains { full[x * 2 + $0.0, y * 2 + $0.1] })
            } }
            #expect(!half[7, 2])
        }
        #expect(BirdMark.foldedHalf.filledCount < BirdMark.extendedHalf.filledCount)
    }

    @Test func rendersWholePixelCellsWithoutAntialiasing() throws {
        for (pixels, cell) in [(52, 2), (26, 1), (16, 0)] {
            let (_, image) = try render(.available, pixels: pixels)
            for index in stride(from: 3, to: image.rgba.count, by: 4) { #expect(image.rgba[index] == 0 || image.rgba[index] == 255) }
            #expect(image.inkedCount == (cell == 0 ? BirdMark.extendedHalf.filledCount : BirdMark.extendedGrid.filledCount * cell * cell))
        }
    }

    @Test func availableSpreadsItsWingsAndAwayFoldsThem() throws {
        let (_, available) = try render(.available)
        let (_, away) = try render(.away)
        let (_, offline) = try render(.offline)
        #expect(available.inkedCount > away.inkedCount)
        #expect(offline.inkedCount == away.inkedCount)
        let wide = { (pixels: Pixels) in (0..<pixels.side).filter { x in (0..<pixels.side).contains { pixels.inked(x, $0) } }.count }
        #expect(wide(available) > wide(away) + 8)
    }

    @Test func purpleForPresenceAndRedOffline() throws {
        let purple = try render(.available).1.meanColor
        #expect(abs(purple.red - BrandTone.purple.red) < 0.02)
        #expect(abs(purple.blue - BrandTone.purple.blue) < 0.02)
        let away = try render(.away).1.meanColor
        #expect(abs(away.blue - purple.blue) < 0.02)
        let red = try render(.offline).1.meanColor
        #expect(red.red > 0.8); #expect(red.green < 0.3); #expect(red.blue < 0.3)
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
            #expect(image === BirdGlyph.image(BirdState(presence: presence)))
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
