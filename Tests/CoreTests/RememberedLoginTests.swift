import Foundation
import Synchronization
import Testing
import Persistence
import ProtocolFixtures
@testable import ArpeggioServices

@Suite struct RememberedLoginTests {
    @Test @MainActor func acceptedAuthenticationSavesPasswordDespiteMessageSetupFailure() async throws {
        let fixture = try await LoginFixture.make()
        let recorder = CredentialRecorder()
        fixture.model.credentials = CredentialWrites(backend: recorder.backend)
        try await fixture.model.database.put("malformed-message", collection: "messages", id: "bad")
        await fixture.model.login(password: "fixture-only", remember: true)
        #expect(fixture.model.connection == .connected)
        #expect(fixture.model.error != nil)
        #expect(recorder.contains("fixture-a"))
        #expect(recorder.events == ["save:fixture-a"])
        await fixture.close()
    }

    @Test @MainActor func rememberedPasswordExistsBeforeSetupAndSignOutRevokesIt() async throws {
        let fixture = try await LoginFixture.make()
        let recorder = CredentialRecorder(); let gate = LoginSetupGate()
        fixture.model.credentials = CredentialWrites(backend: recorder.backend)
        fixture.model.loginSettingsSave = { model in await gate.wait(); await model.saveSettings() }
        let work = Task { await fixture.model.login(password: "fixture-only", remember: true) }
        await waitForLoginCondition { await gate.entered }
        #expect(await gate.entered == true)
        #expect(fixture.model.connection == .connected)
        #expect(recorder.contains("fixture-a"))
        await fixture.model.signOut()
        await gate.release(); await work.value
        #expect(recorder.contains("fixture-a") == false)
        #expect(recorder.events == ["save:fixture-a", "delete:fixture-a"])
        await fixture.close()
    }

