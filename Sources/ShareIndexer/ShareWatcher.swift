import Foundation
import CoreServices

private final class WatchContext: Sendable {
    let ignored: [String]
    let changed: @Sendable () -> Void
    init(ignored: [String], changed: @escaping @Sendable () -> Void) { self.ignored = ignored; self.changed = changed }
}

public final class ShareWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    public init(folders: [URL], ignoring: [URL] = [], changed: @escaping @Sendable () -> Void) throws {
        let token = WatchContext(ignored: ignoring.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }, changed: changed)
        let pointer = Unmanaged.passRetained(token).toOpaque()
        var context = FSEventStreamContext(version: 0, info: pointer, retain: nil, release: { info in
            if let info { Unmanaged<WatchContext>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let token = Unmanaged<WatchContext>.fromOpaque(info).takeUnretainedValue()
            let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if values.contains(where: { path in
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                return !token.ignored.contains { canonical == $0 || canonical.hasPrefix($0 + "/") }
            }) { token.changed() }
        }
        let paths = Array(Set(folders.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })) as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else {
            Unmanaged<WatchContext>.fromOpaque(pointer).release()
            throw CocoaError(.fileReadUnknown)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "tn.ashref.arpeggio.filewatch", qos: .utility))
        guard FSEventStreamStart(stream) else { close(); throw CocoaError(.fileReadUnknown) }
    }
    public func close() {
        lock.withLock {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }
    deinit { close() }
}
