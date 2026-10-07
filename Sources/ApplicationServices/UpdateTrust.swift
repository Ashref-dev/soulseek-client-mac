import Foundation
import Security

public enum UpdateTrust {
    static let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    static func code(_ url: URL) throws -> SecStaticCode {
        var result: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &result) == errSecSuccess, let result else { throw UpdateError.untrusted }
        return result
    }

    /// This requirement never takes its team from the downloaded bundle.
    public static func developerIDRequirement(identifier: String, trustedTeam: String) throws -> SecRequirement {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !identifier.isEmpty, !trustedTeam.isEmpty,
              identifier.unicodeScalars.allSatisfy(safe.contains), trustedTeam.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { throw UpdateError.untrusted }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(trustedTeam)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw UpdateError.untrusted }
        return requirement
    }

    static func metadata(_ code: SecStaticCode) throws -> [String: Any] {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { throw UpdateError.untrusted }
        return info
    }

    /// Returns the exact accepted policy for the surviving helper's re-verification.
    static func verify(_ candidate: URL, replacing current: URL) throws -> String {
        let old = try code(current), new = try code(candidate)
        guard SecStaticCodeCheckValidity(old, flags, nil) == errSecSuccess else { throw UpdateError.untrusted }
        var installedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(old, [], &installedRequirement) == errSecSuccess, let installedRequirement else { throw UpdateError.untrusted }
        let oldInfo = try metadata(old)
        guard let identifier = oldInfo[kSecCodeInfoIdentifier as String] as? String,
              let team = oldInfo[kSecCodeInfoTeamIdentifier as String] as? String else { throw UpdateError.untrusted }
        let developerID = try developerIDRequirement(identifier: identifier, trustedTeam: team)
        let wasDeveloperID = SecStaticCodeCheckValidity(old, flags, developerID) == errSecSuccess
        let accepted: SecRequirement
        if SecStaticCodeCheckValidity(new, flags, installedRequirement) == errSecSuccess {
            guard !wasDeveloperID || SecStaticCodeCheckValidity(new, flags, developerID) == errSecSuccess else { throw UpdateError.untrusted }
            accepted = installedRequirement
        } else {
            // Narrow bridge: pinned installed owner, Developer ID only. Never Apple Development.
            guard SecStaticCodeCheckValidity(new, flags, developerID) == errSecSuccess else { throw UpdateError.untrusted }
            accepted = developerID
        }
        var text: CFString?
        guard SecRequirementCopyString(accepted, [], &text) == errSecSuccess, let text else { throw UpdateError.untrusted }
        return text as String
    }
}
