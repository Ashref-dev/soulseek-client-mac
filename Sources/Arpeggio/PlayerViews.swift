import SwiftUI
import AppKit
import ArpeggioServices
import TransferEngine

/// Persistent mini player shared by every section: what's playing (from the file's own tags), transport,
/// and file actions. Previews stream from the cache until kept.
struct NowPlayingBar: View {
    let model: AppModel
    let navigator: Navigator
    var layout = PlayerLayout(detailHeight: .infinity)
    private var playback: Playback { model.playback }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let item = playback.item {
            if layout.mode == .compact { compact(item) } else { regular(item) }
        }
    }

    /// One row for short windows: cover, title, transport, scrubber and actions side by side.
    private func compact(_ item: Playback.Item) -> some View {
        GeometryReader { proxy in
            let allocation = CompactPlayerAllocation(width: proxy.size.width)
            let tags = playback.metadata
            HStack(spacing: CompactPlayerAllocation.spacing) {
                CoverArt(metadata: tags, image: playback.artwork, playing: playback.isPlaying && !playback.isWaiting, side: CompactPlayerAllocation.cover)
                if allocation.showsInfo {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tags.title ?? (item.fileName as NSString).deletingPathExtension)
                            .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                        if let message = playback.failure ?? playback.status {
                            Text(message).font(.caption)
                                .foregroundStyle(playback.failure != nil ? AnyShapeStyle(.red) : AnyShapeStyle(Color.arpeggio))
                                .lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(tags.artist ?? item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(width: allocation.info, alignment: .leading)
                    .help([tags.title ?? item.fileName, tags.artist ?? item.subtitle, playback.failure ?? playback.status ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
                } else {
                    Color.clear.frame(width: allocation.info)
                }
                transportButtons(playSize: 24, spacing: 14).frame(width: CompactPlayerAllocation.transport)
                HStack(spacing: 6) {
                    if allocation.showsTimes { Text(Self.clock(playback.currentTime)).frame(width: 40, alignment: .trailing) }
                    scrubber
                    if allocation.showsTimes { Text(Self.clock(playback.duration)).frame(width: 40, alignment: .leading) }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: allocation.scrubber)
                actions(item, compact: allocation.actions < 240).frame(width: allocation.actions, alignment: .trailing)
            }
            .padding(.horizontal, CompactPlayerAllocation.padding)
            .frame(maxHeight: .infinity)
        }
        .frame(height: PlayerLayout.compactHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func regular(_ item: Playback.Item) -> some View {
            GeometryReader { proxy in
                let allocation = PlayerWidthAllocation(width: proxy.size.width)
                VStack(spacing: 8) {
                    info(item, chips: allocation.showsMetadataChips)
                        .frame(width: allocation.content, alignment: .leading)
                        .clipped()
                    HStack(spacing: 16) {
                        transport.frame(width: allocation.transport)
                        actions(item, compact: allocation.actions < 240).frame(width: allocation.actions, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .frame(height: PlayerLayout.regularHeight)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }

    private func transportButtons(playSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button { playback.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.system(size: 15, weight: .medium)) }
                .help("Back 15 seconds (⌃⌘←)")
                .accessibilityLabel("Back 15 seconds")
                .disabled(playback.duration <= 0)
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: playSize))
                    .foregroundStyle(Color.arpeggio)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .disabled(playback.failure != nil)
            .help(playback.isPlaying ? "Pause (⌃⌘P)" : "Play (⌃⌘P)")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.system(size: 15, weight: .medium)) }
                .help("Forward 15 seconds (⌃⌘→)")
                .accessibilityLabel("Forward 15 seconds")
                .disabled(playback.duration <= 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var scrubber: some View {
        Scrubber(progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
                 buffered: playback.bufferedFraction, duration: playback.duration,
                 waiting: playback.isWaiting) { playback.seek(toFraction: $0) }
    }

    private func info(_ item: Playback.Item, chips: Bool) -> some View {
        let tags = playback.metadata
        let fileTitle = (item.fileName as NSString).deletingPathExtension
        let byline = [tags.artist, tags.album.map { album in tags.year.map { "\(album) (\($0))" } ?? album }].compactMap { $0 }
        let separator = " · "
        return HStack(spacing: 12) {
            CoverArt(metadata: tags, image: playback.artwork, playing: playback.isPlaying && !playback.isWaiting)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tags.title ?? fileTitle)
                        .font(.headline)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text(byline.isEmpty ? item.subtitle : byline.joined(separator: separator))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                if chips { HStack(spacing: 6) {
                    Chip(text: item.quality, symbol: "waveform")
                    ArtworkChip(metadata: tags, pixels: playback.artworkPixels)
                    Text(item.fileName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(item.remotePath ?? item.fileURL?.path ?? item.fileName)
                        .layoutPriority(-1)
                } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help([tags.title ?? fileTitle, byline.joined(separator: separator), item.subtitle].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var transport: some View {
        VStack(spacing: 4) {
            transportButtons(playSize: 32, spacing: 22)
            HStack(spacing: 8) {
                Text(Self.clock(playback.currentTime)).frame(width: 42, alignment: .trailing)
                scrubber
                Text(Self.clock(playback.duration)).frame(width: 42, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let message = playback.failure ?? playback.status {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(playback.failure != nil ? AnyShapeStyle(.red) : AnyShapeStyle(Color.arpeggio))
                    .lineLimit(1).truncationMode(.middle)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: playback.failure ?? playback.status)
    }

    private func actions(_ item: Playback.Item, compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            HStack(spacing: 6) {
                Button { playback.volume = playback.volume == 0 ? 1 : 0 } label: {
                    Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : playback.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(playback.volume == 0 ? "Unmute (⌃⌘M)" : "Mute (⌃⌘M)")
                .accessibilityLabel(playback.volume == 0 ? "Unmute" : "Mute")
                .accessibilityValue("Volume \(Int(playback.volume * 100)) percent")
                .contextMenu {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                        Button("Volume \(Int(level * 100))%") { playback.volume = Float(level) }
                    }
                }
                if !compact {
                    Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.volume = Float($0) }), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 80)
                        .accessibilityLabel("Volume")
                }
            }
            KeepButton(model: model, navigator: navigator, item: item, compact: compact)
            Button { Task { await model.stopPlayback() } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(item.isPreview ? "Stop and discard the preview" : "Close player")
                .accessibilityLabel("Close player")
        }
        .fixedSize()
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: .capsule)
            .fixedSize()
    }
}

private struct ArtworkChip: View {
    let metadata: TrackMetadata
    let pixels: String?
    var body: some View {
        if !metadata.resolved {
            Chip(text: "Reading tags…", symbol: "ellipsis")
        } else if let size = pixels {
            Chip(text: "Cover \(size)", symbol: "photo", tint: .green)
                .help("This file has embedded cover art")
        } else {
            Chip(text: "No cover art", symbol: "photo.badge.exclamationmark", tint: .orange)
                .help("This file has no embedded cover art")
        }
    }
}

/// Embedded cover art, or an animated placeholder. Click to see it large.
private struct CoverArt: View {
    let metadata: TrackMetadata
    let image: CGImage?
    let playing: Bool
    var side: CGFloat = 58
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { if image != nil { expanded = true } } label: {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill().transition(.opacity)
                } else {
                    LinearGradient(colors: [Color.arpeggio, Color.arpeggio.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform")
                        .font(.system(size: side * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing && !reduceMotion)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: side * 0.155))
            .overlay(RoundedRectangle(cornerRadius: side * 0.155).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: image != nil)
        }
        .buttonStyle(.plain)
        .help(image != nil ? "Show cover art" : "No embedded cover art")
        .accessibilityLabel(image != nil ? "Cover art" : "No cover art")
        .popover(isPresented: $expanded, arrowEdge: .top) {
            if let image {
                VStack(alignment: .leading, spacing: 8) {
                    Image(decorative: image, scale: 2).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 360)
                        .clipShape(.rect(cornerRadius: 8))
                    if let title = metadata.title { Text(title).font(.headline) }
                    Text([metadata.artist, metadata.album, metadata.year].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }
}

/// Seek bar: played and downloaded bands, a hover playhead with the time under the pointer, and a knob while engaged.
private struct Scrubber: View {
    let progress: Double
    let buffered: Double
    let duration: Double
    let waiting: Bool
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @State private var hover: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let shown = min(1, max(0, dragging ?? progress))
            let engaged = hover != nil || dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.primary.opacity(0.16)).frame(width: width * min(1, max(0, buffered)))
                Capsule()
                    .fill(LinearGradient(colors: [Color.arpeggio.opacity(0.75), Color.arpeggio], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(engaged ? 6 : 4, width * shown))
                if let hover, dragging == nil {
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1.5, height: 12).offset(x: width * hover)
                }
            }
            .frame(height: engaged ? 7 : 4)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: 13, height: 13)
                    .offset(x: width * shown - 6.5)
                    .scaleEffect(engaged ? 1 : 0.4)
                    .opacity(engaged ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                if let point = dragging ?? hover, duration > 0 {
                    Text(NowPlayingBar.clock(point * duration))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.regularMaterial, in: .capsule)
                        .fixedSize()
                        .offset(x: min(max(0, width * point - 18), width - 36), y: -20)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case .active(let location) = phase { hover = min(1, max(0, location.x / width)) } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(1, max(0, $0.location.x / width)) }
                .onEnded { value in seek(min(1, max(0, value.location.x / width))); dragging = nil })
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.2), value: engaged)
            .opacity(waiting ? 0.65 : 1)
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(NowPlayingBar.clock(progress * duration)) of \(NowPlayingBar.clock(duration)), \(Int(buffered * 100)) percent downloaded")
        .accessibilityAdjustableAction { direction in
            seek(min(1, max(0, progress + (direction == .increment ? 0.05 : -0.05))))
        }
    }
}

/// Short-lived confirmation that slides up from the bottom of the content area.
struct NoticeToast: View {
    let model: AppModel
    let navigator: Navigator
    /// Measured player height plus a gap, from `ToastGeometry`.
    var bottomPadding: Double = ToastGeometry.gap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: 12) {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(.white, Color.arpeggio)
                        .symbolEffect(.bounce, options: .nonRepeating, value: notice.id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.title).font(.callout.weight(.semibold))
                        Text(notice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    if notice.action == .showDownloads {
                        Button("Show") { navigator.go(.downloads); model.notice = nil }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.arpeggio)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .id(notice.id)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)))
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement("\(notice.title): \(notice.detail)").post()
                    try? await Task.sleep(for: .seconds(3.2))
                    if model.notice?.id == notice.id { model.notice = nil }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, bottomPadding)
        .animation(reduceMotion ? .default : .spring(duration: 0.4, bounce: 0.3), value: model.notice?.id)
        .allowsHitTesting(model.notice != nil)
    }
}

