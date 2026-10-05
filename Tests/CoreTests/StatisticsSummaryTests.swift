import Foundation
import Testing
@testable import ArpeggioServices
import Persistence

private let english = Locale(identifier: "en_US")
private let utc = TimeZone(identifier: "UTC")!
private let start = Date(timeIntervalSince1970: 1_700_000_000)

@Test func gigabytesAreDecimalWithTwoDecimals() {
    #expect(StatisticsFormat.gigabytes(1_000_000_000) == 1)
    #expect(StatisticsFormat.gigabyteText(0, locale: english) == "0.00 GB")
    #expect(StatisticsFormat.gigabyteText(1_000_000_000, locale: english) == "1.00 GB")
    #expect(StatisticsFormat.gigabyteText(1_234_567_890, locale: english) == "1.23 GB")
    #expect(StatisticsFormat.gigabyteText(999_999_999, locale: english) == "1.00 GB")
    #expect(StatisticsFormat.gigabyteText(5_000_000, locale: english) == "0.01 GB")
    #expect(StatisticsFormat.gigabyteText(1, locale: english) == "< 0.01 GB")
    #expect(StatisticsFormat.gigabyteText(4_999_999, locale: english) == "< 0.01 GB")
}

@Test func largeTotalsKeepGroupingAndPrecision() {
    #expect(StatisticsFormat.gigabyteText(12_345_678_901_234, locale: english) == "12,345.68 GB")
    #expect(StatisticsFormat.gigabyteNumber(UInt64.max, locale: english) == "18,446,744,073.71")
    #expect(StatisticsFormat.gigabyteText(1_234_567_890, locale: Locale(identifier: "de_DE")) == "1,23 GB")
    #expect(StatisticsFormat.gigabyteText(12_345_678_901_234, locale: Locale(identifier: "fr_FR")).hasSuffix("345,68 GB"))
    #expect(StatisticsFormat.exactBytes(1_234_567_890, locale: english) == "1,234,567,890 bytes")
}

@Test func fileCountsUseLocaleNumeralsAndPlurals() {
    #expect(StatisticsFormat.files(0, locale: english) == "0 files")
    #expect(StatisticsFormat.files(1, locale: english) == "1 file")
    #expect(StatisticsFormat.files(1_234_567, locale: english) == "1,234,567 files")
    #expect(StatisticsFormat.count(1_234_567, locale: Locale(identifier: "de_DE")) == "1.234.567")
}

@Test func snapshotPreservesLifetimeCountsAndDropsBlankAccounts() {
    var stats = TransferStatistics(since: start)
    stats.uploadedBytes = 98_765_432_109; stats.downloadedBytes = 3
    stats.uploadsCompleted = 4_321; stats.downloadsCompleted = 7
    stats.listeners = ["a", "b"]; stats.peakUploadSpeed = 1e6
    let snapshot = StatisticsSnapshot(stats)
    #expect(snapshot.uploadedBytes == 98_765_432_109); #expect(snapshot.downloadedBytes == 3)
    #expect(snapshot.uploadedFiles == 4_321); #expect(snapshot.downloadedFiles == 7)
    #expect(snapshot.since == start); #expect(snapshot.account == nil)
    #expect(StatisticsSnapshot(stats, account: "  ").account == nil)
    #expect(StatisticsSnapshot(stats, account: " dj ").account == "dj")
    #expect(StatisticsSnapshot(stats, account: "dj") != snapshot)
    var more = stats; more.downloadsCompleted += 1
    #expect(StatisticsSnapshot(more) != snapshot)
    var unrelated = stats; unrelated.peakDownloadSpeed = 5; unrelated.sources = ["x"]
    #expect(StatisticsSnapshot(unrelated) == snapshot)
}

@Test func summaryIsAccurateAndPrivateByDefault() {
    let snapshot = StatisticsSnapshot(since: start, uploadedBytes: 12_345_678_901, downloadedBytes: 987_654_321,
                                      uploadedFiles: 1_234, downloadedFiles: 1)
    #expect(StatisticsFormat.summary(snapshot, locale: english, timeZone: utc) == """
    My Soulseek stats since November 14, 2023
    Uploaded: 12.35 GB, 1,234 files completed
    Downloaded: 0.99 GB, 1 file completed
    Counted by Soulseek-Arpeggio for macOS
    """)
    let named = StatisticsSnapshot(since: start, uploadedBytes: 0, downloadedBytes: 0, uploadedFiles: 0, downloadedFiles: 0, account: "dj")
    let text = StatisticsFormat.summary(named, locale: english, timeZone: utc)
    #expect(text.hasPrefix("dj on Soulseek since November 14, 2023\n"))
    #expect(text.contains("Uploaded: 0.00 GB, 0 files completed"))
    #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"))
}

@Test func statsCardAccountIsOptIn() throws {
    #expect(!AppSettings().showsAccountOnStatsCard)
    var settings = AppSettings(); settings.statsCardAccount = true
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.showsAccountOnStatsCard)
}
