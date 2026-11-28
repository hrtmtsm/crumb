import SwiftUI

struct EmptyRecipeView: View {
    let onAdd: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = 0
    @State private var food = 0

    private enum Artwork {
        static let face = AtlasTexture.image("crumb-thought-frames", rect: CGRect(x: 9, y: 275, width: 236, height: 232))
        static let foods: [UIImage] = [
            AtlasTexture.image("crumb-food-thoughts", rect: CGRect(x: 35, y: 39, width: 587, height: 586)),
            AtlasTexture.image("crumb-food-thoughts", rect: CGRect(x: 635, y: 39, width: 590, height: 588)),
            AtlasTexture.image("crumb-food-thoughts", rect: CGRect(x: 30, y: 623, width: 593, height: 598)),
            AtlasTexture.image("crumb-food-thoughts", rect: CGRect(x: 629, y: 624, width: 602, height: 597))
        ].compactMap { $0 }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    illustration
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 20)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("今日は、何が食べたい？")
                            .font(.custom("Nunito-SemiBold", size: 25, relativeTo: .title2))
                            .foregroundStyle(ink)
                            .multilineTextAlignment(.center)
                        Text("作ったひと皿を、写真とレシピで残そう。")
                            .font(.subheadline).foregroundStyle(secondaryInk)
                            .multilineTextAlignment(.center).frame(maxWidth: 290)
                    }
                    if let onAdd {
                        Button(action: CrumbHaptics.action(onAdd)) {
                            Label("レシピを追加", systemImage: "plus")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 24).frame(minHeight: 48)
                                .background(ink, in: .capsule)
                        }.buttonStyle(.plain).padding(.top, 14)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 28).padding(.bottom, 108)
                .frame(minHeight: geometry.size.height)
            }
        }
        .task(id: AnimationState(active: scenePhase == .active, reduceMotion: reduceMotion)) {
            guard scenePhase == .active else { phase = 0; return }
            if reduceMotion { phase = 3; return }
            do {
                while !Task.isCancelled {
                    phase = 0
                    try await Task.sleep(for: .milliseconds(450))
                    try Task.checkCancellation()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) { phase = 1 }
                    try await Task.sleep(for: .milliseconds(260))
                    try Task.checkCancellation()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) { phase = 2 }
                    try await Task.sleep(for: .milliseconds(300))
                    try Task.checkCancellation()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { phase = 3 }
                    try await Task.sleep(for: .milliseconds(1850))
                    try Task.checkCancellation()
                    withAnimation(.easeOut(duration: 0.18)) { phase = 0 }
                    try await Task.sleep(for: .milliseconds(240))
                    try Task.checkCancellation()
                    // Swap only while hidden: every pop reveals a different dish.
                    food = (food + 1) % max(1, Artwork.foods.count)
                }
            } catch { /* SwiftUI cancels the loop on navigation, backgrounding, or Reduce Motion changes. */ }
        }
    }

    private var illustration: some View {
        ZStack {
            if let face = Artwork.face {
                Image(uiImage: face).resizable().scaledToFit()
                    .frame(width: 112, height: 112)
                    .position(x: 180, y: 178)
            } else {
                Image("CrumbAvatar").resizable().scaledToFit().frame(width: 112, height: 112)
                    .position(x: 180, y: 178)
            }
            thoughtDot(size: 9, visible: phase >= 1).position(x: 229, y: 128)
            thoughtDot(size: 13, visible: phase >= 2).position(x: 246, y: 114)
            if !Artwork.foods.isEmpty {
                Image(uiImage: Artwork.foods[food % Artwork.foods.count])
                    .resizable().scaledToFit().frame(width: 124, height: 124)
                    .scaleEffect(phase >= 3 ? 1 : 0.5, anchor: .bottomLeading)
                    .opacity(phase >= 3 ? 1 : 0)
                    .position(x: 301, y: 66)
            }
        }
        .frame(width: 360, height: 240)
        .scaleEffect(0.75)
        .frame(width: 270, height: 180)
        .offset(x: -6)
    }

    private func thoughtDot(size: CGFloat, visible: Bool) -> some View {
        Circle().fill(.white)
            .overlay(Circle().stroke(ink, lineWidth: 2.5))
            .frame(width: size, height: size)
            .scaleEffect(visible ? 1 : 0.2).opacity(visible ? 1 : 0)
    }
    private struct AnimationState: Equatable { let active: Bool; let reduceMotion: Bool }
}
