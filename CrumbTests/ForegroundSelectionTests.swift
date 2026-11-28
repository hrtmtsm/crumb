import XCTest
import CoreImage
import ImageIO
@testable import crumb

final class ForegroundSelectionTests: XCTestCase {
    func testCentralDishKeepsChopsticksAndExcludesOtherDishes() {
        let objects: [ForegroundSelection.Object] = [
            .init(id: 1, pixels: 12000, bounds: CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.4)),
            .init(id: 2, pixels: 900, bounds: CGRect(x: 0.65, y: 0.15, width: 0.07, height: 0.5)),
            .init(id: 3, pixels: 17000, bounds: CGRect(x: 0, y: 0, width: 0.3, height: 0.25)),
            .init(id: 4, pixels: 800, bounds: CGRect(x: 0.85, y: 0.85, width: 0.1, height: 0.1))
        ]
        XCTAssertEqual(ForegroundSelection.choose(objects), IndexSet([1, 2]))
    }
    func testOffCenterSubjectAndEmptyMask() {
        XCTAssertEqual(ForegroundSelection.choose([]), [])
        let object = ForegroundSelection.Object(id: 5, pixels: 4000, bounds: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(ForegroundSelection.choose([object]), IndexSet(integer: 5))
    }
    func testSoftEdgeAlphaIsNotAppliedTwice() throws {
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        let mask = CIImage(bitmapData: Data(repeating: 128, count: 64), bytesPerRow: 8,
                           size: bounds.size, format: .L8, colorSpace: nil)
        let result = PlatingImage.maskedForeground(source: source, mask: mask)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(result, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        XCTAssertEqual(Int(pixel[3]), 128, accuracy: 3, "A 50% edge must remain 50%, not the previous 25%")
        let crop = try PlatingImage.cutoutBounds(mask: mask, context: context)
        XCTAssertEqual(crop, bounds)
    }
    func testPlateEdgeHasSoftTransitionAndOpaqueInterior() {
        let size = 32
        var bytes = [UInt8](repeating: 0, count: size * size)
        for y in 8..<24 { for x in 8..<24 { bytes[y * size + x] = 255 } }
        let mask = CIImage(bitmapData: Data(bytes), bytesPerRow: size,
                           size: CGSize(width: size, height: size), format: .L8, colorSpace: nil)
        let refined = PlatingImage.plateEdgeMask(mask)
        var result = [UInt8](repeating: 0, count: bytes.count)
        result.withUnsafeMutableBytes {
            CIContext(options: [.useSoftwareRenderer: true]).render(refined, toBitmap: $0.baseAddress!,
                rowBytes: size, bounds: mask.extent, format: .L8, colorSpace: nil)
        }
        XCTAssertEqual(refined.extent, mask.extent)
        XCTAssertEqual(result[16 * size + 16], 255)
        XCTAssertEqual(result[0], 0)
        XCTAssertGreaterThan(result[16 * size + 7], 0)
        XCTAssertLessThan(result[16 * size + 8], 255)
    }

    func testRealFoodPhotoOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Photo segmentation quality must be checked on a physical iPhone; simulator mask tests cover edge alpha separately.")
        #else
        let url = try XCTUnwrap(Bundle.main.url(forResource: "carbonara", withExtension: "jpg"))
        let bytes = try PlatingImage.foreground(from: Data(contentsOf: url), subjectPoint: nil)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(image.width, 100)
        XCTAssertGreaterThan(image.height, 100)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo))
        #endif
    }

}