/// Keeps a preview, then shows the saved file's progress and lands on "Saved" with a Finder shortcut.
private struct KeepButton: View {
    let model: AppModel
    let navigator: Navigator
    let item: Playback.Item
    let compact: Bool
    @State private var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transfer: Transfer? { item.transferID.flatMap { id in model.transfers.first { $0.id == id } } }

    var body: some View {
        Group {
            if item.isPreview {
                Button {
                    working = true
                    Task { await model.keepPreview(); working = false }
                } label: {
                    Label("Download", systemImage: working ? "ellipsis.circle" : "arrow.down.circle.fill")
                        .labelStyle(AdaptiveLabel(compact: compact))
                        .symbolEffect(.pulse, isActive: working && !reduceMotion)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(working)
                .help("Keep this file: it finishes straight into your download folder")
            } else if let transfer, transfer.status != .completed, item.transferID != nil {
                Button { navigator.go(.downloads) } label: {
                    HStack(spacing: 6) {
                        ProgressRing(progress: transfer.progress).frame(width: 14, height: 14)
                        if !compact {
                            Text("Saving \(transfer.progress.formatted(.percent.precision(.fractionLength(0))))")
                                .monospacedDigit().contentTransition(.numericText())
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Saving to your download folder. Click to see it in Downloads.")
                .transition(.scale.combined(with: .opacity))
            } else if let url = transfer?.destination.map(URL.init(fileURLWithPath:)) ?? item.fileURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label(item.fileURL == nil ? "Saved" : "Show", systemImage: item.fileURL == nil ? "checkmark.circle.fill" : "folder")
                        .labelStyle(AdaptiveLabel(compact: compact))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(item.fileURL == nil ? .green : nil)
                .help("Show in Finder")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: item.isPreview)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: transfer?.status)
    }
}

private struct AdaptiveLabel: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { HStack(spacing: 5) { configuration.icon; configuration.title } }
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.2)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(Color.arpeggio, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.3), value: progress)
        }
    }
}
