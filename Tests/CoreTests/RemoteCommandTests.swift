import AVFoundation
import Foundation
import Testing
@testable import ArpeggioServices

@MainActor private final class FakeBridge: RemoteCommandBridge {
    final class Token {}
    var handlers: [RemoteCommand: [(token: Token, handler: @MainActor (RemoteCommandEvent) -> Bool)]] = [:]
    /// Every callback ever registered, kept after removal like a system event already queued for delivery.
    var retained: [RemoteCommand: [@MainActor (RemoteCommandEvent) -> Bool]] = [:]
    var enabled: [RemoteCommand: Bool] = [:]
    var nowPlaying: NowPlayingInfo?
    var nowPlayingWrites = 0

    func addTarget(_ command: RemoteCommand, handler: @escaping @MainActor (RemoteCommandEvent) -> Bool) -> AnyObject {
        let token = Token()
        handlers[command, default: []].append((token, handler))
        retained[command, default: []].append(handler)
        return token
    }
    func removeTarget(_ token: AnyObject, from command: RemoteCommand) { handlers[command]?.removeAll { $0.token === token } }
    func setEnabled(_ enabled: Bool, for command: RemoteCommand) { self.enabled[command] = enabled }
    func setNowPlaying(_ info: NowPlayingInfo?) { nowPlaying = info; nowPlayingWrites += 1 }

    var targetCount: Int { handlers.values.reduce(0) { $0 + $1.count } }
    @discardableResult func send(_ command: RemoteCommand, _ event: RemoteCommandEvent? = nil) -> Bool {
        handlers[command]?.first?.handler(event ?? .command(command)) ?? false
    }
}

@MainActor private final class Log { var calls: [String] = [] }

@MainActor private func handlers(_ log: Log, tag: String = "") -> RemoteCommandRouter.Handlers {
    .init(play: { log.calls.append(tag + "play") }, pause: { log.calls.append(tag + "pause") }, toggle: { log.calls.append(tag + "toggle") },
          stop: { log.calls.append(tag + "stop") }, skip: { log.calls.append(tag + "skip \(Int($0))") }, seek: { log.calls.append(tag + "seek \(Int($0))") })
}

/// A short silent PCM file, enough for AVPlayer to load an item without any network or owner media.
private func silentWave(seconds: Double = 2) throws -> URL {
    let rate = 8000, samples = Int(Double(rate) * seconds)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2)); data.append(Data(count: samples * 2))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-silence-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

@Suite(.serialized) @MainActor struct RemoteCommandTests {
    @Test func callbacksQueuedForAnEarlierSessionCannotControlTheNextOne() throws {
        let bridge = FakeBridge(), log = Log()
        let router = RemoteCommandRouter(bridge: bridge)
        router.activate(handlers(log, tag: "A:"))
        let stalePause = try #require(bridge.retained[.pause]?.last)
        let staleStop = try #require(bridge.retained[.stop]?.last)
        let staleSeek = try #require(bridge.retained[.changePlaybackPosition]?.last)
        router.deactivate()
        router.activate(handlers(log, tag: "B:"))
        #expect(!stalePause(.command(.pause)))
        #expect(!staleStop(.command(.stop)))
        #expect(!staleSeek(.seek(seconds: 30)))
        #expect(log.calls.isEmpty, "a callback from session A acted: \(log.calls)")
        bridge.send(.pause)
        #expect(log.calls == ["B:pause"])
        router.deactivate()
        let lastPause = try #require(bridge.retained[.pause]?.last)
        #expect(!lastPause(.command(.pause)))
        #expect(log.calls == ["B:pause"])
    }

