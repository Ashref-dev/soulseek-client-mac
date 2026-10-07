import Foundation
import SoulseekCore

/// An allowlisted report, not a best-effort regex scrubber. Raw local diagnostic detail is deliberately omitted.
public enum DiagnosticReport {
    public struct Context: Sendable {
        let lines: [String]
        public init(bundle: Bundle = .main, connection: ConnectionState, mapping: PortMappingStatus,
                    external: ExternalPortCheck?, sharedFiles: Int, sharedBytes: UInt64) {
            let app = Self.safeVersion(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            let release = Self.safeVersion(bundle.object(forInfoDictionaryKey: "ArpeggioReleaseVersion") as? String ?? app)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let state: String
            switch connection { case .offline: state = "offline"; case .connecting: state = "connecting"; case .connected: state = "connected"; case .reconnecting: state = "reconnecting"; case .failed: state = "failed" }
            let mappingText: String
            switch mapping {
            case .idle: mappingText = "idle"
            case .disabled: mappingText = "disabled"
            case .mapping: mappingText = "mapping"
            case .unavailable: mappingText = "unavailable"
            case .mapped(let method, let port, _):
                let safeMethod = ["NAT-PMP", "UPnP"].contains(method) ? method : "unknown method"
                mappingText = "\(safeMethod), TCP port \(port) acknowledged"
            }
            var check = "not checked"
            if let external {
                switch external.outcome {
                case nil: check = "checking"
                case .open: check = "open"
                case .closed: check = "closed"
                case .unavailable: check = "unavailable"
                }
                check += ", TCP port \(external.port)"
                if let time = external.checkedAt { check += ", \(time.ISO8601Format())" }
            }
            lines = ["App version: \(app)", "Release version: \(release)",
                     "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "Architecture: \(Self.architecture)",
                     "Connection: \(state)", "Mapping: \(mappingText)", "External check: \(check)",
                     "Shared files: \(max(0, sharedFiles))", "Shared bytes: \(sharedBytes)"]
        }
        static func safeVersion(_ value: String?) -> String {
            guard let value, value.count <= 64,
                  value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta|rc)\.[0-9]+)?$"#, options: .regularExpression) != nil else { return "unknown" }
            return value
        }
        static var architecture: String {
            #if arch(arm64)
            "arm64"
            #elseif arch(x86_64)
            "x86_64"
            #else
            "unknown"
            #endif
        }
    }
    public static func render(entries: [DiagnosticEntry], listeningPort: UInt16, context: Context? = nil) -> String {
        let lines = entries.map { entry in
            "\(entry.timestamp.ISO8601Format()) [\(entry.severity.rawValue)] \(entry.category.rawValue) \(entry.operation.rawValue)"
        }
        return (["Arpeggio support report", "Listening TCP port: \(listeningPort)",
                 "Raw details and identifiers omitted for privacy."] + (context?.lines ?? []) + lines).joined(separator: "\n")
    }
}
