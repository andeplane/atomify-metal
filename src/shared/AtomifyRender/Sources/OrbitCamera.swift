import Foundation
import simd

/// Orbit camera for mouse/touch apps: the eye circles `target` at
/// `distance`, `yaw` around the world y axis and `pitch` above the
/// horizon. Yaw 0, pitch 0 puts the eye on +z looking toward −z.
public struct OrbitCamera: Sendable, Equatable {
    public var target: SIMD3<Float>
    public var distance: Float
    /// Radians.
    public var yaw: Float
    /// Radians, clamped to ±`pitchLimit`.
    public var pitch: Float
    /// Vertical field of view, radians.
    public var fieldOfView: Float = .pi / 4

    /// Just short of straight up or down, so the view never flips.
    public static let pitchLimit: Float = .pi / 2 - 0.001
    public static let minimumDistance: Float = 1e-4
    public static let maximumDistance: Float = 1e8

    public init(target: SIMD3<Float> = .zero, distance: Float = 10, yaw: Float = 0, pitch: Float = 0) {
        self.target = target
        self.distance = Self.clampDistance(distance)
        self.yaw = yaw
        self.pitch = Self.clampPitch(pitch)
    }

    /// Adds `delta.x` to yaw and `delta.y` to pitch (radians).
    public mutating func rotate(by delta: SIMD2<Float>) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        yaw = remainderf(yaw + delta.x, 2 * .pi)
        pitch = Self.clampPitch(pitch + delta.y)
    }

    /// Moves the target in the view plane, by `delta` times the distance
    /// (x to the right, y up on screen).
    public mutating func pan(by delta: SIMD2<Float>) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        let basis = self.basis
        target += (basis.right * delta.x + basis.up * delta.y) * distance
    }

    /// Divides the distance by `factor`: above 1 moves closer.
    public mutating func zoom(by factor: Float) {
        guard factor > 0, factor.isFinite else { return }
        distance = Self.clampDistance(distance / factor)
    }

    /// Fit a bounding box in view: look at its center from far enough that
    /// its bounding sphere fits the vertical field of view (and, with
    /// `aspect` below 1, the horizontal one).
    public mutating func frame(low: SIMD3<Float>, high: SIMD3<Float>) {
        frame(low: low, high: high, aspect: 1)
    }

    public mutating func frame(low: SIMD3<Float>, high: SIMD3<Float>, aspect: Float) {
        let finite = { (v: SIMD3<Float>) in v.x.isFinite && v.y.isFinite && v.z.isFinite }
        guard finite(low), finite(high) else { return }
        let lo = simd_min(low, high), hi = simd_max(low, high)
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1e-3)
        var halfAngle = fieldOfView / 2
        if aspect > 0 && aspect < 1 {
            halfAngle = atanf(tanf(halfAngle) * aspect)
        }
        distance = Self.clampDistance(radius / sinf(max(halfAngle, 1e-3)) * 1.05)
    }

    /// The eye position in world space.
    public var position: SIMD3<Float> {
        let c = cosf(pitch)
        return target + distance * SIMD3(c * sinf(yaw), sinf(pitch), c * cosf(yaw))
    }

    /// Unit vectors of the view in world space.
    public var basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let c = cosf(pitch)
        let forward = -SIMD3(c * sinf(yaw), sinf(pitch), c * cosf(yaw))
        let right = SIMD3(cosf(yaw), 0, -sinf(yaw))
        let up = simd_cross(right, forward)
        return (right, up, forward)
    }

    public var viewMatrix: simd_float4x4 {
        let (right, up, forward) = basis
        let eye = position
        return simd_float4x4(rows: [
            SIMD4(right, -simd_dot(right, eye)),
            SIMD4(up, -simd_dot(up, eye)),
            SIMD4(-forward, simd_dot(forward, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    public func projectionMatrix(aspect: Float, near: Float, far: Float, reverseZ: Bool) -> simd_float4x4 {
        Transforms.perspective(fovY: fieldOfView, aspect: aspect, near: near, far: far, reverseZ: reverseZ)
    }

    /// World-space ray through a point in normalized device coords (−1...1).
    public func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let t = tanf(fieldOfView / 2)
        let (right, up, forward) = basis
        let direction = simd_normalize(forward + right * (ndc.x * t * aspect) + up * (ndc.y * t))
        return (position, direction)
    }

    /// The `pan(by:)` argument that makes the scene at the target follow a
    /// pointer moved by `points` (x right, y down, as in view coordinates)
    /// in a view `viewHeight` points tall.
    public func panDelta(forPointerMove points: SIMD2<Float>, viewHeight: Float) -> SIMD2<Float> {
        guard viewHeight > 0 else { return .zero }
        let unitsPerPoint = 2 * tanf(fieldOfView / 2) / viewHeight
        return SIMD2(-points.x, points.y) * unitsPerPoint
    }

    /// The `rotate(by:)` argument for a pointer moved by `points` (x right,
    /// y down): a drag across the full view height turns about half a turn.
    public func rotationDelta(forPointerMove points: SIMD2<Float>, viewHeight: Float) -> SIMD2<Float> {
        let radiansPerPoint = Float.pi / max(viewHeight, 100)
        return SIMD2(-points.x, points.y) * radiansPerPoint
    }

    /// Near and far planes that suit a scene of `radius` around the target
    /// (far is infinite, for reverse Z).
    public func clipPlanes(sceneRadius radius: Float) -> (near: Float, far: Float) {
        let gap = distance - max(radius, 0)
        let near = max(gap * 0.5, distance * 1e-3, Self.minimumDistance)
        return (near, .infinity)
    }

    static func clampPitch(_ pitch: Float) -> Float {
        guard pitch.isFinite else { return 0 }
        return min(max(pitch, -pitchLimit), pitchLimit)
    }

    static func clampDistance(_ distance: Float) -> Float {
        guard distance.isFinite else { return distance > 0 ? maximumDistance : minimumDistance }
        return min(max(distance, minimumDistance), maximumDistance)
    }
}
