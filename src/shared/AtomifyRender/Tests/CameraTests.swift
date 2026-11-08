import simd
import XCTest
@testable import AtomifyRender

private func XCTAssertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(simd_length(a - b), accuracy, "\(a) != \(b)", file: file, line: line)
}

private func transform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let r = m * SIMD4(p, 1)
    return SIMD3(r.x, r.y, r.z) / r.w
}

final class OrbitCameraTests: XCTestCase {
    func testDefaults() {
        let camera = OrbitCamera()
        XCTAssertEqual(camera.target, .zero)
        XCTAssertEqual(camera.distance, 10)
        XCTAssertEqual(camera.fieldOfView, .pi / 4)
        XCTAssertClose(camera.position, SIMD3(0, 0, 10))
        let (right, up, forward) = camera.basis
        XCTAssertClose(right, SIMD3(1, 0, 0))
        XCTAssertClose(up, SIMD3(0, 1, 0))
        XCTAssertClose(forward, SIMD3(0, 0, -1))
    }

    func testInitClamps() {
        XCTAssertEqual(OrbitCamera(pitch: 3).pitch, OrbitCamera.pitchLimit)
        XCTAssertEqual(OrbitCamera(pitch: -3).pitch, -OrbitCamera.pitchLimit)
        XCTAssertEqual(OrbitCamera(pitch: .nan).pitch, 0)
        XCTAssertEqual(OrbitCamera(distance: -1).distance, OrbitCamera.minimumDistance)
        XCTAssertEqual(OrbitCamera(distance: .infinity).distance, OrbitCamera.maximumDistance)
        XCTAssertEqual(OrbitCamera(distance: .nan).distance, OrbitCamera.minimumDistance)
    }

    func testViewMatrixMapsEyeAndTarget() {
        let camera = OrbitCamera(target: SIMD3(1, 2, 3), distance: 7, yaw: 0.7, pitch: -0.4)
        XCTAssertClose(transform(camera.viewMatrix, camera.position), .zero)
        XCTAssertClose(transform(camera.viewMatrix, camera.target), SIMD3(0, 0, -7))
        let (right, up, forward) = camera.basis
        XCTAssertEqual(simd_dot(right, up), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(right, forward), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(up), 1, accuracy: 1e-5)
        XCTAssertClose(simd_cross(right, up), -forward)
        // The same as a look-at.
        let lookAt = Transforms.lookAt(eye: camera.position, target: camera.target, up: SIMD3(0, 1, 0))
        for column in 0..<4 {
            XCTAssertLessThan(simd_length(lookAt[column] - camera.viewMatrix[column]), 1e-4)
        }
    }

    func testRotate() {
        var camera = OrbitCamera()
        camera.rotate(by: SIMD2(.pi / 2, 0))
        XCTAssertClose(camera.position, SIMD3(10, 0, 0))
        camera.rotate(by: SIMD2(0, 10))
        XCTAssertEqual(camera.pitch, OrbitCamera.pitchLimit)
        camera.rotate(by: SIMD2(.nan, 0))
        XCTAssertEqual(camera.yaw, .pi / 2, accuracy: 1e-6)
        camera.rotate(by: SIMD2(4 * .pi, 0))
        XCTAssertEqual(camera.yaw, .pi / 2, accuracy: 1e-5, "yaw wraps")
    }

    func testPan() {
        var camera = OrbitCamera(distance: 4)
        camera.pan(by: SIMD2(0.5, -0.25))
        XCTAssertClose(camera.target, SIMD3(2, -1, 0))
        camera.pan(by: SIMD2(.infinity, 0))
        XCTAssertClose(camera.target, SIMD3(2, -1, 0))
    }

    func testZoom() {
        var camera = OrbitCamera(distance: 10)
        camera.zoom(by: 2)
        XCTAssertEqual(camera.distance, 5)
        camera.zoom(by: 0)
        camera.zoom(by: -1)
        camera.zoom(by: .nan)
        XCTAssertEqual(camera.distance, 5)
        camera.zoom(by: 1e12)
        XCTAssertEqual(camera.distance, OrbitCamera.minimumDistance)
    }

