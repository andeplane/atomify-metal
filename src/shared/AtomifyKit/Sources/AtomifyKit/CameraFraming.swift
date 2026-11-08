import AtomifyEngine
import Foundation
import AtomifyRender
import simd

/// The starting camera for a run: the script's `#/camera` hint, or the whole
/// box in view.
public enum CameraFraming {
    /// Orbit parameters that put the eye at `position` looking at `target`.
    ///
    /// Assumes the OrbitCamera convention eye = target + distance *
    /// (cos(pitch) sin(yaw), sin(pitch), cos(pitch) cos(yaw)), y up, so
    /// yaw = pitch = 0 looks down −z.
    public static func orbit(position: SIMD3<Float>, target: SIMD3<Float>)
        -> (distance: Float, yaw: Float, pitch: Float) {
        let offset = position - target
        let distance = simd_length(offset)
        guard distance > 0, distance.isFinite else { return (1, 0, 0) }
        let direction = offset / distance
        let pitch = asin(min(max(direction.y, -1), 1))
        let yaw = atan2(direction.x, direction.z)
        return (distance, yaw, pitch)
    }

    /// Whether two cameras show the same view: target, distance, yaw and
    /// pitch equal within `tolerance` (relative to the distance for the
    /// target and the distance itself; radians for the angles).
    public static func isSameView(_ a: OrbitCamera, _ b: OrbitCamera, tolerance: Float = 1e-4) -> Bool {
        let scale = max(abs(a.distance), abs(b.distance), 1)
        return simd_length(a.target - b.target) <= tolerance * scale
            && abs(a.distance - b.distance) <= tolerance * scale
            && abs(a.yaw - b.yaw) <= tolerance
            && abs(a.pitch - b.pitch) <= tolerance
            && a.fieldOfView == b.fieldOfView
    }

    /// The eye position for orbit parameters (the inverse of `orbit`).
    public static func eye(target: SIMD3<Float>, distance: Float, yaw: Float, pitch: Float) -> SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    /// A camera that frames the box, then applies the hint: its target
    /// (default the box center) and its position.
    public static func camera(hint: CameraHint?, boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>,
                              tilt: SIMD3<Double> = .zero, base: OrbitCamera = OrbitCamera()) -> OrbitCamera {
        var camera = base
        let bounds = SceneBuilder.bounds(low: boxLow, high: boxHigh, tilt: tilt)
        if bounds.low.x.isFinite, bounds.high.x.isFinite, bounds.low.y.isFinite, bounds.high.y.isFinite,
           bounds.low.z.isFinite, bounds.high.z.isFinite {
            camera.frame(low: bounds.low, high: bounds.high)
        }
        guard let hint else { return camera }
        let target = hint.target.map { SIMD3<Float>($0) } ?? (bounds.low + bounds.high) / 2
        camera.target = target
        if let position = hint.position {
            let parameters = Self.orbit(position: SIMD3<Float>(position), target: target)
            camera.distance = parameters.distance
            camera.yaw = parameters.yaw
            camera.pitch = parameters.pitch
            // Keep the hinted view inside the zoom limits.
            let range = camera.distanceRange
            camera.distanceRange = min(range.lowerBound, camera.distance)...max(range.upperBound, camera.distance)
        }
        return camera
    }
}
