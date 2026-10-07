import Foundation
import SoulseekCore

extension AppModel {
    public func checkListeningPort() async {
        let port = settings.listeningPort
        let revision = loginRevision
        portCheck = "Checking local TCP listener on \(port)…"
        let socket: TCPConnection
        do { socket = try TCPConnection(host: "127.0.0.1", port: port) }
        catch { portCheck = "Invalid listening port. External reachability unverified."; return }
        let timeout = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { socket.cancel() } }
        defer { timeout.cancel(); socket.cancel() }
        let listening: Bool
        do { try await socket.start(); listening = true } catch { listening = false }
        guard revision == loginRevision, settings.listeningPort == port else { return }
        portCheck = listening
            ? "A local TCP listener accepted a connection on \(port). This is not an external port check and does not identify the listener. Router, firewall and internet reachability remain unverified."
            : "No local TCP connection succeeded on \(port). Connect Arpeggio first and check the listening port. External reachability remains unverified."
    }

    /// The TCP port the current session generation's listener actually bound, read from the session at sign-in.
    /// Nil when offline or superseded; never derived from the (possibly edited) configured port.
    public var activeListeningPort: UInt16? {
        guard !shuttingDown, connection == .connected, let bound = boundListener,
              bound.generation == activeSessionGeneration else { return nil }
        return bound.port
    }

    /// The last external result, shown only while it still describes the configured port on the current connection.
    public var currentExternalPortCheck: ExternalPortCheck? {
        guard let check = externalPortCheck, !shuttingDown, connection == .connected,
              check.generation == activeSessionGeneration, check.port == settings.listeningPort else { return nil }
        return check
    }

    public var canCheckExternalPort: Bool {
        !shuttingDown && connection == .connected && activeSessionGeneration != nil && currentExternalPortCheck?.isChecking != true
    }

    /// Runs only from an explicit, confirmed user action. Contacts the Soulseek port checker for the listener that the
    /// current session generation owns; results from superseded checks, ports or connections are discarded.
    public func checkExternalPort() async {
        guard !shuttingDown, connection == .connected, let generation = activeSessionGeneration else { return }
        let revision = loginRevision
        let configured = settings.listeningPort
        cancelExternalPortCheck()
        externalPortCheckRevision &+= 1; let token = externalPortCheckRevision
        let bound = await session.listeningPort(generation: generation)
        guard token == externalPortCheckRevision else { return }
        guard !shuttingDown, revision == loginRevision, activeSessionGeneration == generation, connection == .connected,
              settings.listeningPort == configured else { return }
        guard let port = bound, port == configured else {
            externalPortCheck = ExternalPortCheck(port: configured, generation: generation, outcome: .unavailable(.notListening), checkedAt: Date())
            return
        }
        externalPortCheck = ExternalPortCheck(port: port, generation: generation)
        let probe = externalPortProbe
        let task = Task<ExternalPortCheck.Outcome, Never> { await probe(port) }
        externalPortCheckTask = task
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard token == externalPortCheckRevision else { return }
        externalPortCheckTask = nil
        guard !shuttingDown, revision == loginRevision, activeSessionGeneration == generation, connection == .connected,
              settings.listeningPort == port else {
            externalPortCheck = nil; return
        }
        externalPortCheck = ExternalPortCheck(port: port, generation: generation, outcome: outcome, checkedAt: Date())
    }

    public func cancelExternalPortCheck() {
        externalPortCheckRevision &+= 1
        externalPortCheckTask?.cancel(); externalPortCheckTask = nil
        if externalPortCheck?.isChecking == true { externalPortCheck = nil }
    }
}