    func testFrame() {
        var camera = OrbitCamera()
        camera.frame(low: SIMD3(0, 0, 0), high: SIMD3(2, 2, 2))
        XCTAssertClose(camera.target, SIMD3(1, 1, 1))
        let radius = simd_length(SIMD3<Float>(2, 2, 2)) / 2
        XCTAssertEqual(camera.distance, radius / sinf(.pi / 8) * 1.05, accuracy: 1e-4)
        // Narrow views back off further.
        var narrow = OrbitCamera()
        narrow.frame(low: SIMD3(0, 0, 0), high: SIMD3(2, 2, 2), aspect: 0.5)
        XCTAssertGreaterThan(narrow.distance, camera.distance)
        // Swapped corners work; degenerate boxes still get a distance.
        var swapped = OrbitCamera()
        swapped.frame(low: SIMD3(2, 2, 2), high: .zero)
        XCTAssertEqual(swapped, camera)
        var point = OrbitCamera()
        point.frame(low: SIMD3(1, 1, 1), high: SIMD3(1, 1, 1))
        XCTAssertGreaterThan(point.distance, 0)
        // Non-finite boxes are ignored.
        var unchanged = OrbitCamera()
        unchanged.frame(low: SIMD3(.nan, 0, 0), high: .zero)
        XCTAssertEqual(unchanged, OrbitCamera())
    }

    func testProjection() {
        let camera = OrbitCamera()
        let standard = camera.projectionMatrix(aspect: 2, near: 0.5, far: 50, reverseZ: false)
        XCTAssertEqual(transform(standard, SIMD3(0, 0, -0.5)).z, 0, accuracy: 1e-5)
        XCTAssertEqual(transform(standard, SIMD3(0, 0, -50)).z, 1, accuracy: 1e-4)
        let reverse = camera.projectionMatrix(aspect: 2, near: 0.5, far: 50, reverseZ: true)
        XCTAssertEqual(transform(reverse, SIMD3(0, 0, -0.5)).z, 1, accuracy: 1e-5)
        XCTAssertEqual(transform(reverse, SIMD3(0, 0, -50)).z, 0, accuracy: 1e-5)
        let infinite = camera.projectionMatrix(aspect: 2, near: 0.5, far: .infinity, reverseZ: true)
        XCTAssertEqual(transform(infinite, SIMD3(0, 0, -0.5)).z, 1, accuracy: 1e-5)
        XCTAssertEqual(transform(infinite, SIMD3(0, 0, -1e6)).z, 0, accuracy: 1e-5)
        let infiniteStandard = camera.projectionMatrix(aspect: 2, near: 0.5, far: .infinity, reverseZ: false)
        XCTAssertEqual(transform(infiniteStandard, SIMD3(0, 0, -0.5)).z, 0, accuracy: 1e-5)
        XCTAssertEqual(transform(infiniteStandard, SIMD3(0, 0, -1e6)).z, 1, accuracy: 1e-5)
        // The top of the field of view maps to y = 1, aspect scales x.
        let top = SIMD3<Float>(0, tanf(.pi / 8), -1)
        XCTAssertEqual(transform(standard, top).y, 1, accuracy: 1e-5)
        let side = SIMD3<Float>(2 * tanf(.pi / 8), 0, -1)
        XCTAssertEqual(transform(standard, side).x, 1, accuracy: 1e-5)
    }

    func testRayRoundTrip() {
        let camera = OrbitCamera(target: SIMD3(1, 0, -2), distance: 6, yaw: -0.3, pitch: 0.5)
        let center = camera.ray(ndc: .zero, aspect: 1.5)
        XCTAssertClose(center.origin, camera.position)
        XCTAssertClose(center.direction, camera.basis.forward)
        let ndc = SIMD2<Float>(0.4, -0.7)
        let ray = camera.ray(ndc: ndc, aspect: 1.5)
        let clip = camera.projectionMatrix(aspect: 1.5, near: 0.1, far: 100, reverseZ: false) * camera.viewMatrix
        let p = transform(clip, ray.origin + ray.direction * 5)
        XCTAssertEqual(p.x, ndc.x, accuracy: 1e-4)
        XCTAssertEqual(p.y, ndc.y, accuracy: 1e-4)
        XCTAssertEqual(simd_length(ray.direction), 1, accuracy: 1e-5)
    }

