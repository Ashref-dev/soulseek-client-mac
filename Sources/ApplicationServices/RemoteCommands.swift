import Foundation
import MediaPlayer

/// System playback commands: media keys, headphone controls and Now Playing in Control Center.
public enum RemoteCommand: String, CaseIterable, Sendable {
    case play, pause, togglePlayPause, stop, skipForward, skipBackward, changePlaybackPosition
}

public enum RemoteCommandEvent: Equatable, Sendable {
    case command(RemoteCommand)
    case skip(seconds: Double)
    case seek(seconds: Double)
}

/// What Now Playing shows. Elapsed time is published on changes only; the system extrapolates while playing.
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: Double
    public var elapsed: Double
    public var playing: Bool
    public init(title: String, artist: String? = nil, album: String? = nil, duration: Double, elapsed: Double, playing: Bool) {
        self.title = title; self.artist = artist; self.album = album
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.playing = playing
    }
}

/// The parts of MPRemoteCommandCenter and MPNowPlayingInfoCenter the router uses, so tests inject a fake.
@MainActor
public protocol RemoteCommandBridge: AnyObject {
    func addTarget(_ command: RemoteCommand, handler: @escaping @MainActor (RemoteCommandEvent) -> Bool) -> AnyObject
    func removeTarget(_ token: AnyObject, from command: RemoteCommand)
    func setEnabled(_ enabled: Bool, for command: RemoteCommand)
    func setNowPlaying(_ info: NowPlayingInfo?)
}

/// Owns system command targets for the lifetime of one playback session. `activate` registers each command
/// once, `deactivate` removes every target and clears Now Playing, so a stopped player never answers media keys
/// or leaves stale metadata behind.
@MainActor
public final class RemoteCommandRouter {
    public struct Handlers {
        public var play: @MainActor () -> Void
        public var pause: @MainActor () -> Void
        public var toggle: @MainActor () -> Void
        public var stop: @MainActor () -> Void
        public var skip: @MainActor (Double) -> Void
        public var seek: @MainActor (Double) -> Void
        public init(play: @escaping @MainActor () -> Void, pause: @escaping @MainActor () -> Void, toggle: @escaping @MainActor () -> Void,
                    stop: @escaping @MainActor () -> Void, skip: @escaping @MainActor (Double) -> Void, seek: @escaping @MainActor (Double) -> Void) {
            self.play = play; self.pause = pause; self.toggle = toggle; self.stop = stop; self.skip = skip; self.seek = seek
        }
    }

    public static let skipInterval: Double = 15
    private let bridge: any RemoteCommandBridge
    private var targets: [(command: RemoteCommand, token: AnyObject)] = []
    /// Changes on every activation and deactivation. A callback acts only while its own activation is current, so an
    /// event the system queued for a stopped session can never pause, seek or stop the next one.
    public private(set) var activation: UInt64 = 0
    public private(set) var published: NowPlayingInfo?
    public private(set) var publications = 0

    public init(bridge: any RemoteCommandBridge) { self.bridge = bridge }

    public var isActive: Bool { !targets.isEmpty }
    public var registeredCommands: [RemoteCommand] { targets.map(\.command) }

    public func activate(_ handlers: Handlers) {
        guard targets.isEmpty else { return }
        activation &+= 1
        let generation = activation
        for command in RemoteCommand.allCases {
            let token = bridge.addTarget(command) { [weak self] event in
                guard let self, self.activation == generation, self.isActive else { return false }
                return Self.route(event, to: handlers)
            }
            bridge.setEnabled(true, for: command)
            targets.append((command, token))
        }
    }

    private static func route(_ event: RemoteCommandEvent, to handlers: Handlers) -> Bool {
        switch event {
        case .command(.play): handlers.play()
        case .command(.pause): handlers.pause()
        case .command(.togglePlayPause): handlers.toggle()
        case .command(.stop): handlers.stop()
        case .command(.skipForward): handlers.skip(skipInterval)
        case .command(.skipBackward): handlers.skip(-skipInterval)
        case .skip(let seconds): handlers.skip(seconds)
        case .seek(let seconds): handlers.seek(seconds)
        case .command(.changePlaybackPosition): return false
        }
        return true
    }

    public func update(_ info: NowPlayingInfo) {
        guard isActive, info != published else { return }
        published = info; publications += 1
        bridge.setNowPlaying(info)
    }

    public func deactivate() {
        guard isActive || published != nil else { return }
        activation &+= 1
        for target in targets {
            bridge.removeTarget(target.token, from: target.command)
            bridge.setEnabled(false, for: target.command)
        }
        targets.removeAll()
        published = nil
        bridge.setNowPlaying(nil)
    }
}

/// The real MediaPlayer centers.
@MainActor
public final class SystemRemoteCommandBridge: RemoteCommandBridge {
    public init() {}

    private func command(_ command: RemoteCommand) -> MPRemoteCommand {
        let center = MPRemoteCommandCenter.shared()
        switch command {
        case .play: return center.playCommand
        case .pause: return center.pauseCommand
        case .togglePlayPause: return center.togglePlayPauseCommand
        case .stop: return center.stopCommand
        case .skipForward: return center.skipForwardCommand
        case .skipBackward: return center.skipBackwardCommand
        case .changePlaybackPosition: return center.changePlaybackPositionCommand
        }
    }

    public func addTarget(_ remote: RemoteCommand, handler: @escaping @MainActor (RemoteCommandEvent) -> Bool) -> AnyObject {
        let target = command(remote)
        if let skip = target as? MPSkipIntervalCommand { skip.preferredIntervals = [NSNumber(value: RemoteCommandRouter.skipInterval)] }
        let token = target.addTarget { event in
            let translated: RemoteCommandEvent
            if let position = event as? MPChangePlaybackPositionCommandEvent { translated = .seek(seconds: position.positionTime) }
            else if let skip = event as? MPSkipIntervalCommandEvent {
                translated = .skip(seconds: remote == .skipBackward ? -abs(skip.interval) : abs(skip.interval))
            } else { translated = .command(remote) }
            guard Thread.isMainThread else {
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = handler(translated) } }
                return .success
            }
            return MainActor.assumeIsolated { handler(translated) } ? .success : .commandFailed
        }
        return token as AnyObject
    }

    public func removeTarget(_ token: AnyObject, from remote: RemoteCommand) { command(remote).removeTarget(token) }

    public func setEnabled(_ enabled: Bool, for remote: RemoteCommand) { command(remote).isEnabled = enabled }

    public func setNowPlaying(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var values: [String: Any] = [MPMediaItemPropertyTitle: info.title,
                                     MPMediaItemPropertyPlaybackDuration: info.duration,
                                     MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
                                     MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
                                     MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artist = info.artist { values[MPMediaItemPropertyArtist] = artist }
        if let album = info.album { values[MPMediaItemPropertyAlbumTitle] = album }
        center.nowPlayingInfo = values
        center.playbackState = info.playing ? .playing : .paused
    }
}
