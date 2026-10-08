import SwiftUI
import ArpeggioServices

/// Presence on the right of the panel header: the purple bird and a menu for Available, Away and Disconnect
/// while connected, as in the main window. Offline it offers Connect, or Sign In without an account.
/// Controls use the native bordered styles: the panel already sits on the system's own glass.
struct PresenceControl: View {
    let model: AppModel
    let connect: () -> Void
    let signIn: () -> Void

    var body: some View {
        Group {
            if model.connection.isConnected {
                Menu {
                    PresenceMenuItems(model: model, navigator: nil)
                } label: {
                    Label {
                        Text(model.presence == .away ? "Away" : "Available")
                    } icon: {
                        Image(nsImage: BirdGlyph.image(BirdState(presence: model.presence)))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .help("Choose Available or Away")
                .accessibilityLabel("Status, \(model.statusText)")
            } else if model.settings.username.isEmpty {
                Button("Sign In…", action: signIn)
                    .help("Open Arpeggio to sign in to Soulseek")
            } else {
                Button(action: connect) {
                    Label {
                        Text(model.connection.isBusy ? "Connecting…" : "Connect")
                    } icon: {
                        Image(nsImage: BirdGlyph.image(BirdState(presence: .offline)))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .disabled(model.connection.isBusy)
                .help("Connect to Soulseek")
                .accessibilityLabel(model.connection.isBusy ? "Connecting" : "Connect")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }
}

/// One direction of transfers: what is moving, how fast and how far, and its Pause or Resume control.
struct TransferRow: View {
    let upload: Bool
    let pulse: TransferPulse
    let suspended: Bool
    let toggle: () -> Void

    private var title: String { upload ? "Uploads" : "Downloads" }
    private var moving: Bool { pulse.transferring > 0 && !suspended }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: upload ? "arrow.up" : "arrow.down")
                .font(.callout.weight(.bold))
                .foregroundStyle(moving ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(moving ? AnyShapeStyle(Color.arpeggio) : AnyShapeStyle(.fill.tertiary), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if moving {
                        Text(Format.speed(pulse.speed))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if moving, let progress = pulse.progress {
                    PanelProgressBar(value: progress).padding(.top, 4)
                }
            }
            .accessibilityElement(children: .combine)
            DirectionToggle(title: title, suspended: suspended, action: toggle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var detail: String {
        let waiting = pulse.waiting > 0 ? "\(pulse.waiting.formatted()) waiting" : nil
        if suspended { return ["Paused", waiting].compactMap { $0 }.joined(separator: " · ") }
        guard pulse.transferring > 0 else { return waiting ?? "Idle" }
        let files = pulse.transferring == 1 ? "1 file" : "\(pulse.transferring.formatted()) files"
        let people = pulse.people == 1 ? "1 person" : "\(pulse.people.formatted()) people"
        return ["\(files) \(upload ? "to" : "from") \(people)", waiting].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Pause, or Resume drawn prominently while a whole direction is paused, since that is the likely next step.
private struct DirectionToggle: View {
    let title: String
    let suspended: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: suspended ? "play.fill" : "pause.fill")
        }
        Group {
            if suspended { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .buttonBorderShape(.circle)
        .help(suspended ? "Resume \(title)" : "Pause \(title)")
        .accessibilityLabel(suspended ? "Resume \(title)" : "Pause \(title)")
    }
}

/// A thin brand-purple bar for how far the moving files are.
private struct PanelProgressBar: View {
    let value: Double

    var body: some View {
        Capsule()
            .fill(.fill.tertiary)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.arpeggio)
                        .frame(width: max(4, proxy.size.width * min(1, max(0, value))))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Files in progress")
            .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}

struct NowPlayingRow: View {
    let playback: Playback
    let item: Playback.Item

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.arpeggio)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            VStack(alignment: .leading, spacing: 1) {
                Text(playback.metadata.title ?? (item.fileName as NSString).deletingPathExtension)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(playback.metadata.artist ?? item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }
}

/// The shared library, with a way into Shared Files when nothing is shared yet, and lifetime totals.
struct ShareSummary: View {
    let live: MenuBarPanelLive
    let isOpen: Bool
    let openSharedFiles: () -> Void

    var body: some View {
        let status = live.share
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if status.isIndexing, isOpen {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: status.symbol)
                    }
                }
                .foregroundStyle(status.isSharing ? AnyShapeStyle(Color.arpeggio) : AnyShapeStyle(.secondary))
                .frame(width: 18)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.headline).font(.callout)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !status.isSharing, !status.isIndexing {
                        Button("Open Shared Files", action: openSharedFiles)
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.arpeggio)
                            .padding(.top, 2)
                            .help("Open Arpeggio to manage Shared Files")
                    }
                }
            }
            if let lifetime {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Color.arpeggio)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(lifetime)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .help(live.since.map { "Totals since \(StatisticsFormat.since($0))" } ?? "Lifetime totals")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Lifetime totals: \(lifetime)")
            }
        }
    }

    private var lifetime: String? {
        var parts: [String] = []
        if live.uploadedBytes > 0 {
            let people = live.listeners == 1 ? "1 person" : "\(live.listeners.formatted()) people"
            parts.append(live.listeners > 0 ? "\(Format.bytes(live.uploadedBytes)) shared with \(people)" : "\(Format.bytes(live.uploadedBytes)) shared")
        }
        if live.downloadedBytes > 0 { parts.append("\(Format.bytes(live.downloadedBytes)) downloaded") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A round button for the panel's quick actions, named by its tooltip and for VoiceOver.
struct PanelIconButton: View {
    let symbol: String
    let title: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}
