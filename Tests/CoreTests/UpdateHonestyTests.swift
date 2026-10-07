import AppKit
import Foundation
import Testing
@testable import ArpeggioServices
@testable import Arpeggio

/// Version and update wording shown to people must match what has actually happened.
@Suite struct UpdateHonestyTests {
    private func bundle(_ info: [String: String]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arpeggio-about-\(UUID().uuidString).app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "tn.ashref.arpeggio.fixture.\(UUID().uuidString)"
        plist["CFBundlePackageType"] = "APPL"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return (try #require(Bundle(url: root)), root)
    }

    @Test func readyStateSaysRestartingToInstallNotInstalled() {
        let text = UpdateCopy.ready(version: "0.6.0-rc.2")
        #expect(text.contains("0.6.0-rc.2"))
        #expect(text.contains("Restarting to install"))
        #expect(!text.localizedCaseInsensitiveContains("installed"))
        #expect(!text.contains("\u{2014}")); #expect(!text.contains("\u{2013}"))
    }

    @Test func aboutPanelShowsTheReleaseVersionNotOnlyTheNumericBundleVersion() throws {
        let (preview, previewURL) = try bundle(["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "11",
                                                "ArpeggioReleaseVersion": "0.6.0-rc.1"])
        defer { try? FileManager.default.removeItem(at: previewURL) }
        let options = AboutPanel.options(bundle: preview)
        #expect(options[.applicationVersion] as? String == "0.6.0-rc.1")
        #expect(options[.applicationName] as? String == "Soulseek-Arpeggio")
        #expect((options[.credits] as? NSAttributedString)?.string.contains("Not affiliated with Soulseek") == true)
        let (legacy, legacyURL) = try bundle(["CFBundleShortVersionString": "0.5.5", "CFBundleVersion": "10"])
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        #expect(AboutPanel.options(bundle: legacy)[.applicationVersion] as? String == "0.5.5")
    }
}
