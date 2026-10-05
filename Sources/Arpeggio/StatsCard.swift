import SwiftUI
import AppKit
import ArpeggioServices

/// The shareable statistics picture. It always lays out at one fixed size, so the in-app preview and the
/// exported PNG (1200 x 676 at 2x, close to 16:9 for social posts) are the same composition.
struct StatsCard: View {
    static let size = CGSize(width: 600, height: 338)

    let snapshot: StatisticsSnapshot
    @Environment(\.locale) private var locale

    var body: some View {
        let size = valueSize
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ArpeggioLogo().frame(width: 26, height: 26)
                Text("Soulseek-Arpeggio").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Text("Lifetime stats").font(.system(size: 13, weight: .medium)).opacity(0.72)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                total("Uploaded", symbol: "arrow.up", bytes: snapshot.uploadedBytes, files: snapshot.uploadedFiles, verb: "uploaded", size: size)
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1).padding(.horizontal, 28)
                total("Downloaded", symbol: "arrow.down", bytes: snapshot.downloadedBytes, files: snapshot.downloadedFiles, verb: "downloaded", size: size)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Since \(StatisticsFormat.since(snapshot.since, locale: locale))")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.78)
                Spacer(minLength: 24)
                if let account = snapshot.account {
                    HStack(spacing: 9) {
                        StatsCardAvatar(picture: snapshot.picture)
                        Text(account)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(0.94)
                    }
                }
            }
            .frame(height: StatsCardAvatar.diameter)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(.white)
        .background { backdrop }
        .environment(\.colorScheme, .dark)
    }

    /// Both totals share the largest size at which the longer one fits its column, so baselines stay aligned.
    private var valueSize: CGFloat {
        let texts = [snapshot.uploadedBytes, snapshot.downloadedBytes].map { StatisticsFormat.gigabyteNumber($0, locale: locale) }
        let room = (Self.size.width - 68 - 57) / 2 - 44
        return stride(from: 56, through: 16, by: -2).first { size in
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold).roundedVariant
            return texts.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= room }
        } ?? 16
    }

    private func total(_ title: String, symbol: String, bytes: UInt64, files: Int, verb: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.arpeggioLavender.mix(with: .white, by: 0.55))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(StatisticsFormat.gigabyteNumber(bytes, locale: locale))
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .tracking(-1.2)
                Text("GB").font(.system(size: max(13, size * 0.44), weight: .semibold, design: .rounded)).opacity(0.78)
            }
            .monospacedDigit()
            .lineLimit(1)
            Text("\(StatisticsFormat.files(files, locale: locale)) \(verb)")
                .font(.system(size: 15, weight: .medium))
                .opacity(0.86)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [.arpeggioDeep, .arpeggioNight], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.arpeggioLavender.opacity(0.42), .clear], center: .topTrailing, startRadius: 10, endRadius: 360)
            ArpeggioLogo()
                .foregroundStyle(.white.opacity(0.05))
                .frame(width: 400, height: 400)
                .offset(x: 205, y: 70)
        }
        .clipped()
    }
}

/// Missing or unreadable picture bytes show a placeholder rather than failing the export.
struct StatsCardAvatar: View {
    static let diameter: CGFloat = 30
    let picture: Data?

    var body: some View {
        Group {
            if let image = StatsAvatar.image(picture) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                LinearGradient(colors: [.arpeggioLavender, .arpeggioDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: Self.diameter * 0.46, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .offset(y: Self.diameter * 0.06)
                    }
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
        .shadow(color: .arpeggioNight.opacity(0.4), radius: 4, y: 2)
    }
}

/// The card scaled to whatever width it's given, with rounded corners and depth for on-screen display.
struct FittedStatsCard: View {
    let snapshot: StatisticsSnapshot
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { proxy in
            StatsCard(snapshot: snapshot)
                .scaleEffect(proxy.size.width / StatsCard.size.width, anchor: .topLeading)
        }
        .aspectRatio(StatsCard.size.width / StatsCard.size.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .arpeggioNight.opacity(0.28), radius: 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatisticsFormat.summary(snapshot, locale: locale))
        .accessibilityAddTraits(.isImage)
    }
}

private extension NSFont {
    var roundedVariant: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
