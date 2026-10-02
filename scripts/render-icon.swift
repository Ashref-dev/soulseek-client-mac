#!/usr/bin/env swift
// Renders the Arpeggio app icon (mirrors Resources/AppIcon.svg) into a macOS .iconset.
// Usage: swift scripts/render-icon.swift path/to/AppIcon.iconset
//        iconutil -c icns path/to/AppIcon.iconset

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Draws the icon on a 1024-point canvas in SVG (top-left origin) coordinates.
func draw(in context: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Tile: vertical violet gradient plus a soft top-left glow.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(gradient([(0, color(0x7A69D6)), (1, color(0x3A2D86))]),
                               start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.20)), (1, color(0xFFFFFF, 0))]),
                               startCenter: CGPoint(x: 330, y: 200), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 200), endRadius: 620, options: [])
    context.restoreGState()

    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(2)
    context.strokePath()

    // Notes: beam, stems, and three heads rising left to right.
    let notes = CGMutablePath()
    notes.addLines(between: [CGPoint(x: 379, y: 454), CGPoint(x: 751, y: 214), CGPoint(x: 751, y: 262), CGPoint(x: 379, y: 502)])
    notes.closeSubpath()
    notes.addRect(CGRect(x: 379, y: 474, width: 22, height: 242))
    notes.addRect(CGRect(x: 554, y: 354, width: 22, height: 242))
    notes.addRect(CGRect(x: 729, y: 234, width: 22, height: 242))
    let heads: [(CGPoint, CGFloat)] = [(CGPoint(x: 330, y: 726), 1), (CGPoint(x: 505, y: 606), 0.94), (CGPoint(x: 680, y: 486), 0.88)]
    func head(_ center: CGPoint) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -22 * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -74, y: -54, width: 148, height: 108), transform: &transform)
    }

    // Shadow (y is flipped by the context, so a positive SVG dy is a negative CG offset).
    context.saveGState()
    let scale = context.ctm.a
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 32 * scale, color: color(0x1B1240, 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    func fillInk(_ path: CGPath, alpha: CGFloat) {
        context.saveGState()
        context.setAlpha(alpha)
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient([(0, color(0xFFFFFF)), (1, color(0xE6DFFF))]),
                                   start: CGPoint(x: 0, y: 210), end: CGPoint(x: 0, y: 780), options: [])
        context.restoreGState()
    }
    fillInk(notes, alpha: 1)
    for (center, alpha) in heads { fillInk(head(center), alpha: alpha) }

    context.endTransparencyLayer()
    context.restoreGState()
}

func render(pixels: Int) throws -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    draw(in: context)
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

do {
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            let url = output.appendingPathComponent(name)
            try write(try render(pixels: points * factor), to: url)
            print("wrote \(url.path) (\(points * factor)px)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("render-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
