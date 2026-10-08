import Foundation
import Testing
import Security
import SoulseekCore
import ProtocolFixtures
@testable import Persistence
@testable import ArpeggioServices
@testable import Arpeggio

@Suite struct StartupCredentialTests {
    @Test func inaccessibleKeychainIsNotAMissingPassword() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let operations = securityOperations(readStatus: status)
            #expect(throws: (any Error).self) {
                try Keychain.password(for: "isolated-fixture", operations: operations)
            }
        }
        #expect(try Keychain.password(for: "isolated-fixture", operations: securityOperations(readStatus: errSecItemNotFound)) == nil)
    }

    @Test func failedCredentialUpdateNeverDeletesOrReplacesExistingItem() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            var operations = securityOperations(readStatus: errSecItemNotFound)
            var deletes = 0; var adds = 0
            operations.update = { _, _ in status }
            operations.delete = { _ in deletes += 1; return errSecSuccess }
            operations.add = { _, _ in adds += 1; return errSecSuccess }
            #expect(throws: (any Error).self) {
                try Keychain.save(password: "fixture-only", for: "isolated-fixture", operations: operations)
            }
            #expect(deletes == 0)
            #expect(adds == 0)
        }
    }

    @Test func credentialRoundTripUpdatesInPlaceAndOnlyAddsWhenMissing() throws {
        var stored: Data?
        var adds = 0; var updates = 0; var deletes = 0
        let operations = Keychain.Operations(
            copyMatching: { _, result in
                guard let stored else { return errSecItemNotFound }
                result?.pointee = stored as CFData; return errSecSuccess
            },
            update: { _, attributes in
                updates += 1
                guard stored != nil else { return errSecItemNotFound }
                stored = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            },
            add: { attributes, _ in
                adds += 1; stored = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            },
            delete: { _ in deletes += 1; return errSecSuccess }
        )
        try Keychain.save(password: "fixture-one", for: "isolated-fixture", operations: operations)
        #expect(try Keychain.password(for: "isolated-fixture", operations: operations) == "fixture-one")
        try Keychain.save(password: "fixture-two", for: "isolated-fixture", operations: operations)
        #expect(try Keychain.password(for: "isolated-fixture", operations: operations) == "fixture-two")
        #expect(adds == 1); #expect(updates == 2); #expect(deletes == 0)
        stored = Data([0xff])
        #expect(throws: KeychainError.self) { try Keychain.password(for: "isolated-fixture", operations: operations) }
    }

    @Test @MainActor func absentPasswordReportsActionAndIsNotRetriedAtLaunch() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try AppModel(dataDirectory: root)
        original.settings.username = "isolated-fixture"
        original.settings.notifications = false; original.settings.checkForUpdates = false
        await original.saveSettings(); await original.shutdown()
        let model = try AppModel(dataDirectory: root)
        await model.start()
        let lookups = CredentialProbe(password: "")
        model.credentialLookup = { _ in await lookups.read() }
        await model.connectAtLaunch(); await model.connectAtLaunch()
        #expect(model.connection == .offline)
        #expect(model.intentionallyOffline == true)
        #expect(!model.reconnectAllowed)
        #expect(model.error?.contains("Sign In") == true)
        #expect(model.error?.contains("Remember password") == true)
        #expect(await lookups.count == 1)
        await model.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func blockedKeychainRelaunchReportsRecoveryWithoutLoginOrRetry() async throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let original = try AppModel(dataDirectory: root)
            original.settings.username = "isolated-fixture"
            original.settings.notifications = false; original.settings.checkForUpdates = false
            await original.saveSettings(); await original.shutdown()
            let relaunched = try AppModel(dataDirectory: root)
            relaunched.credentialLookup = { user in
                try Keychain.password(for: user, operations: securityOperations(readStatus: status)) ?? ""
            }
            await relaunched.start()
            await relaunched.connectAtLaunch(); await relaunched.connectAtLaunch()
            #expect(relaunched.connection == .offline)
            #expect(relaunched.intentionallyOffline == true)
            #expect(relaunched.loginRevision == 0)
            #expect(relaunched.error?.contains("\(status)") == true)
            #expect(relaunched.error?.contains("Sign In") == true)
            await relaunched.shutdown()
        }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func persistedProfileReconnectsAfterRelaunchAndBootstrapCallerCancellation() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try await MockSoulseekServer.start()
        let first = try AppModel(dataDirectory: root)
        first.settings.username = "isolated-fixture"
        first.settings.server = "127.0.0.1"; first.settings.port = try await server.port()
        first.settings.listeningPort = try unusedPort()
        first.settings.notifications = false; first.settings.checkForUpdates = false; first.settings.portMapping = false
        first.settings.downloadDirectory = root.appendingPathComponent("downloads").path
        // nil autoConnect is the pre-existing profile's default, not an explicit opt-in.
        await first.saveSettings()
        await first.start()
        await first.login(password: "fixture-only", remember: false)
        #expect(first.connection == .connected)
        await first.shutdown()

        let relaunched = try AppModel(dataDirectory: root)
        let probe = CredentialProbe(password: "fixture-only", delayed: true)
        relaunched.credentialLookup = { _ in await probe.read() }
        let bootstrap = Bootstrap()
        let caller = Task { await bootstrap.start(relaunched) }
        try await waitForProbe(probe)
        caller.cancel(); await caller.value
        await bootstrap.start(relaunched)
        await probe.resolve()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while relaunched.connection != .connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(relaunched.connection == .connected)
        #expect(relaunched.activeAccount == "isolated-fixture")
        #expect(relaunched.error == nil)
        #expect(await probe.count == 1)
        await relaunched.shutdown(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func delayedStartupCannotUndoOfflineOrChangedSettings() async throws {
        let server = try await MockSoulseekServer.start()
        for change in 0..<7 {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let model = try AppModel(dataDirectory: root)
            model.settings.username = "isolated-fixture"
            model.settings.server = "127.0.0.1"; model.settings.port = try await server.port()
            model.settings.listeningPort = try unusedPort()
            model.settings.notifications = false; model.settings.portMapping = false
            model.settings.downloadDirectory = root.appendingPathComponent("downloads").path
            let probe = CredentialProbe(password: "fixture-only", delayed: true)
            model.credentialLookup = { _ in await probe.read() }
            let work = Task { await model.connectAtLaunch() }
            try await waitForProbe(probe)
            switch change {
            case 0: await model.disconnect()
            case 1: model.settings.username = "other-fixture"
            case 2: model.settings.autoConnect = false
            case 3: model.settings.listeningPort &+= 1
            case 4: model.settings.server = "localhost"
            case 5: model.settings.port &+= 1
            default: await model.shutdown()
            }
            await probe.resolve(); await work.value
            #expect(model.connection == .offline)
            #expect(model.intentionallyOffline == true)
            #expect(model.error == nil)
            await model.shutdown()
        }
        await server.stop()
    }

    /// At login the network is often not ready. A failed first attempt must keep retrying, not stay offline.
    @Test(.timeLimit(.minutes(1))) @MainActor func failedConnectionAtLaunchSchedulesARetry() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.username = "isolated-fixture"
        model.settings.server = "127.0.0.1"; model.settings.port = try unusedPort()
        model.settings.listeningPort = try unusedPort()
        model.settings.notifications = false; model.settings.portMapping = false
        model.settings.downloadDirectory = root.appendingPathComponent("downloads").path
        model.credentialLookup = { _ in "fixture-only" }
        let gate = RaceGate()
        model.reconnectClock = ReconnectClock(now: { Date(timeIntervalSince1970: 1000) }, sleep: { _ in await gate.wait(); try Task.checkCancellation() })
        await model.start(); await model.connectAtLaunch()
        try await raceWait { await gate.arrivals == 1 }
        #expect(model.reconnectAllowed)
        #expect(model.reconnectSchedule.remaining(at: Date(timeIntervalSince1970: 1000)) == 5)
        await model.shutdown()
        await gate.release()
    }

    @Test @MainActor func disabledAutomaticSignInDoesNotReadCredentials() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.username = "isolated-fixture"; model.settings.autoConnect = false
        let probe = CredentialProbe(password: "")
        model.credentialLookup = { _ in await probe.read() }
        await model.connectAtLaunch()
        #expect(await probe.count == 0)
        #expect(model.error == nil)
        await model.shutdown()
    }
}

private func securityOperations(readStatus: OSStatus) -> Keychain.Operations {
    .init(copyMatching: { _, _ in readStatus }, update: { _, _ in errSecSuccess },
          add: { _, _ in errSecSuccess }, delete: { _ in errSecSuccess })
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private actor CredentialProbe {
    let password: String
    let delayed: Bool
    var count = 0
    var continuation: CheckedContinuation<String, Never>?
    init(password: String, delayed: Bool = false) { self.password = password; self.delayed = delayed }
    func read() async -> String {
        count += 1
        if delayed { return await withCheckedContinuation { continuation = $0 } }
        return password
    }
    func resolve() { continuation?.resume(returning: password); continuation = nil }
}

private func waitForProbe(_ probe: CredentialProbe) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await probe.count == 0 {
        guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("Startup credential lookup timed out.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
