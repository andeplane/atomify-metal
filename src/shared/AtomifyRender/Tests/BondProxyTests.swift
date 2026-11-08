import simd
import XCTest
@testable import AtomifyRender

final class BondProxyTests: XCTestCase {
    func testVisibleSpanStartsWhereTheCylinderLeavesEachSphere() throws {
        let span = try XCTUnwrap(BondProxy.visibleSpan(length: 2, radiusA: 0.5, radiusB: 0.3, bondRadius: 0.3))
        XCTAssertEqual(span.lowerBound, 0.4, accuracy: 1e-6)    // sqrt(0.5² − 0.3²)
        XCTAssertEqual(span.upperBound, 2, accuracy: 1e-6)      // a sphere no wider than the bond hides nothing
        // The cylinder's surface at the trim point lies on the sphere.
        XCTAssertEqual((span.lowerBound * span.lowerBound + 0.09).squareRoot(), 0.5, accuracy: 1e-6)
    }

    func testVisibleSpanIsNilWhenTheSpheresHideTheBond() {
        XCTAssertNil(BondProxy.visibleSpan(length: 1, radiusA: 0.7, radiusB: 0.7, bondRadius: 0.1))
        XCTAssertNil(BondProxy.visibleSpan(length: 0, radiusA: 0.1, radiusB: 0.1, bondRadius: 0.05))
        XCTAssertNil(BondProxy.visibleSpan(length: 1, radiusA: 0.1, radiusB: 0.1, bondRadius: 0))
        XCTAssertNotNil(BondProxy.visibleSpan(length: 1, radiusA: 0.4, radiusB: 0.4, bondRadius: 0.1))
    }

    func testClipToDepth() throws {
        let a = SIMD3<Float>(0, 0, -1), b = SIMD3<Float>(0, 0, -5)
        let whole = try XCTUnwrap(BondProxy.clipToDepth(start: a, end: b, minimumDepth: 0.5))
        XCTAssertEqual(whole.start, a)
        XCTAssertEqual(whole.end, b)
        let cut = try XCTUnwrap(BondProxy.clipToDepth(start: a, end: b, minimumDepth: 2))
        XCTAssertEqual(cut.start.z, -2, accuracy: 1e-6)
        XCTAssertEqual(cut.end, b)
        let reversed = try XCTUnwrap(BondProxy.clipToDepth(start: b, end: a, minimumDepth: 2))
        XCTAssertEqual(reversed.start, b)
        XCTAssertEqual(reversed.end.z, -2, accuracy: 1e-6)
        XCTAssertNil(BondProxy.clipToDepth(start: a, end: b, minimumDepth: 6))
    }

    func testQuadRejectsDegenerateInput() {
        XCTAssertNil(BondProxy.quad(start: SIMD3(0, 0, -5), end: SIMD3(0, 0, -5), radius: 0.1))
        XCTAssertNil(BondProxy.quad(start: SIMD3(0, 0, -5), end: SIMD3(1, 0, -5), radius: 0))
        XCTAssertNil(BondProxy.quad(start: SIMD3(0, 0, 0), end: SIMD3(1, 0, 0), radius: 0.1), "at the eye")
        XCTAssertNil(BondProxy.quad(start: SIMD3(0, 0, -0.05), end: SIMD3(1, 0, -5), radius: 0.1), "too close")
    }

    func testQuadCornersLieInItsPlane() throws {
        let quad = try XCTUnwrap(BondProxy.quad(start: SIMD3(-1, 0.2, -6), end: SIMD3(1.5, -0.4, -9), radius: 0.2))
        for i in 0..<4 {
            XCTAssertEqual(-quad.corner(i).z, quad.depth, accuracy: 1e-5)
        }
        XCTAssertEqual(simd_dot(quad.along, quad.across), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_length(quad.along), 1, accuracy: 1e-6)
    }

    /// Every point of the cylinder's surface is seen through the rectangle,
    /// and the rectangle is in front of it (the conservative depth promise).
    func testQuadCoversTheCylinderFromInFront() throws {
        var random = SystemRandomNumberGenerator()
        func unit() -> Float { Float.random(in: -1...1, using: &random) }
        for _ in 0..<200 {
            let start = SIMD3(unit() * 3, unit() * 3, -4 + unit() * 2)
            var end = start + SIMD3(unit(), unit(), unit()) * 2
            if Bool.random(using: &random) { end = start + SIMD3(0.01 * unit(), 0.01 * unit(), -1.5) }    // end-on
            let radius = Float.random(in: 0.02...0.4, using: &random)
            guard let quad = BondProxy.quad(start: start, end: end, radius: radius) else { continue }
            let axis = simd_normalize(end - start)
            let (side, other) = BondProxy.perpendiculars(to: axis)
            for _ in 0..<50 {
                let t = Float.random(in: 0...1, using: &random)
                let angle = Float.random(in: 0..<(2 * .pi), using: &random)
                let point = start + (end - start) * t + (side * cos(angle) + other * sin(angle)) * radius
                XCTAssertGreaterThanOrEqual(-point.z, quad.depth - 1e-4, "the rectangle is in front")
                let onPlane = point * (quad.depth / -point.z)
                let u = simd_dot(onPlane, quad.along), v = simd_dot(onPlane, quad.across)
                XCTAssertTrue(quad.alongRange.lowerBound - 1e-4 <= u && u <= quad.alongRange.upperBound + 1e-4)
                XCTAssertTrue(quad.acrossRange.lowerBound - 1e-4 <= v && v <= quad.acrossRange.upperBound + 1e-4)
            }
        }
    }

