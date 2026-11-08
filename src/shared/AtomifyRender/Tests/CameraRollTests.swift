import simd
import XCTest
@testable import AtomifyRender

final class CameraRollTests: XCTestCase {
    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-5, "\(a) vs \(b)", file: file, line: line)
    }

    func testRollTurnsTheScreenAxes() {
        var camera = OrbitCamera(target: .zero, distance: 10)
        assertClose(camera.basis.right, SIMD3(1, 0, 0))
        assertClose(camera.basis.up, SIMD3(0, 1, 0))
        camera.roll = .pi
        assertClose(camera.basis.right, SIMD3(-1, 0, 0))
        assertClose(camera.basis.up, SIMD3(0, -1, 0))
        assertClose(camera.basis.forward, SIMD3(0, 0, -1))
        camera.roll = .pi / 2
        // Counterclockwise on screen: the old up now points left.
        assertClose(camera.basis.right, SIMD3(0, 1, 0))
        assertClose(camera.basis.up, SIMD3(-1, 0, 0))
    }

    func testRollKeepsTheBasisOrthonormal() {
        let camera = { () -> OrbitCamera in
            var c = OrbitCamera(target: SIMD3(1, 2, 3), distance: 5, yaw: 0.7, pitch: -0.4)
            c.roll = 1.1
            return c
        }()
        let (r, u, f) = camera.basis
        XCTAssertEqual(simd_length(r), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(u), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(r, u), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(r, f), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(u, f), 0, accuracy: 1e-5)
        assertClose(simd_cross(r, u), -f)
    }

    func testDragsFollowTheRolledScreen() {
        var camera = OrbitCamera()
        let plain = camera.rotationDelta(forPointerMove: SIMD2(10, 4), viewHeight: 500)
        camera.roll = .pi
        let flipped = camera.rotationDelta(forPointerMove: SIMD2(10, 4), viewHeight: 500)
        XCTAssertEqual(flipped.x, -plain.x, accuracy: 1e-5)
        XCTAssertEqual(flipped.y, -plain.y, accuracy: 1e-5)
    }
}
