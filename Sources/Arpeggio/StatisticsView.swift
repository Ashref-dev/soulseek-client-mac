import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArpeggioServices

struct StatisticsView: View {
    let model: AppModel
    @State private var rendered: NSImage?
    @State private var copied = false

    private var stats: TransferStatistics { model.statistics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatsCard(stats: stats, user: model.accountName, sharedFiles: model.sharedCount, sharedBytes: model.sharedBytes)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    Metric(symbol: "arrow.up.circle.fill", title: "Uploaded", value: Format.bytes(stats.uploadedBytes), detail: "\(stats.uploadsCompleted.formatted()) files")
                    Metric(symbol: "arrow.down.circle.fill", title: "Downloaded", value: Format.bytes(stats.downloadedBytes), detail: "\(stats.downloadsCompleted.formatted()) files")
                    Metric(symbol: "person.2.fill", title: "People you shared with", value: stats.listeners.count.formatted(), detail: "Unique users")
                    Metric(symbol: "person.crop.circle.badge.checkmark", title: "People you downloaded from", value: stats.sources.count.formatted(), detail: "Unique users")
                    Metric(symbol: "scale.3d", title: "Share ratio", value: ratio, detail: "Uploaded ÷ downloaded")
                    Metric(symbol: "hare.fill", title: "Fastest upload", value: Format.speed(stats.peakUploadSpeed), detail: "Single transfer")
                    Metric(symbol: "bolt.fill", title: "Fastest download", value: Format.speed(stats.peakDownloadSpeed), detail: "Single transfer")
                    Metric(symbol: "externaldrive.fill", title: "Sharing now", value: Format.bytes(model.sharedBytes), detail: "\(model.sharedCount.formatted()) files")
                    Metric(symbol: "dot.radiowaves.left.and.right", title: "Searches answered", value: model.receivedSearchTotal.formatted(), detail: "Since Arpeggio opened")
                }
                Text("Counted on this Mac since \(stats.since.formatted(date: .long, time: .omitted)). Byte totals include partial transfers; file counts include finished files only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("Statistics")
        .navigationSubtitle("Since \(stats.since.formatted(date: .abbreviated, time: .omitted))")
        .toolbar {
            ToolbarItemGroup {
                if let rendered {
                    ShareLink(item: Image(nsImage: rendered), preview: SharePreview("My Arpeggio stats", image: Image(nsImage: rendered))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share a picture of your stats")
                }
                Button(copied ? "Copied" : "Copy Image", systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
                    .contentTransition(.symbolEffect(.replace))
                Button("Save Image…", systemImage: "square.and.arrow.down") { save() }
            }
        }
        .task(id: stats) { rendered = render() }
    }

    private var ratio: String {
        guard stats.downloadedBytes > 0 else { return stats.uploadedBytes > 0 ? "∞" : "-" }
        return (Double(stats.uploadedBytes) / Double(stats.downloadedBytes)).formatted(.number.precision(.fractionLength(2)))
    }

    private func render() -> NSImage? {
        let renderer = ImageRenderer(content: StatsCard(stats: stats, user: model.accountName, sharedFiles: model.sharedCount, sharedBytes: model.sharedBytes)
            .frame(width: 640)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func copy() {
        guard let image = rendered ?? render() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        withAnimation { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
    }

    private func save() {
        guard let image = rendered ?? render(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Arpeggio Stats.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url) } catch { model.error = error.localizedDescription }
    }
}

struct StatsCard: View {
    let stats: TransferStatistics
    let user: String
    let sharedFiles: Int
    let sharedBytes: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                ArpeggioLogo().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(user).font(.title3.weight(.semibold))
                    Text("on Soulseek since \(stats.since.formatted(.dateTime.month(.wide).year()))").font(.caption).opacity(0.75)
                }
                Spacer()
                Text("ARPEGGIO").font(.caption.weight(.bold)).tracking(2.5).opacity(0.7)
            }
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                big(Format.bytes(stats.uploadedBytes), "shared with others", symbol: "arrow.up")
                big(Format.bytes(stats.downloadedBytes), "downloaded", symbol: "arrow.down")
            }
            HStack(spacing: 18) {
                small("\(stats.uploadsCompleted.formatted())", "uploads")
                small("\(stats.listeners.count.formatted())", "people helped")
                small("\(stats.downloadsCompleted.formatted())", "downloads")
                if sharedFiles > 0 { small(sharedFiles.formatted(), "files shared") }
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.27, blue: 0.78), Color(red: 0.12, green: 0.10, blue: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(red: 0.62, green: 0.52, blue: 1).opacity(0.35)).frame(width: 320).blur(radius: 70).offset(x: 220, y: -120)
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func big(_ value: String, _ label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol).font(.callout.weight(.medium)).opacity(0.8)
            Text(value).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }

    private func small(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption).opacity(0.7)
        }
    }
}

private struct Metric: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
    }
}
