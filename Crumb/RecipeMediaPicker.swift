import SwiftUI
import PhotosUI
import Photos
import AVFoundation

private struct SelectedRecipePhoto: Identifiable {
    let id = UUID()
    let data: Data
}
struct RecipeCreationFlow: View {
    var bookID = MenuBook.defaultID
    @State private var selectedPhoto: SelectedRecipePhoto?
    var body: some View {
        Group {
            if let selectedPhoto {
                MealEditor(meal: nil, initialPhoto: selectedPhoto.data, initialBookID: bookID).id(selectedPhoto.id).preferredColorScheme(.light)
            } else {
                RecipeMediaPicker { data in
                    selectedPhoto = SelectedRecipePhoto(data: data)
                }
            }
        }
    }
}

struct RecipeMediaPicker: View {
    let onChoose: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var pickerItem: PhotosPickerItem?
    @State private var camera = false
    @State private var capturedPhoto: Data?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("最近の写真").font(.headline)
                        Spacer()
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("写真を選ぶ", systemImage: "photo.on.rectangle").font(.subheadline)
                        }
                    }.padding(.horizontal, 17).padding(.vertical, 18)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        Button { openCamera() } label: {
                            Rectangle().fill(Color(white: 0.13)).aspectRatio(0.85, contentMode: .fit)
                                .overlay {
                                    VStack(spacing: 10) {
                                        Image(systemName: "camera.fill").font(.system(size: 28))
                                        Text("カメラ").font(.caption)
                                    }.foregroundStyle(.white)
                                }
                        }.buttonStyle(.plain)
                        ForEach(assets, id: \.localIdentifier) { asset in
                            Button { load(asset) } label: { RecipeAssetThumbnail(asset: asset) }.buttonStyle(.plain)
                        }
                    }
                    if status == .denied || status == .restricted {
                        Text("写真へのアクセスを許可するか、上の「写真を選ぶ」から選択できます。")
                            .font(.subheadline).foregroundStyle(.secondary).padding(22)
                    } else if assets.isEmpty {
                        Text("料理を撮影するか、写真を選んでください。")
                            .font(.subheadline).foregroundStyle(.secondary).padding(22)
                    }
                }
            }.background(.black).foregroundStyle(.white)
                .navigationTitle("レシピの写真").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                            .accessibilityLabel("キャンセル")
                    }
                }
                .overlay { if loading { ProgressView().tint(.white).padding(20).background(.black.opacity(0.8), in: .rect(cornerRadius: 14)) } }
                .disabled(loading)
                .task {
                    if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                    refresh()
                }
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        loading = true; defer { loading = false }
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                            choose(data)
                        } catch { self.error = "写真を読み込めませんでした。" }
                    }
                }
                .fullScreenCover(isPresented: $camera, onDismiss: {
                    if let data = capturedPhoto { capturedPhoto = nil; choose(data) }
                }) {
                    GuidedRecipeCamera { image in
                        capturedPhoto = image.jpegData(compressionQuality: 0.9)
                        camera = false
                    } onCancel: { camera = false }
                    .ignoresSafeArea()
                }
                .alert("写真を追加", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("閉じる", role: .cancel) {}
                } message: { Text(AppLanguage.text(error ?? "")) }
        }.preferredColorScheme(.dark)
    }
    private func refresh() {
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 120
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var found: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in found.append(asset) }
        assets = found
    }
    private func choose(_ data: Data) {
        guard let cg = PlatingImage.thumbnail(data, size: 2400),
              let bytes = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) else {
            error = "写真を読み込めませんでした。"; return
        }
        onChoose(bytes)
    }
    private func load(_ asset: PHAsset) {
        loading = true
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            Task { @MainActor in
                loading = false
                if let data { choose(data) }
                else { error = "写真を読み込めませんでした。通信状態を確認してください。" }
            }
        }
    }
    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            error = "この端末ではカメラを利用できません。実機のiPhoneでお試しください。"; return
        }
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            if allowed { camera = true }
            else { error = "カメラの使用が許可されていません。設定アプリから許可してください。" }
        }
    }
}
private struct RecipeAssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    var body: some View {
        Color(white: 0.18).aspectRatio(0.85, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .task(id: asset.localIdentifier) {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 420),
                                                                contentMode: .aspectFill, options: options) { photo, _ in
                    Task { @MainActor in image = photo }
                }
            }.onDisappear { if let requestID { PHImageManager.default().cancelImageRequest(requestID) } }
    }
}
