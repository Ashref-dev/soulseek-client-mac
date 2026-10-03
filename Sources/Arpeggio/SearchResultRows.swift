import SwiftUI
import SoulseekCore
import ArpeggioServices

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

/// Track row: name leads, secondary facts sit in narrow aligned columns.
struct TrackResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.file.symbol)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(result.file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.file.path)
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
        .accessibilityElement(children: .combine)
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
