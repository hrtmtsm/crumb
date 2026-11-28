import SwiftUI
import SwiftData
import PhotosUI

struct PlatePlacement: Equatable {
    var x = 0.0
    var y = 0.0
    var scale = 0.70
}

struct PlateOption: Identifiable {
    let id: String
    let name: String
    let photo: Data
    var placement = PlatePlacement()

    // Original reference sheets remain unchanged. Crop their individual textures when loading the picker.
    static let standard: [Self] = [
        atlasPlate("ceramic-green", "深緑の輪花", source: "ceramic-green", canvas: CGSize(width: 1254, height: 1254), rect: CGRect(x: 64, y: 64, width: 1128, height: 1128), placement: PlatePlacement(x: 0, y: 0.015, scale: 0.72)),
        atlasPlate("ceramic-vines", "藍の花唐草", source: "ceramic-five", canvas: CGSize(width: 1536, height: 1024), rect: CGRect(x: 502, y: 12, width: 510, height: 510), placement: PlatePlacement(scale: 0.82)),
        atlasPlate("ceramic-crest", "藍の三つ紋", source: "ceramic-five", canvas: CGSize(width: 1536, height: 1024), rect: CGRect(x: 1038, y: 35, width: 470, height: 480), placement: PlatePlacement(scale: 0.82)),
        atlasPlate("ceramic-blue-flower", "青い芥子の花", source: "ceramic-five", canvas: CGSize(width: 1536, height: 1024), rect: CGRect(x: 229, y: 507, width: 500, height: 500), placement: PlatePlacement(scale: 0.82)),
        atlasPlate("ceramic-rose", "桃色の花と赤い縁", source: "ceramic-five", canvas: CGSize(width: 1536, height: 1024), rect: CGRect(x: 769, y: 507, width: 500, height: 500), placement: PlatePlacement(scale: 0.82)),
        atlasPlate("ceramic-celadon", "青磁の角皿", source: "ceramic-pair", canvas: CGSize(width: 1774, height: 887), rect: CGRect(x: 70, y: 70, width: 750, height: 750), placement: PlatePlacement(scale: 0.76)),
        atlasPlate("ceramic-imari", "藍と金の輪花", source: "ceramic-pair", canvas: CGSize(width: 1774, height: 887), rect: CGRect(x: 910, y: 50, width: 800, height: 800), placement: PlatePlacement(scale: 0.80))
    ].compactMap { $0 }

    private static func atlasPlate(_ id: String, _ name: String, source: String, canvas: CGSize, rect: CGRect, placement: PlatePlacement) -> Self? {
        guard let url = Bundle.main.url(forResource: source, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let pixels = CGRect(x: rect.minX * CGFloat(image.width) / canvas.width,
                            y: rect.minY * CGFloat(image.height) / canvas.height,
                            width: rect.width * CGFloat(image.width) / canvas.width,
                            height: rect.height * CGFloat(image.height) / canvas.height).integral
        guard let crop = image.cropping(to: pixels), let isolated = AtlasTexture.isolate(crop),
              let photo = UIImage(cgImage: isolated).pngData() else { return nil }
        return Self(id: id, name: name, photo: photo, placement: placement)
    }

    // Existing recipes keep their previous plate when reopened for editing; only the new set appears in the picker.
    static func resolve(_ id: String) -> Self? {
        if let plate = standard.first(where: { $0.id == id }) { return plate }
        guard id.range(of: "^standard-plate-(0[1-9]|1[0-5])$", options: .regularExpression) != nil,
              let url = Bundle.main.url(forResource: id, withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return nil }
        return Self(id: id, name: AppLanguage.text("以前のお皿"), photo: data)
    }

    init(id: String, name: String, photo: Data, placement: PlatePlacement = .init()) {
        self.id = id
        self.name = name
        self.photo = photo
        self.placement = placement
    }

    @MainActor init(plate: HomePlate, number: Int) {
        id = plate.identifier?.uuidString ?? "legacy-\(plate.persistentModelID)"
        name = AppLanguage.format("マイお皿 %lld", Int64(number))
        if plate.photo.isPlatedPhoto {
            photo = plate.photo
        } else {
            photo = (try? PlatingImage.crop(plate.photo, shape: "丸", rim: .clear)) ?? plate.photo
        }
        placement = PlatePlacement(x: plate.foodX ?? 0, y: plate.foodY ?? 0, scale: plate.foodScale ?? 0.70)
    }
}

struct PlatePicker: View {
    let original: Data
    let currentPhoto: Data?
    let initialPlateID: String?
    let foodSubject: () async throws -> Data
    let onApply: (PlateOption?, Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HomePlate.addedAt, order: .reverse) private var homePlates: [HomePlate]
    @State private var selectedID: String?
    @State private var subject: Data?
    @State private var working = false
    @State private var failed = false
    @State private var addingPlate = false
    @State private var attempt = 0
    @State private var compositionError = false

    init(original: Data, currentPhoto: Data?, initialPlateID: String?,
         foodSubject: @escaping () async throws -> Data, onApply: @escaping (PlateOption?, Data) -> Void) {
        self.original = original
        self.currentPhoto = currentPhoto
        self.initialPlateID = initialPlateID
        self.foodSubject = foodSubject
        self.onApply = onApply
        _selectedID = State(initialValue: initialPlateID)
    }

