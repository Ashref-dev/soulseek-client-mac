import Foundation
import ArpeggioServices
import ProtocolFixtures
import Persistence
import SoulseekCore
import Darwin

@main
struct FixtureMain {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("ArpeggioFixture: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--burst" {
            try await BurstFixture.run(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        if CommandLine.arguments.contains("--help") {
            print("ArpeggioFixture: a loopback-only Soulseek test server and independent Swift peer. No live network accounts are used. Runs for ten minutes; Ctrl-C stops it. --burst TEMP_ROOT runs 80 peers with 5040 results, three 384 MiB files and generated FLAC; create TEMP_ROOT/stop to shut down.")
            return
        }
        guard CommandLine.arguments.count == 1 else { throw ProtocolError.invalid("Unknown argument. Use --help.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArpeggioFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Originals/Studio Sessions/Glass Notes")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for track in 1...14 {
            let name = String(format: "%02d", track) + (track == 1 ? " Élégie 日本語.wav" : " Studio Note \(track).wav")
            try wave(track: track).write(to: music.appendingPathComponent(name))
        }
        let server = try await MockSoulseekServer.start()
        let port = try await server.port()
        let peer = try AppModel(dataDirectory: root.appendingPathComponent("state"))
        await peer.start()
        peer.settings.username = "studio-fixture"
        peer.settings.server = "127.0.0.1"; peer.settings.port = port
        peer.settings.listeningPort = try availablePort()
        peer.settings.sharedFolders = [ShareFolder(path: root.appendingPathComponent("Originals").path)]
        peer.settings.uploadLimitKB = 384
        await peer.saveSettings(); await peer.login(password: "fixture-only", remember: false)
        print("LOCAL FIXTURE READY")
        print("Server: 127.0.0.1:\(port)")
        print("Sign in as: qa-listener / fixture-only (do not save in Keychain)")
        print("Search: Glass Notes | Browse: studio-fixture | Room: Arpeggio Test Room")
        print("14 original generated WAV files, real TCP peer transfers. No copyrighted recordings or UI sample data.")
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        var answered: Set<String> = []
        while ContinuousClock.now < deadline {
            for message in peer.messages where !message.outgoing && message.room == nil && !answered.contains(message.id) {
                answered.insert(message.id)
                await peer.sendMessage(to: message.user, text: "Hello from the local protocol fixture. This reply travelled through the server and the native Swift client.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        await peer.shutdown(); await server.stop()
    }
    static func wave(track: Int) -> Data {
        let count = 44_100 * 3
        var pcm = Data(capacity: count * 4)
        for frame in 0..<count {
            let envelope = min(1, Double(frame) / 3000) * min(1, Double(count - frame) / 3000)
            var sample = Int16(sin(Double(frame) * 2 * .pi * Double(180 + track * 20) / 44_100) * 2400 * envelope).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        var writer = WireWriter()
        writer.bytes(Data("RIFF".utf8)); writer.uint(UInt32(36 + pcm.count)); writer.bytes(Data("WAVEfmt ".utf8)); writer.uint(16)
        writer.bytes(Data([1, 0, 2, 0])); writer.uint(44_100); writer.uint(176_400); writer.bytes(Data([4, 0, 16, 0]))
        writer.bytes(Data("data".utf8)); writer.uint(UInt32(pcm.count)); writer.bytes(pcm)
        return writer.data
    }
    static func availablePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ProtocolError.invalid("Could not reserve fixture port.") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
        guard bound == 0, result == 0 else { throw ProtocolError.invalid("Could not read fixture port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
