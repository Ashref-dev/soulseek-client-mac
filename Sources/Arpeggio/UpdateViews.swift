import SwiftUI
import AppKit
import ArpeggioServices

struct UpdateBanner: View {
    let model: AppModel
    @State private var showNotes = false

    var body: some View {
        Group {
            switch model.update {
            case .idle: EmptyView()
            case .checking:
                bar(symbol: "arrow.triangle.2.circlepath", tint: .secondary) {
                    Text("Checking for updates…")
                    ProgressView().controlSize(.small)
                }
            case .upToDate:
                bar(symbol: "checkmark.seal.fill", tint: .green) {
                    Text("Arpeggio \(Updater.currentVersion) is the latest version.")
                    Spacer()
                    dismiss
                }
                .task { try? await Task.sleep(for: .seconds(4)); if model.update == .upToDate { model.dismissUpdate() } }
            case .available(let release):
                bar(symbol: "arrow.down.app.fill", tint: .arpeggio) {
                    Text("Arpeggio \(release.version) is available.").fontWeight(.medium)
                    Text("You have \(Updater.currentVersion).").foregroundStyle(.secondary)
                    Spacer()
                    Button("What’s New") { showNotes = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotes(release: release) }
                    if model.canUpdateInPlace {
                        Button("Install and Relaunch") { install(release) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Link("Download", destination: release.page).controlSize(.small)
                    }
                    dismiss
                }
            case .downloading(let release):
                bar(symbol: "arrow.down.circle", tint: .arpeggio) {
                    Text("Downloading and verifying Arpeggio \(release.version)…")
                    ProgressView().controlSize(.small)
                }
            case .ready(let release):
                bar(symbol: "checkmark.circle.fill", tint: .green) { Text("Arpeggio \(release.version) is installed. Relaunching…") }
            case .failed(let message):
                bar(symbol: "exclamationmark.triangle.fill", tint: .orange) {
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("Try Again") { Task { await model.checkForUpdates() } }.controlSize(.small)
                    dismiss
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.update)
    }

    private var dismiss: some View {
        Button { model.dismissUpdate() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
    }

    private func bar<Content: View>(symbol: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            content()
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func install(_ release: Release) {
        Task { if await model.installUpdate(release) { NSApp.terminate(nil) } }
    }
}

private struct ReleaseNotes: View {
    let release: Release
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Arpeggio \(release.version)").font(.headline)
            ScrollView {
                Text((try? AttributedString(markdown: release.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(release.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            Link("View on GitHub", destination: release.page).font(.callout)
        }
        .padding(16)
        .frame(width: 380)
    }
}
