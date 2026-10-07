import Foundation

/// SemVer precedence, without integer overflow or lexicographic numeric identifiers.
public struct UpdateVersion: Sendable, Equatable, Comparable {
    private let core: [String]
    private let prerelease: [String]

    public init?(_ text: String, legacy: Bool = false) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let build = value.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func identifiers(_ text: Substring) -> [String]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
            return parts
        }
        if build.count == 2, identifiers(build[1]) == nil { return nil }
        let pieces = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        var numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if legacy && (1...2).contains(numbers.count) { numbers += Array(repeating: "0", count: 3 - numbers.count) }
        guard numbers.count == 3, numbers.allSatisfy(Self.numeric), numbers.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
        var pre: [String] = []
        if pieces.count == 2 {
            guard let parsed = identifiers(pieces[1]), parsed.allSatisfy({ !Self.numeric($0) || $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
            pre = parsed
        }
        core = numbers; prerelease = pre
    }

    private static func numeric(_ text: String) -> Bool { !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) } }
    private static func numericLess(_ a: String, _ b: String) -> Bool { a.count == b.count ? a < b : a.count < b.count }
    public static func < (a: Self, b: Self) -> Bool {
        for (x, y) in zip(a.core, b.core) where x != y { return numericLess(x, y) }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            let xn = numeric(x), yn = numeric(y)
            if xn != yn { return xn }
            return xn ? numericLess(x, y) : x < y
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public enum UpdateCompatibility {
    public static func releaseVersion(_ bundle: Bundle) -> String {
        bundle.infoDictionary?["ArpeggioReleaseVersion"] as? String ?? bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func validate(_ candidate: URL, replacing current: URL, expectedVersion: String? = nil,
                         operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        #if !arch(arm64)
        throw UpdateError.incompatible
        #else
        guard let new = Bundle(url: candidate), let old = Bundle(url: current),
              let identifier = old.bundleIdentifier, new.bundleIdentifier == identifier else { throw UpdateError.wrongApp }
        let version = releaseVersion(new)
        guard let parsed = UpdateVersion(version), let installed = UpdateVersion(releaseVersion(old), legacy: true), parsed > installed,
              expectedVersion == nil || version == expectedVersion else { throw UpdateError.notNewer }
        guard let minimum = new.infoDictionary?["LSMinimumSystemVersion"] as? String else { throw UpdateError.incompatible }
        let parts = minimum.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }),
              let major = parts[0], major >= 27 else { throw UpdateError.incompatible }
        let required = parts.map { $0 ?? 0 } + [0, 0]
        let host = [operatingSystem.majorVersion, operatingSystem.minorVersion, operatingSystem.patchVersion]
        guard !host.lexicographicallyPrecedes(Array(required.prefix(3))),
              new.executableArchitectures == [NSNumber(value: Int32(0x0100000c))] else { throw UpdateError.incompatible }
        #endif
    }
}
