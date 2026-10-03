import Testing
import Security
import LocalAuthentication
import Foundation
@testable import ArpeggioServices
@testable import Persistence

@Test func automaticCredentialLookupCannotOpenAuthenticationDialogs() {
    let query = Keychain.lookupQuery("fixture-user")
    let context = query[kSecUseAuthenticationContext as String] as? LAContext
    #expect(context?.interactionNotAllowed == true)
    #expect(query[kSecAttrAccount as String] as? String == "fixture-user")
}

@Test @MainActor func delayedCredentialsCannotOverrideDisconnectOrAccountChange() async throws {
    for disconnect in [true, false] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.username = "fixture"
        model.intentionallyOffline = false; model.reconnectAllowed = true
        let lookup = DelayedCredential()
        model.credentialLookup = { _ in await lookup.value() }
        let configuration = model.settings
        let work = Task { await model.reconnectAfterCredentialLookup(configuration: configuration, revision: model.loginRevision) }
        while !(await lookup.started) { await Task.yield() }
        if disconnect { await model.disconnect() } else { model.settings.username = "other" }
        await lookup.resolve()
        await work.value
        #expect(model.connection == .offline)
        #expect(model.activeAccount.isEmpty)
        if disconnect { #expect(model.intentionallyOffline) }
        await model.shutdown()
    }
}

private actor DelayedCredential {
    var started = false
    var continuation: CheckedContinuation<String, Never>?
    func value() async -> String {
        await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
    }
    func resolve() { continuation?.resume(returning: "fixture-secret"); continuation = nil }
}
