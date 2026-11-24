import SwiftUI

struct PhotoFrame: Codable {
    var shape: String
    var rim: String
    var backgroundRemoved: Bool?
    var zoom: Double = 1
    var x: Double = 0
    var y: Double = 0
    static func decode(_ value: String?) -> PhotoFrame? {
        value.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }
}
struct PhotoFrameShape: Shape {
    let name: String
    func path(in rect: CGRect) -> Path {
        Path(PlatingImage.shapePath(name, in: rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)).cgPath)
    }
}
struct ShapePhotoEditor: View {
    let original: Data
    let shape: String
    let rim: UIColor
    let apply: (PhotoFrame, Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat
    @State private var offset: CGSize
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    @State private var failed = false
    init(original: Data, shape: String, rim: UIColor, initial: PhotoFrame?, apply: @escaping (PhotoFrame, Data) -> Void) {
        self.original = original; self.shape = shape; self.rim = rim; self.apply = apply
        _zoom = State(initialValue: CGFloat(initial?.zoom ?? 1))
        _offset = State(initialValue: CGSize(width: initial?.x ?? 0, height: initial?.y ?? 0))
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = max(1, min(geometry.size.width - 40, geometry.size.height - 180))
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    if let cg = PlatingImage.thumbnail(original, size: 1400) {
                        let image = UIImage(cgImage: cg)
                        let scale = min(5, max(1, zoom * magnification))
                        let size = fitted(image.size, side: side, zoom: scale)
                        let point = clamped(CGSize(width: offset.width + drag.width / side,
                                                   height: offset.height + drag.height / side),
                                            image: image.size, zoom: scale)
                        Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                            .offset(x: point.width * side, y: point.height * side)
                            .frame(width: side, height: side)
                            .clipShape(PhotoFrameShape(name: shape))
                            .overlay(PhotoFrameShape(name: shape).stroke(Color(uiColor: rim), lineWidth: side * 24 / 900))
                            .contentShape(Rectangle())
                            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    offset = clamped(CGSize(width: offset.width + value.translation.width / side,
                                                            height: offset.height + value.translation.height / side),
                                                     image: image.size, zoom: zoom)
                                })
                            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }
                                .onEnded { value in
                                    zoom = min(5, max(1, zoom * value.magnification))
                                    offset = clamped(offset, image: image.size, zoom: zoom)
                                })
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $zoom, in: 1...5)
                                .onChange(of: zoom) { _, value in offset = clamped(offset, image: image.size, zoom: value) }
                                .accessibilityLabel("拡大率")
                            Image(systemName: "plus.magnifyingglass")
                            Text(String(format: "%.1f×", zoom)).font(.caption.monospacedDigit()).frame(width: 38)
                        }.padding(.horizontal, 22)
                    }
                    Text("枠の中をドラッグして移動。ピンチでも拡大・縮小できます。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
                    Button("リセット") { zoom = 1; offset = .zero }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(paper.ignoresSafeArea())
                .navigationTitle("写真の位置を調整").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("適用") {
                            let value = PhotoFrame(shape: shape, rim: "", zoom: Double(zoom), x: Double(offset.width), y: Double(offset.height))
                            do {
                                let data = try PlatingImage.crop(original, shape: shape, rim: rim, frame: value)
                                apply(value, data); dismiss()
                            } catch { failed = true }
                        }
                    }
                }
                .alert("写真を調整できませんでした", isPresented: $failed) { Button("閉じる", role: .cancel) {} }
        }.preferredColorScheme(.light)
    }
    private func fitted(_ size: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = side * zoom / min(size.width, size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    private func clamped(_ offset: CGSize, image: CGSize, zoom: CGFloat) -> CGSize {
        let size = fitted(image, side: 1, zoom: zoom)
        let x = max(0, (size.width - 1) / 2), y = max(0, (size.height - 1) / 2)
        return CGSize(width: min(x, max(-x, offset.width)), height: min(y, max(-y, offset.height)))
    }
}

struct ShapeCropSource: View {
    let original: Data
    let frame: PhotoFrame
    let apply: (PhotoFrame, Data) -> Void
    @State private var source: Data?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let source {
                ShapePhotoEditor(original: source, shape: frame.shape, rim: rimColor, initial: frame) { value, data in
                    var updated = value
                    updated.rim = frame.rim
                    updated.backgroundRemoved = frame.backgroundRemoved
                    apply(updated, data)
                }
            } else {
                NavigationStack {
                    Group {
                        if failed { ContentUnavailableView("写真を読み込めませんでした", systemImage: "photo") }
                        else { ProgressView("写真を準備しています") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(paper)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
                }
            }
        }.task {
            guard source == nil else { return }
            if frame.backgroundRemoved == true {
                do {
                    let data = original
                    let result = try await Task.detached(priority: .userInitiated) {
                        try PlatingImage.foreground(from: data, subjectPoint: nil)
                    }.value
                    guard !Task.isCancelled else { return }
                    source = result
                } catch { failed = true }
            } else { source = original }
        }.preferredColorScheme(.light)
    }
    private var rimColor: UIColor {
        switch frame.rim {
        case "白": .white
        case "黒": UIColor(ink)
        case "クリーム": UIColor(red: 1, green: 0.91, blue: 0.72, alpha: 1)
        case "ピンク": UIColor(red: 1, green: 0.72, blue: 0.79, alpha: 1)
        case "水色": UIColor(red: 0.65, green: 0.82, blue: 1, alpha: 1)
        case "ミント": UIColor(red: 0.68, green: 0.87, blue: 0.76, alpha: 1)
        default: .clear
        }
    }
}
