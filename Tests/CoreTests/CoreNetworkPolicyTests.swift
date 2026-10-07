import Foundation
import Testing
@testable import ArpeggioServices
import SoulseekCore
import Network

struct DiagnosticsTests {
    @Test @MainActor func actualModelReportIncludesUsefulSafeContextWithoutPrivateValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        model.settings.username = "private-account"
        model.settings.server = "192.0.2.123"
        model.settings.downloadDirectory = "/Users/private-account/private-files"
        model.settings.listeningPort = 61147
        model.connection = .failed("private-password 2001:db8::123 private-peer")
        model.portMapping = .mapped(method: "NAT-PMP", port: 61147, externalAddress: "192.0.2.123")
        model.externalPortCheck = ExternalPortCheck(port: 61147, generation: 0, outcome: .closed, checkedAt: Date(timeIntervalSince1970: 1000))
        model.sharedCount = 17; model.sharedBytes = 12345
        model.log("storage error: Could not restore application records. private-password")
        model.log("Peer request failed: private-peer /Users/private-account")
        let report = model.redactedCopyReport()
        for value in ["App version:", "Release version:", "macOS:", "Architecture:", "Connection: failed", "Mapping: NAT-PMP", "External check: closed", "Shared files: 17", "Shared bytes: 12345", "storage", "peerRequest"] { #expect(report.contains(value)) }
        for secret in ["private-account", "private-password", "private-peer", "/Users/", "192.0.2.123", "2001:db8::123"] { #expect(!report.contains(secret)) }
        let storage = try #require(model.diagnosticStore.problems.first)
        #expect(storage.category == .storage); #expect(storage.severity == .error)
        model.portMapping = .unavailable("private-account 192.0.2.123")
        #expect(model.redactedCopyReport().contains("Mapping: unavailable"))
        #expect(model.redactedCopyReport() != report)
        await model.shutdown()
    }
    @Test func activityCannotEvictProblemsAndReportNeverExportsRawText() {
        var store = DiagnosticStore()
        store.append(DiagnosticEntry(severity: .error, category: .server, message: "secret-account secret-password /Users/private 192.0.2.1 2001:db8::1"))
        for _ in 0..<600 { store.append(.classify("Peer messaging ended: The connection closed.")) }
        #expect(store.problems.count == 1)
        #expect(store.entries.count <= 300)
        for _ in 0..<50 { store.append(.classify("Connection detail: secret-account")) }
        #expect(store.problems.count == 51)
        let report = DiagnosticReport.render(entries: store.entries, listeningPort: 61147)
        for secret in ["secret-account", "secret-password", "/Users/private", "192.0.2.1", "2001:db8::1"] { #expect(!report.contains(secret)) }
        #expect(report.contains("61147"))
        #expect(DiagnosticEntry.classify("Peer request failed: invalid response").severity == .warning)
        #expect(DiagnosticEntry.classify("Peer messaging ended: The connection closed.").severity == .info)
    }
}

struct ReconnectScheduleTests {
    @Test @MainActor func actualModelFailureBackoffAndSuccessReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let gate = RaceGate()
        let now = Date(timeIntervalSince1970: 1000)
        model.reconnectClock = ReconnectClock(now: { now }, sleep: { _ in await gate.wait(); try Task.checkCancellation() })
        model.intentionallyOffline = false; model.reconnectAllowed = true
        for (index, delay) in [5, 15, 30, 60, 120, 120].enumerated() {
            await model.handle(.state(.failed("fixture")), account: "fixture", generation: 0)
            try await raceWait { await gate.arrivals == index + 1 }
            #expect(model.reconnectSchedule.remaining(at: now) == delay)
            model.cancelReconnect(reset: false)
            await gate.release()
        }
        await model.handle(.state(.connected), account: "fixture", generation: 0)
        #expect(model.reconnectSchedule.attempt == 0)
        await model.handle(.state(.failed("fixture")), account: "fixture", generation: 0)
        try await raceWait { await gate.arrivals == 7 }
        #expect(model.reconnectSchedule.remaining(at: now) == 5)
        model.cancelReconnect(reset: true)
        await gate.release()
        await model.shutdown()
    }

    @Test @MainActor func newerManualLoginStopsPendingAutomaticCredentialLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let gate = RaceGate()
        model.settings.server = "127.0.0.1"; model.settings.username = "fixture"
        model.intentionallyOffline = false; model.reconnectAllowed = true; model.connection = .failed("fixture")
        model.credentialLookup = { _ in await gate.wait(); return "fixture-password" }
        let retry = Task { await model.retryNow() }
        try await raceWait { await gate.arrivals == 1 }
        await model.login(password: "", remember: false)
        let manualGeneration = await model.session.currentGeneration()
        #expect(!model.reconnectAllowed)
        await gate.release(); await retry.value
        #expect(await model.session.currentGeneration() == manualGeneration)
        #expect(model.connection != .reconnecting)
        await model.shutdown()
    }

