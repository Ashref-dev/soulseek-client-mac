import Foundation
import Testing
import SwiftUI
@testable import ArpeggioServices
@testable import Arpeggio

@Suite struct PlayerGeometryTests {
    /// The 880 x 560 minimum window: about 52 points of toolbar leave a detail area near 508 points tall,
    /// and the widest sidebar (280) leaves 600 points of detail width.
    static let minimumDetail = CGSize(width: 600, height: 508)

    @Test func shortWindowsUseTheCompactPlayerAndTallOnesKeepInformation() {
        #expect(PlayerLayout(detailHeight: Self.minimumDetail.height).mode == .compact)
        #expect(PlayerLayout(detailHeight: Self.minimumDetail.height).height == 60)
        #expect(PlayerLayout(detailHeight: 639).mode == .compact)
        #expect(PlayerLayout(detailHeight: 640).mode == .regular)
        #expect(PlayerLayout(detailHeight: 900).height == 160)
        #expect(PlayerLayout(detailHeight: .nan).mode == .compact)
        #expect(PlayerLayout(detailHeight: .infinity).mode == .compact)
        let share = PlayerLayout(detailHeight: Self.minimumDetail.height).height / Self.minimumDetail.height
        #expect(share < 0.13)
    }

    @Test(arguments: [600.0, 660, 720, 880, 1024, 1280, 2000])
    func compactRowNeverOverlapsItsControls(width: Double) {
        let row = CompactPlayerAllocation(width: width)
        #expect(row.content == width - 32)
        #expect(row.used <= row.content + 0.0001)
        #expect(row.scrubber >= CompactPlayerAllocation.minimumScrubber)
        #expect(row.info >= 0)
        #expect(row.showsInfo)
        #expect(row.actions == (row.content >= 840 ? 240 : 96))
    }

    @Test func narrowAndInvalidWidthsDegradeWithoutNegativeSizes() {
        for width in [0.0, 120, 300, 420, .nan, -50] {
            let row = CompactPlayerAllocation(width: width)
            #expect(row.info >= 0); #expect(row.scrubber >= 0); #expect(row.content >= 0)
        }
        #expect(!CompactPlayerAllocation(width: 360).showsInfo)
        #expect(!CompactPlayerAllocation(width: 600).showsTimes)
        #expect(CompactPlayerAllocation(width: 880).showsTimes)
    }

    @Test func toastSitsAboveTheMeasuredPlayerAndFitsTheShortestWindow() {
        #expect(ToastGeometry.bottomPadding(playerHeight: nil) == 18)
        #expect(ToastGeometry.bottomPadding(playerHeight: 0) == 18)
        #expect(ToastGeometry.bottomPadding(playerHeight: .nan) == 18)
        for height in [PlayerLayout.compactHeight, PlayerLayout.regularHeight, 61.5] {
            let bottom = ToastGeometry.bottomPadding(playerHeight: height)
            #expect(bottom >= height + ToastGeometry.gap)
            let toast = CGRect(x: 0, y: bottom, width: 320, height: ToastGeometry.maximumHeight)
            let player = CGRect(x: 0, y: 0, width: 600, height: height)
            #expect(!toast.intersects(player))
        }
        let compact = PlayerLayout(detailHeight: Self.minimumDetail.height)
        #expect(ToastGeometry.fits(detailHeight: Self.minimumDetail.height, playerHeight: compact.height))
        #expect(!ToastGeometry.fits(detailHeight: 200, playerHeight: PlayerLayout.regularHeight))
    }

    @Test func legacyWidthAllocationStillHoldsAtTheMinimumDetailWidth() {
        let layout = PlayerWidthAllocation(width: Self.minimumDetail.width)
        #expect(layout.transport + layout.actions + 16 <= layout.content)
    }
}

@Suite struct CommandShortcutTests {
    @Test func noTwoMenuCommandsShareAShortcut() {
        let keys = ShortcutKey.all
        #expect(Set(keys).count == keys.count)
    }

    @Test func playbackShortcutsAvoidTextEditingAndListKeys() {
        for shortcut in AppShortcut.allCases where shortcut.isPlayback {
            #expect(shortcut.modifiers.contains(.command))
            #expect(shortcut.modifiers.contains(.control))
            #expect(shortcut.key.character != " ")
        }
        #expect(AppShortcut.allCases.filter(\.isPlayback).count == 7)
    }
}
