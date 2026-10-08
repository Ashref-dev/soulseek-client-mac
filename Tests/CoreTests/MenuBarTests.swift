import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import SoulseekCore
import TransferEngine
@testable import ArpeggioServices
@testable import Arpeggio

private func transfer(_ user: String, upload: Bool = false, _ status: TransferStatus, size: UInt64 = 1_000, done: UInt64 = 0,
                      speed: Double = 0, preview: Bool = false) -> Transfer {
    var item = Transfer(user: user, file: SharedFile(path: "Music\\\(user)\\Track.flac", size: size), upload: upload)
    item.status = status; item.transferred = done; item.speed = speed
    if preview { item.preview = true }
    return item
}

private func alpha(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

/// Mutex is noncopyable, so a class holds it where Sendable callbacks need to capture a count.
private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@MainActor private func eventually(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async throws {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { Issue.record("Condition not met within \(timeout)"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func menuBarStateFollowsPresenceAndMovingBytesOnly() {
    let down = transfer("ann", .transferring), up = transfer("bob", upload: true, .transferring)
    #expect(MenuBarState(presence: .offline, transfers: [down, up]) == .offline)
    #expect(MenuBarState(presence: .available, transfers: []) == .available)
    #expect(MenuBarState(presence: .away, transfers: []) == .away)
    #expect(MenuBarState(presence: .available, transfers: [down]) == .downloading)
    #expect(MenuBarState(presence: .available, transfers: [up]) == .uploading)
    #expect(MenuBarState(presence: .available, transfers: [down, up]) == .downloadingAndUploading)
    #expect(MenuBarState(presence: .away, transfers: [up]) == .uploading)
    let still = [transfer("cy", .queued), transfer("dee", .negotiating), transfer("eve", .paused), transfer("fay", .completed),
                 transfer("gus", .failed), transfer("hal", .transferring, preview: true)]
    #expect(MenuBarState(presence: .available, transfers: still) == .available)
    #expect(MenuBarState(presence: .away, transfers: still) == .away)
}

@Test func menuBarGlyphsAreDistinctTemplatesThatStayInsideTheCanvas() throws {
    var masks: [MenuBarState: [UInt8]] = [:]
    for state in MenuBarState.allCases {
        let image = try #require(MenuBarGlyph.render(state, scale: 2))
        #expect(image.width == 40 && image.height == 36)
        let mask = alpha(image)
        let edges = (0..<image.width).flatMap { [$0, (image.height - 1) * image.width + $0] }
            + (0..<image.height).flatMap { [$0 * image.width, $0 * image.width + image.width - 1] }
        #expect(edges.allSatisfy { mask[$0] == 0 }, "\(state) leaves a clear pixel margin")
        masks[state] = mask
    }
    #expect(Set(masks.values).count == MenuBarState.allCases.count)
    let ink = masks.mapValues { $0.reduce(0) { $0 + Int($1) } }
    #expect(try #require(masks[.offline]).max() ?? 0 <= 103, "Offline is the dimmed mark")
    #expect(try #require(masks[.available]).max() == 255)
    for moving in [MenuBarState.downloading, .uploading, .downloadingAndUploading] {
        #expect(ink[moving] ?? 0 > ink[.available] ?? 0, "Moving states fill the chord")
    }
}

@Test @MainActor func menuBarImagesAreCachedTemplatesWithSpokenStates() {
    for state in MenuBarState.allCases {
        let image = MenuBarGlyph.image(state)
        #expect(image.isTemplate)
        #expect(image === MenuBarGlyph.image(state))
        #expect(image.size == MenuGlyphGeometry.canvas)
        #expect(image.accessibilityDescription == state.accessibilityLabel)
    }
    #expect(Set(MenuBarState.allCases.map(\.accessibilityLabel)).count == MenuBarState.allCases.count)
}

@Test func transferPulseSummarisesOneDirectionWithoutPreviews() {
    let rows = [transfer("ann", .transferring, size: 1_000, done: 250, speed: 100),
                transfer("ann", .transferring, size: 3_000, done: 750, speed: 50),
                transfer("bob", .transferring, size: 1_000, done: 1_000, speed: 25),
                transfer("cy", .queued), transfer("dee", .negotiating), transfer("eve", .paused), transfer("fay", .completed),
                transfer("gus", .transferring, size: 5_000, done: 100, speed: 999, preview: true),
                transfer("hal", upload: true, .transferring, size: 10, done: 5, speed: 7)]
    let downloads = TransferPulse(rows, upload: false)
    #expect(downloads.transferring == 3 && downloads.waiting == 2 && downloads.people == 2)
    #expect(downloads.speed == 175)
    #expect(downloads.progress == 2_000.0 / 5_000.0)
    let uploads = TransferPulse(rows, upload: true)
    #expect(uploads.transferring == 1 && uploads.waiting == 0 && uploads.people == 1 && uploads.speed == 7 && uploads.progress == 0.5)
    #expect(TransferPulse([transfer("cy", .queued)], upload: false).progress == nil)
}

@Suite(.serialized) @MainActor struct MenuBarObservationTests {
    private func model() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-menubar-\(UUID().uuidString)")
        let model = try AppModel(dataDirectory: root)
        model.settings.downloadDirectory = root.path
        return (model, root)
    }

    @Test func labelStateIgnoresTransferTicksAndChangesWithTheDerivedState() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let status = MenuBarStatus()
        let follower = Task { await status.follow(model) }
        defer { follower.cancel() }
        model.connection = .connected
        try await eventually { status.state == .available }
        model.transfers = [transfer("ann", .transferring, done: 10, speed: 10)]
        try await eventually { status.state == .downloading }

        let changes = Counter()
        withObservationTracking { _ = status.state } onChange: { changes.increment() }
        for tick in 1...20 {
            model.transfers = [transfer("ann", .transferring, done: UInt64(10 + tick), speed: Double(tick))]
            try await Task.sleep(for: .milliseconds(5))
        }
        model.awayNow = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(changes.count == 0, "Speed, progress and Away during a transfer leave the icon alone")
        #expect(status.state == .downloading)

        model.transfers = []
        try await eventually { status.state == .away }
        #expect(changes.count == 1)
    }

    @Test func panelFeedSamplesAtMostTwiceASecond() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = MenuBarPanelFeed()
        let follower = Task { await feed.follow(model) }
        defer { follower.cancel() }
        let updates = Counter()
        let watcher = Task { for await _ in Observations({ feed.live }) { updates.increment() } }
        defer { watcher.cancel() }
        let start = ContinuousClock.now
        for tick in 1...40 {
            model.transfers = [transfer("ann", .transferring, size: 10_000, done: UInt64(tick * 100), speed: Double(tick))]
            try await Task.sleep(for: .milliseconds(25))
        }
        let elapsed = ContinuousClock.now - start
        try await Task.sleep(for: MenuBarPanelFeed.interval * 2)
        #expect(feed.live.downloads.transferring == 1)
        #expect(feed.live.downloads.speed == 40, "The last value arrives after the burst")
        let allowed = Int((elapsed / MenuBarPanelFeed.interval).rounded(.up)) + 3
        #expect(updates.count >= 2)
        #expect(updates.count <= allowed, "\(updates.count) updates for 40 changes in \(elapsed)")
    }
}
