import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation

struct HomePlateEditor: View {
    let food: Data
    let onCancel: () -> Void
    let didSave: (PlateOption, Data) -> Void
    @Environment(\.modelContext) private var context
    @State private var item: PhotosPickerItem?
    @State private var source: Data?
    @State private var platePhoto: Data?
    @State private var placement = PlatePlacement()
    @State private var showingCamera = false
    @State private var adjustingCrop = false
    @State private var reviewingPlacement = false
    @State private var processing = false
    @State private var error: String?
    @State private var silhouette: Silhouette = .automatic
    @State private var saving = false

    private enum Silhouette: String, CaseIterable, Identifiable {
        case automatic = "自動"
        case round = "丸皿"
        case scalloped = "波縁"
        case square = "角皿"
        var id: Self { self }
    }

    private struct CutoutChoice: Equatable {
        let source: Data?
        let silhouette: Silhouette
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if reviewingPlacement, let platePhoto {
                    placementControls(platePhoto)
                } else {
                    photoControls
                }
                if let error { Text(AppLanguage.text(error)).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
        .background(paper.ignoresSafeArea())
        .navigationTitle(LocalizedStringKey(reviewingPlacement ? "盛り付け位置" : "お皿を追加"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル", action: onCancel)
            }
        }
        .task(id: item) {
            guard let item else { return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    error = "写真を読み込めませんでした。"
                    return
                }
                guard !Task.isCancelled else { return }
                setPhoto(data)
            } catch {
                if !Task.isCancelled { self.error = "写真を読み込めませんでした。" }
            }
        }
        .task(id: CutoutChoice(source: source, silhouette: silhouette)) { await prepareCutout() }
        .fullScreenCover(isPresented: $showingCamera) {
            PlateCamera { image in
                showingCamera = false
                if let data = image?.jpegData(compressionQuality: 0.92) { setPhoto(data) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $adjustingCrop) {
            if let source, let image = UIImage(data: source) {
                MealPhotoCropper(image: image) { setPhoto($0) }
            }
        }
    }

    private var photoControls: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("空のお皿を真上から撮って、縁まで写真に入れてください。")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("撮影する", systemImage: "camera", action: openCamera)
                    .buttonStyle(.bordered)
                PhotosPicker(selection: $item, matching: .images) {
                    Label("写真を選ぶ", systemImage: "photo")
                }
                .buttonStyle(.bordered)
            }
            if let source {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(ink.opacity(0.065))
                    MealPhoto(data: platePhoto ?? source, size: 750, contentMode: .fit)
                        .padding(14)
                    if processing { ProgressView("お皿を切り抜いています").padding().background(.white, in: Capsule()) }
                }
                .frame(height: 245)
                Picker("切り抜き範囲", selection: $silhouette) {
                    ForEach(Silhouette.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("写真の範囲を調整", systemImage: "crop") { adjustingCrop = true }
                Button("盛り付け位置を確認") { reviewingPlacement = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(platePhoto == nil || processing)
            }
        }
    }

    private func placementControls(_ photo: Data) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PlatedFoodPreview(subject: food, plate: PlateOption(id: "", name: "", photo: photo, placement: placement))
                .frame(maxWidth: 270).frame(maxWidth: .infinity)
            Text("左右の位置").font(.subheadline)
            Slider(value: $placement.x, in: -0.22...0.22).accessibilityLabel("左右の位置")
            Text("上下の位置").font(.subheadline)
            Slider(value: $placement.y, in: -0.22...0.22).accessibilityLabel("上下の位置")
            Text("料理の大きさ").font(.subheadline)
            Slider(value: $placement.scale, in: 0.28...0.86).accessibilityLabel("料理の大きさ")
            Button("切り抜きに戻る") { reviewingPlacement = false }
            Button("保存して使う") { save(photo) }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        }
    }

    private func setPhoto(_ data: Data) {
        source = data
        platePhoto = nil
        silhouette = .automatic
        error = nil
    }

    @MainActor private func prepareCutout() async {
        guard let source else { return }
        platePhoto = nil
        processing = true
        error = nil
        let shape = silhouette
        do {
            let extracted: Data
            switch shape {
            case .automatic:
                extracted = try await Task.detached(priority: .userInitiated) {
                    try PlatingImage.plateForeground(from: source)
                }.value
            case .round, .scalloped, .square:
                let pathName = shape == .round ? "丸" : shape == .scalloped ? "波形" : "角丸"
                extracted = try PlatingImage.crop(source, shape: pathName, rim: .clear)
            }
            try Task.checkCancellation()
            guard let image = UIImage(data: extracted) else { throw CocoaError(.fileReadCorruptFile) }
            // Manual masks already have the same inset as the normalized plate.
            platePhoto = shape == .automatic ? PlateRendering.normalize(image) : extracted
            processing = false
        } catch {
            guard !Task.isCancelled else { return }
            processing = false
            self.error = "切り抜けませんでした。範囲を調整するか、お皿の形を選んでください。"
        }
    }

    @MainActor private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            error = "この端末ではカメラが使えません。ライブラリから写真を選べます。"
            return
        }
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let granted = status == .authorized
            let requested = status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : false
            if granted || requested { showingCamera = true }
            else { error = "カメラへのアクセスを許可するか、ライブラリから写真を選んでください。" }
        }
    }

    private func save(_ photo: Data) {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let model = HomePlate(photo: photo)
        let id = UUID()
        model.identifier = id
        model.foodX = placement.x
        model.foodY = placement.y
        model.foodScale = placement.scale
        let option = PlateOption(id: id.uuidString, name: "マイお皿", photo: photo, placement: placement)
        do {
            let result = try PlateRendering.compose(food: food, on: option)
            context.insert(model)
            do { try context.save() }
            catch { context.delete(model); throw error }
            didSave(option, result)
        } catch {
            self.error = "お皿を保存できませんでした。もう一度お試しください。"
        }
    }
}

private struct PlateCamera: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.cameraCaptureMode = .photo
        camera.delegate = context.coordinator
        let guide = CameraPlateGuide(frame: UIScreen.main.bounds)
        guide.isUserInteractionEnabled = false
        guide.backgroundColor = .clear
        guide.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        camera.cameraOverlayView = guide
        return camera
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}

private final class CameraPlateGuide: UIView {
    override func draw(_ rect: CGRect) {
        let side = min(bounds.width * 0.82, bounds.height * 0.62)
        let guide = UIBezierPath(roundedRect: CGRect(x: bounds.midX - side / 2,
                                                     y: bounds.height * 0.43 - side / 2,
                                                     width: side, height: side), cornerRadius: side * 0.18)
        UIColor.white.setStroke()
        guide.lineWidth = 2
        guide.setLineDash([7, 5], count: 2, phase: 0)
        guide.stroke()
    }
}
