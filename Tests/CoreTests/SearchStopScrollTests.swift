import Foundation
import Testing
import SoulseekCore
@testable import ArpeggioServices
@testable import Arpeggio

/// Stopping a search must keep the outline, so the reader's scroll position survives.
@Test func stoppingASearchKeepsTheOutlineButNewSearchesFiltersAndSortsRebuildIt() {
    let sort = [KeyPathComparator(\SearchResult.slotRank)]
    let live = ProjectionKey(token: 7, filters: ResultFilters(), sort: sort)
    #expect(ProjectionKey.searchStopped(from: live, to: ProjectionKey(token: nil, filters: ResultFilters(), sort: sort)))
    #expect(!ProjectionKey.searchStopped(from: live, to: ProjectionKey(token: 8, filters: ResultFilters(), sort: sort)))
    var lossless = ResultFilters(); lossless.losslessOnly = true
    #expect(!ProjectionKey.searchStopped(from: live, to: ProjectionKey(token: nil, filters: lossless, sort: sort)))
    #expect(!ProjectionKey.searchStopped(from: live, to: ProjectionKey(token: nil, filters: ResultFilters(), sort: [KeyPathComparator(\SearchResult.size)])))
    #expect(!ProjectionKey.searchStopped(from: ProjectionKey(token: nil, filters: ResultFilters(), sort: sort), to: live))
}
