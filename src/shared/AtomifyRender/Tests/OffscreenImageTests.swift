import CoreGraphics
import ImageIO
import Metal
import simd
import XCTest
@testable import AtomifyRender

final class OffscreenImageTests: XCTestCase {
    /// RGBA8 pixels of `image`, top row first.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> SIMD4<UInt8> {
        let i = (y * width + x) * 4
        return SIMD4(data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    private func solid(_ color: CGColor, width: Int, height: Int, alpha: Bool) throws -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: info.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
    }

    func testPixelRectScalesAndRounds() {
        XCTAssertEqual(OffscreenImage.pixelRect(windowRect: CGRect(x: -160, y: 0, width: 1440, height: 900), scale: 2),
                       CGRect(x: -320, y: 0, width: 2880, height: 1800))
        XCTAssertEqual(OffscreenImage.pixelRect(windowRect: CGRect(x: 0.3, y: 10.26, width: 99.8, height: 50.2),
                                                scale: 2),
                       CGRect(x: 1, y: 21, width: 200, height: 100))
    }

    func testCompositeIsOpaqueAndLayersInOrder() throws {
        // A red layer in the bottom-left quarter, then a half-transparent
        // white overlay over everything, on a blue background.
        let layer = try solid(srgb(1, 0, 0), width: 2, height: 2, alpha: false)
        let overlay = try solid(srgb(0.5, 0.5, 0.5, 0.5), width: 4, height: 4, alpha: true)
        let image = try OffscreenImage.composite(size: CGSize(width: 4, height: 4), background: srgb(0, 0, 1),
                                                 layers: [(layer, CGRect(x: 0, y: 0, width: 2, height: 2))],
                                                 overlay: overlay)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 4)
        XCTAssertEqual(image.alphaInfo, .noneSkipLast)
        let data = try pixels(image)
        // Bottom left (last rows, top row first): red under the overlay.
        let red = pixel(data, width: 4, x: 0, y: 3)
        XCTAssertEqual(Int(red.x), 255 / 2 + 64, accuracy: 3)
        XCTAssertEqual(Int(red.z), 64, accuracy: 3)
        // Top right: blue under the overlay.
        let blue = pixel(data, width: 4, x: 3, y: 0)
        XCTAssertEqual(Int(blue.x), 64, accuracy: 3)
        XCTAssertEqual(Int(blue.z), 255 / 2 + 64, accuracy: 3)
        XCTAssertEqual(blue.w, 255)
    }

    func testCompositeWithoutOverlayAndEmptySize() throws {
        let image = try OffscreenImage.composite(size: CGSize(width: 2, height: 1), background: srgb(0, 1, 0),
                                                 layers: [], overlay: nil)
        XCTAssertEqual(pixel(try pixels(image), width: 2, x: 1, y: 0), SIMD4(0, 255, 0, 255))
        XCTAssertThrowsError(try OffscreenImage.composite(size: .zero, background: srgb(0, 0, 0), layers: [],
                                                          overlay: nil))
    }

    func testPNGRoundTrips() throws {
        let image = try OffscreenImage.composite(size: CGSize(width: 3, height: 2), background: srgb(1, 1, 1),
                                                 layers: [], overlay: nil)
        let data = try OffscreenImage.png(image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertFalse([.first, .last, .premultipliedFirst, .premultipliedLast].contains(decoded.alphaInfo))
    }

    func testRenderDrawsTheSceneAtTheViewsPixelSize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let red = ParticleStyle(radius: 1, color: SIMD4(1, 0, 0, 1))
        let scene = SceneData(particles: ParticleData(positions: [SIMD3(0, 0, 0)], styleIndices: [0], styles: [red]))
        var settings = RenderSettings()
        settings.background = SIMD4(0, 0, 0, 1)
        let image = try OffscreenImage.render(scene: scene, camera: OrbitCamera(distance: 5), settings: settings,
                                              pointSize: CGSize(width: 32, height: 24), scale: 2, device: device)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        let data = try pixels(image)
        let center = pixel(data, width: 64, x: 32, y: 24)
        XCTAssertGreaterThan(center.x, 60, "red sphere in the middle: \(center)")
        XCTAssertEqual(pixel(data, width: 64, x: 1, y: 1), SIMD4(0, 0, 0, 255), "background in the corner")
    }

    func testRenderRejectsAnEmptySizeAndAMissingDevice() {
        let scene = SceneData(particles: ParticleData(positions: [], styleIndices: [], styles: []))
        XCTAssertThrowsError(try OffscreenImage.render(scene: scene, camera: OrbitCamera(), settings: RenderSettings(),
                                                       pointSize: .zero, scale: 2))
        XCTAssertThrowsError(try OffscreenImage.render(scene: scene, camera: OrbitCamera(), settings: RenderSettings(),
                                                       pointSize: CGSize(width: 1, height: 1), scale: 1,
                                                       device: nil)) { error in
            XCTAssertEqual((error as? OffscreenImage.Failure)?.description, "No Metal device")
        }
    }
}