    func testQuadIsTightForABondAcrossTheView() throws {
        let quad = try XCTUnwrap(BondProxy.quad(start: SIMD3(-1, 0, -10), end: SIMD3(1, 0, -10), radius: 0.1))
        XCTAssertEqual(quad.depth, 9.9, accuracy: 1e-5)
        // The cylinder projects onto that plane about 1.98 long and 0.2 wide;
        // the rectangle is within about 15% of that.
        let width = quad.acrossRange.upperBound - quad.acrossRange.lowerBound
        let length = quad.alongRange.upperBound - quad.alongRange.lowerBound
        XCTAssertGreaterThanOrEqual(width, 0.198)
        XCTAssertLessThan(width, 0.23)
        XCTAssertGreaterThanOrEqual(length, 1.98)
        XCTAssertLessThan(length, 2.25)
    }

    func testProjectedExtentIsExact() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let center = SIMD3(Float.random(in: -6...6, using: &random), Float.random(in: -6...6, using: &random),
                               -Float.random(in: 0.5...8, using: &random))
            let radius = Float.random(in: 0.01...0.9, using: &random) * (-center.z)
            let plane = (-center.z - radius) * Float.random(in: 0.1...1, using: &random)
            let angle = Float.random(in: 0..<(2 * .pi), using: &random)
            let direction = SIMD3(cos(angle), sin(angle), 0)
            let extent = BondProxy.projectedExtent(of: center, radius: radius, direction: direction, planeDepth: plane)
            var seen: ClosedRange<Float>?
            for _ in 0..<400 {
                let d = simd_normalize(SIMD3(Float.random(in: -1...1, using: &random),
                                             Float.random(in: -1...1, using: &random),
                                             Float.random(in: -1...1, using: &random)))
                let point = center + d * radius
                let u = simd_dot(point * (plane / -point.z), direction)
                let tolerance = 1e-4 * max(abs(extent.lowerBound), abs(extent.upperBound), 1)
                XCTAssertGreaterThanOrEqual(u, extent.lowerBound - tolerance)
                XCTAssertLessThanOrEqual(u, extent.upperBound + tolerance)
                seen = seen.map { min($0.lowerBound, u)...max($0.upperBound, u) } ?? u...u
            }
            // The extremes lie on the circle in the plane of `direction` and
            // the view axis: sampled densely there, the extent is reached.
            for step in 0..<4000 {
                let t = Float(step) / 4000 * 2 * .pi
                let point = center + (direction * cos(t) + SIMD3(0, 0, sin(t))) * radius
                let u = simd_dot(point * (plane / -point.z), direction)
                seen = seen.map { min($0.lowerBound, u)...max($0.upperBound, u) } ?? u...u
            }
            let width = extent.upperBound - extent.lowerBound
            XCTAssertLessThan(seen!.lowerBound - extent.lowerBound, 0.01 * width)
            XCTAssertLessThan(extent.upperBound - seen!.upperBound, 0.01 * width)
        }
    }

    func testQuadStaysSmallForABondFarOffAxis() throws {
        // Far to the side of the view and close to the eye: the old circle
        // bound grew with the lateral distance; the exact extent does not.
        let quad = try XCTUnwrap(BondProxy.quad(start: SIMD3(40, 0, -1), end: SIMD3(41, 0, -1), radius: 0.1))
        let width = quad.acrossRange.upperBound - quad.acrossRange.lowerBound
        XCTAssertLessThan(width, 0.25)
    }

    func testInPlaneDirectionFallsBackForAnEndOnBond() {
        XCTAssertEqual(BondProxy.inPlaneDirection(SIMD3(1, 1, -2), SIMD3(1, 1, -2)), SIMD3(1, 0, 0))
        XCTAssertEqual(BondProxy.inPlaneDirection(SIMD3(0, 0, -2), SIMD3(0, 2, -2)), SIMD3(0, 1, 0))
    }

    func testPerpendicularsAreOrthonormal() {
        for axis in [SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0), simd_normalize(SIMD3<Float>(1, 2, 3))] {
            let (side, other) = BondProxy.perpendiculars(to: axis)
            XCTAssertEqual(simd_dot(side, axis), 0, accuracy: 1e-6)
            XCTAssertEqual(simd_dot(other, axis), 0, accuracy: 1e-6)
            XCTAssertEqual(simd_dot(side, other), 0, accuracy: 1e-6)
            XCTAssertEqual(simd_length(other), 1, accuracy: 1e-6)
        }
    }
}
