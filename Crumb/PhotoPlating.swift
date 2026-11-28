import SwiftUI
import SwiftData
import PhotosUI
import Vision
import CoreImage
import ImageIO

@Model
final class HomePlate {
    @Attribute(.externalStorage) var photo: Data
    var addedAt = Date()
    var identifier: UUID?
    var foodX: Double?
    var foodY: Double?
    var foodScale: Double?

    init(photo: Data) { self.photo = photo }
}

struct PhotoPlating: View {
    let original: Data
    @Binding var photo: Data?
    @Binding var working: Bool
    @Binding var plateID: String?
    @Binding var framing: String?
    init(original: Data, photo: Binding<Data?>, working: Binding<Bool>, plateID: Binding<String?>, framing: Binding<String?>) {
        self.original = original; self._photo = photo; self._working = working
        self._plateID = plateID; self._framing = framing
        let saved = PhotoFrame.decode(framing.wrappedValue)
        let restored = Mode(rawValue: saved?.shape ?? "") ?? .original
        _mode = State(initialValue: restored == .plate ? .original : restored)
        _removeBackground = State(initialValue: restored == .outline)
    }
    @State private var applyingPlate = false
    @State private var showingPlatePicker = false
    @State private var mode: Mode = .original
    @State private var removeBackground = false
    @State private var cutout: Data?
    @Query(sort: \HomePlate.addedAt, order: .reverse) private var homePlates: [HomePlate]

    @State private var error: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case original = "そのまま"
        case outline = "背景削除"
        case circle = "丸"
        case diamond = "ひし形"
        case square = "角丸"
        case oval = "楕円"
        case flower = "花形"
        case scallop = "波形"
        case hexagon = "六角形"
        case plate = "お皿に盛る"
        var id: Self { self }
    }

    private struct PreviewChoice: Equatable {
        let mode: Mode
        let plateID: String?
        let removeBackground: Bool
        let framing: String?
    }

    private var selectedPlate: PlateOption? {
        guard let plateID else { return nil }
        if let plate = PlateOption.resolve(plateID) { return plate }
        guard let index = homePlates.firstIndex(where: {
            ($0.identifier?.uuidString ?? "legacy-\($0.persistentModelID)") == plateID
        }) else { return nil }
        return PlateOption(plate: homePlates[index], number: homePlates.count - index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MealEditorLayout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("形").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        shapeButton(.original, icon: "photo")
                        shapeButton(.outline, icon: "scissors")
                        shapeButton(.circle, icon: "circle")
                        shapeButton(.flower, icon: "flower")
                        shapeButton(.diamond, icon: "diamond")
                        shapeButton(.scallop, icon: "waveform")
                        shapeButton(.hexagon, icon: "hexagon")
                        shapeButton(.square, icon: "square")
                    }
                }
                .scrollIndicators(.hidden)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("お皿").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("もっと見る", systemImage: "chevron.right") { CrumbHaptics.tap();
                        showingPlatePicker = true
                    }
                    .font(.subheadline)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        plateTile(nil)
                        ForEach(quickPlates) { plate in
                            plateTile(plate)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let error {
                Text(AppLanguage.text(error)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(working || applyingPlate)
        .sheet(isPresented: $showingPlatePicker) {
            PlatePicker(original: original, currentPhoto: photo, initialPlateID: plateID,
                        foodSubject: { try await shapedImage() }) { plate, result in
                plateID = plate?.id
                photo = result
                error = nil
                showingPlatePicker = false
            }
        }
        .task(id: PreviewChoice(mode: mode, plateID: plateID, removeBackground: removeBackground, framing: framing)) { await renderPreview() }
    }

    private var quickPlates: [PlateOption] {
        var plates = homePlates.prefix(2).enumerated().map {
            PlateOption(plate: $0.element, number: homePlates.count - $0.offset)
        } + Array(PlateOption.standard.prefix(6))
        if let selectedPlate, !plates.contains(where: { $0.id == selectedPlate.id }) {
            plates.insert(selectedPlate, at: 0)
        }
        return plates
    }

    private func plateTile(_ plate: PlateOption?) -> some View {
        let selected = plateID == plate?.id
        return Button { CrumbHaptics.tap();
            guard !selected else { return }
            CrumbHaptics.selection()
            plateID = plate?.id
            error = nil
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let plate, let image = PlatingImage.thumbnail(plate.photo, size: 120) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: "xmark").font(.title3)
                    }
                }
                .frame(width: 58, height: 58)
                .background(ink.opacity(0.025), in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(ink.opacity(selected ? 1 : 0.13))
                }
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppLanguage.text(plate?.name ?? "お皿なし")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shapeButton(_ shape: Mode, icon: String) -> some View {
        Button { CrumbHaptics.tap();
            guard mode != shape else { return }
            CrumbHaptics.selection()
            mode = shape
            removeBackground = shape == .outline
            if shape == .original { framing = nil }
            working = shape != .original
        } label: {
            VStack(spacing: 5) {
                Group {
                    if shape == .original || shape == .outline {
                        Image(systemName: icon).font(.title3.weight(.regular))
                    } else {
                        let path = Path(PlatingImage.shapePath(shape.rawValue, in: CGRect(x: 0, y: 0, width: 34, height: 34)).cgPath)
                        path.stroke(ink.opacity(0.55), lineWidth: 1.1)
                            .frame(width: 34, height: 34)
                    }
                }
                    .frame(width: 58, height: 58)
                    .background(ink.opacity(0.025), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(mode == shape
                                          ? ink : ink.opacity(0.13))
                    }
                Text(LocalizedStringKey(shape.rawValue)).font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 68, height: 30, alignment: .top)
            }
            .frame(width: 68, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == shape ? .isSelected : [])
    }

    @MainActor private func renderPreview() async {
        error = nil; working = true
        defer { working = false }
        do {
            let image = try await shapedImage()
            try Task.checkCancellation()
            if let selectedPlate {
                photo = try PlateRendering.compose(food: image, on: selectedPlate)
            } else { photo = image }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "写真を加工できませんでした。別の写真か「そのまま」でお試しください。"
        }
    }

    @MainActor private func shapedImage() async throws -> Data {
        var frame = PhotoFrame.decode(framing) ?? PhotoFrame(shape: mode.rawValue, rim: "なし")
        frame.shape = mode.rawValue; frame.rim = "なし"
        frame.backgroundRemoved = mode == .outline
        let image: Data
        if mode == .outline {
            let subject = try await loadSubject()
            try Task.checkCancellation()
            image = try PlatingImage.compose(subject, rim: .clear)
        } else if mode == .original || mode == .plate {
            image = original
        } else {
            image = try PlatingImage.crop(original, shape: mode.rawValue, rim: .clear, frame: frame)
        }
        if framing != frame.encoded { framing = frame.encoded }
        return image
    }

    @MainActor private func loadSubject() async throws -> Data {
        if let cutout { return cutout }
        let source = original
        let result = try await Task.detached(priority: .userInitiated) {
            try PlatingImage.foreground(from: source, subjectPoint: nil)
        }.value
        try Task.checkCancellation()
        cutout = result
        return result
    }
}

