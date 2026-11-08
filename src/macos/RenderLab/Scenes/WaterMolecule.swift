import AtomifyRender
import Foundation
import simd

/// One water molecule in its gas-phase equilibrium geometry.
enum WaterMolecule {
    /// O–H, Å.
    static let bondLength: Float = 0.9572
    /// H–O–H, degrees.
    static let angleDegrees: Float = 104.52
    static let bondRadius: Float = 0.11

    /// O at the origin; both H in the xy plane, below it, symmetric about the y axis.
    static var positions: [SIMD3<Float>] {
        let half = angleDegrees * .pi / 360
        let dx = bondLength * sinf(half)
        let dy = bondLength * cosf(half)
        return [SIMD3(0, 0, 0), SIMD3(dx, -dy, 0), SIMD3(-dx, -dy, 0)]
    }

    static func make() -> GeneratedScene {
        let particles = ParticleData(positions: positions, styleIndices: [0, 1, 1],
                                     styles: [LabElement.oxygen.style, LabElement.hydrogen.style])
        let bonds = BondData(pairs: [SIMD2(0, 1), SIMD2(0, 2)], radius: bondRadius)
        return GeneratedScene(scene: SceneData(particles: particles, bonds: bonds),
                              styleNames: ["O (oxygen)", "H (hydrogen)"],
                              notes: ["O–H \(bondLength) Å, H–O–H \(angleDegrees)°. Positions never change."],
                              viewAngles: SIMD2(0.35, 0.2))
    }
}
