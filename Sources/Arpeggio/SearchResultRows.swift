import SwiftUI
import SoulseekCore
import ArpeggioServices
import TransferEngine

/// Peer header: who has it, how much, and whether they can send now.
struct UserResultRow: View {
    let user: ResultUserNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(user.user)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
            Spacer(minLength: 12)
            Text(Format.speed(Double(user.speed)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            SlotBadge(free: user.freeSlot, queue: user.queue)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let folders = user.folders.count == 1 ? "1 folder" : "\(user.folders.count.formatted()) folders"
        let files = user.fileCount == 1 ? "1 file" : "\(user.fileCount.formatted()) files"
        return "\(folders) · \(files) · \(Format.bytes(user.bytes))"
    }
}

/// Release header: album name, its parent path, a compact quality line, and a one-click whole-folder download.
struct FolderResultRow: View {
    let folder: ResultFolderNode
    let online: Bool
    let download: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "opticaldisc")
                .foregroundStyle(Color.arpeggio)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.title)
                    .lineLimit(1)
                    .help(folder.path)
                if !folder.breadcrumb.isEmpty {
                    Text(folder.breadcrumb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 12)
            Text(details)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
            Button(action: download) {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!online)
            .help("Download Entire Folder")
            .accessibilityLabel("Download entire folder \(folder.title)")
        }
        .accessibilityElement(children: .contain)
    }

    private var details: String {
        let count = folder.tracks.count == 1 ? "1 file" : "\(folder.tracks.count) files"
        var parts = [count]
        if !folder.quality.isEmpty { parts.append(folder.quality) }
        if folder.seconds > 0 { parts.append(Format.duration(Double(folder.seconds))) }
        parts.append(Format.bytes(folder.bytes))
        return parts.joined(separator: " · ")
    }
}

/// Track row: name leads, secondary facts sit in narrow aligned columns. The leading glyph shows
/// download state live, and audio rows offer a play/preview button on hover.
struct TrackResultRow: View {
    let result: SearchResult
    let model: AppModel
    let listen: () -> Void
    @State private var hovering = false

    private var transfer: Transfer? { model.downloadState(user: result.user, path: result.file.path) }
    private var isCurrent: Bool { model.playback.item?.user == result.user && model.playback.item?.remotePath == result.file.path }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if result.file.isAudio && (hovering || isCurrent) {
                    Button(action: listen) {
                        Image(systemName: isCurrent && model.playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundStyle(Color.arpeggio)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(transfer?.status == .completed ? "Play" : "Preview: stream before downloading")
                    .accessibilityLabel(transfer?.status == .completed ? "Play \(result.file.name)" : "Preview \(result.file.name)")
                    .transition(.opacity)
                } else {
                    TrackStateGlyph(transfer: transfer, symbol: result.file.symbol)
                }
            }
            .frame(width: 18)
            Text(result.file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(transfer?.status == .completed ? Color.secondary : Color.primary)
                .help(result.file.path)
            if let transfer, transfer.status != .completed {
                Text(TrackStateGlyph.caption(transfer))
                    .font(.caption).foregroundStyle(transfer.status == .failed ? Color.red : Color.arpeggio)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 12)
            Group {
                Text(result.file.quality)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .trailing)
                Text(Format.clock(result.file.length))
                    .frame(width: 44, alignment: .trailing)
                Text(Format.bytes(result.file.size))
                    .frame(width: 68, alignment: .trailing)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: transfer?.status)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
    }
}

/// Leading status for a track: plain icon, queued, connecting, live progress ring, done or failed.
struct TrackStateGlyph: View {
    let transfer: Transfer?
    let symbol: String

    var body: some View {
        Group {
            switch transfer?.status {
            case .transferring:
                ProgressView(value: transfer?.progress ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Color.arpeggio)
            case .negotiating:
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(Color.arpeggio)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            case .queued:
                Image(systemName: "clock.fill").foregroundStyle(Color.arpeggio)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            case .cancelled, nil:
                Image(systemName: symbol).foregroundStyle(.tertiary)
            }
        }
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(transfer.map { $0.status.label } ?? "")
    }

    static func caption(_ transfer: Transfer) -> String {
        switch transfer.status {
        case .transferring: transfer.progress.formatted(.percent.precision(.fractionLength(0)))
        case .queued, .negotiating: transfer.queuePosition > 0 ? "Queued #\(transfer.queuePosition)" : "Starting…"
        case .failed: "Failed"
        case .paused: "Paused"
        default: ""
        }
    }
}

struct SlotBadge: View {
    let free: Bool
    let queue: UInt32

    var body: some View {
        Image(systemName: free ? "checkmark.circle.fill" : "hourglass")
            .foregroundStyle(free ? Color.green : Color.secondary)
            .frame(width: 18)
            .help(free ? "Free upload slot" : "Queued: \(queue)")
            .accessibilityLabel(free ? "Free slot" : "Queue \(queue)")
    }
}
