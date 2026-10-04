import SwiftUI
import ArpeggioServices

struct ReceivedSearchesView: View {
    let model: AppModel
    let navigator: Navigator
    @State private var matchesOnly = false
    @State private var filter = ""

    private var rows: [ReceivedSearch] {
        model.receivedSearches.filter {
            (!matchesOnly || $0.results > 0) &&
            (filter.isEmpty || $0.query.localizedCaseInsensitiveContains(filter) || $0.user.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            OfflineNotice(model: model, navigator: navigator)
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(model.receivedSearches.isEmpty ? "No Searches Yet" : "No Matching Searches", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(model.receivedSearches.isEmpty
                         ? "While you’re connected, other people’s searches reach Arpeggio so it can answer from your shared folders. The latest ones appear here."
                         : "Try another filter.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Time") { Text($0.date.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary) }
                        .width(min: 70, ideal: 80)
                    TableColumn("Search") { Text($0.query).lineLimit(1) }
                    TableColumn("User") { item in
                        Text(item.user).lineLimit(1)
                            .contextMenu { UserActions(user: item.user, model: model, navigator: navigator) }
                    }
                    .width(min: 100, ideal: 150)
                    TableColumn("Your Matches") { item in
                        Text(item.results == 0 ? "-" : item.results.formatted())
                            .monospacedDigit()
                            .foregroundStyle(item.results > 0 ? Color.arpeggio : .secondary)
                            .fontWeight(item.results > 0 ? .semibold : .regular)
                    }
                    .width(min: 70, ideal: 90)
                }
            }
        }
        .navigationTitle("Received Searches")
        .navigationSubtitle("\(model.receivedSearchTotal.formatted()) received · \(model.receivedSearches.filter { $0.results > 0 }.count) answered recently")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter searches")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $matchesOnly) { Label("Only Matches", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Show only searches your shares answered")
                Button("Clear", systemImage: "trash") { model.clearReceivedSearches() }
                    .disabled(model.receivedSearches.isEmpty)
            }
        }
    }
}