    private var custom: [PlateOption] {
        homePlates.enumerated().map { PlateOption(plate: $0.element, number: homePlates.count - $0.offset) }
    }

    private var selectedPlate: PlateOption? {
        custom.first { $0.id == selectedID } ?? selectedID.flatMap(PlateOption.resolve)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let selectedPlate, let subject {
                            PlatedFoodPreview(subject: subject, plate: selectedPlate)
                        } else {
                            MealPhoto(data: selectedID != nil && selectedID == initialPlateID ? currentPhoto ?? original : original,
                                      size: 680, contentMode: .fit)
                        }
                    }
                    .frame(width: 156, height: 156)
                    .frame(maxWidth: .infinity)
                    if working { ProgressView("料理を切り抜いています") }
                    if failed {
                        Text("料理を切り抜けませんでした。元の写真に戻すこともできます。")
                            .font(.footnote)
                        HStack {
                            Button("もう一度試す") { CrumbHaptics.tap(); attempt += 1 }
                            Button("写真をそのまま盛る") { CrumbHaptics.tap();
                                subject = try? PlatingImage.crop(original, shape: "角丸", rim: .clear)
                                failed = subject == nil
                            }
                        }
                    }
                    Button { CrumbHaptics.tap();
                        if selectedID != nil { CrumbHaptics.selection() }
                        selectedID = nil
                    } label: {
                        Label("なし", systemImage: selectedID == nil ? "checkmark.circle.fill" : "photo")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.white, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Text("マイお皿").font(.headline)
                    LazyVGrid(columns: columns, spacing: 10) {
                        Button { CrumbHaptics.tap(); CrumbHaptics.add(); addingPlate = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("お皿を追加").font(.caption2)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(.white, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(subject == nil)
                        ForEach(custom) { plateTile($0) }
                    }
                    Text("標準のお皿").font(.headline)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(PlateOption.standard) { plateTile($0) }
                    }
                }
                .padding(18)
            }
            .background(paper.ignoresSafeArea())
            .navigationTitle("お皿を変える")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { CrumbHaptics.tap(); dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button(LocalizedStringKey(selectedID == nil ? "お皿なしにする" : "このお皿にする")) { CrumbHaptics.tap();
                    if selectedID == nil {
                        onApply(nil, original)
                    } else if let selectedPlate, let subject {
                        do {
                            let result = try PlateRendering.compose(food: subject, on: selectedPlate)
                            onApply(selectedPlate, result)
                        } catch {
                            compositionError = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedID != nil && (subject == nil || selectedPlate == nil))
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(paper)
            }
            .navigationDestination(isPresented: $addingPlate) {
                if let subject {
                    HomePlateEditor(food: subject, onCancel: { dismiss() }) { plate, photo in
                        onApply(plate, photo)
                    }
                }
            }
            .alert("盛り付けを反映できませんでした", isPresented: $compositionError) {
                Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
            }
            .task(id: attempt) {
                working = true
                failed = false
                defer { working = false }
                do { subject = try await foodSubject() }
                catch { if !Task.isCancelled { failed = true } }
            }
        }
    }

    private func plateTile(_ plate: PlateOption) -> some View {
        Button { CrumbHaptics.tap();
            guard selectedID != plate.id else { return }
            CrumbHaptics.selection()
            selectedID = plate.id
        } label: {
            MealPhoto(data: plate.photo, size: 160, contentMode: .fit)
                .aspectRatio(1, contentMode: .fit)
                .padding(4)
                .background(.white, in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selectedID == plate.id ? ink : ink.opacity(0.08), lineWidth: selectedID == plate.id ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppLanguage.text(plate.name)))
        .accessibilityAddTraits(selectedID == plate.id ? .isSelected : [])
    }
}

struct PlatedFoodPreview: View {
    let subject: Data
    let plate: PlateOption

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            if let food = UIImage(data: subject) {
                ZStack {
                    MealPhoto(data: plate.photo, size: 620, contentMode: .fit)
                    Image(uiImage: food).resizable().scaledToFit()
                        .frame(width: side * plate.placement.scale, height: side * plate.placement.scale)
                        .offset(x: side * plate.placement.x, y: side * plate.placement.y)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

enum PlateRendering {
    @MainActor static func compose(food: Data, on plate: PlateOption) throws -> Data {
        guard let food = UIImage(data: food), let backdrop = UIImage(data: plate.photo) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side: CGFloat = 900
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
            backdrop.draw(in: fitted(backdrop.size, inside: side, center: CGPoint(x: side / 2, y: side / 2)))
            let placement = plate.placement
            food.draw(in: fitted(food.size, inside: side * placement.scale,
                                 center: CGPoint(x: side * (0.5 + placement.x), y: side * (0.5 + placement.y))))
        }
    }

    @MainActor static func normalize(_ image: UIImage) -> Data {
        let side: CGFloat = 1200
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
            image.draw(in: fitted(image.size, inside: 1073, center: CGPoint(x: side / 2, y: side / 2)))
        }
    }

    private static func fitted(_ size: CGSize, inside side: CGFloat, center: CGPoint) -> CGRect {
        let scale = side / max(size.width, size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}
