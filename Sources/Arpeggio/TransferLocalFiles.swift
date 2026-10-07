import Foundation
import TransferEngine

/// Whether finished downloads are still on disk. Checked when rows change and again at the moment someone
/// plays, previews or opens a row, never on a timer.
enum TransferLocalFiles {
    enum Action: Equatable {
        case openLocal(URL)
        case missing
        case streamFromPeer
        case unavailable
    }

    static func missing(_ transfers: [Transfer], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<String> {
        Set(transfers.filter { !$0.upload && $0.status == .completed && !($0.destination.map(exists) ?? false) }.map(\.id))
    }

    static func action(for transfer: Transfer, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Action {
        if transfer.status == .completed {
            guard !transfer.upload else { return .unavailable }
            guard let path = transfer.destination, exists(path) else { return .missing }
            return .openLocal(URL(fileURLWithPath: path))
        }
        return transfer.upload ? .unavailable : .streamFromPeer
    }
}
