import SwiftUI
import ArpeggioServices

/// Settings > Statistics: the lifetime totals with the same card and share actions as the sidebar view.
struct StatisticsSettings: View {
    @Bindable var model: AppModel
    @State private var exporter = StatisticsExporter()
    @Environment(\.locale) private var locale

    var body: some View {
        let snapshot = model.statisticsSnapshot
        Form {
            Section {
                FittedStatsCard(snapshot: snapshot)
                    .padding(.vertical, 6)
                HStack(spacing: 8) {
                    StatisticsActions(exporter: exporter, snapshot: snapshot, model: model)
                }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                Toggle("Show my profile picture and username on shared pictures and summaries", isOn: Binding(
                    get: { model.settings.showsAccountOnStatsCard }, set: { model.settings.statsCardAccount = $0 }))
            } header: {
                Text("Share Your Stats")
            } footer: {
                Text("Pictures are 1200 × 676 PNGs sized for social posts. With this on, pictures show your profile picture and username, and text summaries name you. They never include your folders, files or the people you traded with.")
                    .foregroundStyle(.secondary)
            }
            Section {
                total("Uploaded", bytes: snapshot.uploadedBytes)
                count("Files uploaded", snapshot.uploadedFiles)
                total("Downloaded", bytes: snapshot.downloadedBytes)
                count("Files downloaded", snapshot.downloadedFiles)
                LabeledContent("Counting since", value: StatisticsFormat.since(snapshot.since, locale: locale))
            } header: {
                Text("Lifetime Totals")
            } footer: {
                StatisticsFootnote(since: snapshot.since)
            }
        }
        .formStyle(.grouped)
        .frame(height: 680)
        .task(id: StatsRenderKey(snapshot: snapshot, locale: locale.identifier)) { exporter.refresh(snapshot, locale: locale) }
    }

    private func total(_ title: String, bytes: UInt64) -> some View {
        LabeledContent(title) {
            Text(StatisticsFormat.gigabyteText(bytes, locale: locale))
                .monospacedDigit()
                .textSelection(.enabled)
                .help(StatisticsFormat.exactBytes(bytes, locale: locale))
        }
    }

    private func count(_ title: String, _ value: Int) -> some View {
        LabeledContent(title) {
            Text(StatisticsFormat.count(value, locale: locale)).monospacedDigit().textSelection(.enabled)
        }
    }
}
