import XCTest
import simd
@testable import AtomifyRender

final class CameraUpAxisTests: XCTestCase {
    private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ accuracy: Float = 1e-4, _ message: String = "") {
        XCTAssertLessThan(simd_length(a - b), accuracy, "\(a) vs \(b) \(message)")
    }

    func testDefaultUpIsPlusYAndChangesNothing() {
        var camera = OrbitCamera(target: SIMD3(1, 2, 3), distance: 5, yaw: 0.7, pitch: 0.3)
        XCTAssertEqual(camera.up, SIMD3(0, 1, 0))
        let position = camera.position
        let basis = camera.basis
        camera.up = SIMD3(0, 1, 0)
        close(camera.position, position)
        close(camera.basis.right, basis.right)
        XCTAssertEqual(camera.orbitFrame, matrix_identity_float3x3)
    }

    func testUnusableUpFallsBackToPlusYAndIsNormalized() {
        var camera = OrbitCamera()
        camera.up = .zero
        XCTAssertEqual(camera.up, SIMD3(0, 1, 0))
        camera.up = SIMD3(.nan, 0, 0)
        XCTAssertEqual(camera.up, SIMD3(0, 1, 0))
        camera.up = SIMD3(0, 0, 4)
        close(camera.up, SIMD3(0, 0, 1))
    }

    /// With z up, the screen's up stays z-ish at level, and yaw turns about z.
    func testZUpOrbitKeepsTheFloorLevelWhenYawing() {
        var camera = OrbitCamera(target: .zero, distance: 10, yaw: 0, pitch: 0)
        camera.up = SIMD3(0, 0, 1)
        for yaw in stride(from: Float(0), through: 6, by: 0.5) {
            camera.yaw = yaw
            close(camera.basis.up, SIMD3(0, 0, 1), 1e-4, "level view, yaw \(yaw)")
            XCTAssertEqual(camera.position.z, 0, accuracy: 1e-4)
            XCTAssertEqual(simd_length(camera.position), 10, accuracy: 1e-3)
        }
        // Pitching up lifts the eye along +z.
        camera.yaw = 0.4
        camera.pitch = 0.5
        XCTAssertEqual(camera.position.z, 10 * sinf(0.5), accuracy: 1e-4)
        // The view always looks at the target, and right/up/forward are orthonormal.
        let (right, up, forward) = camera.basis
        close(forward, simd_normalize(-camera.position))
        XCTAssertEqual(simd_dot(right, up), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(right, forward), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(simd_cross(right, up), -forward), 1, accuracy: 1e-5)
    }

    /// Looking from the side (pitch 0) of a z-up scene must show z as screen up
    /// and, while rotating down from the top, never roll the picture.
    func testRotatingDownFromAboveNeverRollsAZUpScene() {
        var camera = OrbitCamera(target: .zero, distance: 10, yaw: 0.9, pitch: 1.4)
        camera.up = SIMD3(0, 0, 1)
        var last = camera.basis.right
        for pitch in stride(from: Float(1.4), through: -0.5, by: -0.1) {
            camera.pitch = pitch
            let right = camera.basis.right
            XCTAssertEqual(right.z, 0, accuracy: 1e-5, "screen right stays level at pitch \(pitch)")
            XCTAssertGreaterThan(simd_dot(right, last), 0.99)
            last = right
        }
    }

    func testDownUpSceneRotatesTheRightWay() {
        // Atomify 2 viewed some systems with -y up: the floor is at +y.
        var camera = OrbitCamera(target: .zero, distance: 10, yaw: 0, pitch: 0)
        camera.up = SIMD3(0, -1, 0)
        close(camera.basis.up, SIMD3(0, -1, 0))
        camera.pitch = 0.5
        XCTAssertLessThan(camera.position.y, 0, "positive pitch lifts the eye along the up axis (-y)")
        camera.rotate(by: SIMD2(0.3, 0))
        close(camera.basis.up.y < 0 ? SIMD3(0, -1, 0) : SIMD3(0, 1, 0), SIMD3(0, -1, 0))
    }

    func testOrbitAnglesInvertPosition() {
        for up in [SIMD3<Float>(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0.3, -0.5, 0.8)] {
            var camera = OrbitCamera(target: SIMD3(1, -2, 3), distance: 7, yaw: 0.8, pitch: -0.4)
            camera.up = up
            let angles = camera.orbitAngles(forOffset: camera.position - camera.target)
            XCTAssertEqual(angles?.yaw ?? 9, 0.8, accuracy: 1e-4, "\(up)")
            XCTAssertEqual(angles?.pitch ?? 9, -0.4, accuracy: 1e-4, "\(up)")
        }
        XCTAssertNil(OrbitCamera().orbitAngles(forOffset: .zero))
        XCTAssertNil(OrbitCamera().orbitAngles(forOffset: SIMD3(.nan, 0, 0)))
    }
}
