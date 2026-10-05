import SwiftUI
import ArpeggioServices

struct StatisticsView: View {
    let model: AppModel
    @State private var exporter = StatisticsExporter()
    @Environment(\.locale) private var locale

    private var stats: TransferStatistics { model.statistics }

    var body: some View {
        let snapshot = model.statisticsSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FittedStatsCard(snapshot: snapshot)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    Metric(symbol: "arrow.up.circle.fill", title: "Uploaded", value: StatisticsFormat.gigabyteText(stats.uploadedBytes, locale: locale),
                           detail: "\(StatisticsFormat.files(stats.uploadsCompleted, locale: locale)) completed")
                    Metric(symbol: "arrow.down.circle.fill", title: "Downloaded", value: StatisticsFormat.gigabyteText(stats.downloadedBytes, locale: locale),
                           detail: "\(StatisticsFormat.files(stats.downloadsCompleted, locale: locale)) completed")
                    Metric(symbol: "person.2.fill", title: "People you shared with", value: stats.listeners.count.formatted(), detail: "Unique users")
                    Metric(symbol: "person.crop.circle.badge.checkmark", title: "People you downloaded from", value: stats.sources.count.formatted(), detail: "Unique users")
                    Metric(symbol: "scale.3d", title: "Share ratio", value: ratio, detail: "Uploaded ÷ downloaded")
                    Metric(symbol: "hare.fill", title: "Fastest upload", value: Format.speed(stats.peakUploadSpeed), detail: "Single transfer")
                    Metric(symbol: "bolt.fill", title: "Fastest download", value: Format.speed(stats.peakDownloadSpeed), detail: "Single transfer")
                    Metric(symbol: "externaldrive.fill", title: "Sharing now", value: Format.bytes(model.sharedBytes), detail: "\(model.sharedCount.formatted()) files")
                    Metric(symbol: "dot.radiowaves.left.and.right", title: "Searches answered", value: model.receivedSearchTotal.formatted(), detail: "Since Arpeggio opened")
                }
                StatisticsFootnote(since: stats.since)
            }
            .padding(24)
        }
        .navigationTitle("Statistics")
        .navigationSubtitle("Since \(stats.since.formatted(date: .abbreviated, time: .omitted))")
        .toolbar {
            ToolbarItemGroup {
                StatisticsActions(exporter: exporter, snapshot: snapshot, model: model)
            }
        }
        .task(id: StatsRenderKey(snapshot: snapshot, locale: locale.identifier)) { exporter.refresh(snapshot, locale: locale) }
    }

    private var ratio: String {
        guard stats.downloadedBytes > 0 else { return stats.uploadedBytes > 0 ? "∞" : "-" }
        return (Double(stats.uploadedBytes) / Double(stats.downloadedBytes)).formatted(.number.precision(.fractionLength(2)))
    }
}

struct StatisticsFootnote: View {
    let since: Date
    @Environment(\.locale) private var locale

    var body: some View {
        Text("Counted on this Mac since \(StatisticsFormat.since(since, locale: locale)). Data totals include partial transfers and use decimal gigabytes (1 GB = 1,000,000,000 bytes). File counts include finished files only.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct Metric: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
