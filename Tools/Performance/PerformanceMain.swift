import Foundation
import Darwin
import ArpeggioServices
import ProtocolFixtures
import Persistence
import SoulseekCore
import TransferEngine

/// Long-session workload against a loopback fixture: two isolated profiles, a local mock server and generated
/// audio. It cycles searches, downloads, list removal, previews and reconnects, then idles, and reports duration,
/// memory and idle CPU for this machine. No real accounts, Keychain items, owner data or user interface are used.
@main
struct PerformanceMain {
    @MainActor static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help { print(Options.usage); return }
            let report = try await LongSession(options: options).run()
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let path = options.output { try data.write(to: URL(fileURLWithPath: path)) }
            FileHandle.standardOutput.write(data); print()
            if (report["failures"] as? [String])?.isEmpty == false { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("ArpeggioPerformance: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

struct Options {
    static let usage = """
    ArpeggioPerformance [--cycles N] [--idle SECONDS] [--tracks N] [--output FILE]
      Runs an isolated loopback long session and prints a JSON report. Defaults: 20 cycles, 10 s idle, 12 tracks.
    """
    var cycles = 20
    var idle: Double = 10
    var tracks = 12
    var output: String?
    var help = false

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--help", "-h": help = true
            case "--cycles": cycles = try Self.number(iterator.next(), argument, 1...10_000)
            case "--tracks": tracks = try Self.number(iterator.next(), argument, 2...200)
            case "--idle": idle = Double(try Self.number(iterator.next(), argument, 0...3600))
            case "--output":
                guard let value = iterator.next() else { throw ProtocolError.invalid("--output needs a file path.") }
                output = value
            default: throw ProtocolError.invalid("Unknown argument \(argument). Use --help.")
            }
        }
    }

    private static func number(_ value: String?, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value, let number = Int(value), range.contains(number) else { throw ProtocolError.invalid("\(name) needs a number in \(range).") }
        return number
    }
}

enum ProcessSample {
    /// Current and peak resident memory in bytes.
    static func memory() -> (resident: UInt64, peak: UInt64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.resident_size), UInt64(info.resident_size_max))
    }

    /// User plus system CPU seconds used by this process so far.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func machine() -> [String: Any] {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return ["model": sysctl("hw.model") ?? "unknown", "cpu": sysctl("machdep.cpu.brand_string") ?? "unknown",
                "cores": ProcessInfo.processInfo.activeProcessorCount,
                "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                "os": ProcessInfo.processInfo.operatingSystemVersionString]
    }
}

@MainActor
final class LongSession {
    let options: Options
    let root: URL
    private var timings: [String: [Double]] = [:]
    private var failures: [String] = []
    private var counters: [String: Int] = [:]
    private var peakResident: UInt64 = 0

    init(options: Options) {
        self.options = options
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArpeggioPerformance-\(UUID().uuidString)").resolvingSymlinksInPath()
    }

    func run() async throws -> [String: Any] {
        let started = ContinuousClock.now
        let startMemory = ProcessSample.memory()
        let music = root.appendingPathComponent("Share/Perf Session/Generated Tones")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for track in 1...options.tracks {
            try Self.wave(track: track).write(to: music.appendingPathComponent(String(format: "%02d Perf Session Tone %d.wav", track, track)))
        }
        let server = try await MockSoulseekServer.start()
        let port = try await server.port()
        let sharer = try await profile("perf-sharer", port: port, share: root.appendingPathComponent("Share"))
        let listener = try await profile("perf-listener", port: port, share: nil)
        listener.playback.volume = 0
        var report: [String: Any] = [:]
        do {
            try await wait("both connected", seconds: 15) { sharer.connection == .connected && listener.connection == .connected }
            try await wait("share indexed", seconds: 30) { sharer.sharedCount == self.options.tracks && !sharer.indexing }
            let setup = elapsed(started)
            for cycle in 1...options.cycles {
                let cycleStart = ContinuousClock.now
                await runCycle(cycle, listener: listener)
                note("cycle", elapsed(cycleStart))
                peakResident = max(peakResident, ProcessSample.memory().resident)
            }
            let active = elapsed(started)
            let idleCPUStart = ProcessSample.cpuSeconds(), idleStart = ContinuousClock.now
            try await Task.sleep(for: .seconds(options.idle))
            let idleCPU = ProcessSample.cpuSeconds() - idleCPUStart
            let idleWall = elapsed(idleStart)
            let previewsLeft = listener.transfers.filter(\.isPreview).count
            if previewsLeft > 0 { failures.append("\(previewsLeft) preview transfers left after stopping previews") }
            report = ["setupSeconds": setup, "activeSeconds": active - setup,
                      "idleSeconds": idleWall, "idleCPUSeconds": idleCPU, "idleCPUFraction": idleWall > 0 ? idleCPU / idleWall : 0,
                      "listTransfersAtEnd": listener.transfers.count]
        } catch { failures.append(error.localizedDescription) }
        await listener.shutdown(); await sharer.shutdown(); await server.stop()
        let previewFolders = ["perf-sharer", "perf-listener"].map { root.appendingPathComponent("state-\($0)/Previews").path }
        let leftovers = previewFolders.reduce(0) { $0 + ((try? FileManager.default.contentsOfDirectory(atPath: $1).count) ?? 0) }
        if leftovers > 0 { failures.append("\(leftovers) preview cache files left after shutdown") }
        try? FileManager.default.removeItem(at: root)
        if FileManager.default.fileExists(atPath: root.path) { failures.append("temporary fixture directory was not removed") }
        let endMemory = ProcessSample.memory()
        report["machine"] = ProcessSample.machine()
        report["options"] = ["cycles": options.cycles, "idleSeconds": options.idle, "tracks": options.tracks]
        report["durationSeconds"] = elapsed(started)
        report["memory"] = ["startResidentBytes": startMemory.resident, "endResidentBytes": endMemory.resident,
                            "peakResidentBytes": max(endMemory.peak, peakResident), "peakSampledBetweenCyclesBytes": peakResident]
        report["timings"] = timings.mapValues(Self.summary)
        report["counters"] = counters
        report["failures"] = failures
        report["note"] = "Measured on this machine against a loopback fixture in one process (two profiles plus the mock server). Not a universal benchmark."
        return report
    }

