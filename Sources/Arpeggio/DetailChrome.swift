import SwiftUI
import ArpeggioServices

/// The detail column's chrome: banners above the content, the player and the confirmation toast below it.
/// The column is measured on its outer frame, which banners, the player and the toast never resize, so
/// switching the player between its forms cannot feed back into the measurement that chose the form.
struct DetailChrome<Content: View, Banners: View, Player: View, Toast: View>: View {
    let showsPlayer: Bool
    let onMeasure: ((Double) -> Void)?
    let content: () -> Content
    let banners: () -> Banners
    let player: (PlayerLayout) -> Player
    let toast: (Double) -> Toast
    @State private var columnHeight: Double?
    @State private var playerHeight: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(showsPlayer: Bool, onMeasure: ((Double) -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder banners: @escaping () -> Banners,
         @ViewBuilder player: @escaping (PlayerLayout) -> Player,
         @ViewBuilder toast: @escaping (Double) -> Toast) {
        self.showsPlayer = showsPlayer; self.onMeasure = onMeasure
        self.content = content; self.banners = banners; self.player = player; self.toast = toast
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { banners() } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsPlayer {
                    player(PlayerLayout(detailHeight: columnHeight ?? PlayerLayout.compactBelowHeight))
                        .onGeometryChange(for: Double.self) { $0.size.height } action: { playerHeight = $0 }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) { toast(ToastGeometry.bottomPadding(playerHeight: showsPlayer ? playerHeight : nil)) }
            .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                columnHeight = height
                onMeasure?(height)
            }
    }
}
