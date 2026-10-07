import SwiftUI
import AppKit
import ArpeggioServices

/// Which diagnostic entries a list shows. Problems are warnings and errors; routine activity is everything else.
enum DiagnosticScope: String, CaseIterable, Identifiable {
    case problems, all
    var id: Self { self }
    var title: String { self == .problems ? "Problems" : "All Activity" }

    func filter(_ entries: [DiagnosticEntry]) -> [DiagnosticEntry] {
        self == .problems ? entries.filter { $0.severity != .info } : entries
    }
}

extension DiagnosticSeverity {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
    var tint: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
    var title: String { rawValue.capitalized }
}

/// Settings > Advanced diagnostics: retained problems first, routine activity on request, and a support report
/// that leaves out names, paths, addresses and raw messages.
struct DiagnosticsSection: View {
    let model: AppModel
    @State private var scope = DiagnosticScope.problems
    @State private var copied = false

    var body: some View {
        let entries = model.diagnosticStore.entries
        let shown = Array(scope.filter(entries).suffix(300))
        let problems = model.diagnosticStore.problems.count
        Section {
            Picker("Show", selection: $scope) {
                ForEach(DiagnosticScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Diagnostic scope")
            if shown.isEmpty {
                Text(scope == .problems ? "No problems recorded. Routine peer activity is under All Activity." : "No diagnostic messages yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(shown) { entry in DiagnosticRow(entry: entry) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 170)
                .accessibilityLabel("\(scope.title), \(shown.count) entries")
            }
            HStack {
                Text("\(problems) problem\(problems == 1 ? "" : "s") · \(entries.count) entries kept")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(copied ? "Copied" : "Copy Report") { copyReport() }
                    .help("Copies a privacy-safe summary: times, severities and categories, without usernames, paths, addresses or message text")
                Button("Copy Details") { copyDetails(shown) }
                    .disabled(shown.isEmpty)
                    .help("Copies the full local messages shown above. Review before sharing: they can include usernames and paths.")
            }
            .controlSize(.small)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Problems are kept even when routine peer activity is busy. Copy Report is safe to share; Copy Details is for your own troubleshooting.")
                .foregroundStyle(.secondary)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.redactedCopyReport(), forType: .string)
        copied = true
    }

    private func copyDetails(_ entries: [DiagnosticEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries.map(DiagnosticRow.line).joined(separator: "\n"), forType: .string)
    }
}

private struct DiagnosticRow: View {
    let entry: DiagnosticEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.severity.symbol).foregroundStyle(entry.severity.tint).imageScale(.small)
                .accessibilityLabel(entry.severity.title)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary).monospacedDigit()
            Text(entry.category.rawValue.capitalized).foregroundStyle(.secondary)
            Text(entry.message).foregroundStyle(entry.severity == .info ? .secondary : .primary)
                .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    static func line(_ entry: DiagnosticEntry) -> String {
        "\(entry.timestamp.ISO8601Format()) [\(entry.severity.rawValue)] \(entry.category.rawValue): \(entry.message)"
    }
}
