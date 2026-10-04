import Foundation
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SoulseekCore
import TransferEngine

@MainActor @Observable
public final class Playback {
    public struct Item: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        public let user: String?
        public let remotePath: String?
        public let transferID: String?
        public var isPreview: Bool
        public let fileURL: URL?
        public let fileName: String
        public let quality: String
    }

    public private(set) var item: Item?
    public private(set) var metadata = TrackMetadata()
    public private(set) var artwork: CGImage?
    public private(set) var artworkPixels: String?
    public var volume: Float = 1 { didSet { player?.volume = volume } }
    public private(set) var isPlaying = false
    public private(set) var isWaiting = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var bufferedFraction: Double = 1
    public private(set) var status: String?
    public private(set) var failure: String?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loader: StreamingResourceLoader?
    @ObservationIgnored private var feed: StreamFeed?
    @ObservationIgnored private var expectedDuration: Double = 0
    @ObservationIgnored private var metadataTask: Task<Void, Never>?

    public init() {}

    public func playFile(_ url: URL, title: String, subtitle: String, file: SharedFile? = nil) {
        let asset = AVURLAsset(url: url)
        start(Item(title: title, subtitle: subtitle, user: nil, remotePath: nil, transferID: nil, isPreview: false, fileURL: url,
                   fileName: url.lastPathComponent, quality: Self.quality(file, fallbackName: url.lastPathComponent)),
              asset: asset, expected: Double(file?.length ?? 0))
        bufferedFraction = 1
        let path = url.path
        readTags(asset: asset, isFLAC: url.pathExtension.lowercased() == "flac") { (path, UInt64.max) }
    }
    func playCompletedTransfer(_ transfer: Transfer, url: URL) {
        let asset = AVURLAsset(url: url)
        start(Item(title: transfer.file.name, subtitle: transfer.user, user: transfer.user, remotePath: transfer.file.path,
                   transferID: transfer.id, isPreview: transfer.isPreview, fileURL: url, fileName: transfer.file.name,
                   quality: Self.quality(transfer.file, fallbackName: transfer.file.name)), asset: asset, expected: Double(transfer.file.length))
        bufferedFraction = 1
        readTags(asset: asset, isFLAC: url.pathExtension.lowercased() == "flac") { (url.path, UInt64.max) }
    }

    static func quality(_ file: SharedFile?, fallbackName: String) -> String {
        guard let file else { return (fallbackName as NSString).pathExtension.uppercased() }
        let parts = [file.format, file.quality == file.format ? "" : file.quality, ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// FLAC headers are parsed directly (cover art included); other formats use AVFoundation's tag reader.
    /// Streams wait until the header bytes have arrived.
    private func readTags(asset: AVURLAsset, isFLAC: Bool, source: @escaping @Sendable () -> (path: String?, available: UInt64)) {
        metadataTask?.cancel()
        metadata = TrackMetadata(); artwork = nil; artworkPixels = nil
        metadataTask = Task { [weak self] in
            var tags = TrackMetadata()
            if isFLAC {
                for _ in 0..<240 {
                    guard !Task.isCancelled else { return }
                    let (path, available) = source()
                    if let path, let header = Self.prefix(path, limit: min(available, 24 * 1024 * 1024)) {
                        switch FLACTags.parse(header) {
                        case .parsed(let parsed): tags = parsed
                        case .notFLAC: break
                        case .needMoreData: if available < 24 * 1024 * 1024 { try? await Task.sleep(for: .milliseconds(500)); continue }
                        }
                    } else { try? await Task.sleep(for: .milliseconds(500)); continue }
                    break
                }
            }
            if tags.title == nil || tags.artwork == nil, let items = try? await asset.load(.metadata) {
                var common = TrackMetadata()
                for item in items {
                    let key = (item.key as? String)?.uppercased()
                    if item.commonKey == .commonKeyArtwork || item.identifier == .id3MetadataAttachedPicture {
                        if common.artwork == nil, let data = try? await item.load(.dataValue), !data.isEmpty { common.artwork = data }
                        continue
                    }
                    guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                    switch (item.commonKey, key) {
                    case (.commonKeyTitle?, _), (_, "TITLE"?): common.title = common.title ?? value
                    case (.commonKeyArtist?, _), (_, "ARTIST"?): common.artist = common.artist ?? value
                    case (.commonKeyAlbumName?, _), (_, "ALBUM"?): common.album = common.album ?? value
                    case (.commonKeyCreationDate?, _): common.year = common.year ?? String(value.prefix(4))
                    default: break
                    }
                }
                tags.fill(from: common)
            }
            let picture = tags.artwork
            tags.artwork = nil
            let decoded = await Task.detached(priority: .utility) { picture.flatMap(Self.decodeArtwork) }.value
            guard !Task.isCancelled, let self else { return }
            tags.resolved = true
            self.artwork = decoded?.image; self.artworkPixels = decoded?.pixels
            self.metadata = tags
        }
    }

    /// Cover art is decoded once at display size; the original bytes are dropped.
    nonisolated static func decodeArtwork(_ data: Data) -> (image: CGImage, pixels: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 12_000, height <= 12_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 800, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, "\(width)×\(height)")
    }

    nonisolated private static func prefix(_ path: String, limit: UInt64) -> Data? {
        guard limit > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: Int(limit))
    }

    public func skip(by seconds: Double) {
        guard duration > 0 else { return }
        seek(toFraction: (currentTime + seconds) / duration)
    }

    func playStream(transferID: String, user: String, file: SharedFile, preview: Bool) {
        let feed = StreamFeed(size: file.size)
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension)?.identifier ?? UTType.audio.identifier
        let loader = StreamingResourceLoader(feed: feed, contentType: type)
        let ext = (file.name as NSString).pathExtension
        let url = URL(string: "arpeggio-stream://preview/\(UUID().uuidString)" + (ext.isEmpty ? "" : "." + ext))!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let folder = file.folder.split(separator: "\\").last.map(String.init) ?? ""
        start(Item(title: file.name, subtitle: [user, folder].filter { !$0.isEmpty }.joined(separator: " · "),
                   user: user, remotePath: file.path, transferID: transferID, isPreview: preview, fileURL: nil,
                   fileName: file.name, quality: Self.quality(file, fallbackName: file.name)),
              asset: asset, expected: Double(file.length), loader: loader, feed: feed)
        bufferedFraction = 0
        status = "Asking \(user) for the file…"
        readTags(asset: asset, isFLAC: ext.lowercased() == "flac") { let state = feed.snapshot(); return (state.path, state.available) }
    }

    private func start(_ item: Item, asset: AVURLAsset, expected: Double, loader: StreamingResourceLoader? = nil, feed: StreamFeed? = nil) {
        teardown()
        self.loader = loader; self.feed = feed
        self.item = item; failure = nil; status = nil
        currentTime = 0; expectedDuration = expected; duration = expected
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = volume
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        player.play()
        isPlaying = true
    }

    private func tick() {
        guard let player, let current = player.currentItem else { return }
        let seconds = player.currentTime().seconds
        currentTime = seconds.isFinite ? seconds : 0
        let known = current.duration.seconds
        if known.isFinite, known > 0 { duration = known } else { duration = expectedDuration }
        isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isPlaying = player.timeControlStatus != .paused
        if current.status == .failed {
            failure = item?.isPreview == true || item?.transferID != nil
                ? "This file can’t be streamed. Download it to play it."
                : "This file can’t be played."
            isPlaying = false
        }
        if duration > 0, currentTime >= duration - 0.3, player.timeControlStatus == .paused { isPlaying = false }
    }

    func refresh(_ transfers: [Transfer]) {
        guard let id = item?.transferID, let feed else { return }
        guard let transfer = transfers.first(where: { $0.id == id }) else { feed.update(path: nil, available: 0, failed: true); return }
        switch transfer.status {
        case .completed:
            feed.update(path: transfer.destination, available: transfer.file.size, failed: false)
            status = nil
        case .transferring:
            feed.update(path: transfer.partial, available: transfer.transferred, failed: false)
            status = isWaiting ? "Buffering…" : nil
        case .queued, .negotiating:
            feed.update(path: transfer.partial, available: transfer.transferred, failed: false)
            status = transfer.queuePosition > 0 ? "Waiting in \(transfer.user)’s queue · #\(transfer.queuePosition)" : "Connecting to \(transfer.user)…"
        case .paused:
            status = "Paused"
        case .failed, .cancelled:
            feed.update(path: nil, available: transfer.transferred, failed: true)
            if failure == nil { failure = transfer.error ?? "The transfer stopped." }
        }
        bufferedFraction = transfer.progress
        if item?.isPreview == true, !transfer.isPreview { item?.isPreview = false }
    }

    public func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if duration > 0, currentTime >= duration - 0.3 { player.seek(to: .zero) }
            player.play(); isPlaying = true
        } else { player.pause(); isPlaying = false }
    }

    public func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func markKept() { item?.isPreview = false }

    @discardableResult
    func stop() -> Item? {
        let previous = item
        teardown()
        item = nil; metadata = TrackMetadata(); artwork = nil; artworkPixels = nil; isPlaying = false; isWaiting = false; status = nil; failure = nil
        currentTime = 0; duration = 0; bufferedFraction = 1
        return previous
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        metadataTask?.cancel(); metadataTask = nil
        loader?.cancel(); loader = nil; feed = nil
    }
}