    func testPointerDeltas() {
        let camera = OrbitCamera(distance: 10)
        let pan = camera.panDelta(forPointerMove: SIMD2(100, 50), viewHeight: 500)
        let unit = 2 * tanf(.pi / 8) / 500
        XCTAssertEqual(pan.x, -100 * unit, accuracy: 1e-6)
        XCTAssertEqual(pan.y, 50 * unit, accuracy: 1e-6)
        XCTAssertEqual(camera.panDelta(forPointerMove: SIMD2(1, 1), viewHeight: 0), .zero)
        let rotate = camera.rotationDelta(forPointerMove: SIMD2(500, -500), viewHeight: 500)
        XCTAssertEqual(rotate.x, -.pi, accuracy: 1e-5)
        XCTAssertEqual(rotate.y, -.pi, accuracy: 1e-5)

        // Panning by a pointer move keeps the target-plane point under the pointer.
        var moved = camera
        moved.pan(by: pan)
        XCTAssertEqual(moved.target.x, -100 * unit * 10, accuracy: 1e-5)
    }

    func testClipPlanes() {
        let camera = OrbitCamera(distance: 100)
        XCTAssertEqual(camera.clipPlanes(sceneRadius: 10).near, 45, accuracy: 1e-4)
        XCTAssertEqual(camera.clipPlanes(sceneRadius: 1000).near, 0.1, accuracy: 1e-6)
        XCTAssertEqual(camera.clipPlanes(sceneRadius: .infinity).near, 0.1, accuracy: 1e-6)
        XCTAssertEqual(camera.clipPlanes(sceneRadius: 10).far, .infinity)
    }
}

final class TransformsTests: XCTestCase {
    func testTranslationAndScale() {
        XCTAssertClose(transform(Transforms.translation(SIMD3(1, 2, 3)), SIMD3(1, 1, 1)), SIMD3(2, 3, 4))
        XCTAssertClose(transform(Transforms.scale(SIMD3(2, 3, 4)), SIMD3(1, 1, 1)), SIMD3(2, 3, 4))
        XCTAssertEqual(Transforms.uniformScale(of: Transforms.scale(SIMD3(repeating: 3))), 3)
    }

    func testLookAtAlongUp() {
        let m = Transforms.lookAt(eye: SIMD3(0, 5, 0), target: .zero, up: SIMD3(0, 1, 0))
        XCTAssertClose(transform(m, .zero), SIMD3(0, 0, -5))
        XCTAssertFalse(m.columns.0.x.isNaN)
    }

    func testNearPlane() {
        for reverse in [false, true] {
            for far in [Float(50), .infinity] {
                let p = Transforms.perspective(fovY: 1, aspect: 1, near: 0.25, far: far, reverseZ: reverse)
                XCTAssertEqual(Transforms.nearPlane(of: p, reverseZ: reverse) ?? -1, 0.25, accuracy: 1e-5)
            }
        }
        // An orthographic matrix has no near plane in this sense.
        XCTAssertNil(Transforms.nearPlane(of: matrix_identity_float4x4, reverseZ: false))
    }

    func testPickMatrix() {
        let viewport = SIMD2<Float>(200, 100)
        let pixel = SIMD2<Float>(50, 25)
        let pick = Transforms.pickMatrix(pixel: pixel, viewport: viewport)
        let ndc = Transforms.ndc(pixel: pixel, viewport: viewport)
        XCTAssertEqual(ndc, SIMD2(-0.5, 0.5))
        // The pixel's center goes to the middle; a pixel to the right to the edge.
        let center = pick * SIMD4(ndc.x * 3, ndc.y * 3, 0.5, 3)
        XCTAssertEqual(center.x / center.w, 0, accuracy: 1e-5)
        XCTAssertEqual(center.y / center.w, 0, accuracy: 1e-5)
        XCTAssertEqual(center.z, 0.5)
        let right = pick * SIMD4(ndc.x + 1 / viewport.x, ndc.y - 1 / viewport.y, 0, 1)
        XCTAssertEqual(right.x, 1, accuracy: 1e-4)
        XCTAssertEqual(right.y, -1, accuracy: 1e-4)
        XCTAssertEqual(Transforms.ndc(pixel: SIMD2(0, 0), viewport: SIMD2(0, 0)), SIMD2(-1, 1))
    }
}