    private func runCycle(_ cycle: Int, listener: AppModel) async {
        do {
            listener.query = "Perf Session"
            var start = ContinuousClock.now
            await listener.search()
            try await wait("search results", seconds: 10) { !listener.results.isEmpty }
            note("searchFirstResult", elapsed(start))
            try await wait("all search results", seconds: 10) { listener.results.count >= self.options.tracks }
            note("searchAllResults", elapsed(start))
            listener.stopSearch()
            count("searches")
            let results = listener.results.sorted { $0.file.path < $1.file.path }

            let wanted = results[cycle % results.count]
            start = ContinuousClock.now
            await listener.download([wanted])
            try await wait("download", seconds: 30) {
                listener.transfers.contains { $0.file.path == wanted.file.path && !$0.isPreview && $0.status == .completed }
            }
            note("download", elapsed(start))
            count("downloads")
            let finished = listener.transfers.filter { $0.file.path == wanted.file.path && !$0.isPreview }
            start = ContinuousClock.now
            if await listener.removeTransfers(Set(finished.map(\.id))) {
                note("removeFromList", elapsed(start)); count("removals")
                for item in finished {
                    guard let path = item.destination else { continue }
                    if FileManager.default.fileExists(atPath: path) { count("filesKeptAfterRemoval"); try? FileManager.default.removeItem(atPath: path) }
                    else { failures.append("cycle \(cycle): removal lost \(item.file.name)") }
                }
            } else { failures.append("cycle \(cycle): removal failed") }

            let previewed = results[(cycle + 1) % results.count]
            start = ContinuousClock.now
            await listener.listen(to: previewed)
            try await wait("preview", seconds: 15) { listener.playback.item != nil || listener.documentPreview != nil }
            note("previewStart", elapsed(start))
            await listener.stopPlayback(); await listener.closeDocumentPreview()
            try await wait("preview discarded", seconds: 10) { !listener.transfers.contains(where: \.isPreview) }
            count("previews")

            if cycle % 5 == 0 {
                start = ContinuousClock.now
                await listener.disconnect()
                await listener.login(password: "fixture-only", remember: false)
                try await wait("reconnect", seconds: 15) { listener.connection == .connected }
                note("reconnect", elapsed(start)); count("reconnects")
            }
        } catch { failures.append("cycle \(cycle): \(error.localizedDescription)") }
    }

    private func profile(_ name: String, port: UInt16, share: URL?) async throws -> AppModel {
        let model = try AppModel(dataDirectory: root.appendingPathComponent("state-\(name)"))
        await model.start()
        model.settings.username = name
        model.settings.server = "127.0.0.1"; model.settings.port = port
        model.settings.listeningPort = try Self.unusedPort()
        model.settings.portMapping = false; model.settings.notifications = false; model.settings.checkForUpdates = false
        model.settings.onboardingVersion = 1; model.settings.awayWhenIdle = false
        model.settings.downloadDirectory = root.appendingPathComponent("Downloads-\(name)").path
        if let share { model.settings.sharedFolders = [ShareFolder(path: share.path)] }
        await model.saveSettings()
        await model.login(password: "fixture-only", remember: false)
        return model
    }

    private func wait(_ label: String, seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProtocolError.invalid("\(label) timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func note(_ name: String, _ seconds: Double) { timings[name, default: []].append(seconds) }
    private func count(_ name: String) { counters[name, default: 0] += 1 }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return ["count": Double(sorted.count), "min": sorted[0], "median": percentile(0.5), "p95": percentile(0.95), "max": sorted[sorted.count - 1]]
    }

    static func unusedPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ProtocolError.invalid("Could not reserve a loopback port.") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
        guard bound == 0, result == 0 else { throw ProtocolError.invalid("Could not read a loopback port.") }
        return UInt16(bigEndian: address.sin_port)
    }

    /// One second of a generated stereo tone; distinct pitch per track.
    static func wave(track: Int) -> Data {
        let count = 44_100
        var pcm = Data(capacity: count * 4)
        for frame in 0..<count {
            let envelope = min(1, Double(frame) / 2000) * min(1, Double(count - frame) / 2000)
            var sample = Int16(sin(Double(frame) * 2 * .pi * Double(220 + track * 30) / 44_100) * 2000 * envelope).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        var writer = WireWriter()
        writer.bytes(Data("RIFF".utf8)); writer.uint(UInt32(36 + pcm.count)); writer.bytes(Data("WAVEfmt ".utf8)); writer.uint(16)
        writer.bytes(Data([1, 0, 2, 0])); writer.uint(44_100); writer.uint(176_400); writer.bytes(Data([4, 0, 16, 0]))
        writer.bytes(Data("data".utf8)); writer.uint(UInt32(pcm.count)); writer.bytes(pcm)
        return writer.data
    }
}
