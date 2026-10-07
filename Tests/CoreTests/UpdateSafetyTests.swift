import Foundation
import Security
import Testing
@testable import ArpeggioServices

@Suite struct UpdaterVersionTests {
    @Test func semverPrecedenceAndMalformedInput() {
        let sequence = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0-rc.2", "1.0.0"]
        for (old, new) in zip(sequence, sequence.dropFirst()) { #expect(Updater.isNewer(new, than: old)); #expect(!Updater.isNewer(old, than: new)) }
        for bad in ["1.0.0-", "01.0.0", "1.0.x", "1.0.0-rc.01", "1.0.0+", "1.0.0++foo", "vV1.0.0"] { #expect(UpdateVersion(bad) == nil) }
        #expect(!Updater.isNewer("1.0.0+two", than: "1.0.0+one"))
        #expect(Updater.isNewer("999999999999999999999999.0.0", than: "2.0.0"))
    }
}

private func updateFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

@Suite struct UpdateCompatibilityTests {
    @Test func signedCustomVersionIsAuthoritative() throws {
        let root = try updateFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "tn.ashref.arpeggio", "CFBundleShortVersionString": "0.6.0", "ArpeggioReleaseVersion": "0.6.0-rc.1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))
        #expect(UpdateCompatibility.releaseVersion(bundle) == "0.6.0-rc.1")
        #expect(Updater.isNewer("0.6.0", than: UpdateCompatibility.releaseVersion(bundle)))
    }
    @Test func wrongBundleAndIncompatibleBundleLeaveOldUnchanged() throws {
        let root = try updateFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, identifier: String, minimum: String, cpu: UInt32 = 0x0100000c) throws -> URL {
            let app = root.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture", "CFBundleShortVersionString": name == "Old" ? "0.5.5" : "0.6.0", "LSMinimumSystemVersion": minimum]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            var header = Data()
            for word: UInt32 in [0xfeedfacf, cpu, 0, 2, 0, 0, 0, 0] {
                for shift in 0..<4 { header.append(UInt8(truncatingIfNeeded: word >> (shift * 8))) }
            }
            try header.write(to: app.appendingPathComponent("Contents/MacOS/fixture"))
            return app
        }
        let old = try bundle("Old", identifier: "tn.ashref.arpeggio", minimum: "27.0")
        let before = try FileManager.default.attributesOfItem(atPath: old.path)
        let high = try bundle("High", identifier: "tn.ashref.arpeggio", minimum: "99.0")
        let wrong = try bundle("Wrong", identifier: "other.app", minimum: "27.0")
        let intel = try bundle("Intel", identifier: "tn.ashref.arpeggio", minimum: "27.0", cpu: 0x01000007)
        let valid = try bundle("Valid", identifier: "tn.ashref.arpeggio", minimum: "27.0")
        #expect(throws: UpdateError.self) { try UpdateCompatibility.validate(high, replacing: old) }
        #expect(throws: UpdateError.self) { try UpdateCompatibility.validate(wrong, replacing: old) }
        #expect(throws: UpdateError.self) { try UpdateCompatibility.validate(intel, replacing: old) }
        try UpdateCompatibility.validate(valid, replacing: old, operatingSystem: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        let after = try FileManager.default.attributesOfItem(atPath: old.path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }
}

private func zipFixture(_ entries: [(String, UInt32, UInt32)]) -> Data {
    var local = Data(), central = Data()
    func append(_ value: UInt64, bytes: Int, to data: inout Data) { for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
    for (name, size, mode) in entries {
        let offset = local.count, encoded = Data(name.utf8)
        append(0x04034b50, bytes: 4, to: &local)
        for value: UInt64 in [20, 0, 0, 0, 0] { append(value, bytes: 2, to: &local) }
        for value: UInt64 in [0, 0, UInt64(size)] { append(value, bytes: 4, to: &local) }
        append(UInt64(encoded.count), bytes: 2, to: &local); append(0, bytes: 2, to: &local); local.append(encoded)
        append(0x02014b50, bytes: 4, to: &central)
        for value: UInt64 in [0x0314, 20, 0, 0, 0, 0] { append(value, bytes: 2, to: &central) }
        for value: UInt64 in [0, 0, UInt64(size)] { append(value, bytes: 4, to: &central) }
        for value in [encoded.count, 0, 0, 0, 0] { append(UInt64(value), bytes: 2, to: &central) }
        append(UInt64(mode) << 16, bytes: 4, to: &central); append(UInt64(offset), bytes: 4, to: &central); central.append(encoded)
    }
    let offset = local.count; local.append(central)
    append(0x06054b50, bytes: 4, to: &local)
    for value in [0, 0, entries.count, entries.count] { append(UInt64(value), bytes: 2, to: &local) }
    append(UInt64(central.count), bytes: 4, to: &local); append(UInt64(offset), bytes: 4, to: &local); append(0, bytes: 2, to: &local)
    return local
}

@Suite struct UpdateArchiveTests {
    @Test func rejectsTraversalSymlinksMultipleRootsAndBombs() throws {
        #expect(try UpdateArchive.validate(zipFixture([("Safe.app/Contents/file", 0, 0x8000)])) == "Safe.app")
        for entries: [(String, UInt32, UInt32)] in [[("../escape", 0, 0)], [("/Safe.app/a", 0, 0)], [("Safe.app/../escape", 0, 0)], [("Safe.app/link", 0, 0xa000)], [("A.app/a", 0, 0), ("B.app/b", 0, 0)], [("A.app/bomb", UInt32(UpdateArchive.expandedLimit + 1), 0)], [("A.app/a", 0, 0), ("A.app/A", 0, 0)]] {
            #expect(throws: UpdateError.self) { try UpdateArchive.validate(zipFixture(entries)) }
        }
        #expect(throws: UpdateError.self) { try UpdateArchive.validate(zipFixture(Array(repeating: ("A.app/file", 0, 0), count: 5_001))) }
        var mismatch = zipFixture([("Safe.app/file", 0, 0)])
        mismatch[30] = 88
        #expect(throws: UpdateError.self) { try UpdateArchive.validate(mismatch) }
    }
    @Test func processTimeoutIsBounded() async throws {
        await #expect(throws: UpdateError.self) { try await UpdateProcess.run("/bin/sleep", arguments: ["5"], timeout: 0.1) }
    }
    @Test func actualDittoArchiveIsAcceptedBeforeExtraction() async throws {
        let root = try updateFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Safe.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: app.appendingPathComponent("file"))
        let archive = root.appendingPathComponent("test.zip")
        try await UpdateProcess.run("/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--keepParent", app.deletingLastPathComponent().path, archive.path])
        #expect(try UpdateArchive.validate(archive) == "Safe.app")
        let actual = try Data(contentsOf: archive)
        let descriptor = try #require(actual.range(of: Data([0x50, 0x4b, 0x07, 0x08])))
        var mismatch = actual
        mismatch[descriptor.lowerBound + 8] ^= 1
        #expect(throws: UpdateError.self) { try UpdateArchive.validate(mismatch) }
        var dishonestSize = actual
        let central = try #require(actual.range(of: Data([0x50, 0x4b, 0x01, 0x02]), options: .backwards))
        dishonestSize[descriptor.lowerBound + 12] = 6
        dishonestSize[central.lowerBound + 24] = 6
        #expect(throws: UpdateError.self) { try UpdateArchive.validate(dishonestSize) }
    }
    @Test func compressedCapRejectsSparseOversizedArchiveBeforeReading() throws {
        let root = try updateFixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("oversize.zip")
        #expect(FileManager.default.createFile(atPath: archive.path, contents: nil))
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: UInt64(UpdateArchive.compressedLimit + 1)); try handle.close()
        #expect(throws: UpdateError.self) { try UpdateArchive.validate(archive) }
    }
}

@Suite struct UpdateTrustTests {
    @Test func requirementParsesAndDevelopmentArtifactCannotSatisfyDeveloperID() throws {
        _ = try UpdateTrust.developerIDRequirement(identifier: "tn.ashref.arpeggio", trustedTeam: "TRUSTEDTEAM")
        #expect(throws: UpdateError.self) { try UpdateTrust.developerIDRequirement(identifier: "x\" or true", trustedTeam: "TEAM") }
        let app = URL(fileURLWithPath: "/Applications/Soulseek-Arpeggio.app")
        if FileManager.default.fileExists(atPath: app.path) {
            let metadata = try UpdateTrust.metadata(UpdateTrust.code(app))
            let team = try #require(metadata[kSecCodeInfoTeamIdentifier as String] as? String)
            let requirement = try UpdateTrust.developerIDRequirement(identifier: "tn.ashref.arpeggio", trustedTeam: team)
            #expect(SecStaticCodeCheckValidity(try UpdateTrust.code(app), UpdateTrust.flags, requirement) != errSecSuccess)
            #expect(!(try UpdateTrust.verify(app, replacing: app)).isEmpty)
        }
    }
    @Test func receiptRejectsUnboundOrNonPrivatePaths() throws {
        #expect(throws: UpdateError.self) { try UpdateLaunchReceipt.acknowledgeIfRequested(arguments: ["fixture", "--arpeggio-update-receipt", "/tmp", UUID().uuidString]) }
        #expect(throws: UpdateError.self) { try UpdateLaunchReceipt.acknowledgeIfRequested(arguments: ["fixture", "--arpeggio-update-receipt"]) }
        try UpdateLaunchReceipt.acknowledgeIfRequested(arguments: ["fixture"])
    }
    @Test func realInstalledSignatureAcknowledgesOnlyBoundNonce() throws {
        let installed = URL(fileURLWithPath: "/Applications/Soulseek-Arpeggio.app")
        guard FileManager.default.fileExists(atPath: installed.path) else { return }
        let bundle = try #require(Bundle(url: installed))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(".arpeggio-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let nonce = UUID().uuidString
        let request = UpdateLaunchReceipt.Request(nonce: nonce, installedPath: installed.path,
                                                  version: UpdateCompatibility.releaseVersion(bundle), requirement: try UpdateTrust.verify(installed, replacing: installed))
        let file = root.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: UpdateError.self) { try UpdateLaunchReceipt.acknowledgeIfRequested(arguments: ["fixture", "--arpeggio-update-receipt", root.path, UUID().uuidString], bundle: bundle) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("receipt").path))
        try UpdateLaunchReceipt.acknowledgeIfRequested(arguments: ["fixture", "--arpeggio-update-receipt", root.path, nonce], bundle: bundle)
        #expect(try String(contentsOf: root.appendingPathComponent("receipt"), encoding: .utf8) == nonce)
        #expect(throws: UpdateError.self) { try UpdateLaunchReceipt.acknowledgeIfRequested(arguments: ["fixture", "--arpeggio-update-receipt", root.path, nonce], bundle: bundle) }
    }
}
