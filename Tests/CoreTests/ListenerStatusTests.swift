import Foundation
import Testing
import Persistence
import ProtocolFixtures
@testable import SoulseekCore
@testable import ArpeggioServices
@testable import Arpeggio

@Suite struct ListenerStatusTests {
    @Test func activeListenerIsShownWhileAnEditedPortWaitsForReconnect() throws {
        let status = ListenerStatus.make(connected: true, busyLabel: nil, activePort: 61147, configuredPort: 2234)
        #expect(status.title == "Listening on 61147")
        #expect(!status.title.contains("2234"))
        #expect(status.tone == .active)
        let detail = try #require(status.detail)
        #expect(detail.contains("2234"))
        #expect(detail.contains("next time you connect"))
        #expect(!detail.contains("\u{2014}")); #expect(!detail.contains("\u{2013}"))
    }

    @Test func matchingPortsNeedNoReconnectNote() {
        let status = ListenerStatus.make(connected: true, busyLabel: nil, activePort: 61147, configuredPort: 61147)
        #expect(status.title == "Listening on 61147")
        #expect(status.detail == nil)
        #expect(status.tone == .active)
    }

    @Test func unknownBoundPortNeverClaimsAListenerFromConfiguration() {
        let status = ListenerStatus.make(connected: true, busyLabel: nil, activePort: nil, configuredPort: 2234)
        #expect(status.title == "Connected to Soulseek")
        #expect(!status.title.contains("Listening"))
        #expect(!status.title.contains("2234"))
        #expect(status.detail?.contains("2234") != true)
    }

    @Test func offlineAndBusyStatesNeverClaimAListener() {
        let offline = ListenerStatus.make(connected: false, busyLabel: nil, activePort: nil, configuredPort: 61147)
        #expect(offline.title == "Starts when you connect")
        #expect(offline.tone == .neutral)
        let busy = ListenerStatus.make(connected: false, busyLabel: "Connecting…", activePort: 61147, configuredPort: 61147)
        #expect(busy.title == "Connecting…")
        #expect(busy.tone == .neutral)
        for status in [offline, busy] {
            #expect(!status.title.contains("Listening"))
            #expect(status.detail == nil)
        }
    }
}

@Suite struct ActiveListenerPortTests {
    @Test(.timeLimit(.minutes(1))) @MainActor func activePortComesFromTheSessionBindingNotTheEditedSetting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = try await MockSoulseekServer.start()
        let model = try AppModel(dataDirectory: root)
        var settings = AppSettings()
        settings.username = "listener-fixture"; settings.server = "127.0.0.1"
        settings.port = try await server.port(); settings.listeningPort = try unusedPort()
        settings.notifications = false; settings.checkForUpdates = false; settings.portMapping = false
        settings.downloadDirectory = root.appendingPathComponent("downloads").path
        try await model.database.put(settings, collection: "settings", id: "main")
        await model.start()
        model.credentials = CredentialWrites(backend: .init(save: { _, _ in }, delete: { _ in }))
        #expect(model.activeListeningPort == nil)

        await model.login(password: "fixture-only", remember: false)
        #expect(model.connection == .connected)
        let generation = try #require(model.activeSessionGeneration)
        let bound = try #require(await model.session.listeningPort(generation: generation))
        #expect(model.activeListeningPort == bound)

        var edited = try unusedPort()
        while edited == bound { edited = try unusedPort() }
        model.settings.listeningPort = edited
        #expect(model.activeListeningPort == bound)
        let status = ListenerStatus.make(connected: model.connection.isConnected, busyLabel: nil,
                                         activePort: model.activeListeningPort, configuredPort: model.settings.listeningPort)
        #expect(status.title == "Listening on \(bound)")
        #expect(!status.title.contains(String(edited)))
        #expect(status.detail?.contains(String(edited)) == true)

        await model.disconnect()
        #expect(model.activeListeningPort == nil)
        await model.shutdown(); await server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}
