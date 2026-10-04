import SwiftUI
import ArpeggioServices

/// Instant, local refinement of results already received. Common quality choices are one menu;
/// exact numbers live behind More Filters, and the ⓘ button explains every term.
struct SearchFilterBar: View {
    @Binding var filters: ResultFilters
    let formats: [String]
    let shown: Int
    let expandAll: () -> Void
    let collapseAll: () -> Void
    @State private var showMore = false
    @State private var showGuide = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
                TextField("Filter results", text: $filters.text)
                    .textFieldStyle(.plain)
                if !filters.text.isEmpty {
                    Button { filters.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                        .accessibilityLabel("Clear filter text")
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 6))
            .frame(maxWidth: 230)
            .help("Words narrow results by file path or username. Prefix a word with - to hide matches.")

            Menu {
                Picker("Quality", selection: Binding(get: { filters.preset ?? .any }, set: { filters.apply($0) })) {
                    ForEach(QualityPreset.allCases) { preset in
                        Label { Text(preset.title); Text(preset.detail) } icon: { Image(systemName: preset.symbol) }.tag(preset)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(filters.preset?.title ?? "Custom Quality", systemImage: (filters.preset ?? .lossless).symbol)
            }
            .fixedSize()
            .help("Quick quality presets")

            Picker("Format", selection: $filters.format) {
                Text("Any Format").tag("Any")
                Divider()
                ForEach(formats, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Toggle("Free slots", isOn: $filters.freeSlotsOnly)
                .toggleStyle(.checkbox)
                .help("Only peers who can start sending right away")

            Button { showMore.toggle() } label: {
                Label("More", systemImage: "slider.horizontal.3")
                    .foregroundStyle(filters.hasAdvancedValues ? Color.arpeggio : Color.primary)
            }
            .help("Exact bitrate, sample rate, bit depth and size limits")
            .popover(isPresented: $showMore, arrowEdge: .bottom) { MoreFilters(filters: $filters) }

            Spacer(minLength: 8)

            if filters.isActive {
                Text("\(shown.formatted()) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Reset") { withAnimation(.smooth(duration: 0.2)) { filters = ResultFilters() } }
                    .buttonStyle(.borderless)
                    .help("Remove all filters")
            }

            ControlGroup {
                Button(action: expandAll) { Image(systemName: "rectangle.expand.vertical") }
                    .help("Expand All (⌥⌘→)")
                    .accessibilityLabel("Expand all")
                Button(action: collapseAll) { Image(systemName: "rectangle.compress.vertical") }
                    .help("Collapse All (⌥⌘←)")
                    .accessibilityLabel("Collapse all")
            }
            .fixedSize()

            Button { showGuide.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("How searching and filtering work")
                .accessibilityLabel("Search and filter guide")
                .popover(isPresented: $showGuide, arrowEdge: .bottom) { FilterGuide() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MoreFilters: View {
    @Binding var filters: ResultFilters

    var body: some View {
        Form {
            Section("Quality") {
                Toggle("Lossless only", isOn: $filters.losslessOnly)
                Picker("Minimum bitrate", selection: $filters.minBitrate) {
                    Text("Any").tag(0)
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Minimum bit depth", selection: $filters.minimumBitDepth) {
                    Text("Any").tag(0); Text("16-bit").tag(16); Text("24-bit").tag(24)
                }
                Picker("Minimum sample rate", selection: $filters.minimumSampleRate) {
                    Text("Any").tag(0)
                    ForEach([44100, 48000, 96000, 192000], id: \.self) { Text("\(Double($0) / 1000, specifier: "%.1f") kHz").tag($0) }
                }
            }
            Section("Files") {
                Toggle("Audio files only", isOn: $filters.audioOnly)
                TextField("Largest file (MB)", value: $filters.maximumMegabytes, format: .number, prompt: Text("No limit"))
            }
            HStack {
                Spacer()
                Button("Reset Filters") { filters = ResultFilters() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }
}

private struct FilterGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Searching & Filtering").font(.title3.weight(.semibold))
                topic("magnifyingglass", "Network search", """
                The search field asks peers on Soulseek. Each word must appear in a file’s path, so fewer, \
                distinctive words find more. Put - before a word to exclude it (Monster Hunter -remix). \
                Many peers also accept * at the start of a word for partial matches (*tallica).
                """)
                topic("timer", "When a search ends", """
                Soulseek never says a search is finished: peers keep answering as long as it’s open. \
                By default Arpeggio stops listening after 15 seconds without new results, or 2 minutes at most. \
                Change this in Settings › General, or press Stop anytime.
                """)
                topic("line.3.horizontal.decrease", "Filter results", """
                Filtering is instant and local. Words match the file path or username; -word hides matches. \
                Nothing is re-searched, and Reset brings everything back.
                """)
                topic("waveform", "Quality presets", """
                Lossless keeps FLAC, WAV, ALAC, AIFF, APE and WavPack: bit-perfect copies of the source. \
                Hi-Res Lossless needs 24-bit audio. 320 kbps is the best MP3/AAC quality; 256 kbps is close \
                and smaller. Bitrate presets always include lossless files.
                """)
                topic("slider.horizontal.3", "More filters", """
                Bitrate (kbps) is how much data each second of lossy audio uses. Bit depth (16 or 24-bit) and \
                sample rate (kHz) describe lossless audio. Peers only report what their client measured: files \
                with unknown bitrate are hidden by a minimum bitrate, and sample rate or bit depth limits hide \
                most lossy files.
                """)
                topic("checkmark.circle.fill", "Free slots", """
                A green check means the peer can start sending now. An hourglass means you join their queue. \
                Speed is what the peer reports for uploads, not a guarantee.
                """)
                topic("play.circle", "Listen first", """
                Press a track’s play button or Space to stream it before downloading. Press Download in the \
                player to keep it.
                """)
            }
            .padding(18)
        }
        .frame(width: 420, height: 470)
    }

    private func topic(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.arpeggio).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
