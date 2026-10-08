import AppKit
import Foundation
import SwiftUI
import Testing
import Persistence
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices
@testable import Arpeggio

/// Offscreen renders of the menu bar icon states, the menu bar panel and the transfers list, written only when
/// ARPEGGIO_MENUBAR_RENDER_OUTPUT names a folder. Windows sit far off every screen, the model uses a temporary
/// profile and synthetic data, and nothing touches the network or the owner's app.
private let menuBarRenderOutput = ProcessInfo.processInfo.environment["ARPEGGIO_MENUBAR_RENDER_OUTPUT"]

@Suite(.serialized) @MainActor struct MenuBarRenderTests {
    private func write(_ image: CGImage, _ name: String) throws {
        let directory = URL(fileURLWithPath: try #require(menuBarRenderOutput), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func snapshot<V: View>(_ view: V, dark: Bool) throws -> CGImage {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let offscreen = CGPoint(x: -30_000, y: -30_000)
        let window = NSWindow(contentRect: CGRect(origin: offscreen, size: CGSize(width: 10, height: 10)), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.setFrameOrigin(offscreen)
        window.orderFrontRegardless()
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        return try #require(bitmap.cgImage)
    }

    /// Enlarges without smoothing, so every pixel of a menu bar sized render stays visible.
    private func enlarge(_ image: CGImage, by factor: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
        return try #require(context.makeImage())
    }

    private func rendered<V: View>(_ view: V, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    @Test(.enabled(if: menuBarRenderOutput != nil)) func menuBarIconStates() throws {
        for dark in [false, true] {
            let strip = try rendered(MenuBarStrip(dark: dark), scale: 2)
            try write(strip, "icons-menubar-actual-\(dark ? "dark" : "light")")
            try write(try enlarge(strip, by: 4), "icons-menubar-pixels-\(dark ? "dark" : "light")")
        }
        try write(try rendered(MenuBarIconSheet(), scale: 2), "icons-states-detail")
    }

    private func panelModel(_ root: URL) throws -> AppModel {
        let model = try AppModel(dataDirectory: root)
        let music = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        model.settings.username = "lowlight"
        model.settings.downloadDirectory = root.path
        model.settings.sharedFolders = [ShareFolder(path: music.path)]
        model.indexedFolders = model.settings.sharedFolders
        model.indexedExclusions = model.settings.shareExclusions ?? []
        model.sharedCount = 12_345
        model.sharedBytes = 221_400_000_000
        var statistics = TransferStatistics(since: Date(timeIntervalSince1970: 1_767_225_600))
        statistics.uploadedBytes = 1_240_000_000
        statistics.downloadedBytes = 5_630_000_000
        statistics.listeners = Set((1...34).map { "listener\($0)" })
        model.statistics = statistics
        return model
    }

    private func transfer(_ user: String, _ path: String, upload: Bool = false, _ status: TransferStatus, done: Double = 0, speed: Double = 0) -> Transfer {
        var item = Transfer(user: user, file: SharedFile(path: path, size: 42_000_000, attributes: [0: 320]), upload: upload)
        item.status = status; item.transferred = UInt64(42_000_000 * done); item.speed = speed
        return item
    }

    private func renderPanel(_ model: AppModel, _ name: String) throws {
        for dark in [false, true] {
            let panel = PanelBackdrop(dark: dark) { MenuBarPanelContent(model: model, live: MenuBarPanelLive(model)) }
            try write(try snapshot(panel, dark: dark), "panel-\(name)-\(dark ? "dark" : "light")")
        }
    }

    @Test(.enabled(if: menuBarRenderOutput != nil)) func menuBarPanelStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-menubar-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try panelModel(root)

        model.connection = .connected
        model.transfers = [transfer("northwind", "Shares\\Glass Notes\\01 Opening.flac", .transferring, done: 0.72, speed: 640_000),
                           transfer("northwind", "Shares\\Glass Notes\\02 Second.flac", .transferring, done: 0.41, speed: 480_000),
                           transfer("basalt", "Music\\Low Tide\\03 Harbour.flac", .transferring, done: 0.18, speed: 310_000)]
            + (4...12).map { transfer("northwind", "Shares\\Glass Notes\\\($0) Track.flac", .queued) }
            + [transfer("quietroom", "Music\\Synthetic Artist\\Live Set.flac", upload: true, .transferring, done: 0.33, speed: 320_000)]
        let tone = root.appendingPathComponent("Synthetic Tone.wav")
        try silentWave().write(to: tone)
        model.playback.volume = 0
        model.playback.playFile(tone, title: "Synthetic Tone", subtitle: "Generated fixture")
        try renderPanel(model, "active")
        model.playback.stop()

        model.awayNow = true
        model.downloadsSuspended = true
        model.transfers = (1...4).map { transfer("northwind", "Shares\\Glass Notes\\0\($0) Track.flac", .queued) }
        try renderPanel(model, "away-downloads-paused")

        model.awayNow = false
        model.downloadsSuspended = false
        model.connection = .offline
        model.transfers = []
        model.indexing = true
        model.shareProgress.filesProcessed = 4_812
        try renderPanel(model, "offline-indexing")

        model.indexing = false
        model.settings.username = ""
        model.settings.sharedFolders = []
        model.statistics = TransferStatistics()
        try renderPanel(model, "signed-out")
    }

    @Test(.enabled(if: menuBarRenderOutput != nil)) func transfersListLeavesEmptySpaceClean() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-menubar-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "arpeggio-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TransferLayout.flat.rawValue, forKey: TransferLayout.preferenceKey(upload: false))
        let model = try AppModel(dataDirectory: root)
        model.settings.downloadDirectory = root.path
        model.connection = .connected
        model.transfers = [transfer("lowlight", "Music\\Synthetic Artist\\Glass Notes\\01 Opening.flac", .transferring, done: 0.62, speed: 1_400_000),
                           transfer("lowlight", "Music\\Synthetic Artist\\Glass Notes\\02 Second.flac", .completed, done: 1),
                           transfer("lowlight", "Music\\Synthetic Artist\\Glass Notes\\03 Third.flac", .queued),
                           transfer("northwind", "Shares\\Other Artist\\Glass Notes\\01 Opening.flac", .negotiating),
                           transfer("northwind", "loose-file.mp3", .paused, done: 0.2)]
        let navigator = Navigator()
        for dark in [false, true] {
            let list = NavigationStack { TransfersView(model: model, navigator: navigator, upload: false) }
                .defaultAppStorage(defaults)
                .frame(width: 900, height: 420)
            try write(try snapshot(list, dark: dark), "transfers-flat-\(dark ? "dark" : "light")")
        }
    }

    private func silentWave() -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let samples = 8000 * 3
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2)); data.append(Data(count: samples * 2))
        return data
    }
}

