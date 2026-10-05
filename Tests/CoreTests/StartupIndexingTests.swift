import Foundation
import Testing
import SoulseekCore
import ProtocolFixtures
import Persistence
@testable import ArpeggioServices
@testable import TransferEngine

@Suite struct StartupIndexingTests {
    @Test(.timeLimit(.minutes(1))) @MainActor
    func startupAndLoginFinishBeforeInitialScanAndPublishOnlyCommittedIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Collection")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture-content".utf8).write(to: folder.appendingPathComponent("track.txt"))
        let server = try await MockSoulseekServer.start()
        let model = try AppModel(dataDirectory: root.appendingPathComponent("profile"))
        var settings = AppSettings()
        settings.username = "indexing-fixture"; settings.server = "127.0.0.1"
        settings.port = try await server.port(); settings.listeningPort = try unusedPort()
        settings.notifications = false; settings.checkForUpdates = false; settings.portMapping = false
        settings.downloadDirectory = root.appendingPathComponent("downloads").path
        settings.sharedFolders = [ShareFolder(path: folder.path)]
        try await model.database.put(settings, collection: "settings", id: "main")
        let gate = InitialScanGate()
        model.initialShareScan = { model in
            model.indexing = true
            await gate.wait()
            model.indexing = false
            if !Task.isCancelled { await model.rescanShares() }
            await gate.finish()
        }
        model.credentialLookup = { _ in "fixture-only" }
        var startupReturned = false; var loginReturned = false
        let startup = Task {
            await model.start(); startupReturned = true
            await model.connectAtLaunch(); loginReturned = true
        }
        await waitFor { await gate.started }
        await waitFor { loginReturned }
        #expect(startupReturned == true)
        #expect(loginReturned == true)
        #expect(model.connection == .connected)
        #expect(await model.transferEngine.uploadAuthorizer != nil)
        #expect(await gate.finished == false)
        #expect(model.indexing == true)
        #expect(model.sharedCount == 0)
        #expect(model.sharedLibrary.isEmpty)
        #expect(await model.shareIndex.library().isEmpty)
        await gate.release(); await startup.value
        await waitFor { await gate.finished }
        #expect(model.sharedCount == 1)
        #expect(model.sharedLibrary.values.flatMap { $0 }.count == 1)
        #expect(await model.shareIndex.library().values.flatMap { $0 }.count == 1)
        #expect(model.indexing == false)
        await model.shutdown(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func shutdownCancelsAndJoinsInitialScanBeforeClosingStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        var settings = AppSettings(); settings.checkForUpdates = false; settings.notifications = false
        let folder = root.appendingPathComponent("Collection")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settings.sharedFolders = [ShareFolder(path: folder.path)]
        try await model.database.put(settings, collection: "settings", id: "main")
        let gate = InitialScanGate()
        model.initialShareScan = { model in
            model.indexing = true
            await withTaskCancellationHandler {
                await gate.wait()
                model.indexing = false
                if !Task.isCancelled { await model.rescanShares() }
            } onCancel: {
                Task { await gate.cancel() }
            }
            await gate.finish()
        }
        var startupReturned = false; var shutdownReturned = false
        let startup = Task { await model.start(); startupReturned = true }
        await waitFor { await gate.started }
        await waitFor { startupReturned }
        #expect(startupReturned == true)
        let shutdown = Task { await model.shutdown(); shutdownReturned = true }
        await waitFor { await gate.cancelled || shutdownReturned }
        #expect(await gate.cancelled == true)
        #expect(shutdownReturned == false)
        #expect(await gate.finished == false)
        await gate.release()
        await startup.value; await shutdown.value
        #expect(await gate.finished == true)
        #expect(shutdownReturned == true)
        #expect(model.shareScanTask == nil)
        #expect(model.initialShareTask == nil)
        #expect(model.sharedCount == 0)
        #expect(model.sharedLibrary.isEmpty)
        #expect(model.shareWatcher == nil)
    }
}

@MainActor private func waitFor(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private actor InitialScanGate {
    var started = false
    var cancelled = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func cancel() { cancelled = true }
    func finish() { finished = true }
    func release() { continuation?.resume(); continuation = nil }
}
