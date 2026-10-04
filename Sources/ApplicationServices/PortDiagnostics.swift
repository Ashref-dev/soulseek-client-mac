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
}
