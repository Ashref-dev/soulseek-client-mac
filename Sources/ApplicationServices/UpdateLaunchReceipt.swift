import Foundation
import Security

public enum UpdateLaunchReceipt {
    struct Request: Codable {
        let nonce: String
        let installedPath: String
        let version: String
        let requirement: String
    }

    public static func acknowledgeIfRequested(arguments: [String] = CommandLine.arguments, bundle: Bundle = .main) throws {
        guard let index = arguments.firstIndex(of: "--arpeggio-update-receipt") else { return }
        guard arguments.count == index + 3 else { throw UpdateError.invalidReceipt }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let nonce = arguments[index + 2]
        guard UUID(uuidString: nonce)?.uuidString == nonce,
              root.lastPathComponent.hasPrefix(".arpeggio-update-"), root.path == root.resolvingSymlinksInPath().path else { throw UpdateError.invalidReceipt }
        try requirePrivate(root, directory: true)
        let requestURL = root.appendingPathComponent("request.json")
        try requirePrivate(requestURL, directory: false)
        guard (try requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_384 else { throw UpdateError.invalidReceipt }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        guard nonce == request.nonce, bundle.bundleURL.resolvingSymlinksInPath().path == request.installedPath,
              UpdateCompatibility.releaseVersion(bundle) == request.version else { throw UpdateError.invalidReceipt }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(request.requirement as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(try UpdateTrust.code(bundle.bundleURL), UpdateTrust.flags, requirement) == errSecSuccess else { throw UpdateError.untrusted }
        let receipt = root.appendingPathComponent("receipt")
        guard !FileManager.default.fileExists(atPath: receipt.path) else { throw UpdateError.invalidReceipt }
        try Data(nonce.utf8).write(to: receipt, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }

    static func requirePrivate(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw UpdateError.invalidReceipt }
    }

    public static func archivalNoticeIfRequested(arguments: [String] = CommandLine.arguments) async throws -> String? {
        guard let index = arguments.firstIndex(of: "--arpeggio-update-receipt") else { return nil }
        guard arguments.count == index + 3 else { throw UpdateError.invalidReceipt }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try requirePrivate(root, directory: true)
        let file = root.appendingPathComponent("result")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) {
                try requirePrivate(file, directory: false)
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 256 else { throw UpdateError.invalidReceipt }
                let result = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                switch result {
                case "confirmed-archived": return nil
                case "confirmed-local-backup": return "The update started successfully. Backup archival could not complete; the verified previous app is safely retained beside the installation in its private recovery folder."
                case "rolled-back", "rollback-copy-retained", "failed-before-swap", "rolled-back-launch-failed": return "The update could not finish. The previous app or its private recovery copy was retained."
                case "rollback-incomplete": return "Automatic update recovery could not finish. The verified previous app remains in the private recovery folder; the current copy must not be treated as restored."
                case "confirmed-archival-pending", "": break
                default: throw UpdateError.invalidReceipt
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return "The update started, but backup archival is still pending. The local recovery copy is retained."
    }
}
