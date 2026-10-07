import SwiftUI
import AppKit
import ArpeggioServices
import SoulseekCore

extension AppModel {
    var accountName: String {
        connection.isConnected ? activeAccount : (settings.username.isEmpty ? "No Account" : settings.username)
    }

    var statusText: String {
        switch connection {
        case .connected: presence == .away ? "Away" : "Available"
        case .connecting, .reconnecting: connection.label
        case .failed: "Offline · connection lost"
        case .offline: settings.username.isEmpty ? "Not signed in" : "Offline"
        }
    }

    var statusTint: Color {
        switch connection {
        case .connected: presence == .away ? .orange : .green
        case .connecting, .reconnecting: .yellow
        case .failed: .red
        case .offline: .secondary
        }
    }

    func reconnect(_ navigator: Navigator?) {
        Task {
            let password = await savedPassword()
            if password.isEmpty { navigator?.showLogin = true } else { await login(password: password) }
        }
    }
}

struct ProfileAvatar: View {
    let model: AppModel
    var size: CGFloat = 34
    var showsPresence = true

    private var initials: String {
        let letters = model.accountName.filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty || model.settings.username.isEmpty ? "" : String(letters.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = PictureCache.image(model.profilePicture) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    LinearGradient(colors: [Color.arpeggio, Color.arpeggio.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay {
                            if initials.isEmpty {
                                Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.white.opacity(0.9))
                            } else {
                                Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            }
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
            if showsPresence {
                Circle()
                    .fill(model.statusTint)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .shadow(color: model.statusTint.opacity(0.6), radius: model.connection.isConnected ? 3 : 0)
                    .offset(x: 2, y: 2)
                    .animation(.smooth, value: model.statusText)
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
enum PictureCache {
    private static var cached: (Int, NSImage)?
    static func image(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let cached, cached.0 == data.hashValue { return cached.1 }
        guard let image = NSImage(data: data) else { return nil }
        cached = (data.hashValue, image)
        return image
    }
}

struct PresenceMenuItems: View {
    let model: AppModel
    let navigator: Navigator?

    var body: some View {
        if model.connection.isConnected {
            Toggle(isOn: Binding(get: { model.presence == .available }, set: { if $0 { Task { await model.setAway(false) } } })) {
                Label { Text("Available") } icon: { Image(nsImage: BirdGlyph.image(BirdState(presence: .available))) }
            }
            Toggle(isOn: Binding(get: { model.presence == .away }, set: { if $0 { Task { await model.setAway(true) } } })) {
                Label { Text("Away") } icon: { Image(nsImage: BirdGlyph.image(BirdState(presence: .away))) }
            }
            Divider()
            Button("Disconnect") { Task { await model.disconnect() } }
        } else {
            Button(model.settings.username.isEmpty ? "Sign In…" : "Connect") {
                if model.settings.username.isEmpty { navigator?.showLogin = true } else { model.reconnect(navigator) }
            }
            .disabled(model.connection.isBusy)
        }
    }
}

struct AccountFooter: View {
    let model: AppModel
    let navigator: Navigator

    var body: some View {
        Menu {
            PresenceMenuItems(model: model, navigator: navigator)
            Divider()
            Button("Account and Server…") { navigator.showLogin = true }
            SettingsLink { Text("Profile and Settings…") }
            if !model.settings.username.isEmpty {
                Divider()
                Button("Sign Out…", role: .destructive) { navigator.confirmSignOut = true }
            }
        } label: {
            HStack(spacing: 10) {
                ProfileAvatar(model: model)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.accountName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(model.statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.statusTint)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Label(model.settings.isSoulseekServer ? model.settings.server : model.settings.serverEndpoint,
                          systemImage: model.settings.isLocalServer ? "exclamationmark.triangle.fill" : "globe")
                        .labelStyle(CompactIconLabel())
                        .font(.caption)
                        .foregroundStyle(model.settings.isLocalServer ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        .padding(10)
        .help("Status, account and connection")
        .accessibilityLabel("Account \(model.accountName), \(model.statusText)")
    }
}

struct CompactIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.imageScale(.small); configuration.title }
    }
}
