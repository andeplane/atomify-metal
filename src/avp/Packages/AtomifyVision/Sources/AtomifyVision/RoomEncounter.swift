import AtomifyEngine
import Foundation
import simd

/// Evidence for one particle approaching and turning near one measured patch.
/// It observes engine positions only; it neither launches particles nor applies
/// forces, and it does not attribute the turn to a particular collision force.
public struct RoomEncounter: Sendable {
    public private(set) var witnessTag: Int64?
    public private(set) var observedTurn = false
    private var lastSequence: UInt64?
    private var lastTimestep: Int64?
    private var lastFreshAt: Double?
    private var lastProcessedAt: Double?
    private var searchOffset = 0
    private var candidate: Candidate?

    private struct Candidate: Sendable {
        var tag: Int64
        var startedAt: Double
        var startNormal: Float
        var closestNormal: Float
        var side: Float
        var lastPosition: SIMD3<Float>
        var approached = false
    }

    public init() {}
    public mutating func reset() { self = Self() }

    /// At most ten position samples per second and 256 candidates per search.
    /// Duplicate snapshots cannot manufacture elapsed movement. Pausing or a
    /// sample gap above 250 ms discards unfinished evidence.
    public mutating func observe(snapshot: SimulationSnapshot, patch: DistanceGrid.Triangle,
                                 active: Bool, at now: Double) {
        guard active, now.isFinite, !snapshot.minimizing, !snapshot.frozen,
              snapshot.tags.count == snapshot.positions.count,
              let normal = Self.normal(patch) else { reset(); return }
        if let lastFreshAt, now < lastFreshAt || now - lastFreshAt > 0.25 {
            clearEvidence()
        }
        if let lastSequence {
            if snapshot.sequence < lastSequence { reset(); return }
            guard snapshot.sequence != lastSequence else { return }
        }
        if let lastProcessedAt, now - lastProcessedAt < 0.1 { return }
        if let lastTimestep, snapshot.timestep <= lastTimestep {
            clearEvidence()
            return
        }
        lastSequence = snapshot.sequence
        lastTimestep = snapshot.timestep
        lastFreshAt = now
        lastProcessedAt = now
        guard !observedTurn else { return }

        if var current = candidate, let index = snapshot.index(ofTag: current.tag) {
            let point = snapshot.positions[index] * RoomScenario.metersPerUnit
            let signed = simd_dot(point - patch.a, normal)
            let normalDistance = abs(signed)
            let exactDistance = DistanceGrid.distance(from: point, to: patch)
            let center = (patch.a + patch.b + patch.c) / 3
            // A wrap, discontinuity, crossed plane or departure far from the
            // highlighted patch is not evidence of a turn at this patch.
            if !Self.finite(point) || !exactDistance.isFinite || now - current.startedAt > 1 ||
                signed * current.side <= 0 || simd_distance(point, current.lastPosition) > 0.25 ||
                simd_distance(point, center) > 0.5 {
                candidate = nil
                witnessTag = nil
            } else {
                current.closestNormal = min(current.closestNormal, normalDistance)
                if exactDistance <= 0.13 && current.startNormal - current.closestNormal >= 0.02 {
                    current.approached = true
                }
                if current.approached && normalDistance - current.closestNormal >= 0.025 {
                    observedTurn = true
                }
                current.lastPosition = point
                candidate = current
                return
            }
        } else {
            candidate = nil
            witnessTag = nil
        }

        let count = snapshot.atomCount
        guard count > 0 else { return }
        let center = (patch.a + patch.b + patch.c) / 3
        var best: (index: Int, distance: Float)?
        let examined = min(count, 256)
        // Rotate the bounded search so a large room never permanently excludes
        // particles that happened to fall outside the first 256 tags.
        for offset in 0..<examined {
            let index = (searchOffset + offset) % count
            let point = snapshot.positions[index] * RoomScenario.metersPerUnit
            guard Self.finite(point), simd_distance(point, center) < 0.45 else { continue }
            let distance = DistanceGrid.distance(from: point, to: patch)
            let perpendicular = abs(simd_dot(point - patch.a, normal))
            guard distance.isFinite, distance >= 0.14, distance < 0.28,
                  perpendicular >= 0.14 else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        searchOffset = (searchOffset + examined) % count
        if let best {
            let point = snapshot.positions[best.index] * RoomScenario.metersPerUnit
            let side = simd_dot(point - patch.a, normal)
            let tag = snapshot.tags[best.index]
            guard tag > 0 else { return }
            witnessTag = tag
            candidate = Candidate(tag: tag, startedAt: now, startNormal: abs(side),
                                  closestNormal: abs(side), side: side, lastPosition: point)
        }
    }

    /// Selects real observed geometry in front of the wearer, in a comfortable viewing
    /// range, then takes a smaller triangle *inside* it for a restrained marker.
    /// No synthetic wall plane is created. A large observed patch is preferred;
    /// small reconstructed triangles remain a truthful fallback.
    public static func selectPatch(from triangles: [DistanceGrid.Triangle],
                                   worldFromWearer: simd_float4x4) -> DistanceGrid.Triangle? {
        guard (0..<4).allSatisfy({ axis in
            let column = worldFromWearer[axis]
            return column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite
        }), abs(simd_determinant(worldFromWearer)) > 0.5 else { return nil }
        let wearerFromWorld = worldFromWearer.inverse
        var preferred: (triangle: DistanceGrid.Triangle, score: Float)?
        var fallback: (triangle: DistanceGrid.Triangle, score: Float)?
        for triangle in triangles {
            guard finite(triangle.a), finite(triangle.b), finite(triangle.c), normal(triangle) != nil else { continue }
            let center = (triangle.a + triangle.b + triangle.c) / 3
            guard (0..<3).allSatisfy({ center[$0] >= RoomScenario.roomLow[$0] && center[$0] <= RoomScenario.roomHigh[$0] }) else { continue }
            let transformed = wearerFromWorld * SIMD4(center, 1)
            let local = SIMD3(transformed.x, transformed.y, transformed.z)
            let distance = simd_length(local)
            guard finite(local), distance > 0.4, distance < 2.7, local.z < -0.35,
                  abs(local.x) < 1.2, local.y > -1.7, local.y < 0.55,
                  -local.z / distance > 0.4 else { continue }
            let area = simd_length(simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)) * 0.5
            let score = distance + abs(local.x) * 0.4
            if area >= 0.02 {
                if preferred == nil || score < preferred!.score { preferred = (triangle, score) }
            } else if fallback == nil || score < fallback!.score { fallback = (triangle, score) }
        }
        guard let source = (preferred ?? fallback)?.triangle else { return nil }
        let center = (source.a + source.b + source.c) / 3
        let radius = max(simd_distance(source.a, center), max(simd_distance(source.b, center), simd_distance(source.c, center)))
        let fraction: Float = min(1, 0.25 / radius)
        let a = center + (source.a - center) * fraction
        let b = center + (source.b - center) * fraction
        let c = center + (source.c - center) * fraction
        return .init(a, b, c)
    }

    private mutating func clearEvidence() {
        candidate = nil
        witnessTag = nil
        observedTurn = false
    }
    private static func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
    private static func normal(_ t: DistanceGrid.Triangle) -> SIMD3<Float>? {
        guard finite(t.a), finite(t.b), finite(t.c) else { return nil }
        let cross = simd_cross(t.b - t.a, t.c - t.a)
        let length = simd_length(cross)
        guard length.isFinite, length > 2e-6 else { return nil }
        return cross / length
    }
}
