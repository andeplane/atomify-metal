import AtomifyRender
import simd

enum PickingLayout: String, CaseIterable, Identifiable, Sendable {
    case denseCluster, layeredSlabs

    var id: Self { self }

    var title: String {
        switch self {
        case .denseCluster: "Dense cluster"
        case .layeredSlabs: "Layered slabs"
        }
    }
}

/// Scenes where a wrong depth order in picking is easy to see: the
/// highlighted particle must be the one under the cursor, never one behind it.
enum PickingScene {
    static let clusterCount = 4000
    static let clusterRadius: Float = 14
    static let clusterStyles: [ParticleStyle] = [
        ParticleStyle(radius: 0.7, color: linearColor(hex: 0xE5484D)),
        ParticleStyle(radius: 0.9, color: linearColor(hex: 0x46A758)),
        ParticleStyle(radius: 1.1, color: linearColor(hex: 0x3E63DD)),
        ParticleStyle(radius: 1.4, color: linearColor(hex: 0xF5D90A)),
    ]
    static let clusterStyleNames = ["Red (r 0.7)", "Green (r 0.9)", "Blue (r 1.1)", "Yellow (r 1.4)"]

    /// Three square sheets one behind the other (front along +z), each
    /// offset so the ones behind show through the gaps in front.
    static let slabSide = 20
    static let slabSpacing: Float = 2.4
    static let slabLayerGap: Float = 2.6
    static let slabStyles: [ParticleStyle] = [
        ParticleStyle(radius: 0.55, color: linearColor(hex: 0xE5484D)),
        ParticleStyle(radius: 0.8, color: linearColor(hex: 0x46A758)),
        ParticleStyle(radius: 1.05, color: linearColor(hex: 0x3E63DD)),
    ]
    static let slabStyleNames = ["Front (red, r 0.55)", "Middle (green, r 0.8)", "Back (blue, r 1.05)"]
    static let slabBondRadius: Float = 0.12

    static func make(_ layout: PickingLayout) -> GeneratedScene {
        switch layout {
        case .denseCluster: denseCluster()
        case .layeredSlabs: layeredSlabs()
        }
    }

    /// Overlapping spheres of four sizes packed into a ball.
    static func denseCluster() -> GeneratedScene {
        var rng = SplitMix64(seed: 0x5EED_CAFE)
        var positions: [SIMD3<Float>] = []
        var styleIndices: [UInt16] = []
        positions.reserveCapacity(clusterCount)
        styleIndices.reserveCapacity(clusterCount)
        let r = clusterRadius
        while positions.count < clusterCount {
            let x = rng.uniform(-r, r)
            let y = rng.uniform(-r, r)
            let z = rng.uniform(-r, r)
            let p = SIMD3<Float>(x, y, z)
            guard simd_length(p) <= r else { continue }
            positions.append(p)
            styleIndices.append(UInt16(rng.next() % UInt64(clusterStyles.count)))
        }
        let particles = ParticleData(positions: positions, styleIndices: styleIndices, styles: clusterStyles)
        return GeneratedScene(scene: SceneData(particles: particles), styleNames: clusterStyleNames,
                              notes: ["\(clusterCount) overlapping spheres. Click one: the highlight must land on the sphere you see."])
    }

    /// Red sheet in front (with bonds along x), green behind it, blue at the back.
    static func layeredSlabs() -> GeneratedScene {
        var positions: [SIMD3<Float>] = []
        var styleIndices: [UInt16] = []
        var pairs: [SIMD2<UInt32>] = []
        let n = slabSide
        for layer in 0..<3 {
            let shift = Float(layer) * slabSpacing / 3
            let z = -Float(layer) * slabLayerGap
            for j in 0..<n {
                for i in 0..<n {
                    let index = positions.count
                    let x = Float(i) * slabSpacing + shift
                    let y = Float(j) * slabSpacing + shift
                    positions.append(SIMD3<Float>(x, y, z))
                    styleIndices.append(UInt16(layer))
                    if layer == 0, i > 0 {
                        pairs.append(SIMD2(UInt32(index - 1), UInt32(index)))
                    }
                }
            }
        }
        let particles = ParticleData(positions: positions, styleIndices: styleIndices, styles: slabStyles)
        let bonds = BondData(pairs: pairs, radius: slabBondRadius)
        let side = Float(n - 1) * slabSpacing + slabSpacing
        let low = SIMD3<Float>(-slabSpacing / 2, -slabSpacing / 2, -2 * slabLayerGap - 1.5)
        let high = SIMD3<Float>(side, side, 1.5)
        let box = LineData.box(low: low, high: high, color: LabLines.boxColor)
        return GeneratedScene(scene: SceneData(particles: particles, bonds: bonds, lines: [box]),
                              styleNames: slabStyleNames,
                              notes: ["Front red sheet has bonds along x; bonds hide what is behind them, so clicking one selects nothing.",
                                      "Click through the gaps to reach the green and blue sheets."],
                              viewAngles: SIMD2(0.18, 0.12))
    }
}
