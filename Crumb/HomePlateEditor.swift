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
    @State private var guide: PlateCaptureGuide = .round
    @State private var saving = false

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
                Button("キャンセル", action: CrumbHaptics.action(onCancel))
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
        .task(id: source) { await prepareCutout() }
        .fullScreenCover(isPresented: $showingCamera) {
            PlateCamera(guide: guide) { image in
                showingCamera = false
                if let data = image?.jpegData(compressionQuality: 0.92) { setPhoto(data) }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Picker("撮影ガイド", selection: $guide) {
                    ForEach(PlateCaptureGuide.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(12)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 24).padding(.top, 54)
            }
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
                Button("撮影する", systemImage: "camera", action: CrumbHaptics.action(openCamera))
                    .buttonStyle(.bordered)
                PhotosPicker(selection: $item, matching: .images) {
                    Label("写真を選ぶ", systemImage: "photo")
                }.hapticActivation()
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
                Button("写真の範囲を調整", systemImage: "crop") { CrumbHaptics.tap(); adjustingCrop = true }
                Button("盛り付け位置を確認") { CrumbHaptics.tap(); reviewingPlacement = true }
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
            Button("切り抜きに戻る") { CrumbHaptics.tap(); reviewingPlacement = false }
            Button("保存して使う") { CrumbHaptics.tap(); save(photo) }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        }
    }

    private func setPhoto(_ data: Data) {
        source = data
        platePhoto = nil
        error = nil
    }

    @MainActor private func prepareCutout() async {
        guard let source else { return }
        platePhoto = nil
        processing = true
        error = nil
        do {
            let extracted = try await Task.detached(priority: .userInitiated) {
                try PlatingImage.plateForeground(from: source)
            }.value
            try Task.checkCancellation()
            guard let image = UIImage(data: extracted) else { throw CocoaError(.fileReadCorruptFile) }
            platePhoto = PlateRendering.normalize(image)
            processing = false
        } catch {
            guard !Task.isCancelled else { return }
            processing = false
            self.error = "切り抜けませんでした。お皿全体が写るように範囲を調整するか、背景と色の違う場所で撮り直してください。"
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
            do { try context.save()
            NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil) }
            catch { context.delete(model); throw error }
            CrumbHaptics.success()
            didSave(option, result)
        } catch {
            self.error = "お皿を保存できませんでした。もう一度お試しください。"
        }
    }
}

private enum PlateCaptureGuide: String, CaseIterable, Identifiable {
    case round = "丸皿"
    case scalloped = "波縁"
    case square = "角皿"
    var id: Self { self }
}

private struct PlateCamera: UIViewControllerRepresentable {
    let guide: PlateCaptureGuide
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.cameraCaptureMode = .photo
        camera.delegate = context.coordinator
        let guide = CameraPlateGuide(frame: UIScreen.main.bounds)
        guide.shape = self.guide
        guide.isUserInteractionEnabled = false
        guide.backgroundColor = .clear
        guide.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        camera.cameraOverlayView = guide
        return camera
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        if let overlay = controller.cameraOverlayView as? CameraPlateGuide {
            overlay.shape = guide
        }
    }

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
    var shape: PlateCaptureGuide = .round { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        let side = min(bounds.width * 0.82, bounds.height * 0.62)
        let area = CGRect(x: bounds.midX - side / 2, y: bounds.height * 0.43 - side / 2,
                          width: side, height: side)
        let path: UIBezierPath
        switch shape {
        case .round: path = UIBezierPath(ovalIn: area)
        case .square: path = UIBezierPath(roundedRect: area, cornerRadius: side * 0.08)
        case .scalloped: path = PlatingImage.shapePath("波形", in: area)
        }
        UIColor.white.setStroke()
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}
