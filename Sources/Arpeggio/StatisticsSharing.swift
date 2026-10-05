import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ArpeggioServices
import Persistence

extension AppModel {
    /// Lifetime totals from the persisted statistics, with the username and current profile picture only
    /// when the person opted in.
    var statisticsSnapshot: StatisticsSnapshot {
        guard settings.showsAccountOnStatsCard else { return StatisticsSnapshot(statistics) }
        let name = connection.isConnected ? activeAccount : settings.username
        return StatisticsSnapshot(statistics, account: name, picture: profilePicture)
    }
}

/// Decodes the card's avatar from picture bytes, downsampled for its small on-card size. The last result is
/// kept so the live preview doesn't decode again on every redraw; it is matched on the full bytes.
@MainActor
enum StatsAvatar {
    static let maxPixels = 128
    private static var cached: (data: Data, image: CGImage?)?

    static func image(_ data: Data?) -> CGImage? {
        guard let data, !data.isEmpty else { return nil }
        if let cached, cached.data == data { return cached.image }
        let image = decode(data)
        cached = (data, image)
        return image
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A rendered statistics picture. Shared as a PNG file named for the person receiving it.
struct StatsPicture: Transferable, Equatable {
    let png: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName("Arpeggio Stats.png")
    }
}

/// Everything a rendered picture depends on. A cached picture is used only while this still matches.
struct StatsRenderKey: Hashable {
    let snapshot: StatisticsSnapshot
    let locale: String
}

@MainActor
enum StatisticsExport {
    static let scale: CGFloat = 2

    static func render(_ snapshot: StatisticsSnapshot, locale: Locale) -> StatsPicture? {
        let renderer = ImageRenderer(content: StatsCard(snapshot: snapshot).environment(\.locale, locale))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return StatsPicture(png: png)
    }

    static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copy(_ picture: StatsPicture) {
        let item = NSPasteboardItem()
        item.setData(picture.png, forType: .png)
        if let tiff = NSImage(data: picture.png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func save(_ picture: StatsPicture) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Arpeggio Stats.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try picture.png.write(to: url, options: .atomic)
    }
}

/// Renders the card once per change and backs the copy, save and share actions in every statistics view.
@MainActor @Observable
final class StatisticsExporter {
    enum Copied { case summary, image }

    private(set) var key: StatsRenderKey?
    private(set) var picture: StatsPicture?
    private(set) var preview: Image?
    private(set) var copied: Copied?
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    func refresh(_ snapshot: StatisticsSnapshot, locale: Locale) {
        let next = StatsRenderKey(snapshot: snapshot, locale: locale.identifier)
        guard next != key || picture == nil else { return }
        picture = StatisticsExport.render(snapshot, locale: locale)
        preview = picture.flatMap { NSImage(data: $0.png) }.map { Image(nsImage: $0) }
        key = next
    }

    /// The picture for exactly these totals, rendering again if the cached one is out of date.
    func current(_ snapshot: StatisticsSnapshot, locale: Locale) -> StatsPicture? {
        refresh(snapshot, locale: locale)
        return picture
    }

    func picture(matching snapshot: StatisticsSnapshot, locale: Locale) -> StatsPicture? {
        key == StatsRenderKey(snapshot: snapshot, locale: locale.identifier) ? picture : nil
    }

    func flash(_ what: Copied, animated: Bool) {
        withAnimation(animated ? .smooth : nil) { copied = what }
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(animated ? .smooth : nil) { self?.copied = nil }
        }
    }
}

/// Copy Summary, Copy Image, Save Image and Share. Works as toolbar items or as an inline row.
struct StatisticsActions: View {
    let exporter: StatisticsExporter
    let snapshot: StatisticsSnapshot
    let model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: String { StatisticsFormat.summary(snapshot, locale: locale) }

    var body: some View {
        Button(exporter.copied == .summary ? "Copied" : "Copy Summary", systemImage: exporter.copied == .summary ? "checkmark" : "text.quote") {
            StatisticsExport.copy(text: summary)
            exporter.flash(.summary, animated: !reduceMotion)
        }
        .help("Copy your totals as text to paste into a post or message")
        Button(exporter.copied == .image ? "Copied" : "Copy Image", systemImage: exporter.copied == .image ? "checkmark" : "photo.on.rectangle") {
            guard let picture = exporter.current(snapshot, locale: locale) else { return }
            StatisticsExport.copy(picture)
            exporter.flash(.image, animated: !reduceMotion)
        }
        .help("Copy the statistics picture to paste into a post or message")
        Button("Save Image…", systemImage: "square.and.arrow.down") {
            guard let picture = exporter.current(snapshot, locale: locale) else { return }
            do { try StatisticsExport.save(picture) } catch { model.error = "Couldn’t save the picture. \(error.localizedDescription)" }
        }
        .help("Save the statistics picture as a PNG")
        if let picture = exporter.picture(matching: snapshot, locale: locale), let preview = exporter.preview {
            ShareLink(item: picture, subject: Text("My Soulseek stats"), message: Text(summary),
                      preview: SharePreview("My Soulseek stats", image: preview)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .help("Share the statistics picture with its summary")
        }
    }
}
