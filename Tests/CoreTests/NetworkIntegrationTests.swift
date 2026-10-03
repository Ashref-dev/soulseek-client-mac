import Foundation
import Testing
import Network
@testable import SoulseekCore
import ArpeggioServices
import Persistence
import TransferEngine
import Darwin
import ProtocolFixtures

@Test func addressByteOrder() {
    #expect(SoulseekSession.ipString(0x7f000001) == "127.0.0.1")
    #expect(SoulseekSession.ipString(0xc0a80102) == "192.168.1.2")
}

@MainActor
private func waitUntil(_ label: String, details: () async -> String = { "" }, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("\(label) timed out: \(await details())") }
        try await Task.sleep(for: .milliseconds(25))
    }
}

func unusedPort() throws -> UInt16 {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw ProtocolError.invalid("No test socket.") }
    defer { Darwin.close(socket) }
    var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw ProtocolError.invalid("Could not bind test port.") }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) }
    }
    guard result == 0 else { throw ProtocolError.invalid("Could not read test port.") }
    return UInt16(bigEndian: address.sin_port)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func partialDownloadResumesAfterRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let share = root.appendingPathComponent("Originals")
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    let bytes = Data(repeating: 42, count: 1_000_000)
    try bytes.write(to: share.appendingPathComponent("resume.txt"))
    let fixture = try await MockSoulseekServer.start()
    let port = try await fixture.port()
    let state = root.appendingPathComponent("receiver-state")
    let receiver = try AppModel(dataDirectory: state)
    let sender = try AppModel(dataDirectory: root.appendingPathComponent("sender-state"))
    await receiver.start(); await sender.start()
    for model in [receiver, sender] {
        model.settings.server = "127.0.0.1"; model.settings.port = port; model.settings.listeningPort = try unusedPort()
        model.settings.downloadDirectory = root.appendingPathComponent("downloads").path
    }
    receiver.settings.username = "resume-receiver"; sender.settings.username = "resume-sender"
    receiver.settings.downloadLimitKB = 256
    sender.settings.sharedFolders = [ShareFolder(path: share.path)]
    await receiver.saveSettings(); await sender.saveSettings()
    receiver.error = "Previous sign-in failed."
    await receiver.login(password: "fixture-only", remember: false); await sender.login(password: "fixture-only", remember: false)
    #expect(receiver.error == nil)
    receiver.query = "resume"; await receiver.search()
    try await waitUntil("resume search") { !receiver.results.isEmpty }
    await receiver.download([try #require(receiver.results.first)])
    try await waitUntil("partial bytes") { receiver.transfers.contains { $0.transferred > 0 && $0.status == .transferring } }
    let item = try #require(receiver.transfers.first)
    await receiver.transferEngine.pause(item.id)
    let partialPath = try #require(item.partial)
    let partialBytes = try Data(contentsOf: URL(fileURLWithPath: partialPath)).count
    #expect(partialBytes > 0); #expect(partialBytes < bytes.count)
    await receiver.shutdown()
    let restored = try AppModel(dataDirectory: state); await restored.start()
    try await waitUntil("restored pause") { restored.transfers.first?.status == .paused }
    restored.settings.downloadLimitKB = 0; await restored.saveSettings()
    await restored.login(password: "fixture-only", remember: false)
    await restored.transferEngine.resume(item.id)
    try await waitUntil("resumed download", details: { "\(restored.transfers.map { ($0.status.rawValue, $0.error ?? "") })" }) { restored.transfers.contains { $0.status == .completed } }
    let complete = try #require(restored.transfers.first { $0.status == .completed })
    #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(complete.destination))) == bytes)
    await restored.shutdown(); await sender.shutdown(); await fixture.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func standaloneSearchBrowseDownloadUploadChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let shares = root.appendingPathComponent("Collection/Björk")
    try FileManager.default.createDirectory(at: shares, withIntermediateDirectories: true)
    let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
    try content.write(to: shares.appendingPathComponent("01 Jóga.flac"))
    let server = try await MockSoulseekServer.start(forceIndirect: ["fixture-alice"])
    let port = try await server.port()
    let alice = try AppModel(dataDirectory: root.appendingPathComponent("alice-state"))
    let bob = try AppModel(dataDirectory: root.appendingPathComponent("bob-state"))
    await alice.start(); await bob.start()
    for model in [alice, bob] {
        model.settings.server = "127.0.0.1"; model.settings.port = port
        model.settings.listeningPort = try unusedPort()
        model.settings.downloadDirectory = root.appendingPathComponent("downloads").path
    }
    alice.settings.username = "fixture-alice"; bob.settings.username = "fixture-bob"
    bob.settings.sharedFolders = [ShareFolder(path: root.appendingPathComponent("Collection").path)]
    await alice.saveSettings(); await bob.saveSettings()
    let metadata = try shares.appendingPathComponent("01 Jóga.flac").resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
    #expect(bob.sharedCount == 1, "scan errors=\(bob.shareErrors), storage error=\(bob.error ?? "none"), regular=\(String(describing: metadata.isRegularFile)), readable=\(String(describing: metadata.isReadable)), path=\(shares.path)")
    #expect(await bob.shareIndex.search("Jóga").count == 1)
    await alice.login(password: "fixture-only", remember: false)
    await bob.login(password: "fixture-only", remember: false)
    #expect(alice.connection == .connected); #expect(bob.connection == .connected)
    try await Task.sleep(for: .milliseconds(100))
    alice.query = "Jóga"
    await alice.search()
    try await waitUntil("search", details: { "alice=\(alice.diagnostics), bob=\(bob.diagnostics), token=\(String(describing: alice.searchToken)), server=\(await server.trace)" }) { !alice.results.isEmpty }
    let result = try #require(alice.results.first)
    #expect(result.file.size == UInt64(content.count)); #expect(result.user == "fixture-bob")
    await alice.browse("fixture-bob")
    try await waitUntil("browse") { alice.libraries["fixture-bob"] != nil }
    #expect(alice.libraries["fixture-bob"]?.folders.values.flatMap { $0 }.count == 1)
    await alice.download([result])
    try await waitUntil("download", details: { "\(alice.transfers.map { ($0.status.rawValue, $0.error ?? "") }); uploads=\(bob.transfers.map { ($0.status.rawValue, $0.error ?? "") })" }) { alice.transfers.contains { $0.status == .completed } }
    let finished = try #require(alice.transfers.first { $0.status == .completed })
    let path = try #require(finished.destination)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == content)
    try await waitUntil("upload") { bob.transfers.contains { $0.upload && $0.status == .completed } }
    await alice.sendMessage(to: "fixture-bob", text: "Hello from the independent Swift client")
    try await waitUntil("private message") { bob.messages.contains { $0.text == "Hello from the independent Swift client" } }
    await alice.joinRoom("Arpeggio Test Room"); await bob.joinRoom("Arpeggio Test Room")
    try await waitUntil("room join") { bob.joinedRooms["Arpeggio Test Room"] != nil }
    await alice.sendMessage(to: "Arpeggio Test Room", text: "Room test", room: true)
    try await waitUntil("room message") { bob.messages.contains { $0.room == "Arpeggio Test Room" && $0.text == "Room test" } }
    await alice.disconnect(); await bob.disconnect(); await server.stop()
    let restored = try await alice.database.all(Transfer.self, collection: "transfers")
    #expect(restored.contains { $0.status == .completed && $0.transferred == UInt64(content.count) })
    await alice.database.close(); await bob.database.close()
}
