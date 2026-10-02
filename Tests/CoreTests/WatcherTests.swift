import Foundation
import Testing
import ShareIndexer

private actor WatchSignal {
    var count = 0
    func changed() { count += 1 }
}

@Test(.timeLimit(.minutes(1))) func filesystemWatcherObservesNestedChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let signal = WatchSignal()
    let watcher = try ShareWatcher(folders: [root]) { Task { await signal.changed() } }
    defer { watcher.close() }
    try await Task.sleep(for: .milliseconds(100))
    try Data("original test data".utf8).write(to: root.appendingPathComponent("nested/new.txt"))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await signal.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(await signal.count > 0)
}