/// Thread-safe view of how much of a transferring file exists on disk, shared with the loader queue.
final class StreamFeed: @unchecked Sendable {
    let size: UInt64
    private let lock = NSLock()
    private var path: String?
    private var available: UInt64 = 0
    private var failed = false
    init(size: UInt64) { self.size = size }
    func update(path: String?, available: UInt64, failed: Bool) {
        lock.withLock { if let path { self.path = path }; self.available = min(size, available); self.failed = failed }
    }
    func snapshot() -> (path: String?, available: UInt64, failed: Bool) { lock.withLock { (path, available, failed) } }
}

/// Serves byte ranges of a growing partial file to AVFoundation, holding requests until bytes arrive.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "tn.ashref.arpeggio.stream")
    private let feed: StreamFeed
    private let contentType: String
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var timer: DispatchSourceTimer?

    init(feed: StreamFeed, contentType: String) { self.feed = feed; self.contentType = contentType }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        pending.append(loadingRequest)
        serve()
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
            timer.setEventHandler { [weak self] in self?.serve() }
            timer.resume(); self.timer = timer
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }

    func cancel() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            for request in pending where !request.isFinished { request.finishLoading(with: CancellationError()) }
            pending.removeAll()
        }
    }

    private func serve() {
        let state = feed.snapshot()
        pending.removeAll { request in
            if request.isCancelled || request.isFinished { return true }
            if let info = request.contentInformationRequest {
                info.contentType = contentType
                info.contentLength = Int64(feed.size)
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else { request.finishLoading(); return true }
            let end = StreamWindow.end(offset: data.requestedOffset, length: data.requestedLength,
                                       toEnd: data.requestsAllDataToEndOfResource, size: Int64(feed.size))
            if let window = StreamWindow.readable(from: data.currentOffset, to: end, available: Int64(state.available)),
               let path = state.path, let bytes = read(path, offset: window.offset, count: window.count) {
                data.respond(with: bytes)
            }
            if data.currentOffset >= end { request.finishLoading(); return true }
            if state.failed { request.finishLoading(with: CocoaError(.fileReadUnknown)); return true }
            return false
        }
        if pending.isEmpty { timer?.cancel(); timer = nil }
    }

    private func read(_ path: String, offset: Int64, count: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)); return try handle.read(upToCount: count) } catch { return nil }
    }
}

public enum StreamWindow {
    public static let chunk = 512 * 1024
    /// Where a request finishes; ranges past the end of the file stop at EOF so they can complete.
    public static func end(offset: Int64, length: Int, toEnd: Bool, size: Int64) -> Int64 {
        toEnd ? size : min(size, offset + Int64(length))
    }
    /// The next contiguous slice already on disk for a request currently at `offset`, ending before `end`.
    public static func readable(from offset: Int64, to end: Int64, available: Int64) -> (offset: Int64, count: Int)? {
        let limit = min(end, available)
        guard limit > offset else { return nil }
        return (offset, Int(min(Int64(chunk), limit - offset)))
    }
}