    @Test @MainActor func intentionalDisconnectStopsAndUnregistersMonitor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let monitor = FakeNetworkMonitor(); model.networkMonitorFactory = { monitor }
        model.startNetworkMonitoring()
        #expect(!monitor.stopped)
        await model.disconnect()
        #expect(monitor.stopped)
        #expect(model.networkMonitor == nil)
        await model.shutdown()
    }
    @Test @MainActor func cancellingRetryCallerDuringCredentialLookupCannotConnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let gate = RaceGate()
        model.settings.username = "fixture"; model.settings.server = "127.0.0.1"
        model.settings.port = try unusedPort(); model.settings.listeningPort = try unusedPort()
        model.intentionallyOffline = false; model.reconnectAllowed = true; model.connection = .failed("fixture")
        model.credentialLookup = { _ in await gate.wait(); return "fixture-password" }
        let retry = Task { await model.retryNow() }
        try await raceWait { await gate.arrivals == 1 }
        retry.cancel(); await gate.release(); await retry.value
        #expect(await model.session.currentGeneration() == 0)
        #expect(model.connection == .failed("fixture"))
        #expect(model.reconnectTask == nil)
        await model.shutdown()
    }
    @Test @MainActor func retryNowAndNetworkReturnCancelWaitWithoutDuplicateLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let gate = RaceGate(); let probe = RetryProbe()
        model.settings.username = "synthetic"
        model.credentialLookup = { _ in await probe.read() }
        model.reconnectClock = ReconnectClock(now: { Date(timeIntervalSince1970: 1000) }, sleep: { _ in await gate.wait(); try Task.checkCancellation() })
        model.intentionallyOffline = false; model.reconnectAllowed = true
        let monitor = FakeNetworkMonitor()
        model.networkMonitorFactory = { monitor }
        model.startNetworkMonitoring()
        await model.handle(.state(.failed("synthetic failure")), account: "synthetic", generation: 0)
        try await raceWait { await gate.arrivals == 1 }
        #expect(model.reconnectSchedule.remaining(at: Date(timeIntervalSince1970: 1000)) == 5)
        monitor.emit(false); monitor.emit(true)
        try await raceWait { await probe.count == 1 }
        await gate.release()
        #expect(await probe.count == 1)
        #expect(model.reconnectSchedule.deadline == nil)
        model.intentionallyOffline = true
        await model.retryNow()
        #expect(await probe.count == 1)
        await model.shutdown()
        #expect(monitor.stopped)
        monitor.emit(false); monitor.emit(true)
        #expect(await probe.count == 1)
    }

    @Test @MainActor func supersededCredentialLookupCannotReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(dataDirectory: root)
        let gate = RaceGate()
        model.intentionallyOffline = false; model.reconnectAllowed = true; model.connection = .failed("fixture")
        model.credentialLookup = { _ in await gate.wait(); return "fixture-password" }
        let retry = Task { await model.retryNow() }
        try await raceWait { await gate.arrivals == 1 }
        model.loginRevision &+= 1
        await gate.release(); await retry.value
        #expect(model.connection == .failed("fixture"))
        #expect(await model.session.currentGeneration() == 0)
        await model.shutdown()
    }
    @Test func backoffDeadlineResetAndDisableAreDeterministic() {
        var schedule = ReconnectSchedule()
        let now = Date(timeIntervalSince1970: 1000)
        for delay in [5, 15, 30, 60, 120, 120] {
            #expect(schedule.schedule(at: now) == Double(delay))
            #expect(schedule.remaining(at: now) == delay)
            #expect(schedule.remaining(at: now.addingTimeInterval(1)) == delay - 1)
        }
        schedule.cancel(reset: false)
        #expect(schedule.deadline == nil)
        schedule.cancel(reset: true)
        #expect(schedule.attempt == 0)
        #expect(schedule.schedule(at: now) == 5)
    }
}

private actor RetryProbe {
    private(set) var count = 0
    func read() -> String { count += 1; return "" }
}
@MainActor private final class FakeNetworkMonitor: NetworkMonitoring {
    var callback: (@MainActor @Sendable (Bool) -> Void)?
    var stopped = false
    func start(_ changed: @escaping @MainActor @Sendable (Bool) -> Void) { callback = changed; stopped = false }
    func stop() { callback = nil; stopped = true }
    func emit(_ available: Bool) { callback?(available) }
}

struct SettingsNavigationTests {
    @Test func occupiedListeningPortExplainsConflictWithoutSwitching() async throws {
        let occupied = try NWListener(using: .tcp, on: .any)
        occupied.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            occupied.stateUpdateHandler = { state in
                switch state {
                case .ready: occupied.stateUpdateHandler = nil; ready.resume()
                case .failed(let error): occupied.stateUpdateHandler = nil; ready.resume(throwing: error)
                default: break
                }
            }
            occupied.start(queue: DispatchQueue(label: "fixture.occupied-port"))
        }
        defer { occupied.cancel() }
        let port = try #require(occupied.port?.rawValue)
        let session = SoulseekSession()
        do {
            try await session.connect(host: "127.0.0.1", port: port, user: "fixture", password: "fixture", listeningPort: port)
            Issue.record("Occupied listener must fail before server login")
        } catch {
            #expect(error is ListeningPortError)
            #expect(error.localizedDescription.contains("one app"))
            #expect(error.localizedDescription.contains("\(port)"))
            #expect(error.localizedDescription.contains("Network"))
        }
        await session.shutdown()
    }
    @Test func portAndRecoveryRoutesAreTyped() {
        #expect(SettingsTab.allCases.map(\.rawValue) == ["general", "account", "profile", "transfers", "sharing", "network", "statistics", "advanced"])
        #expect(SettingsDestination.port.tab == .network)
        #expect(SettingsDestination.recovery.tab == .advanced)
        #expect(SettingsDestination.account.tab == .account)
        let copy = PortGuidance.instructions(port: 61147).joined(separator: " ")
        for phrase in ["61147", "TCP", "Virtual Server", "Port Forwarding", "LAN", "Qt", "one app", "obfuscated"] { #expect(copy.contains(phrase)) }
        #expect(ListeningPortError.inUse(61147).localizedDescription.contains("one app"))
    }
}
