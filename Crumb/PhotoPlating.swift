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
    @State private var applyingPlate = false
    @State private var showingPlatePicker = false
    @State private var mode: Mode = .original
    @State private var rim: Rim = .white
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

    private enum Rim: String, CaseIterable, Identifiable {
        case white = "白", black = "黒", cream = "クリーム", pink = "ピンク", blue = "水色", green = "ミント"

        var id: Self { self }
        var color: UIColor {
            switch self {
            case .white: .white
            case .black: UIColor(ink)
            case .cream: UIColor(red: 1, green: 0.91, blue: 0.72, alpha: 1)
            case .pink: UIColor(red: 1, green: 0.72, blue: 0.79, alpha: 1)
            case .blue: UIColor(red: 0.65, green: 0.82, blue: 1, alpha: 1)
            case .green: UIColor(red: 0.68, green: 0.87, blue: 0.76, alpha: 1)
            }
        }
    }

    private struct PreviewChoice: Equatable {
        let mode: Mode
        let rim: Rim
        let plateID: String?

    }

    private var selectedPlate: PlateOption? {
        guard let plateID else { return nil }
        if let plate = PlateOption.standard.first(where: { $0.id == plateID }) { return plate }
        guard let index = homePlates.firstIndex(where: {
            ($0.identifier?.uuidString ?? "legacy-\($0.persistentModelID)") == plateID
        }) else { return nil }
        return PlateOption(plate: homePlates[index], number: homePlates.count - index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                        shapeButton(.oval, icon: "oval")
                    }
                }
                .scrollIndicators(.hidden)
            }
            if mode != .original && mode != .plate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("縁の色").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Rim.allCases) { option in
                                Button {
                                    if rim != option { working = true; rim = option }
                                } label: {
                                    Circle().fill(Color(uiColor: option.color))
                                        .frame(width: 30, height: 30)
                                        .overlay { Circle().strokeBorder(ink.opacity(0.18)) }
                                        .padding(5)
                                        .overlay { Circle().strokeBorder(rim == option ? ink : .clear, lineWidth: 2) }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.rawValue)
                                .accessibilityAddTraits(rim == option ? .isSelected : [])
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("お皿").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("もっと見る", systemImage: "chevron.right") {
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
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(working || applyingPlate)
        .sheet(isPresented: $showingPlatePicker) {
            PlatePicker(original: original, currentPhoto: photo, initialPlateID: plateID,
                        foodSubject: { try await loadSubject() }) { plate, result in
                plateID = plate?.id
                mode = plate == nil ? .original : .plate
                photo = result
                error = nil
                showingPlatePicker = false
            }
        }
        .task(id: PreviewChoice(mode: mode, rim: rim, plateID: plateID)) { await renderPreview() }
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
        return Button {
            guard !selected else { return }
            if let plate {
                applyingPlate = true
                working = true
                Task {
                    defer { applyingPlate = false; working = false }
                    do {
                        let subject = try await loadSubject()
                        let result = try PlateRendering.compose(food: subject, on: plate)
                        plateID = plate.id
                        mode = .plate
                        photo = result
                        error = nil
                    } catch {
                        self.error = "お皿に盛り付けられませんでした。"
                    }
                }
            } else {
                plateID = nil
                mode = .original
                photo = original
                error = nil
            }
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
                Text(plate?.name ?? "なし").font(.caption2).lineLimit(1)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plate?.name ?? "なし")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shapeButton(_ shape: Mode, icon: String) -> some View {
        Button {
            guard mode != shape || shape == .original || plateID != nil else { return }
            plateID = nil
            mode = shape
            working = shape != .original
            if shape == .original { photo = original }
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
                            .strokeBorder(mode == shape && plateID == nil && (shape != .original || photo == original)
                                          ? ink : ink.opacity(0.13))
                    }
                Text(shape.rawValue).font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == shape ? .isSelected : [])
    }

    @MainActor private func renderPreview() async {
        working = false
        guard mode != .original, mode != .plate else { return }
        error = nil
        working = true
        do {
            if mode != .outline && mode != .plate {
                photo = try PlatingImage.crop(original, shape: mode.rawValue, rim: rim.color)
                working = false
                return
            }
            let subject = try await loadSubject()
            try Task.checkCancellation()
            photo = try PlatingImage.compose(subject, rim: rim.color)
            working = false
        } catch {
            guard !Task.isCancelled else { return }
            working = false
            photo = original
            self.error = "料理を切り抜けませんでした。「そのまま」で続けるか、別の写真をお試しください。"
        }
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
        guard let photo = thumbnail(data, size: 2000) else { throw CocoaError(.fileReadCorruptFile) }
        let handler = VNImageRequestHandler(cgImage: photo)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let instances = try substantialInstances(in: observation, subjectPoint: subjectPoint)
        let buffer = try observation.generateMaskedImage(ofInstances: instances,
                                                         from: handler, croppedToInstancesExtent: true)
        let image = CIImage(cvPixelBuffer: buffer)
        // Smooth only the alpha edge so the color and texture of the food stay sharp.
        let alpha = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let edgeMask = alpha.clampedToExtent()
            .applyingFilter("CIMedianFilter")
            .applyingGaussianBlur(sigma: 0.7)
            .cropped(to: image.extent)
        let foreground = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: edgeMask,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent)
        ])
        guard let result = CIContext().createCGImage(foreground, from: image.extent),
              let png = UIImage(cgImage: result).pngData() else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    static func plateForeground(from data: Data) throws -> Data {
        guard let original = thumbnail(data, size: 1000) else { throw CocoaError(.fileReadCorruptFile) }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: original)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let instances = try substantialInstances(in: observation, subjectPoint: nil)
        let buffer = try observation.generateMaskedImage(ofInstances: instances, from: handler,
                                                         croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        let ciContext = CIContext()
        guard let maskImage = ciContext.createCGImage(masked, from: masked.extent) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = original.width
        let height = original.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let readMask = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(maskImage, in: bounds)
            return true
        }
        guard readMask else { throw CocoaError(.fileReadCorruptFile) }
        var alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }

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
            if alpha[index] < 72 { alpha[index] = 255 }
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
            kCIInputMaskImageKey: CIImage(cgImage: matte),
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds)
        ])
        let rect = CGRect(x: minX - 2, y: height - 1 - maxY - 2,
                          width: maxX - minX + 5, height: maxY - minY + 5).intersection(bounds)
        guard let image = ciContext.createCGImage(cutout, from: rect),
              let png = UIImage(cgImage: image).pngData() else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    private static func substantialInstances(in observation: VNInstanceMaskObservation, subjectPoint: CGPoint?) throws -> IndexSet {
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
        for y in 0..<height {
            for x in 0..<width { area[Int(pixels[y * stride + x])] += 1 }
        }
        let supported = observation.allInstances.filter { $0 < area.count }
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

    @MainActor static func crop(_ data: Data, shape: String, rim: UIColor) throws -> Data {
        guard let image = thumbnail(data, size: 1100) else { throw CocoaError(.fileReadCorruptFile) }
        let source = UIImage(cgImage: image)
        let canvas = CGRect(x: 0, y: 0, width: 900, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvas.size, format: format).pngData { drawing in
            let path = shapePath(shape, in: canvas.insetBy(dx: 45, dy: 45))
            drawing.cgContext.saveGState()
            path.addClip()
            let scale = 900 / min(source.size.width, source.size.height)
            let width = source.size.width * scale
            let height = source.size.height * scale
            source.draw(in: CGRect(x: (900 - width) / 2, y: (900 - height) / 2,
                                   width: width, height: height))
            drawing.cgContext.restoreGState()
            rim.setStroke()
            path.lineWidth = 18
            path.stroke()
        }
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
        return renderer.pngData { _ in
            let silhouette = subject.withTintColor(rim, renderingMode: .alwaysOriginal)
            for index in 0..<32 {
                let angle = Double(index) * 2 * .pi / 32
                silhouette.draw(in: foodBounds.offsetBy(dx: cos(angle) * 20, dy: sin(angle) * 20))
            }
            subject.draw(in: foodBounds)
        }
    }
}
