import simd

/// Where an experiment appears: about a metre in front of the wearer, in
/// the direction they face, a little below eye level and anchored in the
/// room (never following the head). All in world meters, y up.
public enum LabComfort {
    /// Distance from the eyes to the centre of the experiment.
    public static let viewingDistance: Float = 1.0
    /// How far the centre sits below eye level.
    public static let belowEyeLevel: Float = 0.15
    /// Used when the head pose is unknown (Simulator, tracking not ready).
    public static let fallbackPosition = SIMD3<Float>(0, 1.2, -1.0)
    /// Longest visible side when an experiment opens.
    public static let initialSize: Float = 0.55
    /// Gap between the bottom of the experiment and the top of its tip.
    public static let tipGap: Float = 0.06
    /// Eye heights above the floor that a seated or standing wearer can
    /// have. A pose outside this range (the Simulator reports the device at
    /// the floor) is not trusted.
    public static let plausibleEyeHeight: ClosedRange<Float> = 0.5...2.5

    /// The placement in front of a head pose. `head` is the device's
    /// origin-from-device transform (the device looks along its -z). Only
    /// the heading counts: the content turns about the vertical to face the
    /// wearer and is never tilted with the head. Scale is 1. An unknown or
    /// implausible pose gives the fallback position.
    public static func placement(head: simd_float4x4?) -> BoxPlacement {
        guard let head, let forward = heading(of: head),
              plausibleEyeHeight.contains(head.columns.3.y) else {
            return BoxPlacement(position: fallbackPosition)
        }
        let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var position = eye + forward * viewingDistance
        position.y = eye.y - belowEyeLevel
        // Turn the content's -z (its far side) to point along `forward`.
        let yaw = atan2(-forward.x, -forward.z)
        return BoxPlacement(position: position, orientation: simd_quatf(angle: yaw, axis: [0, 1, 0]))
    }

    /// The horizontal unit direction a head pose faces, or nil for an
    /// invalid pose. Looking straight up or down falls back to where the top
    /// of the head points (forward when looking down, backward when up).
    static func heading(of head: simd_float4x4) -> SIMD3<Float>? {
        let values = [head.columns.0, head.columns.1, head.columns.2, head.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        guard values.allSatisfy(\.isFinite) else { return nil }
        let back = SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let up = SIMD3<Float>(head.columns.1.x, head.columns.1.y, head.columns.1.z)
        let forward = -back
        var flat = SIMD3<Float>(forward.x, 0, forward.z)
        if simd_length(flat) < 0.1 {
            let top = forward.y < 0 ? up : -up
            flat = SIMD3<Float>(top.x, 0, top.z)
        }
        guard simd_length(flat) >= 0.1 else { return SIMD3<Float>(0, 0, -1) }
        return simd_normalize(flat)
    }

    /// Half the height of the content in the world: the vertical half
    /// extent of the turned, scaled box of size `extent` (meters at scale 1).
    public static func worldHalfHeight(of placement: BoxPlacement, extent: SIMD3<Float>) -> Float {
        let rotation = simd_float3x3(placement.orientation)
        let half = extent / 2 * placement.scale
        return abs(rotation.columns.0.y) * half.x + abs(rotation.columns.1.y) * half.y + abs(rotation.columns.2.y) * half.z
    }

    /// Where a tip goes: centred under the content, clear of it however the
    /// content is turned or sized. The tip's own top edge sits here.
    public static func tipPosition(below placement: BoxPlacement, extent: SIMD3<Float>) -> SIMD3<Float> {
        placement.position - SIMD3<Float>(0, worldHalfHeight(of: placement, extent: extent) + tipGap, 0)
    }
}

/// The two in-context tips, taught by doing: pull an atom, then hold the
/// experiment with both hands. Each disappears once it has been done, for
/// the rest of the app session.
public struct LabTips: Equatable, Sendable {
    public enum Tip: Equatable, Sendable {
        case pullAtom
        case holdWithBothHands

        public var text: String {
            switch self {
            case .pullAtom: "Pinch an atom to pull it"
            case .holdWithBothHands: "Pinch with both hands to move, turn and resize"
            }
        }

        public var systemImage: String {
            switch self {
            case .pullAtom: "hand.pinch"
            case .holdWithBothHands: "hands.and.sparkles"
            }
        }
    }

    public private(set) var hasPulledAtom = false
    public private(set) var hasHeldWithBothHands = false

    public init() {}

    /// The tip to show now, if any.
    public var current: Tip? {
        if !hasPulledAtom { return .pullAtom }
        if !hasHeldWithBothHands { return .holdWithBothHands }
        return nil
    }

    public mutating func atomPulled() { hasPulledAtom = true }
    public mutating func heldWithBothHands() { hasHeldWithBothHands = true }
}