/// A stand-in for the menu bar: system symbols and a clock around every Arpeggio state, for weight and size.
private struct MenuBarStrip: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            ForEach(MenuBarState.allCases, id: \.self) { state in
                Image(nsImage: MenuBarGlyph.image(state)).renderingMode(.template)
            }
            Image(systemName: "battery.75percent")
            Text("Thu 14:06")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(dark ? Color(red: 0.13, green: 0.12, blue: 0.17) : Color(red: 0.93, green: 0.92, blue: 0.96))
    }
}

/// Every state enlarged from the vector glyph, on light and dark menu bars, with its spoken label.
private struct MenuBarIconSheet: View {
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(MenuBarState.allCases, id: \.self) { state in
                    Text(state.accessibilityLabel.replacingOccurrences(of: "Arpeggio, ", with: ""))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 128, height: 28)
                }
            }
            ForEach([false, true], id: \.self) { dark in
                GridRow {
                    ForEach(MenuBarState.allCases, id: \.self) { state in
                        Image(nsImage: MenuBarGlyph.image(state))
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 100, height: 90)
                            .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
                            .frame(width: 128, height: 112)
                            .background(dark ? Color(red: 0.13, green: 0.12, blue: 0.17) : Color(red: 0.93, green: 0.92, blue: 0.96))
                    }
                }
            }
        }
        .background(.white)
    }
}

/// Approximates the menu bar panel's surroundings: a wallpaper and the panel's rounded material.
private struct PanelBackdrop<Content: View>: View {
    let dark: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.08)))
            .padding(24)
            .background(LinearGradient(colors: dark ? [Color(red: 0.16, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.06, blue: 0.12)]
                                                    : [Color(red: 0.80, green: 0.78, blue: 0.95), Color(red: 0.93, green: 0.88, blue: 0.84)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
