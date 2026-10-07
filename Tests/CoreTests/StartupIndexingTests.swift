import Foundation
import Testing
import SoulseekCore
import ProtocolFixtures
import Persistence
@testable import ArpeggioServices
@testable import TransferEngine

@Suite struct StartupIndexingTests {
    @Test func releaseBeforeWaitIsLatched() async throws {
        let gate = InitialScanGate()
        await gate.release()
        let waiter = Task { await gate.wait(); await gate.finish() }
        do { try await gate.finishedEvent.wait(until: .now.advanced(by: .seconds(30))) }
        catch { await gate.release(); await waiter.value; throw error }
        #expect(await gate.finished, "release before wait must not be lost")
        await gate.release()
        await waiter.value
    }

    @Test func cancellationResumesAnInstalledWaiter() async throws {
        let gate = InitialScanGate()
        let waiter = Task { await gate.wait(); await gate.finish() }
        do {
            try await gate.startedEvent.wait(until: .now.advanced(by: .seconds(30)))
            waiter.cancel()
            try await gate.finishedEvent.wait(until: .now.advanced(by: .seconds(30)))
        } catch { waiter.cancel(); await gate.release(); await waiter.value; throw error }
        #expect(await gate.finished, "cancellation must resume a suspended waiter")
        #expect(await gate.cancelled)
        await gate.release()
        await waiter.value
    }

    @Test @MainActor func completionSurvivesControlledMainActorContention() async throws {
        var completed = false
        let completion = StartupTestSignal()
        let queued = Task { completed = true; await completion.signal() }
        holdMainActorForContention()
        try await completion.wait(until: .now.advanced(by: .seconds(30)))
        #expect(completed, "queued completion must survive contention beyond the old one-second polling deadline")
        await queued.value
    }

    @Test func cancellationBeforeWaitAndTimeoutLeaveNoWaiters() async throws {
        let signal = StartupTestSignal()
        let begin = StartupTestSignal()
        let waiter = Task {
            await begin.waitForCleanupRelease()
            do { try await signal.wait(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        waiter.cancel()
        await begin.signal()
        #expect(await waiter.value)
        do {
            try await signal.wait(until: .now.advanced(by: .milliseconds(100)))
            Issue.record("an unsignalled completion must time out")
        } catch is StartupTestSignal.Timeout {}
        #expect(await signal.waiterCount == 0)
        await signal.signal()
        try await signal.wait()
        await signal.signal()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func startupAndLoginFinishBeforeInitialScanAndPublishOnlyCommittedIndex(contended: Bool) async throws {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let loginCompleted = StartupTestSignal()
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
            await loginCompleted.signal()
        }
        do {
            if contended { holdMainActorForContention() }
            try await gate.startedEvent.wait(until: deadline)
            try await loginCompleted.wait(until: deadline)
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
            try await gate.finishedEvent.wait(until: deadline)
            #expect(model.sharedCount == 1)
            #expect(model.sharedLibrary.values.flatMap { $0 }.count == 1)
            #expect(await model.shareIndex.library().values.flatMap { $0 }.count == 1)
            #expect(model.indexing == false)
            await model.shutdown(); await server.stop()
        } catch {
            startup.cancel(); await gate.release(); await startup.value
            await model.shutdown(); await server.stop()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func shutdownCancelsAndJoinsInitialScanBeforeClosingStorage(contended: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        var settings = AppSettings(); settings.checkForUpdates = false; settings.notifications = false
        let folder = root.appendingPathComponent("Collection")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settings.sharedFolders = [ShareFolder(path: folder.path)]
        try await model.database.put(settings, collection: "settings", id: "main")
        let gate = InitialScanGate(holdsCleanup: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let startupCompleted = StartupTestSignal()
        let shutdownCompleted = StartupTestSignal()
        model.initialShareScan = { model in
            model.indexing = true
            await gate.wait()
            model.indexing = false
            if !Task.isCancelled { await model.rescanShares() }
            await gate.finish()
        }
        var startupReturned = false; var shutdownReturned = false
        let startup = Task { await model.start(); startupReturned = true; await startupCompleted.signal() }
        var shutdown: Task<Void, Never>?
        do {
            if contended { holdMainActorForContention() }
            try await gate.startedEvent.wait(until: deadline)
            try await startupCompleted.wait(until: deadline)
            #expect(startupReturned == true)
            shutdown = Task { await model.shutdown(); shutdownReturned = true; await shutdownCompleted.signal() }
            try await gate.cancelledEvent.wait(until: deadline)
            #expect(await gate.cancelled == true)
            #expect(shutdownReturned == false)
            #expect(await gate.finished == false)
            #expect(try await model.database.all(AppSettings.self, collection: "settings").count == 1)
            await gate.release()
            try await shutdownCompleted.wait(until: deadline)
            await startup.value; await shutdown?.value
            #expect(await gate.finished == true)
            #expect(shutdownReturned == true)
            #expect(model.shareScanTask == nil)
            #expect(model.initialShareTask == nil)
            #expect(model.sharedCount == 0)
            #expect(model.sharedLibrary.isEmpty)
            #expect(model.shareWatcher == nil)
        } catch {
            startup.cancel(); await gate.release(); await startup.value
            if let shutdown { await shutdown.value } else { await model.shutdown() }
            throw error
        }
    }
}

@MainActor private func holdMainActorForContention() {
    let unblock = DispatchSemaphore(value: 0)
    Task.detached {
        try? await Task.sleep(for: .milliseconds(1200))
        unblock.signal()
    }
    unblock.wait()
}
