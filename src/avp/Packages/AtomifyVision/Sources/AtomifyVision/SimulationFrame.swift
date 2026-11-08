import AtomifyEngine
import simd

public enum LabBonds {
    /// Bond thickness that reads well next to the smallest atoms.
    public static func radius(styles: AtomStyleTable, atomScale: Float = 1) -> Float {
        let smallest = styles.styles.values.map(\.radius).min() ?? 0.5
        return Float(smallest) * atomScale * 0.35
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
