import AppKit
import Foundation
import ImageIO
import Testing
@testable import Arpeggio
@testable import ArpeggioServices

private let synthetic = StatisticsSnapshot(since: Date(timeIntervalSince1970: 1_700_000_000), uploadedBytes: 1_234_567_890_123,
                                           downloadedBytes: 456_789_012_345, uploadedFiles: 48_213, downloadedFiles: 9_876)

/// A made-up portrait (warm gradient, abstract head and shoulders) run through the app's own 512 px
/// normalization, so tests exercise exactly the bytes a real profile picture would have.
private func syntheticAvatar(top: (CGFloat, CGFloat, CGFloat) = (0.99, 0.66, 0.18),
                             bottom: (CGFloat, CGFloat, CGFloat) = (0.94, 0.30, 0.30)) throws -> Data {
    let side = 640
    let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let colors = [CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1), CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)]
    let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]))
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(side)), end: CGPoint(x: CGFloat(side), y: 0), options: [])
    context.setFillColor(CGColor(srgbRed: 1, green: 0.94, blue: 0.86, alpha: 1))
    context.fillEllipse(in: CGRect(x: 205, y: 290, width: 230, height: 230))
    context.fillEllipse(in: CGRect(x: 90, y: -150, width: 460, height: 380))
    let image = try #require(context.makeImage())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-avatar-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    return try #require(AppModel.normalizedPicture(at: url))
}

/// Pixels in the card's footer band that match the synthetic avatar's warm orange, which the card's own
/// purple and white palette never produces.
private func warmFooterPixels(_ png: Data) throws -> Int {
    let bitmap = try #require(NSBitmapImageRep(data: png))
    var count = 0
    for y in 520..<660 {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent > 0.8, color.blueComponent < 0.45, color.greenComponent > 0.2 { count += 1 }
        }
    }
    return count
}

/// Share of pixels that differ visibly (more than 8 of 255 in any channel). Gradient dithering makes
/// repeated renders differ by a level or two, so byte equality isn't a stable test of "same picture".
private func visibleDifference(_ first: Data, _ second: Data) throws -> Double {
    let a = try #require(NSBitmapImageRep(data: first)), b = try #require(NSBitmapImageRep(data: second))
    try #require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh && a.bitsPerPixel == b.bitsPerPixel && a.bitsPerSample == 8)
    let pa = try #require(a.bitmapData), pb = try #require(b.bitmapData)
    let channels = a.samplesPerPixel
    var differing = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            let ia = y * a.bytesPerRow + x * channels, ib = y * b.bytesPerRow + x * channels
            if (0..<channels).contains(where: { abs(Int(pa[ia + $0]) - Int(pb[ib + $0])) > 8 }) { differing += 1 }
        }
    }
    return Double(differing) / Double(a.pixelsWide * a.pixelsHigh)
}

@Test @MainActor func statsCardShowsOwnProfilePictureOnlyWithIdentity() throws {
    let english = Locale(identifier: "en_US")
    let avatar = try syntheticAvatar()
    let base = try #require(StatisticsExport.render(synthetic, locale: english)).png

    var named = synthetic; named.account = "synthetic-user"
    let placeholder = try #require(StatisticsExport.render(named, locale: english)).png
    let withPicture = StatisticsSnapshot(since: synthetic.since, uploadedBytes: synthetic.uploadedBytes, downloadedBytes: synthetic.downloadedBytes,
                                         uploadedFiles: synthetic.uploadedFiles, downloadedFiles: synthetic.downloadedFiles,
                                         account: "synthetic-user", picture: avatar)
    #expect(withPicture.picture == avatar)
    let rendered = try #require(StatisticsExport.render(withPicture, locale: english)).png
    #expect(try warmFooterPixels(rendered) > 800)
    #expect(try warmFooterPixels(placeholder) == 0)
    #expect(try visibleDifference(rendered, placeholder) > 0.001)
    #expect(StatisticsFormat.summary(withPicture, locale: english) == StatisticsFormat.summary(named, locale: english))

    let identityOff = StatisticsSnapshot(since: synthetic.since, uploadedBytes: synthetic.uploadedBytes, downloadedBytes: synthetic.downloadedBytes,
                                         uploadedFiles: synthetic.uploadedFiles, downloadedFiles: synthetic.downloadedFiles,
                                         account: "  ", picture: avatar)
    #expect(identityOff.account == nil); #expect(identityOff.picture == nil)
    #expect(identityOff == synthetic)
    #expect(try visibleDifference(try #require(StatisticsExport.render(identityOff, locale: english)).png, base) < 0.0005)

    var invalid = named; invalid.picture = Data([0xFF, 0xD8, 0x00, 0x13, 0x37])
    let fallback = try #require(StatisticsExport.render(invalid, locale: english)).png
    #expect(try warmFooterPixels(fallback) == 0)
    #expect(try visibleDifference(fallback, placeholder) < 0.0005)

    if let path = ProcessInfo.processInfo.environment["ARPEGGIO_STATS_CARD_OUTPUT"] {
        let url = URL(fileURLWithPath: path).deletingPathExtension()
        try rendered.write(to: url.appendingPathExtension("avatar.png"))
        try placeholder.write(to: url.appendingPathExtension("placeholder.png"))
        try avatar.write(to: url.appendingPathExtension("avatar-source.jpg"))
        try fallback.write(to: url.appendingPathExtension("fallback.png"))
    }
}

