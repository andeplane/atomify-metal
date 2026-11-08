import AtomifyEngine
import simd

/// Per-instance transforms for instanced rendering, in simulation units.
/// Atoms use a unit sphere; bonds and box edges use a unit cylinder along +Y
/// (height 1, radius 1, centered at the origin).
public struct InstanceBatches: Sendable {
    /// Atom transforms grouped by atom type.
    public var atoms: [Int: [simd_float4x4]] = [:]
    /// Each bond is drawn as two half cylinders, grouped by the atom type at
    /// their end, so a bond takes the colors of the atoms it connects.
    public var halfBonds: [Int: [simd_float4x4]] = [:]
    public var contextAtoms: [Int: [simd_float4x4]] = [:]
    public var contextHalfBonds: [Int: [simd_float4x4]] = [:]

    public init() {}
}

public enum InstanceBuilder {
    public static func build(snapshot: SimulationSnapshot, styles: AtomStyleTable, atomScale: Float,
                             bondRadius: Float, includeBonds: Bool, focusedTags: Set<Int64>? = nil) -> InstanceBatches {
        var batches = InstanceBatches()
        let positions = snapshot.positions
        let radii = snapshot.radii

        var radiusByType: [Int32: Float] = [:]
        for type in Set(snapshot.types) {
            radiusByType[type] = Float(styles.style(forType: Int(type)).radius) * atomScale
        }

        for i in positions.indices {
            let type = snapshot.types[i]
            let radius = radii.map { $0[i] * atomScale } ?? radiusByType[type] ?? 0
            let transform = sphereTransform(center: positions[i], radius: radius)
            if let focusedTags, !focusedTags.contains(snapshot.tags[i]) {
                batches.contextAtoms[Int(type), default: []].append(transform)
            } else {
                batches.atoms[Int(type), default: []].append(transform)
            }
        }

        if includeBonds && bondRadius > 0 {
            for bond in snapshot.bonds {
                let i = Int(bond.x), j = Int(bond.y)
                guard i < positions.count, j < positions.count else { continue }
                let middle = (positions[i] + positions[j]) * 0.5
                let context = focusedTags.map { !$0.contains(snapshot.tags[i]) || !$0.contains(snapshot.tags[j]) } ?? false
                if let half = cylinderTransform(from: positions[i], to: middle, radius: bondRadius) {
                    if context { batches.contextHalfBonds[Int(snapshot.types[i]), default: []].append(half) }
                    else { batches.halfBonds[Int(snapshot.types[i]), default: []].append(half) }
                }
                if let half = cylinderTransform(from: positions[j], to: middle, radius: bondRadius) {
                    if context { batches.contextHalfBonds[Int(snapshot.types[j]), default: []].append(half) }
                    else { batches.halfBonds[Int(snapshot.types[j]), default: []].append(half) }
                }
            }
        }
        return batches
    }

    /// Bond thickness that reads well next to the smallest atoms.
    public static func bondRadius(styles: AtomStyleTable, atomScale: Float) -> Float {
        let smallest = styles.styles.values.map(\.radius).min() ?? 0.5
        return Float(smallest) * atomScale * 0.35
    }

    public static func sphereTransform(center: SIMD3<Float>, radius: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(radius, 0, 0, 0), SIMD4(0, radius, 0, 0), SIMD4(0, 0, radius, 0),
                                SIMD4(center, 1)))
    }

    /// Maps the unit cylinder onto the segment from `start` to `end`.
    public static func cylinderTransform(from start: SIMD3<Float>, to end: SIMD3<Float>,
                                         radius: Float) -> simd_float4x4? {
        let axis = end - start
        let length = simd_length(axis)
        guard length > 1e-6, length.isFinite else { return nil }
        let y = axis / length
        let helper: SIMD3<Float> = abs(y.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
        let x = simd_normalize(simd_cross(helper, y))
        let z = simd_cross(x, y)
        return simd_float4x4(columns: (SIMD4(x * radius, 0), SIMD4(y * length, 0), SIMD4(z * radius, 0),
                                       SIMD4((start + end) * 0.5, 1)))
    }

    /// The twelve edges of an axis aligned box.
    public static func boxEdges(low: SIMD3<Float>, high: SIMD3<Float>, radius: Float) -> [simd_float4x4] {
        var corners: [SIMD3<Float>] = []
        for k in 0..<8 {
            corners.append(SIMD3(k & 1 == 0 ? low.x : high.x, k & 2 == 0 ? low.y : high.y,
                                 k & 4 == 0 ? low.z : high.z))
        }
        var edges: [simd_float4x4] = []
        for a in 0..<8 {
            for bit in [1, 2, 4] where a & bit == 0 {
                if let edge = cylinderTransform(from: corners[a], to: corners[a | bit], radius: radius) {
                    edges.append(edge)
                }
            }
        }
        return edges
    }
}

/// Places the simulation box in the room: the box is centered on the origin
/// of the entity holding the atoms and its longest side spans `size` meters.
public struct SimulationFrame: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var metersPerUnit: Float

    public init(boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>, size: Float) {
        let low = SIMD3<Float>(boxLow), high = SIMD3<Float>(boxHigh)
        center = (low + high) * 0.5
        let extent = (high - low).max()
        metersPerUnit = extent > 0 && extent.isFinite ? size / extent : 1
    }

    /// Fixed scale around `center`, e.g. simulation units straight onto the room.
    public init(center: SIMD3<Float>, metersPerUnit: Float) {
        self.center = center
        self.metersPerUnit = metersPerUnit
    }

    /// Transform from simulation coordinates to the parent entity, in meters.
    public var localFromSimulation: simd_float4x4 {
        let s = metersPerUnit
        return simd_float4x4(columns: (SIMD4(s, 0, 0, 0), SIMD4(0, s, 0, 0), SIMD4(0, 0, s, 0),
                                       SIMD4(-center * s, 1)))
    }

    public func simulationPoint(fromLocal point: SIMD3<Float>) -> SIMD3<Float> {
        point / metersPerUnit + center
    }
}
