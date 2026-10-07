public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, account, profile, transfers, sharing, network, statistics, advanced
    public var id: String { rawValue }
}
public enum SettingsDestination: Sendable {
    case port, network, account, recovery
    public var tab: SettingsTab {
        switch self { case .port, .network: .network; case .account: .account; case .recovery: .advanced }
    }
}
