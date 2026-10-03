import Foundation
import Testing
import ArpeggioServices
import Persistence

@Test(.timeLimit(.minutes(1))) @MainActor
func refusedConnectionNamesConfiguredEndpointInsteadOfMisidentifyingServer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try AppModel(dataDirectory: root)
    await model.start()
    let port = try unusedPort()
    model.settings.server = "127.0.0.1"; model.settings.port = port
    model.settings.listeningPort = try unusedPort(); model.settings.username = "fixture"
    await model.login(password: "fixture-only", remember: false)
    #expect(model.error?.contains("127.0.0.1:\(port)") == true)
    await model.shutdown()
}

@Test func restoringSoulseekEndpointPreservesAccountAndUserPreferences() {
    var settings = AppSettings()
    settings.username = "fixture-user"; settings.server = "127.0.0.1"; settings.port = 12345
    settings.listeningPort = 2345; settings.downloadSlots = 7
    settings.useSoulseekServer()
    #expect(settings.serverEndpoint == "server.slsknet.org:2242")
    #expect(!settings.isLocalServer); #expect(settings.username == "fixture-user")
    #expect(settings.listeningPort == 2345); #expect(settings.downloadSlots == 7)
}
