import SwiftUI
import AppKit
import ArpeggioServices
import SoulseekCore
import Persistence

/// Compact profile for any Soulseek user, built only from data the server and peer actually returned.
struct UserProfileSheet: View {
    let username: String
    let model: AppModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var requestedAt: Date?
    @State private var timedOut = false

    private var online: Bool { model.connection.isConnected }
    private var record: UserRecord? { model.users.first { $0.username == username } }
    private var status: UInt32? { model.userStatuses[username] }
    private var stats: UserStatistics? { model.userStatistics[username] }
    private var profileText: String? { model.userDescriptions[username] }
    private var picture: NSImage? {
        guard let data = model.userPictures[username], let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            details.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            footer.padding(16)
        }
        .frame(width: 440)
        .frame(minHeight: 340)
        .task(id: online) { await request() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Avatar(image: picture, name: username)
            VStack(alignment: .leading, spacing: 3) {
                Text(username).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(status: online ? status : nil)
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
                if let record, record.trusted || record.ignored {
                    Text(record.ignored ? "Ignored" : "Trusted")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(record.ignored ? Color.secondary : Color.arpeggio)
                }
            }
            Spacer()
            if online {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await request(force: true) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Request profile again")
                    .disabled(isLoading)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Shared files", stats.map { Int($0.files).formatted() })
                row("Average speed", stats.flatMap { $0.speed > 0 ? Format.speed(Double($0.speed)) : nil })
                row("Country", stats?.country.flatMap(countryName))
                if let note = record?.note, !note.isEmpty { row("Your note", note) }
            }
            .font(.callout)

            Group {
                if let profileText, !profileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(profileText)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 40, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(placeholder).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Browse Files") { dismiss(); navigator.browse(username, model: model) }
                .disabled(!online)
            Button("Message") { dismiss(); navigator.message(username) }
            if record == nil {
                Button("Add to Users") { Task { await model.bookmark(username) } }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value ?? "-").textSelection(.enabled).lineLimit(2)
        }
    }

    // MARK: State

    private var isLoading: Bool { online && requestedAt != nil && !timedOut && profileText == nil }

    private var statusText: String {
        guard online else { return "Status unavailable while offline" }
        switch status {
        case 2: return "Online"
        case 1: return "Away"
        case 0: return "Offline"
        default: return "Status unknown"
        }
    }

    private var placeholder: String {
        if profileText != nil { return "No description provided." }
        if !online { return "Connect to request this user’s profile." }
        if timedOut { return stats == nil ? "No profile received. The user may be offline or unreachable." : "No description received. The user may be unreachable directly." }
        return "Requesting profile…"
    }

    private func request(force: Bool = false) async {
        guard online else { return }
        if !force, requestedAt != nil { return }
        requestedAt = .now
        timedOut = false
        await model.userInfo(username)
        try? await Task.sleep(for: .seconds(15))
        if !Task.isCancelled, profileText == nil { timedOut = true }
    }

    private func countryName(_ code: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return nil }
        return Locale.current.localizedString(forRegionCode: code).map { "\($0) (\(code.uppercased()))" } ?? code.uppercased()
    }
}

private struct Avatar: View {
    let image: NSImage?
    let name: String

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.arpeggio.opacity(0.75), Color.arpeggio.opacity(0.15))
                    .symbolRenderingMode(.palette)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
        .accessibilityLabel(image == nil ? "No picture for \(name)" : "Picture of \(name)")
    }
}
