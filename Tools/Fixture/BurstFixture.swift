import Foundation
import ArpeggioServices
import ProtocolFixtures
import Persistence
import SoulseekCore

/// 80 independent loopback peers sharing 63 files each, with three large downloads and native FLAC.
enum BurstFixture {
    @MainActor static func run(root: URL) async throws {
        let music = root.appendingPathComponent("Share/Burst Album")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for track in 1...59 {
            try FixtureMain.wave(track: track).write(to: music.appendingPathComponent(String(format: "%02d Burst Tone.wav", track)))
        }
        for track in 1...3 {
            let url = music.appendingPathComponent("Large Burst \(track).bin")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ProtocolError.invalid("Could not create fixture file.") }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 384 * 1024 * 1024)
            try handle.close()
        }
        let wave = root.appendingPathComponent("noise.wav")
        try noiseWave().write(to: wave)
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "flac", "-d", "flac", wave.path, music.appendingPathComponent("Burst Preview.flac").path]
        try convert.run(); convert.waitUntilExit()
        guard convert.terminationStatus == 0 else { throw ProtocolError.invalid("FLAC conversion failed.") }
        try FileManager.default.removeItem(at: wave)

        let server = try await MockSoulseekServer.start()
        let port = try await server.port()
        var peers: [AppModel] = []
        do {
            for index in 0..<80 {
                let name = String(format: "burst-peer-%02d", index)
                let peer = try AppModel(dataDirectory: root.appendingPathComponent(name))
                peers.append(peer)
                await peer.start()
                peer.settings.username = name
                peer.settings.server = "127.0.0.1"; peer.settings.port = port
                peer.settings.listeningPort = try FixtureMain.availablePort()
                peer.settings.portMapping = false; peer.settings.notifications = false
                peer.settings.checkForUpdates = false; peer.settings.awayWhenIdle = false
                peer.settings.downloadDirectory = root.appendingPathComponent("UnusedDownloads").path
                peer.settings.sharedFolders = [ShareFolder(path: root.appendingPathComponent("Share").path)]
                peer.settings.uploadSlots = 4
                await peer.saveSettings()
                await peer.login(password: "fixture-only", remember: false)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while peers.contains(where: { $0.sharedCount != 63 || $0.connection != .connected || $0.indexing }) {
                guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("Burst peers not ready.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Data(String(port).utf8).write(to: root.appendingPathComponent("port"))
            print("BURST READY: 5040 results, 80 users, port \(port)")
            let end = ContinuousClock.now.advanced(by: .seconds(900))
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path), ContinuousClock.now < end {
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            for peer in peers { await peer.shutdown() }
            await server.stop()
            throw error
        }
        for peer in peers { await peer.shutdown() }
        await server.stop()
    }

    private static func noiseWave() -> Data {
        let frames = 44_100 * 180
        var pcm = Data(capacity: frames * 4)
        var state: UInt32 = 42
        for _ in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            var sample = Int16(truncatingIfNeeded: state >> 16).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        var writer = WireWriter()
        writer.bytes(Data("RIFF".utf8)); writer.uint(UInt32(36 + pcm.count)); writer.bytes(Data("WAVEfmt ".utf8)); writer.uint(16)
        writer.bytes(Data([1, 0, 2, 0])); writer.uint(44_100); writer.uint(176_400); writer.bytes(Data([4, 0, 16, 0]))
        writer.bytes(Data("data".utf8)); writer.uint(UInt32(pcm.count)); writer.bytes(pcm)
        return writer.data
    }
}
