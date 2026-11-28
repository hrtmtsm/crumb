import UIKit

/// Reads individual cutouts from the supplied sheets while preserving their original artwork.
enum AtlasTexture {
    static func image(_ source: String, rect: CGRect) -> UIImage? {
        guard let url = Bundle.main.url(forResource: source, withExtension: "png"),
              let source = UIImage(contentsOfFile: url.path)?.cgImage,
              let crop = source.cropping(to: rect), let image = isolate(crop) else { return nil }
        return UIImage(cgImage: image)
    }

    // Atlas rectangles can include a few pixels of the neighboring dish. Retain the largest
    // connected alpha silhouette instead of clipping the handmade rim to a perfect circle.
    static func isolate(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height, count = width * height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        var visited = [Bool](repeating: false, count: count)
        var largest: [Int] = []
        for start in 0..<count where !visited[start] && bytes[start * 4 + 3] > 8 {
            var component = [start], cursor = 0
            visited[start] = true
            while cursor < component.count {
                let pixel = component[cursor]; cursor += 1
                let x = pixel % width
                let neighbors = [x > 0 ? pixel - 1 : -1, x + 1 < width ? pixel + 1 : -1, pixel - width, pixel + width]
                for next in neighbors where next >= 0 && next < count && !visited[next] && bytes[next * 4 + 3] > 8 {
                    visited[next] = true; component.append(next)
                }
            }
            if component.count > largest.count { largest = component }
        }
        guard !largest.isEmpty else { return nil }
        var retained = [Bool](repeating: false, count: count)
        for pixel in largest { retained[pixel] = true }
        for pixel in 0..<count where !retained[pixel] {
            for channel in 0..<4 { bytes[pixel * 4 + channel] = 0 }
        }
        return context.makeImage()
    }

}
