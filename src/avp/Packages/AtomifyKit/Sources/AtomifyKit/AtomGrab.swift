import Foundation
import simd

/// One atom held by a pinch: which atom, how the hand maps to its target,
/// and the smoothed target. Everything in world meters.
public struct AtomGrab: Equatable, Sendable {
    /// Largest move of the smoothed target per frame (about 1 m/s at 90 Hz).
    public static let maxStep: Float = 0.012

    /// The atom's LAMMPS id.
    public let tag: Int64
    public let drag: GrabDrag
    /// Where the hand wants the atom.
    public private(set) var desired: SIMD3<Float>
    /// Where the atom is pulled to, eased toward `desired` every frame.
    public private(set) var current: SIMD3<Float>

    /// `atomPosition` is the atom's world position when `pinch` began.
    public init(tag: Int64, atomPosition: SIMD3<Float>, pinch: PinchSample) {
        self.tag = tag
        drag = GrabDrag(atomPosition: atomPosition, pinch: pinch)
        desired = atomPosition
        current = atomPosition
    }

    public mutating func follow(_ pinch: PinchSample) {
        let target = drag.target(for: pinch)
        guard target.x.isFinite, target.y.isFinite, target.z.isFinite else { return }
        desired = target
    }

    /// Advances the smoothed target one frame and returns it.
    public mutating func step(maxStep: Float = AtomGrab.maxStep) -> SIMD3<Float> {
        current = GrabDrag.smoothed(from: current, toward: desired, maxStep: maxStep)
        return current
    }
}

/// Bookkeeping between the gesture, which starts, moves and ends a grab,
/// and the frame loop, which must refresh the engine's grab every frame
/// (the engine lets go of grabs that are not refreshed, and a perfectly
/// still hand produces no gesture events) and release it exactly once.
public struct GrabLink: Equatable, Sendable {
    /// What the frame loop tells the engine this frame.
    public enum Command: Equatable, Sendable {
        case none
        /// Pull the atom toward this world point.
        case hold(tag: Int64, target: SIMD3<Float>)
        case release
    }

    public private(set) var grab: AtomGrab?
    private var needsRelease = false
    private var began: Int64?

    public init() {}

    public var isHolding: Bool { grab != nil }

    /// Starts holding an atom, replacing any atom held before.
    public mutating func begin(_ grab: AtomGrab) {
        self.grab = grab
        began = grab.tag
        needsRelease = false
    }

    public mutating func follow(_ pinch: PinchSample) {
        grab?.follow(pinch)
    }

    /// Lets go; the next frame releases the atom in the engine.
    public mutating func end() {
        if grab != nil { needsRelease = true }
        grab = nil
        began = nil
    }

    /// The tag of a grab that began since the last call, once, for feedback.
    public mutating func takeBegan() -> Int64? {
        defer { began = nil }
        return began
    }

    /// One frame. `canHold` is false while the experiment is paused,
    /// stopped, failed, preparing, or held with both hands: the grab ends
    /// and is not resumed until a new pinch.
    public mutating func frame(canHold: Bool) -> Command {
        if canHold, var grab {
            let target = grab.step()
            self.grab = grab
            return .hold(tag: grab.tag, target: target)
        }
        if grab != nil { end() }
        if needsRelease {
            needsRelease = false
            return .release
        }
        return .none
    }
}

/// Which atom a pinch picks. Simulation units throughout.
public enum AtomPick {
    /// Reach of a direct pinch, in world meters.
    public static let directReach: Float = 0.035
    /// Extra radius for an indirect (gaze) pick per meter of distance:
    /// about 2.5° of visual angle across, the smallest comfortable target.
    public static let angularTolerance: Float = 0.022
}

extension SimulationSnapshot {
    /// The atom nearest to `point` among those within `max(reach, radius(i))`
    /// of it, as an index; nil when none is that close.
    public func atomNear(_ point: SIMD3<Float>, reach: Float, radius: (Int) -> Float) -> Int? {
        var best: Int?
        var bestDistance = Float.infinity
        for (i, position) in positions.enumerated() {
            let distance = simd_distance(position, point)
            guard distance <= max(reach, radius(i)), distance < bestDistance else { continue }
            bestDistance = distance
            best = i
        }
        return best
    }
}

/// How fast the integration runs.
public enum SimulationSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow, normal, fast

    public var id: Self { self }
    public var title: String { rawValue.capitalized }

    /// Normal speed when a demo does not set its own.
    public static let defaultNormalStepsPerSecond: Double = 120
    public static let slowFraction: Double = 0.3

    /// Step-rate limit for a demo; nil runs as fast as the device allows.
    public func stepsPerSecond(for demo: Demo) -> Double? {
        let normal = demo.stepsPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? Self.defaultNormalStepsPerSecond
        switch self {
        case .slow: return normal * Self.slowFraction
        case .normal: return normal
        case .fast: return nil
        }
    }
}

/// Short labels for the controls panel.
public enum Readout {
    /// "300 K" in physical units; "T = 0.85 (reduced)" in Lennard-Jones
    /// units; nil before the first frame or for an invalid value.
    public static func temperature(_ value: Double, units: String, locale: Locale = .current) -> String? {
        guard !units.isEmpty, value.isFinite else { return nil }
        if units == "lj" {
            return "T = \(value.formatted(.number.precision(.fractionLength(2)).locale(locale))) (reduced)"
        }
        return "\(Int(value.rounded())) K"
    }
}
