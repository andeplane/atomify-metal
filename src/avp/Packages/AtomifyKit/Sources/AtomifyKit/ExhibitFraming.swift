import simd

/// A presentation frame around actual particles, independent of the physical
/// simulation box. Compute it once when an exhibit appears; reusing this value
/// keeps the scene still while the molecule moves or a learner pulls an atom.
public struct ExhibitFraming: Equatable, Sendable {
    public let frame: SimulationFrame
    /// Bounds used only by the exhibit handle and gesture hit volume, in meters
    /// at placement scale one. These are never drawn as a physical box.
    public let extent: SIMD3<Float>

    public init?(snapshot: SimulationSnapshot, styles: AtomStyleTable,
                 atomScale: Float = 1, size: Float = 0.32) {
        guard !snapshot.positions.isEmpty, snapshot.positions.count == snapshot.types.count,
              atomScale.isFinite, atomScale > 0, size.isFinite, size > 0,
              snapshot.radii == nil || snapshot.radii?.count == snapshot.positions.count else { return nil }
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for index in snapshot.positions.indices {
            let point = snapshot.positions[index]
            let radius = (snapshot.radii?[index] ?? Float(styles.style(forType: Int(snapshot.types[index])).radius)) * atomScale
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                  radius.isFinite, radius >= 0 else { return nil }
            let padding = SIMD3<Float>(repeating: radius)
            low = simd_min(low, point - padding)
            high = simd_max(high, point + padding)
        }
        let longest = (high - low).max()
        guard longest.isFinite, longest > 0 else { return nil }
        // A little room around the visible sphere surfaces; no vacuum-box size
        // enters the frame. The actual structure fills about 89% of the span.
        let breathingRoom = SIMD3<Float>(repeating: longest * 0.06)
        low -= breathingRoom
        high += breathingRoom
        let padded = high - low
        let scale = size / padded.max()
        guard scale.isFinite, scale > 0 else { return nil }
        let center = low + padded / 2
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { return nil }
        frame = SimulationFrame(center: center, metersPerUnit: scale)
        extent = simd_max(padded * scale, SIMD3<Float>(repeating: 0.05))
    }
}
