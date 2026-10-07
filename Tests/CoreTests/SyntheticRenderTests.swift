import AppKit
import Foundation
import SwiftUI
import Testing
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices
@testable import Arpeggio

/// Offscreen renders of new surfaces with synthetic data, written only when ARPEGGIO_UI_RENDER_OUTPUT is set.
/// They use a throwaway defaults suite and a temporary profile; they never open the owner's app or data.
private let renderOutput = ProcessInfo.processInfo.environment["ARPEGGIO_UI_RENDER_OUTPUT"]

@Suite(.serialized) @MainActor struct SyntheticRenderTests {
    private func render<V: View>(_ view: V, size: CGSize, name: String, scheme: ColorScheme = .light) throws {
        let directory = URL(fileURLWithPath: try #require(renderOutput), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    private func transfers() -> [Transfer] {
        func item(_ user: String, _ path: String, _ status: TransferStatus, _ done: Double = 0, position: UInt32 = 0, retries: Int = 0) -> Transfer {
            var transfer = Transfer(user: user, file: SharedFile(path: path, size: 42_000_000, attributes: [0: 320]))
            transfer.status = status; transfer.transferred = UInt64(42_000_000 * done); transfer.queuePosition = position; transfer.retries = retries
            if status == .transferring { transfer.speed = 1_400_000 }
            if status == .failed { transfer.error = "Couldn’t connect to this user." }
            return transfer
        }
        return [item("lowlight", "Music\\Synthetic Artist\\Glass Notes\\01 Opening.flac", .transferring, 0.62),
                item("lowlight", "Music\\Synthetic Artist\\Glass Notes\\02 Second.flac", .completed, 1),
                item("lowlight", "Music\\Synthetic Artist\\Glass Notes\\03 Third.flac", .queued),
                item("northwind", "Shares\\Other Artist\\Glass Notes\\01 Opening.flac", .negotiating, position: 14),
                item("northwind", "Shares\\Other Artist\\Glass Notes\\02 Second.flac", .failed, retries: 1),
                item("northwind", "loose-file.mp3", .paused, 0.2)]
    }

    @Test(.enabled(if: renderOutput != nil)) func transfersOutlineAndCompactPlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "arpeggio-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try AppModel(dataDirectory: root)
        model.transfers = transfers()
        model.downloadsSuspended = true
        let navigator = Navigator()
        for layout in TransferLayout.allCases {
            defaults.set(layout.rawValue, forKey: TransferLayout.preferenceKey(upload: false))
            try render(NavigationStack { TransfersView(model: model, navigator: navigator, upload: false) }.defaultAppStorage(defaults),
                       size: CGSize(width: 900, height: 360), name: "transfers-\(layout.rawValue)")
        }

        let tone = root.appendingPathComponent("Synthetic Tone.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try silentWave().write(to: tone)
        model.playback.volume = 0
        model.playback.playFile(tone, title: "Synthetic Tone", subtitle: "Generated fixture")
        for width in [600.0, 880] {
            try render(NowPlayingBar(model: model, navigator: navigator, layout: PlayerLayout(detailHeight: 508)),
                       size: CGSize(width: width, height: PlayerLayout.compactHeight), name: "player-compact-\(Int(width))")
        }
        try render(NowPlayingBar(model: model, navigator: navigator, layout: PlayerLayout(detailHeight: 900)),
                   size: CGSize(width: 880, height: PlayerLayout.regularHeight), name: "player-regular-880")
        model.playback.stop()
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
