import AtomifyRender
import simd

/// An axis-aligned box around a scene, for framing the camera.
struct SceneBounds: Sendable, Equatable {
    var low: SIMD3<Float>
    var high: SIMD3<Float>

    var center: SIMD3<Float> { (low + high) / 2 }
    var size: SIMD3<Float> { high - low }

    /// The bounds of `points`, or nil when there are none (non-finite points are skipped).
    static func of(_ points: [SIMD3<Float>]) -> SceneBounds? {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        var any = false
        for p in points where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            low = simd_min(low, p)
            high = simd_max(high, p)
            any = true
        }
        return any ? SceneBounds(low: low, high: high) : nil
    }

    /// Grown by `margin` on every side.
    func padded(by margin: Float) -> SceneBounds {
        let m = SIMD3<Float>(repeating: max(margin, 0))
        return SceneBounds(low: low - m, high: high + m)
    }

    /// Grown to hold the box shifted by every offset in `images`.
    func including(images: [SIMD3<Float>]) -> SceneBounds {
        guard let shifts = SceneBounds.of(images) else { return self }
        return SceneBounds(low: low + simd_min(shifts.low, .zero), high: high + simd_max(shifts.high, .zero))
    }

    func union(_ other: SceneBounds) -> SceneBounds {
        SceneBounds(low: simd_min(low, other.low), high: simd_max(high, other.high))
    }

    /// Everything that is drawn: particles (padded by the largest radius),
    /// line end points, and the periodic copies. A unit box for an empty scene.
    static func enclosing(_ scene: SceneData) -> SceneBounds {
        let particles = scene.particles
        var bounds = SceneBounds.of(particles.positions)
        if let b = bounds {
            let styleRadius = particles.styles.map(\.radius).max() ?? ParticleStyle.fallback.radius
            let overrideRadius = particles.radii.flatMap { $0.count == particles.count ? $0.max() : nil } ?? 0
            bounds = b.padded(by: max(styleRadius, overrideRadius))
        }
        let ends = scene.lines.flatMap { line in line.segments.flatMap { [$0.0, $0.1] } }
        if let lineBounds = SceneBounds.of(ends) {
            bounds = bounds.map { $0.union(lineBounds) } ?? lineBounds
        }
        let result = bounds ?? SceneBounds(low: SIMD3(repeating: -0.5), high: SIMD3(repeating: 0.5))
        return result.including(images: scene.images)
    }
}

/// How many periodic copies the large crystal draws.
enum PeriodicImages: String, CaseIterable, Identifiable, Sendable {
    case off, three, five

    var id: Self { self }

    /// Copies along each axis.
    var perAxis: Int {
        switch self {
        case .off: 1
        case .three: 3
        case .five: 5
        }
    }

    var title: String {
        switch self {
        case .off: "None"
        case .three: "3×3×3"
        case .five: "5×5×5"
        }
    }

    /// Offsets of every copy of a box of `size`, the original (zero) first.
    func offsets(box size: SIMD3<Float>) -> [SIMD3<Float>] {
        let half = perAxis / 2
        var result: [SIMD3<Float>] = [.zero]
        for k in -half...half {
            for j in -half...half {
                for i in -half...half where i != 0 || j != 0 || k != 0 {
                    result.append(SIMD3(Float(i), Float(j), Float(k)) * size)
                }
            }
        }
        return result
    }
}
