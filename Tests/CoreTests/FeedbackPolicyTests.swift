import Foundation
import Testing
@testable import ArpeggioServices
@testable import SoulseekCore
import Persistence
import ProtocolFixtures

@Test func sharingPolicyDistinguishesUnknownZeroAndPositive() {
    #expect(SharingPolicy.allows(required: false, files: 0))
    #expect(SharingPolicy.allows(required: true, files: nil))
    #expect(!SharingPolicy.allows(required: true, files: 0))
    #expect(SharingPolicy.allows(required: true, files: 1))
    #expect(!AppSettings().requiresSharing)
    #expect(AppSettings().sharingMessage == "You must share files in order to download from me.")
}

private actor LookupCounter {
    var value = 0
    func increment() { value += 1 }
}

@Test func sharingLookupIsBoundedCoalescedAndStaleZeroIsUnknown() async {
    let policy = SharingPolicy(); let counter = LookupCounter()
    await policy.observe(user: "peer", files: 0, now: Date().addingTimeInterval(-120))
    async let first = policy.permits(user: "peer", required: true, timeout: .milliseconds(100)) { await counter.increment() }
    async let second = policy.permits(user: "peer", required: true, timeout: .milliseconds(100)) { await counter.increment() }
    #expect(await first); #expect(await second)
    #expect(await counter.value == 1)
    await policy.observe(user: "peer", files: 0)
    #expect(await policy.permits(user: "peer", required: true) {} == false)
    await policy.reset()
    #expect(await policy.permits(user: "peer", required: true, timeout: .milliseconds(1)) {})
}

@Test func sharingLookupReceivesFreshEvidenceWhileWaiting() async {
    let policy = SharingPolicy()
    #expect(await policy.permits(user: "zero", required: true) { await policy.observe(user: "zero", files: 0) } == false)
    #expect(await policy.permits(user: "positive", required: true) { await policy.observe(user: "positive", files: 3) })
}

@Test func automaticSharingMessageThrottleIsAccountScoped() async {
    let policy = SharingPolicy(); let now = Date(timeIntervalSince1970: 0)
    #expect(await policy.shouldNotify(account: "one", user: "peer", now: now))
    #expect(await policy.shouldNotify(account: "one", user: "peer", now: now.addingTimeInterval(3599)) == false)
    #expect(await policy.shouldNotify(account: "two", user: "peer", now: now))
    #expect(await policy.shouldNotify(account: "one", user: "peer", now: now.addingTimeInterval(3600)))
}

@Test @MainActor func bothUploadRequestProtocolsRejectZeroSharesAndRevalidate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("song.mp3"); try Data("bytes".utf8).write(to: source)
    let server = try await MockSoulseekServer.start()
    let sender = try AppModel(dataDirectory: root.appendingPathComponent("sender")); await sender.start()
    let peer = try AppModel(dataDirectory: root.appendingPathComponent("peer")); await peer.start()
    for model in [sender, peer] {
        model.settings.server = "127.0.0.1"; model.settings.port = try await server.port()
        model.settings.listeningPort = try unusedPort(); model.settings.portMapping = false
    }
    sender.settings.username = "sender"; peer.settings.username = "zero"
    sender.settings.sharedFolders = [ShareFolder(path: folder.path)]
    sender.settings.requireSharing = true
    await sender.saveSettings(); await peer.saveSettings()
    await sender.login(password: "fixture-only", remember: false); await peer.login(password: "fixture-only", remember: false)
    try await Task.sleep(for: .milliseconds(100))
    var modern = WireWriter(); modern.string("Music\\song.mp3")
    try await sender.handlePeer(user: "zero", code: 43, payload: modern.data)
    var legacy = WireWriter(); legacy.uint(0); legacy.uint(7); legacy.string("Music\\song.mp3")
    try await sender.handlePeer(user: "zero", code: 40, payload: legacy.data)
    #expect(await sender.transferEngine.snapshot().isEmpty)
    #expect(await sender.authorizeUpload(user: "zero", file: SharedFile(path: "Music\\song.mp3", size: 5), url: source) == false)
    await sender.setTransfersSuspended(upload: true, true)
    sender.settings.requireSharing = false
    try await sender.handlePeer(user: "zero", code: 43, payload: modern.data)
    #expect(await sender.transferEngine.snapshot().contains { $0.upload && $0.status == .queued })
    sender.settings.requireSharing = true; await sender.saveSettings()
    #expect(await sender.transferEngine.snapshot().allSatisfy { $0.status == .cancelled })
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while peer.messages.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(peer.messages.filter { $0.text == sender.settings.sharingMessage }.count == 1)
    #expect(await server.trace.filter { $0 == "sender:36" }.count == 1)
    await sender.shutdown(); await peer.shutdown(); await server.stop()
}
