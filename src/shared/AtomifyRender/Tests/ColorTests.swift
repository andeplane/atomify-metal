import simd
import XCTest
@testable import AtomifyRender

final class ColorTests: XCTestCase {
    func testSrgbToLinear() {
        XCTAssertEqual(srgbToLinear(0), 0)
        XCTAssertEqual(srgbToLinear(1), 1, accuracy: 1e-6)
        XCTAssertEqual(srgbToLinear(0.5), 0.21404, accuracy: 1e-4)
        XCTAssertEqual(srgbToLinear(0.04), 0.04 / 12.92, accuracy: 1e-7)
        XCTAssertEqual(srgbToLinear(SIMD3(0, 0.5, 1)), SIMD3(0, srgbToLinear(0.5), srgbToLinear(1)))
    }

    func testLinearToSrgbRoundTrip() {
        for v: Float in stride(from: 0, through: 1, by: 0.05) {
            XCTAssertEqual(linearToSrgb(srgbToLinear(v)), v, accuracy: 1e-5)
        }
        XCTAssertEqual(linearToSrgb(-1), 0)
        XCTAssertEqual(linearToSrgb(2), 1, accuracy: 1e-6)
        XCTAssertEqual(linearToSrgb(0.002), 0.002 * 12.92, accuracy: 1e-7)
        let c = SIMD3<Float>(0.1, 0.5, 0.9)
        XCTAssertLessThan(simd_length(srgbToLinear(linearToSrgb(c)) - c), 1e-5)
    }

    func testHexColors() {
        XCTAssertEqual(srgbColor(hex: 0xFF8000), SIMD3(1, 128.0 / 255, 0))
        XCTAssertLessThan(simd_length(linearColor(hex: 0xFFFFFF, alpha: 0.5) - SIMD4(1, 1, 1, 0.5)), 1e-6)
        XCTAssertEqual(linearColor(srgb: SIMD3(0.5, 0, 1)).x, 0.21404, accuracy: 1e-4)
    }

    func testColormapEndpoints() {
        func hexLinear(_ hex: UInt32) -> SIMD4<Float> { linearColor(hex: hex) }
        XCTAssertLessThan(simd_length(Colormap.viridis.color(at: 0) - hexLinear(0x440154)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.viridis.color(at: 1) - hexLinear(0xFDE725)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.plasma.color(at: 0) - hexLinear(0x0D0887)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.plasma.color(at: 1) - hexLinear(0xF0F921)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.inferno.color(at: 0) - hexLinear(0x000004)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.inferno.color(at: 1) - hexLinear(0xFCFFA4)), 1e-5)
        XCTAssertEqual(Colormap.grayscale.color(at: 0), SIMD4(0, 0, 0, 1))
        XCTAssertEqual(Colormap.grayscale.color(at: 1), SIMD4(1, 1, 1, 1))
        XCTAssertLessThan(simd_length(Colormap.coolwarm.srgbColor(at: 0.5) - SIMD3(repeating: 221.0 / 255)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.jet.srgbColor(at: 0) - SIMD3(0, 0, 131.0 / 255)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.jet.srgbColor(at: 0.375) - SIMD3(5.0 / 255, 1, 1)), 1e-5)
        XCTAssertLessThan(simd_length(Colormap.jet.srgbColor(at: 1) - SIMD3(128.0 / 255, 0, 0)), 1e-5)
    }

    func testColormapInterpolatesAndClamps() {
        XCTAssertEqual(Colormap.grayscale.srgbColor(at: 0.25), SIMD3(repeating: 0.25))
        XCTAssertEqual(Colormap.grayscale.color(at: -3), Colormap.grayscale.color(at: 0))
        XCTAssertEqual(Colormap.grayscale.color(at: 7), Colormap.grayscale.color(at: 1))
        XCTAssertEqual(Colormap.viridis.color(at: .nan), Colormap.viridis.color(at: 0))
        // Halfway between jet's first two stops.
        let mid = Colormap.jet.srgbColor(at: 0.0625)
        XCTAssertEqual(mid.y, 30.0 / 255, accuracy: 1e-5)
        // Luminance of viridis grows monotonically.
        var last: Float = -1
        for t in stride(from: Float(0), through: 1, by: 0.05) {
            let c = Colormap.viridis.color(at: t)
            let luminance = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            XCTAssertGreaterThan(luminance, last)
            last = luminance
        }
    }

    func testEveryColormapIsValid() {
        for map in Colormap.allCases {
            XCTAssertEqual(Colormap(rawValue: map.rawValue), map)
            for t in stride(from: Float(0), through: 1, by: 0.01) {
                let c = map.color(at: t)
                XCTAssertTrue(c.x >= 0 && c.x <= 1 && c.y >= 0 && c.y <= 1 && c.z >= 0 && c.z <= 1, "\(map) \(t)")
                XCTAssertEqual(c.w, 1)
            }
        }
        XCTAssertEqual(Colormap.allCases.count, 5)
    }

    func testTableAndRange() {
        XCTAssertEqual(Colormap.jet.table(count: 0), [])
        XCTAssertEqual(Colormap.jet.table(count: 1), [Colormap.jet.color(at: 0)])
        let table = Colormap.plasma.table(count: 5)
        XCTAssertEqual(table.count, 5)
        XCTAssertEqual(table[2], Colormap.plasma.color(at: 0.5))
        XCTAssertEqual(Colormap.viridis.color(for: 15, in: 10...20), Colormap.viridis.color(at: 0.5))
        XCTAssertEqual(Colormap.viridis.color(for: 3, in: 5...5), Colormap.viridis.color(at: 0.5))
    }
}
