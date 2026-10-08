import Observation
import TransferEngine

/// Track rows observe their own user/path, including absent downloads, not the whole snapshot.
@MainActor final class DownloadStateIndex: Observable {
    private let registrar = ObservationRegistrar()
    private var values: [String: Transfer] = [:]

    subscript(key: String) -> Transfer? {
        registrar.access(self, keyPath: \.[key])
        return values[key]
    }

    func replace(with snapshot: [String: Transfer]) {
        for key in Set(values.keys).union(snapshot.keys) where values[key] != snapshot[key] {
            registrar.withMutation(of: self, keyPath: \.[key]) {
                values[key] = snapshot[key]
            }
        }
    }
}
