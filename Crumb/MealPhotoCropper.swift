import SwiftUI

struct MealPhotoCropper: View {
    let image: UIImage
    let apply: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = max(1, min(geometry.size.width - 32, geometry.size.height - 90))
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    cropFrame(side)
                    Text("ピンチで拡大し、ドラッグで位置を調整")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(paper.ignoresSafeArea())
            .navigationTitle("トリミング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private func cropFrame(_ side: CGFloat) -> some View {
        let scale = min(max(zoom * magnification, 1), 5)
        let size = fittedSize(side: side, scale: scale)
        let position = constrainedOffset(
            CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
            size: size,
            side: side
        )

        return Image(uiImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .offset(position)
            .frame(width: side, height: side)
            .clipped()
            .contentShape(Rectangle())
            .overlay {
                CropGrid().stroke(.white.opacity(0.78), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .gesture(DragGesture()
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset = constrainedOffset(
                        CGSize(width: offset.width + value.translation.width,
                               height: offset.height + value.translation.height),
                        size: fittedSize(side: side, scale: zoom), side: side
                    )
                })
            .simultaneousGesture(MagnifyGesture()
                .updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    zoom = min(max(zoom * value.magnification, 1), 5)
                    offset = constrainedOffset(offset, size: fittedSize(side: side, scale: zoom), side: side)
                })
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") { save(side: side) }.fontWeight(.semibold)
                }
            }
    }

    private func fittedSize(side: CGFloat, scale: CGFloat) -> CGSize {
        let factor = side * scale / min(image.size.width, image.size.height)
        return CGSize(width: image.size.width * factor, height: image.size.height * factor)
    }

    private func constrainedOffset(_ proposed: CGSize, size: CGSize, side: CGFloat) -> CGSize {
        let horizontal = max(0, (size.width - side) / 2)
        let vertical = max(0, (size.height - side) / 2)
        return CGSize(width: min(max(proposed.width, -horizontal), horizontal),
                      height: min(max(proposed.height, -vertical), vertical))
    }

    private func save(side: CGFloat) {
        let sourceSize = fittedSize(side: side, scale: zoom)
        let position = constrainedOffset(offset, size: sourceSize, side: side)
        let outputSide: CGFloat = min(1400, min(image.size.width, image.size.height) / zoom)
        let ratio = outputSide / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
        let data = renderer.jpegData(withCompressionQuality: 0.9) { _ in
            image.draw(in: CGRect(x: ((side - sourceSize.width) / 2 + position.width) * ratio,
                                  y: ((side - sourceSize.height) / 2 + position.height) * ratio,
                                  width: sourceSize.width * ratio, height: sourceSize.height * ratio))
        }
        apply(data)
        dismiss()
    }
}

private struct CropGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        for division in 1...2 {
            let x = rect.minX + rect.width * CGFloat(division) / 3
            let y = rect.minY + rect.height * CGFloat(division) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
