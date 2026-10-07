import Foundation
import Testing
@testable import ArpeggioServices

@Suite struct UpdaterAssetSelectionTests {
    private func payload(_ names: [String]) -> Data {
        let assets = names.enumerated().map { index, name in
            "{\"name\":\"\(name)\",\"browser_download_url\":\"https://example.com/\(index).zip\"}"
        }.joined(separator: ",")
        return Data("{\"tag_name\":\"v0.6.0-rc.1\",\"html_url\":\"https://github.com/a/b\",\"assets\":[\(assets)]}".utf8)
    }
    @Test func canonicalVersionMatchedArchiveWinsRegardlessOfOrder() throws {
        let release = try Updater.parse(payload(["Soulseek-Arpeggio-0.5.5.zip", "Soulseek-Arpeggio-0.6.0-rc.1-debug.zip", "Soulseek-Arpeggio-0.6.0-rc.1.zip"]))
        #expect(release.asset.absoluteString == "https://example.com/2.zip")
    }
    @Test(arguments: [["Soulseek-Arpeggio-0.5.5.zip"], ["Soulseek-Arpeggio-0.6.0-rc.1-debug.zip"], ["Soulseek-Arpeggio-0.6.0-rc.1.zip", "Soulseek-Arpeggio-0.6.0-rc.1.zip"], ["Arpeggio-0.6.0-rc.1.zip", "Arpeggio-0.6.0-rc.1.zip"]])
    func wrongDebugAndAmbiguousArchivesAreRejected(_ names: [String]) {
        #expect(throws: UpdateError.self) { try Updater.parse(payload(names)) }
    }
    @Test func uniqueExactLegacyArchiveRemainsSupported() throws {
        let release = try Updater.parse(payload(["Arpeggio-0.6.0-rc.1.zip", "checksums.txt"]))
        #expect(release.asset.absoluteString == "https://example.com/0.zip")
    }
}
