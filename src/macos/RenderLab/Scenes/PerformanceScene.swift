import AtomifyRender
import simd

enum PerformanceLattice: String, CaseIterable, Identifiable, Sendable {
    case siliconCarbide, fcc

    var id: Self { self }

    var title: String {
        switch self {
        case .siliconCarbide: "SiC (zincblende)"
        case .fcc: "FCC (Al)"
        }
    }

    var atomsPerCell: Int {
        switch self {
        case .siliconCarbide: ZincblendeLattice.atomsPerCell
        case .fcc: FCCLattice.atomsPerCell
        }
    }

    /// Whether the generator can make bonds for this lattice.
    var hasBonds: Bool { self == .siliconCarbide }
}

/// Target particle counts; the crystal is the nearest whole number of cells.
enum PerformanceSize: Int, CaseIterable, Identifiable, Sendable {
    case tenThousand = 10_000
    case hundredThousand = 100_000
    case oneMillion = 1_000_000
    case fourMillion = 4_000_000
    case eightMillion = 8_000_000

    var id: Self { self }

    var title: String {
        switch self {
        case .tenThousand: "10k"
        case .hundredThousand: "100k"
        case .oneMillion: "1M"
        case .fourMillion: "4M"
        case .eightMillion: "8M"
        }
    }
}

struct PerformanceParameters: Sendable, Equatable, Hashable {
    var lattice: PerformanceLattice = .siliconCarbide
    var size: PerformanceSize = .hundredThousand
    var bonds = true
    var images: PeriodicImages = .off

    var cells: Int { cellsPerAxis(forAtoms: size.rawValue, atomsPerCell: lattice.atomsPerCell) }
    var particleCount: Int { lattice.atomsPerCell * cells * cells * cells }
}

/// A large crystal for measuring upload and drawing cost.
enum PerformanceScene {
    static let fccLatticeConstant: Float = 4.05

    static func make(_ parameters: PerformanceParameters) -> GeneratedScene {
        let cells = parameters.cells
        var notes: [String] = []
        let particles: ParticleData
        var bonds: BondData?
        let boxLength: Float
        let styleNames: [String]
        switch parameters.lattice {
        case .siliconCarbide:
            let lattice = ZincblendeLattice(cells: cells)
            particles = ParticleData(positions: lattice.positions(), styleIndices: lattice.sublatticeIndices(),
                                     styles: SiliconCarbideScene.styles)
            if parameters.bonds {
                var data = BondData(pairs: lattice.bonds(), radius: SiliconCarbideScene.bondRadius)
                data.maxLength = lattice.nearestNeighbourDistance * 1.2
                bonds = data
            }
            boxLength = lattice.boxLength
            styleNames = SiliconCarbideScene.styleNames
        case .fcc:
            let lattice = FCCLattice(latticeConstant: fccLatticeConstant, cells: cells)
            particles = ParticleData(positions: lattice.positions(), styles: [LabElement.aluminium.style])
            boxLength = lattice.boxLength
            styleNames = ["Al (aluminium)"]
            if parameters.bonds { notes.append("The FCC crystal has no bonds.") }
        }
        let size = SIMD3<Float>(repeating: boxLength)
        let images = parameters.images.offsets(box: size)
        notes.insert("\(cells)³ cells, \(particles.count) atoms, \(bonds?.pairs.count ?? 0) bonds"
                     + (images.count > 1 ? ", \(images.count) copies" : "") + ".", at: 0)
        if images.count > 1, bonds != nil {
            notes.append("Bonds are not periodic, so copies show seams.")
        }
        let scene = SceneData(particles: particles, bonds: bonds, lines: [LabLines.box(size: size)], images: images)
        return GeneratedScene(scene: scene, styleNames: styleNames, notes: notes)
    }
}
