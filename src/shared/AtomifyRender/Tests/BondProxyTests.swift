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

    func testProjectedReachBoundsTheSphere() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let center = SIMD3(Float.random(in: -4...4, using: &random), Float.random(in: -4...4, using: &random),
                               -Float.random(in: 1...8, using: &random))
            let radius = Float.random(in: 0.01...0.5, using: &random) * (-center.z) * 0.5
            let plane = (-center.z - radius) * Float.random(in: 0.1...1, using: &random)
            let reach = BondProxy.projectedReach(of: center, radius: radius, planeDepth: plane)
            let projectedCenter = center * (plane / -center.z)
            let direction = simd_normalize(SIMD3(Float.random(in: -1...1, using: &random),
                                                 Float.random(in: -1...1, using: &random),
                                                 Float.random(in: -1...1, using: &random)))
            let point = center + direction * radius
            let projected = point * (plane / -point.z)
            XCTAssertLessThanOrEqual(simd_distance(projected, projectedCenter), reach * (1 + 1e-4) + 1e-6)
        }
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
