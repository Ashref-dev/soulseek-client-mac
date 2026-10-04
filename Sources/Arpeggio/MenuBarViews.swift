import SwiftUI
import AppKit
import ArpeggioServices

/// The Arpeggio mark: three beamed notes rising. Dimmed when offline, with a moon when away
/// and an arrow while someone is downloading from you.
enum MenuBarGlyph {
    static func image(presence: Presence, uploading: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.setAlpha(presence == .offline ? 0.38 : 1)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.setFill()
            func beamTop(_ x: CGFloat) -> CGFloat { 10.9 + (x - 5.0) * 0.36 }
            for center in [NSPoint(x: 3.3, y: 3.0), NSPoint(x: 9.5, y: 4.9), NSPoint(x: 15.7, y: 6.8)] {
                let head = NSBezierPath(ovalIn: NSRect(x: -2.75, y: -2.0, width: 5.5, height: 4.0))
                var transform = AffineTransform(rotationByDegrees: 20)
                transform.append(AffineTransform(translationByX: center.x, byY: center.y))
                head.transform(using: transform)
                head.fill()
                let stemX = center.x + 1.25
                NSBezierPath(rect: NSRect(x: stemX, y: center.y, width: 1.4, height: beamTop(stemX + 1.4) - center.y)).fill()
            }
            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: 4.55, y: beamTop(4.55))); beam.line(to: NSPoint(x: 18.35, y: beamTop(18.35)))
            beam.line(to: NSPoint(x: 18.35, y: beamTop(18.35) - 2.1)); beam.line(to: NSPoint(x: 4.55, y: beamTop(4.55) - 2.1)); beam.close()
            beam.fill()
            context.endTransparencyLayer()
            context.setAlpha(1)
            let badge = NSRect(x: 16.4, y: 0.4, width: 5.6, height: 5.6)
            if uploading, presence != .offline {
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: badge.midX, y: badge.maxY)); arrow.line(to: NSPoint(x: badge.maxX, y: badge.midY + 0.2))
                arrow.line(to: NSPoint(x: badge.midX + 0.8, y: badge.midY + 0.2)); arrow.line(to: NSPoint(x: badge.midX + 0.8, y: badge.minY))
                arrow.line(to: NSPoint(x: badge.midX - 0.8, y: badge.minY)); arrow.line(to: NSPoint(x: badge.midX - 0.8, y: badge.midY + 0.2))
                arrow.line(to: NSPoint(x: badge.minX, y: badge.midY + 0.2)); arrow.close()
                NSColor.black.setFill(); arrow.fill()
            } else if presence == .away {
                NSColor.black.setFill(); NSBezierPath(ovalIn: badge).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: badge.offsetBy(dx: 2.1, dy: 1.6)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    let bootstrap: Bootstrap

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(presence: model.presence, uploading: model.activeUploads > 0))
            .accessibilityLabel("Arpeggio, \(model.statusText)\(model.activeUploads > 0 ? ", uploading" : "")")
            .task { await bootstrap.start(model) }
    }
}

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            activity.padding(14)
            if let item = model.playback.item { Divider(); nowPlaying(item).padding(.horizontal, 14).padding(.vertical, 10) }
            Divider()
            VStack(spacing: 2) {
                PanelRow(title: "Open Arpeggio", symbol: "macwindow") { openMain() }
                PanelRow(title: "Settings…", symbol: "gearshape") { NSApp.activate(); openSettings() }
                PanelRow(title: "Quit Arpeggio", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProfileAvatar(model: model, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.accountName).font(.headline).lineLimit(1)
                Text(model.statusText).font(.caption.weight(.medium)).foregroundStyle(model.statusTint)
            }
            Spacer()
            Menu {
                PresenceMenuItems(model: model, navigator: nil)
            } label: {
                Text(model.connection.isConnected ? "Status" : "Connect")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(model.settings.username.isEmpty)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Tile(symbol: "arrow.down", title: "Downloading", value: Format.speed(model.downloadSpeed),
                     detail: count(model.transfers.filter { !$0.upload && !$0.isPreview && $0.status.isActive }.count, "file"), active: model.downloadSpeed > 0)
                Tile(symbol: "arrow.up", title: "Uploading", value: Format.speed(model.uploadSpeed),
                     detail: count(model.activeUploads, "listener"), active: model.activeUploads > 0)
            }
            Label {
                Text(model.sharedCount > 0 ? "Sharing \(model.sharedCount.formatted()) files · \(Format.bytes(model.sharedBytes))" : "You aren’t sharing any folders yet")
            } icon: { Image(systemName: model.sharedCount > 0 ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.plus") }
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.statistics.uploadedBytes > 0 {
                Label("\(Format.bytes(model.statistics.uploadedBytes)) shared with \(model.statistics.listeners.count.formatted()) people so far", systemImage: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nowPlaying(_ item: Playback.Item) -> some View {
        HStack(spacing: 10) {
            Button { model.playback.togglePlay() } label: {
                Image(systemName: model.playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(Color.arpeggio)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.playback.metadata.title ?? (item.fileName as NSString).deletingPathExtension).font(.callout.weight(.medium)).lineLimit(1)
                Text(model.playback.metadata.artist ?? item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func count(_ value: Int, _ noun: String) -> String {
        value == 0 ? "Idle" : "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private func openMain() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct Tile: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(active ? Color.arpeggio : .secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: active)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

private struct PanelRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hovering ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
