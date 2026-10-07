import Network
import Foundation

@MainActor public protocol NetworkMonitoring: AnyObject {
    func start(_ changed: @escaping @MainActor @Sendable (Bool) -> Void)
    func stop()
}

@MainActor public final class NetworkMonitor: NetworkMonitoring {
    private var monitor: NWPathMonitor?
    private var revision: UInt64 = 0
    public init() {}
    public func start(_ changed: @escaping @MainActor @Sendable (Bool) -> Void) {
        stop(); let monitor = NWPathMonitor(); self.monitor = monitor
        let token = revision
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.revision == token, self.monitor != nil else { return }
                changed(available)
            }
        }
        monitor.start(queue: DispatchQueue(label: "tn.ashref.arpeggio.network-path"))
    }
    public func stop() { revision &+= 1; monitor?.pathUpdateHandler = nil; monitor?.cancel(); monitor = nil }
}
