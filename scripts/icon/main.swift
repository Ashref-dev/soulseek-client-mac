// Renders the app icon from Sources/Arpeggio/ArpeggioMark.swift into a macOS .iconset.
// Usage: swiftc -O scripts/icon/main.swift Sources/Arpeggio/ArpeggioMark.swift -o /tmp/arpeggio-icon
//        /tmp/arpeggio-icon path/to/AppIcon.iconset

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
    var out: UInt32 = 0
    for shift in [16, 8, 0] as [UInt32] {
        let x = CGFloat((a >> shift) & 0xFF), y = CGFloat((b >> shift) & 0xFF)
        out |= UInt32((x * (1 - t) + y * t).rounded()) << shift
    }
    return out
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func context(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    return ctx
}

/// Apple's macOS icon shape: a superellipse plate on an 824 px tile inside the 1024 px canvas.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi, c = cos(t), s = sin(t)
        let point = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 0.4), c), y: r.midY + r.height / 2 * copysign(pow(abs(s), 0.4), s))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// A raised piece lit from the top left: a soft violet shadow below, a body gradient, a specular spot and,
/// for the notes, a thin bevel that is light on top and dark underneath.
func raised(_ ctx: CGContext, _ path: CGPath, light: UInt32, base: UInt32, dark: UInt32, shadow: CGFloat, specular: CGFloat, bevel: Bool, size: CGFloat) {
    let bounds = path.boundingBoxOfPath
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -shadow * size * 0.03), blur: shadow * size * 0.055, color: rgb(0x150D3A, 0.5))
    ctx.addPath(path); ctx.setFillColor(rgb(dark)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    let spot = CGPoint(x: bounds.minX + bounds.width * 0.3, y: bounds.minY + bounds.height * 0.18)
    ctx.saveGState(); ctx.addPath(path); ctx.clip(using: .evenOdd)
    ctx.drawRadialGradient(gradient([(0, rgb(light)), (0.5, rgb(base)), (1, rgb(dark))]), startCenter: spot, startRadius: 0,
                           endCenter: spot, endRadius: hypot(bounds.width, bounds.height) * 0.95, options: [.drawsAfterEndLocation])
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, specular)), (1, rgb(0xFFFFFF, 0))]), startCenter: spot, startRadius: 0,
                           endCenter: spot, endRadius: max(bounds.width, bounds.height) * 0.3, options: [])
    if bevel {
        ctx.addPath(path); ctx.setLineWidth(max(1.5, size * 0.006)); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.35)), (0.55, rgb(0xFFFFFF, 0)), (1, rgb(0x2A1C6E, 0.25))]),
                               start: CGPoint(x: 0, y: bounds.minY), end: CGPoint(x: 0, y: bounds.maxY), options: [])
    }
    ctx.restoreGState()
}

func icon() -> CGImage {
    let ctx = context(1024)
    let plate = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: rgb(0x000000, 0.3))
    ctx.addPath(plate); ctx.setFillColor(rgb(0x3A2D86)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(plate); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x8775E0)), (0.55, rgb(0x5E4CB8)), (1, rgb(0x34287E))]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.26)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: 512, y: 150), startRadius: 0, endCenter: CGPoint(x: 512, y: 150), endRadius: 600, options: [])
    let size = 824 * 0.66
    var transform = ArpeggioMark.transform(into: CGRect(x: 512 - size / 2, y: 512 - size / 2, width: size, height: size))
    raised(ctx, ArpeggioMark.wave.copy(using: &transform)!, light: 0xFFFFFF, base: 0xE4DCFF, dark: 0x9C89E6,
           shadow: 0.55, specular: 0.4, bevel: false, size: size)
    for (index, note) in ArpeggioMark.notes.enumerated() {
        // Lightest on top, a little more violet toward the bottom of the chord.
        let base = mix(0xA996EE, 0xF7F4FF, 1 - 0.225 * CGFloat(index))
        raised(ctx, note.copy(using: &transform)!, light: mix(base, 0xFFFFFF, 0.65), base: base, dark: mix(base, 0x4E3BB5, 0.5),
               shadow: 0.6, specular: 0.6, bevel: true, size: size)
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    ctx.addPath(plate); ctx.setLineWidth(14); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.42)), (0.3, rgb(0xFFFFFF, 0)), (1, rgb(0x000000, 0.16))]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, size: Int, to url: URL) throws {
    let ctx = context(size)
    ctx.saveGState(); ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: arpeggio-icon <output.iconset>\n".utf8)); exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let master = icon()
    for points in [16, 32, 128, 256, 512] {
        try write(master, size: points, to: output.appendingPathComponent("icon_\(points)x\(points).png"))
        try write(master, size: points * 2, to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
} catch {
    FileHandle.standardError.write(Data("arpeggio-icon: \(error.localizedDescription)\n".utf8)); exit(1)
}