enum PlatingImage {
    static func thumbnail(_ data: Data, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ] as CFDictionary)
    }

    static func foreground(from data: Data, subjectPoint: CGPoint?) throws -> Data {
        guard let photo = thumbnail(data, size: 2400) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: photo)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let instances = try substantialInstances(in: observation, subjectPoint: subjectPoint, primaryOnly: true)
        let buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        try Task.checkCancellation()
        let source = CIImage(cgImage: photo)
        // A matte is coverage, not a photograph: bypass color-space gamma on its gray values.
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]).cropped(to: source.extent)
        let context = CIContext()
        let foreground = maskedForeground(source: source, mask: mask)
        let bounds = try cutoutBounds(mask: mask, context: context)
        guard let result = context.createCGImage(foreground, from: bounds),
              let png = UIImage(cgImage: result).pngData() else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    // Apply Vision's high-resolution mask once to original colors. Masking an already masked
    // image squares its alpha and eats fine edges, chopsticks and pale ceramic rims.
    static func maskedForeground(source: CIImage, mask: CIImage) -> CIImage {
        source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent)
        ])
    }

    static func cutoutBounds(mask: CIImage, context: CIContext) throws -> CGRect {
        guard let image = context.createCGImage(mask, from: mask.extent, format: .L8,
                                               colorSpace: CGColorSpaceCreateDeviceGray()),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = image.width, height = image.height, stride = image.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * stride + x] > 4 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { throw CocoaError(.fileReadCorruptFile) }
        return CGRect(x: mask.extent.minX + CGFloat(minX) - 4,
                      y: mask.extent.minY + CGFloat(height - 1 - maxY) - 4,
                      width: CGFloat(maxX - minX + 9), height: CGFloat(maxY - minY + 9))
            .intersection(mask.extent).integral
    }

    static func plateForeground(from data: Data) throws -> Data {
        guard let original = thumbnail(data, size: 2400) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: original)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let instances = try substantialInstances(in: observation, subjectPoint: nil, primaryOnly: true)
        let buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        try Task.checkCancellation()
        let width = original.width, height = original.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let ciContext = CIContext()
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]).cropped(to: bounds)
        var alpha = [UInt8](repeating: 0, count: width * height)
        alpha.withUnsafeMutableBytes {
            ciContext.render(mask, toBitmap: $0.baseAddress!, rowBytes: width, bounds: bounds,
                             format: .L8, colorSpace: nil)
        }

        // Flood-fill transparent pixels connected to the edge to distinguish the table from holes inside the plate.
        var outside = [Bool](repeating: false, count: alpha.count)
        var queue: [Int] = []
        func visit(_ index: Int) {
            guard !outside[index], alpha[index] < 72 else { return }
            outside[index] = true
            queue.append(index)
        }
        for x in 0..<width { visit(x); visit((height - 1) * width + x) }
        for y in 0..<height { visit(y * width); visit(y * width + width - 1) }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            if index % width > 0 { visit(index - 1) }
            if index % width < width - 1 { visit(index + 1) }
            if index >= width { visit(index - width) }
            if index < alpha.count - width { visit(index + width) }
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for index in alpha.indices where !outside[index] {
            let x = index % width
            let y = index / width
            if alpha[index] == 0 { alpha[index] = 255 }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        guard maxX >= minX, maxY >= minY, !queue.isEmpty,
              let provider = CGDataProvider(data: Data(alpha) as CFData),
              let matte = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
        let source = CIImage(cgImage: original)
        let cutout = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: plateEdgeMask(CIImage(cgImage: matte, options: [.colorSpace: NSNull()])),
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds)
        ])
        let rect = CGRect(x: minX - 2, y: height - 1 - maxY - 2,
                          width: maxX - minX + 5, height: maxY - minY + 5).intersection(bounds)
        guard let image = ciContext.createCGImage(cutout, from: rect),
              let png = UIImage(cgImage: image).pngData() else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    // Subpixel feathering reduces staircase edges without blurring the ceramic texture.
    static func plateEdgeMask(_ mask: CIImage) -> CIImage {
        mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
            .cropped(to: mask.extent)
    }

    private static func substantialInstances(in observation: VNInstanceMaskObservation, subjectPoint: CGPoint?, primaryOnly: Bool = false) throws -> IndexSet {
        let mask = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else {
            return observation.allInstances
        }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else {
            return observation.allInstances
        }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        if let point = subjectPoint, width > 0, height > 0 {
            let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
            let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
            let label = Int(pixels[y * stride + x])
            guard observation.allInstances.contains(label) else { throw CocoaError(.fileReadCorruptFile) }
            return IndexSet(integer: label)
        }
        var area = Array(repeating: 0, count: 256)
        var bounds = Array(repeating: CGRect.null, count: 256)
        for y in 0..<height {
            for x in 0..<width {
                let label = Int(pixels[y * stride + x])
                area[label] += 1
                if primaryOnly && label != 0 {
                    bounds[label] = bounds[label].union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let supported = observation.allInstances.filter { $0 < area.count }
        if primaryOnly {
            let objects = supported.compactMap { label -> ForegroundSelection.Object? in
                guard area[label] > 0 else { return nil }
                let box = bounds[label]
                return .init(id: label, pixels: area[label],
                             bounds: CGRect(x: box.minX / CGFloat(width), y: box.minY / CGFloat(height),
                                            width: box.width / CGFloat(width), height: box.height / CGFloat(height)))
            }
            let selected = ForegroundSelection.choose(objects)
            guard !selected.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return selected
        }
        let largest = supported.map { area[$0] }.max() ?? 0
        guard largest > 0 else { return observation.allInstances }
        let minimumArea = max(1, min(largest / 30, width * height / 220))
        let retained = IndexSet(supported.filter { area[$0] >= minimumArea })
        return retained.isEmpty ? observation.allInstances : retained
    }

    static func shapePath(_ shape: String, in rect: CGRect) -> UIBezierPath {
        switch shape {
        case "ひし形":
            let side = rect.width * 0.72
            let path = UIBezierPath(roundedRect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side),
                                    cornerRadius: side * 0.18)
            path.apply(CGAffineTransform(rotationAngle: .pi / 4)
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
            return path
        case "角丸":
            return UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.16)
        case "楕円":
            return UIBezierPath(ovalIn: rect.insetBy(dx: 0, dy: rect.height * 0.15))
        case "花形", "波形", "六角形":
            let hexagon = shape == "六角形"
            let lobes = shape == "花形" ? 8.0 : 12.0
            let amplitude = shape == "花形" ? 0.11 : 0.045
            let samples = hexagon ? 6 : 144
            let path = UIBezierPath()
            for index in 0..<samples {
                let angle = Double(index) / Double(samples) * 2 * .pi - .pi / 2
                let scale = hexagon ? 1 : (1 - amplitude + amplitude * cos(angle * lobes))
                let radius = rect.width / 2 * scale
                let point = CGPoint(x: rect.midX + cos(angle) * radius,
                                    y: rect.midY + sin(angle) * radius)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close()
            path.lineJoinStyle = .round
            return path
        default:
            return UIBezierPath(ovalIn: rect)
        }
    }

    @MainActor static func crop(_ data: Data, shape: String, rim: UIColor, frame: PhotoFrame? = nil) throws -> Data {
        guard let image = thumbnail(data, size: 1100) else { throw CocoaError(.fileReadCorruptFile) }
        let source = UIImage(cgImage: image)
        let canvas = CGRect(x: 0, y: 0, width: 900, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sticker = UIGraphicsImageRenderer(size: canvas.size, format: format).image { drawing in
            let path = shapePath(shape, in: canvas.insetBy(dx: 45, dy: 45))
            drawing.cgContext.saveGState()
            path.addClip()
            let scale = 900 * CGFloat(min(5, max(1, frame?.zoom ?? 1))) / min(source.size.width, source.size.height)
            let width = source.size.width * scale
            let height = source.size.height * scale
            let x = min((width - 900) / 2, max(-(width - 900) / 2, CGFloat(frame?.x ?? 0) * 900))
            let y = min((height - 900) / 2, max(-(height - 900) / 2, CGFloat(frame?.y ?? 0) * 900))
            source.draw(in: CGRect(x: (900 - width) / 2 + x, y: (900 - height) / 2 + y,
                                   width: width, height: height))
            drawing.cgContext.restoreGState()
            rim.setStroke()
            path.lineWidth = 24
            path.lineJoinStyle = .round
            path.stroke()
        }
        return stickerPNG(sticker, canvas: canvas.size, shadow: rim.cgColor.alpha > 0)
    }

    @MainActor static func compose(_ data: Data, rim: UIColor) throws -> Data {
        guard let subject = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let canvas = CGRect(x: 0, y: 0, width: 900, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas.size, format: format)
        let scale = 740 / max(subject.size.width, subject.size.height)
        let width = subject.size.width * scale
        let height = subject.size.height * scale
        let foodBounds = CGRect(x: canvas.midX - width / 2, y: canvas.midY - height / 2, width: width, height: height)
        let sticker = renderer.image { _ in
            let silhouette = subject.withTintColor(rim, renderingMode: .alwaysOriginal)
            // Dense, overlapping silhouettes create a smooth sticker border.
            for index in 0..<64 {
                let angle = Double(index) * 2 * .pi / 64
                silhouette.draw(in: foodBounds.offsetBy(dx: cos(angle) * 22, dy: sin(angle) * 22))
            }
            subject.draw(in: foodBounds)
        }
        return stickerPNG(sticker, canvas: canvas.size, shadow: rim.cgColor.alpha > 0)
    }

    @MainActor private static func stickerPNG(_ image: UIImage, canvas: CGSize, shadow: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).pngData { drawing in
            if shadow {
                drawing.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 4,
                                            color: UIColor.black.withAlphaComponent(0.06).cgColor)
            }
            image.draw(in: CGRect(origin: .zero, size: canvas))
        }
    }
}
