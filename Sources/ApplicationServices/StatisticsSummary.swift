import Foundation

/// Lifetime totals as they are shown and exported: on the statistics card, in Settings and in copied text.
/// It holds exactly what an exported picture contains, so it doubles as the identity that tells when a
/// rendered picture is out of date.
public struct StatisticsSnapshot: Hashable, Sendable {
    public var since: Date
    public var uploadedBytes: UInt64
    public var downloadedBytes: UInt64
    public var uploadedFiles: Int
    public var downloadedFiles: Int
    /// Set only when the person chose to show their identity on shared pictures.
    public var account: String?
    /// The person's own profile picture bytes (the normalized 512 px JPEG), kept only alongside an opted-in
    /// account. Holding the bytes rather than a path means a new picture is a new snapshot, so a cached
    /// export can never outlive the picture it shows.
    public var picture: Data?

    public init(since: Date, uploadedBytes: UInt64, downloadedBytes: UInt64, uploadedFiles: Int, downloadedFiles: Int,
                account: String? = nil, picture: Data? = nil) {
        self.since = since
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.uploadedFiles = max(0, uploadedFiles)
        self.downloadedFiles = max(0, downloadedFiles)
        let name = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.account = name.isEmpty ? nil : name
        self.picture = name.isEmpty || picture?.isEmpty != false ? nil : picture
    }

    /// Reads the persisted lifetime statistics, never the current transfer list.
    public init(_ statistics: TransferStatistics, account: String? = nil, picture: Data? = nil) {
        self.init(since: statistics.since, uploadedBytes: statistics.uploadedBytes, downloadedBytes: statistics.downloadedBytes,
                  uploadedFiles: statistics.uploadsCompleted, downloadedFiles: statistics.downloadsCompleted,
                  account: account, picture: picture)
    }
}

/// Formatting shared by the statistics surfaces. Data uses decimal gigabytes, 1 GB = 1,000,000,000 bytes.
public enum StatisticsFormat {
    public static let bytesPerGigabyte: Double = 1_000_000_000
    /// Totals that round below this many bytes would read as 0.00 GB, so they are shown as "< 0.01".
    static let smallestShown: UInt64 = 5_000_000

    public static func gigabytes(_ bytes: UInt64) -> Double { Double(bytes) / bytesPerGigabyte }

    /// The number part, always with two decimals and the locale's separators, for example "1,234.57".
    public static func gigabyteNumber(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).rounded(rule: .toNearestOrAwayFromZero).locale(locale)
        if bytes > 0, bytes < smallestShown { return "< " + 0.01.formatted(style) }
        return gigabytes(bytes).formatted(style)
    }

    public static func gigabyteText(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        gigabyteNumber(bytes, locale: locale) + " GB"
    }

    public static func count(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }

    /// "1 file" or "1,234 files".
    public static func files(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        count(value, locale: locale) + (value == 1 ? " file" : " files")
    }

    public static func exactBytes(_ bytes: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        bytes.formatted(.number.locale(locale)) + (bytes == 1 ? " byte" : " bytes")
    }

    public static func since(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, timeZone: timeZone))
    }

    /// Plain text for pasting into a post or message. Mentions the username only when the snapshot has one.
    public static func summary(_ snapshot: StatisticsSnapshot, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let date = since(snapshot.since, locale: locale, timeZone: timeZone)
        let title = snapshot.account.map { "\($0) on Soulseek since \(date)" } ?? "My Soulseek stats since \(date)"
        return [
            title,
            "Uploaded: \(gigabyteText(snapshot.uploadedBytes, locale: locale)), \(files(snapshot.uploadedFiles, locale: locale)) completed",
            "Downloaded: \(gigabyteText(snapshot.downloadedBytes, locale: locale)), \(files(snapshot.downloadedFiles, locale: locale)) completed",
            "Counted by Soulseek-Arpeggio for macOS"
        ].joined(separator: "\n")
    }
}