@Test @MainActor func exporterRendersAgainWhenTheProfilePictureChanges() throws {
    let exporter = StatisticsExporter()
    let english = Locale(identifier: "en_US")
    let warm = try syntheticAvatar()
    let cool = try syntheticAvatar(top: (0.20, 0.75, 0.95), bottom: (0.10, 0.35, 0.80))
    #expect(warm != cool)
    var named = synthetic; named.account = "synthetic-user"; named.picture = warm
    let first = try #require(exporter.current(named, locale: english))
    #expect(exporter.current(named, locale: english) == first)

    var changed = named; changed.picture = cool
    #expect(StatsRenderKey(snapshot: changed, locale: english.identifier) != StatsRenderKey(snapshot: named, locale: english.identifier))
    #expect(exporter.picture(matching: changed, locale: english) == nil)
    let second = try #require(exporter.current(changed, locale: english))
    #expect(try visibleDifference(second.png, first.png) > 0.0008)
    #expect(try warmFooterPixels(second.png) == 0)

    var removed = changed; removed.picture = nil
    #expect(exporter.picture(matching: removed, locale: english) == nil)
}

@Test @MainActor func modelSnapshotUsesTheCurrentProfilePictureOnlyWhenOptedIn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root)
    let avatar = try syntheticAvatar()
    model.settings.username = "synthetic-user"
    model.profilePicture = avatar
    #expect(!model.settings.showsAccountOnStatsCard)
    #expect(model.statisticsSnapshot.account == nil)
    #expect(model.statisticsSnapshot.picture == nil)

    model.settings.statsCardAccount = true
    #expect(model.statisticsSnapshot.account == "synthetic-user")
    #expect(model.statisticsSnapshot.picture == avatar)

    let replacement = try syntheticAvatar(top: (0.20, 0.75, 0.95), bottom: (0.10, 0.35, 0.80))
    model.profilePicture = replacement
    #expect(model.statisticsSnapshot.picture == replacement)
    model.profilePicture = nil
    #expect(model.statisticsSnapshot.picture == nil)
    #expect(model.statisticsSnapshot.account == "synthetic-user")
}

@Test @MainActor func statsCardRendersAnOpaqueSocialSizedPNG() throws {
    let picture = try #require(StatisticsExport.render(synthetic, locale: Locale(identifier: "en_US")))
    let bitmap = try #require(NSBitmapImageRep(data: picture.png))
    #expect(bitmap.pixelsWide == 1200); #expect(bitmap.pixelsHigh == 676)
    #expect(!bitmap.hasAlpha || bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 1)
    if let path = ProcessInfo.processInfo.environment["ARPEGGIO_STATS_CARD_OUTPUT"] {
        try picture.png.write(to: URL(fileURLWithPath: path))
        var named = synthetic; named.account = "synthetic-user"
        let extremes = [("named", named, "de_DE"),
                        ("zero", StatisticsSnapshot(since: synthetic.since, uploadedBytes: 0, downloadedBytes: 0, uploadedFiles: 0, downloadedFiles: 0), "en_US"),
                        ("huge", StatisticsSnapshot(since: synthetic.since, uploadedBytes: .max, downloadedBytes: 1, uploadedFiles: 2_000_000_000, downloadedFiles: 1), "en_US")]
        for (name, snapshot, locale) in extremes {
            try #require(StatisticsExport.render(snapshot, locale: Locale(identifier: locale))).png
                .write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(name).png"))
        }
    }
}

@Test @MainActor func exporterRendersAgainWheneverAnExportedInputChanges() throws {
    let exporter = StatisticsExporter()
    let english = Locale(identifier: "en_US")
    exporter.refresh(synthetic, locale: english)
    let first = try #require(exporter.picture)
    #expect(exporter.picture(matching: synthetic, locale: english) == first)

    var more = synthetic; more.downloadedFiles += 1
    #expect(exporter.picture(matching: more, locale: english) == nil)
    let updated = try #require(exporter.current(more, locale: english))
    #expect(updated != first)

    var named = more; named.account = "dj"
    #expect(exporter.picture(matching: named, locale: english) == nil)
    #expect(exporter.picture(matching: more, locale: Locale(identifier: "de_DE")) == nil)
    #expect(exporter.current(more, locale: english) == updated)
}