    @Test @MainActor func supersededSetupCannotSendRoomPrivilegeOrWatchFramesOnReplacementSession() async throws {
        let fixture = try await LoginFixture.make()
        let gate = LoginSetupGate(); let recorder = CredentialRecorder()
        fixture.model.credentials = CredentialWrites(backend: recorder.backend)
        fixture.model.users = [UserRecord(username: "watched-fixture")]
        fixture.model.loginSettingsSave = { model in
            if model.settings.username == "fixture-a" { await gate.wait() }
            await model.saveSettings()
        }
        let first = Task { await fixture.model.login(password: "fixture-a-only", remember: true) }
        await waitForLoginCondition { await gate.entered }
        #expect(await gate.entered == true)
        fixture.model.settings.username = "fixture-b"
        fixture.model.settings.listeningPort = try unusedPort()
        await fixture.model.login(password: "fixture-b-only", remember: true)
        #expect(fixture.model.connection == .connected)
        let generation = fixture.model.activeSessionGeneration
        await gate.release(); await first.value
        try await fixture.model.session.send(code: 999)
        await waitForLoginCondition { await fixture.server.trace.contains("fixture-b:999") }
        let trace = await fixture.server.trace
        #expect(trace.contains("fixture-b:999"))
        for code in [64, 92, 5] { #expect(trace.filter { $0 == "fixture-b:\(code)" }.count == 1) }
        #expect(fixture.model.activeAccount == "fixture-b")
        #expect(fixture.model.activeSessionGeneration == generation)
        #expect(fixture.model.error == nil)
        await fixture.close()
    }

    @Test @MainActor func deletionDuringAuthenticationPreventsLateCredentialRecreation() async throws {
        let fixture = try await LoginFixture.make(loginDelay: .milliseconds(200))
        let recorder = CredentialRecorder()
        fixture.model.credentials = CredentialWrites(backend: recorder.backend)
        let work = Task { await fixture.model.login(password: "fixture-only", remember: true) }
        await waitForLoginCondition { await fixture.server.trace.contains(":1") }
        #expect(await fixture.server.trace.contains(":1"))
        try await fixture.model.credentials.delete(for: "fixture-a")
        await work.value
        #expect(fixture.model.connection == .connected)
        #expect(recorder.contains("fixture-a") == false)
        #expect(recorder.events == ["delete:fixture-a"])
        await fixture.close()
    }

    @Test func credentialSaveAndDeleteRemainSerializedInBothOrderings() async throws {
        for saveFirst in [true, false] {
            let recorder = CredentialRecorder(); let writes = CredentialWrites(backend: recorder.backend)
            let generation = await writes.generation
            if saveFirst { try await writes.save(password: "fixture-only", for: "fixture-a", ifGeneration: generation) }
            try await writes.delete(for: "fixture-a")
            if !saveFirst { try await writes.save(password: "fixture-only", for: "fixture-a", ifGeneration: generation) }
            #expect(recorder.contains("fixture-a") == false)
            #expect(recorder.events == (saveFirst ? ["save:fixture-a", "delete:fixture-a"] : ["delete:fixture-a"]))
        }
    }

    @Test @MainActor func rememberedSignInReconnectsRecreatedModelWithoutAnotherWrite() async throws {
        let fixture = try await LoginFixture.make()
        let recorder = CredentialRecorder()
        fixture.model.credentials = CredentialWrites(backend: recorder.backend)
        await fixture.model.login(password: "fixture-only", remember: true)
        #expect(recorder.contains("fixture-a"))
        await fixture.model.shutdown()
        let restored = try AppModel(dataDirectory: fixture.root)
        restored.credentials = CredentialWrites(backend: recorder.backend)
        restored.credentialLookup = { user in recorder.password(for: user) }
        await restored.start(); await restored.connectAtLaunch()
        #expect(restored.connection == .connected)
        #expect(restored.activeAccount == "fixture-a")
        #expect(restored.error == nil)
        #expect(recorder.events == ["save:fixture-a"])
        await restored.shutdown(); await fixture.close()
    }

    @Test @MainActor func failedRememberWriteDoesNotBlockAuthenticatedSetupAndRememberFalseDoesNotWrite() async throws {
        let fixture = try await LoginFixture.make()
        let recorder = CredentialRecorder()
        fixture.model.credentials = CredentialWrites(backend: recorder.backend)
        await fixture.model.login(password: "fixture-only", remember: false)
        #expect(recorder.events.isEmpty)
        var failing = recorder.backend
        failing.save = { _, _ in throw StorageError.sqlite("Isolated credential write failure.") }
        fixture.model.credentials = CredentialWrites(backend: failing)
        fixture.model.settings.listeningPort = try unusedPort()
        await fixture.model.login(password: "fixture-only", remember: true)
        #expect(fixture.model.connection == .connected)
        #expect(fixture.model.error?.contains("Keychain") == true)
        try await fixture.model.session.send(code: 999)
        await waitForLoginCondition { await fixture.server.trace.contains("fixture-a:999") }
        #expect(await fixture.server.trace.filter { $0 == "fixture-a:64" }.count == 2)
        await fixture.close()
    }

    @Test @MainActor func staleCredentialWriteFailureCannotOverwriteNewerOfflineStatus() async throws {
        let fixture = try await LoginFixture.make()
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let backend = CredentialWrites.Backend(save: { _, _ in
            entered.withLock { $0 = true }
            release.wait()
            throw StorageError.sqlite("Isolated delayed credential write failure.")
        }, delete: { _ in })
        fixture.model.credentials = CredentialWrites(backend: backend)
        let work = Task { await fixture.model.login(password: "fixture-only", remember: true) }
        await waitForLoginCondition { entered.withLock { $0 } }
        #expect(entered.withLock { $0 })
        await fixture.model.disconnect()
        fixture.model.error = "Current offline notice."
        release.signal(); await work.value
        #expect(fixture.model.connection == .offline)
        #expect(fixture.model.error == "Current offline notice.")
        await fixture.close()
    }
}

private final class CredentialRecorder: Sendable {
    private struct State { var passwords: [String: String] = [:]; var events: [String] = [] }
    private let state = Mutex(State())
    var events: [String] { state.withLock { $0.events } }
    func contains(_ user: String) -> Bool { state.withLock { $0.passwords[user] != nil } }
    func password(for user: String) -> String { state.withLock { $0.passwords[user] ?? "" } }
    var backend: CredentialWrites.Backend {
        .init(save: { password, user in
            self.state.withLock { $0.passwords[user] = password; $0.events.append("save:\(user)") }
        }, delete: { user in
            self.state.withLock { $0.passwords.removeValue(forKey: user); $0.events.append("delete:\(user)") }
        })
    }
}

@MainActor private struct LoginFixture {
    let root: URL
    let model: AppModel
    let server: MockSoulseekServer
    static func make(loginDelay: Duration = .zero) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = try await MockSoulseekServer.start(loginDelay: loginDelay)
        let model = try AppModel(dataDirectory: root)
        var settings = AppSettings()
        settings.username = "fixture-a"; settings.server = "127.0.0.1"
        settings.port = try await server.port(); settings.listeningPort = try unusedPort()
        settings.notifications = false; settings.checkForUpdates = false; settings.portMapping = false
        settings.downloadDirectory = root.appendingPathComponent("downloads").path
        try await model.database.put(settings, collection: "settings", id: "main")
        await model.start()
        return Self(root: root, model: model, server: server)
    }
    func close() async {
        await model.shutdown(); await server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LoginSetupGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private func waitForLoginCondition(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}
