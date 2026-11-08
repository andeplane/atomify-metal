import AtomifyRender
import Foundation
import simd

/// A small 3C-SiC crystal with bonds and its box.
enum SiliconCarbideScene {
    static let bondRadius: Float = 0.16
    static let styles = [LabElement.silicon.style, LabElement.carbon.style]
    static let styleNames = ["Si (silicon)", "C (carbon)"]

    static func make(cells: Int) -> GeneratedScene {
        let lattice = ZincblendeLattice(cells: cells)
        let particles = ParticleData(positions: lattice.positions(), styleIndices: lattice.sublatticeIndices(),
                                     styles: styles)
        var bonds = BondData(pairs: lattice.bonds(), radius: bondRadius)
        bonds.maxLength = lattice.nearestNeighbourDistance * 1.2
        let box = LabLines.box(size: SIMD3(repeating: lattice.boxLength))
        let nn = String(format: "%.3f", Double(lattice.nearestNeighbourDistance))
        return GeneratedScene(scene: SceneData(particles: particles, bonds: bonds, lines: [box]),
                              styleNames: styleNames,
                              notes: ["a = \(lattice.latticeConstant) Å, nearest neighbours \(nn) Å.",
                                      "Bonds stop at the box (not periodic)."])
    }
}
