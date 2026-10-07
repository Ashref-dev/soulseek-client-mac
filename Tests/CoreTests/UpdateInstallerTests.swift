import Foundation
import Testing
@testable import ArpeggioServices

@Suite struct UpdateInstallerTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(".arpeggio-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func app(_ root: URL, name: String, content: String, launcher: String) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Data(content.utf8).write(to: app.appendingPathComponent("identity"))
        let executable = app.appendingPathComponent("launch")
        try Data(("#!/bin/bash\n" + launcher + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return app
    }
    private func run(root: URL, current: URL, candidate: URL, previous: URL, launcherFailure: Bool = false, archiver: String = "/usr/bin/ditto") async throws -> String {
        let script = UpdateInstaller.helper(staging: root, candidate: candidate, current: current, executableRelative: "launch", nonce: "TEST-NONCE",
                                             requirement: "fixture", previous: previous, oldPID: 0, verifier: launcherFailure ? "/usr/bin/false" : "/usr/bin/true",
                                             receiptSeconds: 1, rollbackLauncher: "/usr/bin/true", archiver: archiver)
        let file = root.appendingPathComponent("helper.sh")
        try Data(script.utf8).write(to: file)
        do { try await UpdateProcess.run("/bin/bash", arguments: [file.path], timeout: 8) } catch is UpdateError { }
        return try String(contentsOf: root.appendingPathComponent("result"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(arguments: ["launch", "receipt", "swap", "verify"]) func faultRestoresOldWithoutTouchingData(_ fault: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: fault == "launch" ? "exit 1" : "/bin/sleep 2")
        let data = root.appendingPathComponent("user.sqlite")
        try Data("USER-DATA".utf8).write(to: data)
        if fault == "swap" { try FileManager.default.removeItem(at: candidate) }
        let outcome = try await run(root: root, current: current, candidate: candidate, previous: root.appendingPathComponent("archive"), launcherFailure: fault == "verify")
        #expect(outcome == (fault == "verify" ? "failed-before-swap" : "rolled-back"))
        #expect(try String(contentsOf: current.appendingPathComponent("identity"), encoding: .utf8) == "OLD")
        #expect(try Data(contentsOf: data) == Data("USER-DATA".utf8))
    }

    @Test func successArchivesOnlyAfterAcknowledgment() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: "printf '%s' \"$3\" > \"$2/receipt\"; /bin/sleep 1")
        let previous = root.appendingPathComponent("archive")
        #expect(try await run(root: root, current: current, candidate: candidate, previous: previous) == "confirmed-archived")
        #expect(try String(contentsOf: current.appendingPathComponent("identity"), encoding: .utf8) == "NEW")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("previous.app").path))
        let archived = previous.appendingPathComponent(root.lastPathComponent + ".app/identity")
        #expect(try String(contentsOf: archived, encoding: .utf8) == "OLD")
    }

    @Test func archivalFailureRetainsLocalVerifiedOldCopy() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: "printf '%s' \"$3\" > \"$2/receipt\"; /bin/sleep 1")
        let previous = root.appendingPathComponent("not-a-directory")
        try Data().write(to: previous)
        #expect(try await run(root: root, current: current, candidate: candidate, previous: previous) == "confirmed-local-backup")
        #expect(try String(contentsOf: root.appendingPathComponent("previous.app/identity"), encoding: .utf8) == "OLD")
    }

    @Test func survivingHelperAcknowledgesBeforeWaitingForOldPID() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: "exit 1")
        let script = UpdateInstaller.helper(staging: root, candidate: candidate, current: current, executableRelative: "launch", nonce: "N", requirement: "fixture",
                                             previous: root.appendingPathComponent("archive"), oldPID: ProcessInfo.processInfo.processIdentifier,
                                             verifier: "/usr/bin/true", rollbackLauncher: "/usr/bin/true")
        let file = root.appendingPathComponent("helper.sh"); try Data(script.utf8).write(to: file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [file.path]
        try process.run(); defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(process.isRunning)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        #expect(try String(contentsOf: current.appendingPathComponent("identity"), encoding: .utf8) == "OLD")
        process.terminate()
        process.waitUntilExit()
    }

    @Test func helperStartFailureNeverModifiesInstalledCopy() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = root.appendingPathComponent("Candidate.app")
        try FileManager.default.createDirectory(at: candidate.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "fixture", "CFBundleExecutable": "launch", "CFBundleShortVersionString": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: candidate.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: candidate.appendingPathComponent("Contents/MacOS/launch"))
        await #expect(throws: UpdateError.self) {
            try await UpdateInstaller.prepare(staging: root, candidate: candidate, current: current, requirement: "fixture", helperExecutable: "/nonexistent-arpeggio-helper")
        }
        #expect(try String(contentsOf: current.appendingPathComponent("identity"), encoding: .utf8) == "OLD")
    }

    @Test func injectedCrossVolumeCopyFailureRetainsLocalOld() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: "printf '%s' \"$3\" > \"$2/receipt\"; /bin/sleep 1")
        #expect(try await run(root: root, current: current, candidate: candidate, previous: root.appendingPathComponent("archive"), archiver: "/usr/bin/false") == "confirmed-local-backup")
        #expect(try String(contentsOf: root.appendingPathComponent("previous.app/identity"), encoding: .utf8) == "OLD")
    }

    @Test func actualCodesignRequirementAllowsHelperReadinessWithoutLaunchingApp() async throws {
        let installed = URL(fileURLWithPath: "/Applications/Soulseek-Arpeggio.app")
        guard FileManager.default.fileExists(atPath: installed.path) else { return }
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current.app"), candidate = root.appendingPathComponent("Candidate.app")
        try FileManager.default.copyItem(at: installed, to: current)
        try FileManager.default.copyItem(at: installed, to: candidate)
        let script = UpdateInstaller.helper(staging: root, candidate: candidate, current: current, executableRelative: "Contents/MacOS/Arpeggio", nonce: "N",
                                             requirement: try UpdateTrust.verify(candidate, replacing: current), previous: root.appendingPathComponent("archive"),
                                             oldPID: ProcessInfo.processInfo.processIdentifier, rollbackLauncher: "/usr/bin/true")
        let file = root.appendingPathComponent("helper.sh"); try Data(script.utf8).write(to: file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [file.path]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(process.isRunning)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("previous.app").path))
    }

    @Test func rejectedMoveFailureNeverClaimsRollbackOrLaunchesRejectedCopy() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: "exit 1")
        let mover = root.appendingPathComponent("mover"), launcher = root.appendingPathComponent("rollback-launcher")
        try Data("#!/bin/bash\ncase \"$2\" in */rejected.app) printf 'INJECTED_REJECTED_MOVE_FAILURE\\n' >&2; exit 1;; esac\nexec /bin/mv \"$@\"\n".utf8).write(to: mover)
        try Data(("#!/bin/bash\ntouch " + UpdateInstaller.quote(root.appendingPathComponent("unexpected-launch").path) + "\n").utf8).write(to: launcher)
        for executable in [mover, launcher] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path) }
        let script = UpdateInstaller.helper(staging: root, candidate: candidate, current: current, executableRelative: "launch", nonce: "N", requirement: "fixture",
                                             previous: root.appendingPathComponent("archive"), oldPID: 0, verifier: "/usr/bin/true", rollbackLauncher: launcher.path, mover: mover.path)
        let file = root.appendingPathComponent("helper.sh"); try Data(script.utf8).write(to: file)
        do { try await UpdateProcess.run("/bin/bash", arguments: [file.path], timeout: 5) } catch is UpdateError { }
        #expect(try String(contentsOf: root.appendingPathComponent("result"), encoding: .utf8).contains("rollback-incomplete"))
        #expect(try String(contentsOf: root.appendingPathComponent("previous.app/identity"), encoding: .utf8) == "OLD")
        #expect(try String(contentsOf: current.appendingPathComponent("identity"), encoding: .utf8) == "NEW")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-launch").path))
        #expect(try String(contentsOf: root.appendingPathComponent("helper.log"), encoding: .utf8).contains("INJECTED_REJECTED_MOVE_FAILURE"))
    }

    @Test func verifierStderrIsRetainedInPrivateBoundedHelperLog() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try app(root, name: "Current.app", content: "OLD", launcher: "exit 0")
        let candidate = try app(root, name: "Candidate.app", content: "NEW", launcher: "exit 1")
        let verifier = root.appendingPathComponent("verifier")
        try Data("#!/bin/bash\nprintf 'DISTINCTIVE_SIGNATURE_FAILURE\\n' >&2\nexit 1\n".utf8).write(to: verifier)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: verifier.path)
        let script = UpdateInstaller.helper(staging: root, candidate: candidate, current: current, executableRelative: "launch", nonce: "N", requirement: "fixture",
                                             previous: root.appendingPathComponent("archive"), oldPID: 0, verifier: verifier.path, rollbackLauncher: "/usr/bin/true")
        let file = root.appendingPathComponent("helper.sh"); try Data(script.utf8).write(to: file)
        do { try await UpdateProcess.run("/bin/bash", arguments: [file.path], timeout: 5) } catch is UpdateError { }
        let log = root.appendingPathComponent("helper.log")
        #expect(FileManager.default.fileExists(atPath: log.path))
        if FileManager.default.fileExists(atPath: log.path) {
            #expect(try String(contentsOf: log, encoding: .utf8).contains("DISTINCTIVE_SIGNATURE_FAILURE"))
            try UpdateLaunchReceipt.requirePrivate(log, directory: false)
            #expect((try log.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 131_072)
        }
        #expect(try String(contentsOf: current.appendingPathComponent("identity"), encoding: .utf8) == "OLD")
    }
}
