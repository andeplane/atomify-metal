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
            && abs(a.roll - b.roll) <= tolerance
            && simd_length(a.up - b.up) <= tolerance
            && a.fieldOfView == b.fieldOfView
            && a.fitsShorterSide == b.fitsShorterSide
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
        camera.roll = 0
        camera.up = SIMD3(0, 1, 0)
        camera.fieldOfView = OrbitCamera().fieldOfView
        camera.fitsShorterSide = false
        if let degrees = hint?.fieldOfView, degrees.isFinite, degrees > 0, degrees < 180 {
            // A hinted field of view comes from Atomify 2, which ran in
            // landscape: it spans the shorter side.
            camera.fieldOfView = Float(degrees * .pi / 180)
            camera.fitsShorterSide = true
        }
        let bounds = SceneBuilder.bounds(low: boxLow, high: boxHigh, tilt: tilt)
        if bounds.low.x.isFinite, bounds.high.x.isFinite, bounds.low.y.isFinite, bounds.high.y.isFinite,
           bounds.low.z.isFinite, bounds.high.z.isFinite {
            camera.frame(low: bounds.low, high: bounds.high)
        }
        guard let hint else { return camera }
        let center = (bounds.low + bounds.high) / 2
        let origin: SIMD3<Float> = hint.relativeToBoxCenter && Self.isFinite(center) ? center : .zero
        let target = hint.target.map { origin + SIMD3<Float>($0) } ?? center
        camera.target = target
        // The hint's up direction is the axis the camera orbits about, so a
        // sideways drag keeps the scene's floor level, whichever axis that is.
        if let up = hint.up {
            camera.up = SIMD3<Float>(up)
        }
        if let position = hint.position {
            let offset = origin + SIMD3<Float>(position) - target
            let parameters = Self.orbit(position: origin + SIMD3<Float>(position), target: target)
            camera.distance = parameters.distance
            // Angles in the up frame; a view along the up axis keeps its
            // yaw and looks straight down or up.
            if let angles = camera.orbitAngles(forOffset: offset) {
                camera.yaw = angles.yaw
                camera.pitch = angles.pitch
            }
            // Keep the hinted view inside the zoom limits.
            let range = camera.distanceRange
            camera.distanceRange = min(range.lowerBound, camera.distance)...max(range.upperBound, camera.distance)
        }
        return camera
    }

    /// The roll that turns `camera`'s screen up toward `up` (its part
    /// across the viewing direction); 0 when `up` is along it.
    public static func roll(toward up: SIMD3<Float>, in camera: OrbitCamera) -> Float {
        var level = camera
        level.roll = 0
        let (right, levelUp, forward) = level.basis
        let across = up - simd_dot(up, forward) * forward
        guard Self.isFinite(across), simd_length(across) > 1e-6 else { return 0 }
        // Rolled up = cos(r)·up − sin(r)·right.
        return atan2(-simd_dot(across, right), simd_dot(across, levelUp))
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
}
