import SwiftUI

struct AssistantWaiting: View {
    enum Phase: String { case thinking, recipe, meal }
    let phase: Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var frame = 0
    private var frames: [UIImage] { phase == .thinking ? Art.thinking : Art.cooking }
    private var label: String {
        switch phase { case .thinking: return "Thinking…"; case .recipe: return "Working on your recipe…"; case .meal: return "Putting your meal together…" }
    }
    var body: some View {
        VStack(spacing: 8) {
            if !frames.isEmpty {
                Image(uiImage: frames[reduceMotion ? 0 : frame % frames.count])
                    .resizable().scaledToFit().frame(width: 120, height: 120).accessibilityHidden(true)
            }
            Text(verbatim: label).font(.subheadline).foregroundStyle(secondaryInk)
        }
        .accessibilityElement(children: .combine)
        .task(id: "\(phase.rawValue)-\(reduceMotion)-\(scenePhase)") {
            frame = 0
            guard !reduceMotion, scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(phase == .thinking ? 220 : 100)) } catch { return }
                frame = (frame + 1) % max(1, frames.count)
            }
        }
    }
    private enum Art {
        static let thinking = load("crumb-thinking")
        static let cooking = load("crumb-cooking")
        static func load(_ name: String) -> [UIImage] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let image = UIImage(contentsOfFile: url.path)?.cgImage else { return [] }
            let width = image.width / 3, height = image.height / 2
            return (0..<6).compactMap { index in
                image.cropping(to: CGRect(x: (index % 3)*width, y: (index / 3)*height, width: width, height: height)).map { UIImage(cgImage: $0) }
            }
        }
    }
}
