import simd

/// Maps a pinching hand to where a grabbed atom should go. A direct pinch
/// moves the atom one to one with the hand. An indirect pinch, at an atom
/// farther away than the hand, is amplified by how much farther it is, so
/// a small hand motion carries a distant atom across the view.
/// Everything is in world meters.
public struct GrabDrag: Equatable, Sendable {
    public var atomStart: SIMD3<Float>
    public var handStart: SIMD3<Float>
    public var gain: Float

    /// Gain bounds for indirect pinches, and the gain when there is no ray.
    public static let indirectGainRange: ClosedRange<Float> = 1...5
    public static let indirectGainWithoutRay: Float = 2
    /// Hands closer to the eyes than this count as this far.
    public static let minimumHandDistance: Float = 0.15

    /// `atomPosition` is the grabbed atom's world position when `pinch` began.
    public init(atomPosition: SIMD3<Float>, pinch: PinchSample) {
        atomStart = atomPosition
        handStart = pinch.position
        switch pinch.kind {
        case .direct:
            gain = 1
        case .indirect:
            if let ray = pinch.ray {
                let atomDistance = simd_distance(ray.origin, atomPosition)
                let handDistance = max(simd_distance(ray.origin, pinch.position), Self.minimumHandDistance)
                let ratio = atomDistance / handDistance
                gain = ratio.isFinite
                    ? min(max(ratio, Self.indirectGainRange.lowerBound), Self.indirectGainRange.upperBound)
                    : Self.indirectGainWithoutRay
            } else {
                gain = Self.indirectGainWithoutRay
            }
        }
    }

    /// Where the atom should be with the hand at `pinch`'s position.
    public func target(for pinch: PinchSample) -> SIMD3<Float> {
        atomStart + (pinch.position - handStart) * gain
    }

    /// One smoothing step from `previous` toward `desired`: a third of the
    /// way at most, and no more than `maxStep`, so the pulled atom does not
    /// jerk. Works in any units, as long as `maxStep` uses the same.
    public static func smoothed(from previous: SIMD3<Float>, toward desired: SIMD3<Float>,
                                maxStep: Float) -> SIMD3<Float> {
        let delta = desired - previous
        let distance = simd_length(delta)
        return previous + delta * min(0.35, maxStep / max(distance, 1e-8))
    }
}