    @Test func activationRegistersEachCommandOnceAndRoutesEvents() {
        let bridge = FakeBridge(), log = Log()
        let router = RemoteCommandRouter(bridge: bridge)
        router.activate(handlers(log))
        router.activate(handlers(log))
        #expect(bridge.targetCount == RemoteCommand.allCases.count)
        #expect(RemoteCommand.allCases.allSatisfy { bridge.enabled[$0] == true })
        bridge.send(.play); bridge.send(.pause); bridge.send(.togglePlayPause); bridge.send(.stop)
        bridge.send(.skipForward); bridge.send(.skipBackward)
        bridge.send(.skipForward, .skip(seconds: 30))
        bridge.send(.changePlaybackPosition, .seek(seconds: 42))
        #expect(log.calls == ["play", "pause", "toggle", "stop", "skip 15", "skip -15", "skip 30", "seek 42"])
        #expect(!bridge.send(.changePlaybackPosition, .command(.changePlaybackPosition)))
    }

    @Test func nowPlayingPublishesChangesOnlyWhileActive() {
        let bridge = FakeBridge(), log = Log()
        let router = RemoteCommandRouter(bridge: bridge)
        let info = NowPlayingInfo(title: "Synthetic", artist: "Fixture", duration: 120, elapsed: 3, playing: true)
        router.update(info)
        #expect(bridge.nowPlayingWrites == 0)
        router.activate(handlers(log))
        router.update(info); router.update(info)
        #expect(bridge.nowPlayingWrites == 1)
        #expect(bridge.nowPlaying == info)
        router.update(NowPlayingInfo(title: "Synthetic", artist: "Fixture", duration: 120, elapsed: 3, playing: false))
        #expect(bridge.nowPlayingWrites == 2)
        #expect(NowPlayingInfo(title: "x", duration: .nan, elapsed: -4, playing: true).duration == 0)
    }

    @Test func deactivationRemovesTargetsAndClearsStaleMetadata() {
        let bridge = FakeBridge(), log = Log()
        let router = RemoteCommandRouter(bridge: bridge)
        router.activate(handlers(log))
        router.update(NowPlayingInfo(title: "Synthetic", duration: 60, elapsed: 0, playing: true))
        router.deactivate()
        #expect(bridge.targetCount == 0)
        #expect(RemoteCommand.allCases.allSatisfy { bridge.enabled[$0] == false })
        #expect(bridge.nowPlaying == nil)
        #expect(!router.isActive)
        #expect(!bridge.send(.play))
        #expect(log.calls.isEmpty)
        router.activate(handlers(log))
        #expect(bridge.targetCount == RemoteCommand.allCases.count)
    }

    @Test func playbackActivatesOnPlayAndTearsDownOnStop() async throws {
        let url = try silentWave()
        defer { try? FileManager.default.removeItem(at: url) }
        let bridge = FakeBridge()
        let playback = Playback()
        playback.remoteCommands = RemoteCommandRouter(bridge: bridge)
        #expect(bridge.targetCount == 0)
        playback.volume = 0
        playback.playFile(url, title: "Silence", subtitle: "Synthetic fixture")
        #expect(bridge.targetCount == RemoteCommand.allCases.count)
        #expect(bridge.nowPlaying?.title.hasPrefix("arpeggio-silence") == true)
        bridge.send(.pause)
        #expect(!playback.isPlaying)
        #expect(bridge.nowPlaying?.playing == false)
        var stopped = false
        playback.remoteStop = { stopped = true; playback.stop() }
        bridge.send(.stop)
        #expect(stopped)
        #expect(playback.item == nil)
        #expect(bridge.targetCount == 0)
        #expect(bridge.nowPlaying == nil)
    }

    @Test func playbackWithoutARouterNeverTouchesSystemCenters() throws {
        let url = try silentWave(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = Playback()
        playback.volume = 0
        playback.playFile(url, title: "Silence", subtitle: "Synthetic fixture")
        #expect(playback.remoteCommands == nil)
        playback.changeVolume(by: 0.3); #expect(abs(playback.volume - 0.3) < 0.0001)
        playback.changeVolume(by: 5); #expect(playback.volume == 1)
        playback.changeVolume(by: -9); #expect(playback.volume == 0)
        playback.stop()
    }
}
