import Foundation
import simd

/// A cubic zincblende crystal (3C-SiC, GaAs, …) of `cells`³ conventional
/// unit cells, eight atoms each: four on the first sublattice (fcc sites)
/// and four on the second, shifted by a quarter of the body diagonal.
///
/// Atom `8 * cell + b` sits in cell `cell = (z * n + y) * n + x` at basis
/// site `b`; sites 0–3 are the first sublattice (Si), 4–7 the second (C).
struct ZincblendeLattice: Sendable, Equatable {
    var latticeConstant: Float
    var cells: Int

    static let atomsPerCell = 8
    /// 3C-SiC at room temperature, Å.
    static let siliconCarbideLatticeConstant: Float = 4.3596

    /// Basis sites in units of a/4.
    static let basis: [SIMD3<Int>] = [
        SIMD3(0, 0, 0), SIMD3(0, 2, 2), SIMD3(2, 0, 2), SIMD3(2, 2, 0),
        SIMD3(1, 1, 1), SIMD3(1, 3, 3), SIMD3(3, 1, 3), SIMD3(3, 3, 1),
    ]

    /// From a second-sublattice atom to its four first-sublattice
    /// neighbours, in units of a/4.
    static let bondDirections: [SIMD3<Int>] = [
        SIMD3(-1, -1, -1), SIMD3(1, 1, -1), SIMD3(1, -1, 1), SIMD3(-1, 1, 1),
    ]

    /// Basis index of each position inside a cell (units of a/4, key
    /// x·16 + y·4 + z), or -1 where there is no atom.
    private static let basisLookup: [Int] = {
        var table = [Int](repeating: -1, count: 64)
        for (index, site) in ZincblendeLattice.basis.enumerated() {
            table[site.x * 16 + site.y * 4 + site.z] = index
        }
        return table
    }()

    init(latticeConstant: Float = ZincblendeLattice.siliconCarbideLatticeConstant, cells: Int) {
        self.latticeConstant = latticeConstant
        self.cells = max(cells, 1)
    }

    var count: Int { Self.atomsPerCell * cells * cells * cells }
    var boxLength: Float { latticeConstant * Float(cells) }
    /// a·√3/4: 1.888 Å for SiC.
    var nearestNeighbourDistance: Float { latticeConstant * Float(3).squareRoot() / 4 }

    func index(cell: SIMD3<Int>, basis b: Int) -> Int {
        ((cell.z * cells + cell.y) * cells + cell.x) * Self.atomsPerCell + b
    }

    /// The atom at grid point `g` (units of a/4 from the origin), or nil
    /// when `g` is outside the crystal or not an atom site.
    func siteIndex(grid g: SIMD3<Int>) -> Int? {
        let limit = 4 * cells
        guard g.x >= 0, g.y >= 0, g.z >= 0, g.x < limit, g.y < limit, g.z < limit else { return nil }
        let b = Self.basisLookup[(g.x & 3) * 16 + (g.y & 3) * 4 + (g.z & 3)]
        guard b >= 0 else { return nil }
        return index(cell: SIMD3(g.x >> 2, g.y >> 2, g.z >> 2), basis: b)
    }

    func positions() -> [SIMD3<Float>] {
        let quarter = latticeConstant / 4
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        for z in 0..<cells {
            for y in 0..<cells {
                for x in 0..<cells {
                    for site in Self.basis {
                        let gx = Float(4 * x + site.x)
                        let gy = Float(4 * y + site.y)
                        let gz = Float(4 * z + site.z)
                        result.append(SIMD3(gx, gy, gz) * quarter)
                    }
                }
            }
        }
        return result
    }

    /// 0 for the first sublattice, 1 for the second, in atom order.
    func sublatticeIndices() -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(count)
        let cell: [UInt16] = [0, 0, 0, 0, 1, 1, 1, 1]
        for _ in 0..<(cells * cells * cells) {
            result.append(contentsOf: cell)
        }
        return result
    }

    /// Every nearest-neighbour pair inside the crystal (second-sublattice
    /// atom, first-sublattice atom). Not periodic: pairs that would cross
    /// the box are left out.
    func bonds() -> [SIMD2<UInt32>] {
        var result: [SIMD2<UInt32>] = []
        result.reserveCapacity(2 * count)
        for z in 0..<cells {
            for y in 0..<cells {
                for x in 0..<cells {
                    let cell = SIMD3<Int>(x, y, z)
                    for b in 4..<8 {
                        let site = Self.basis[b]
                        let atom = UInt32(index(cell: cell, basis: b))
                        for direction in Self.bondDirections {
                            let gx = 4 * x + site.x + direction.x
                            let gy = 4 * y + site.y + direction.y
                            let gz = 4 * z + site.z + direction.z
                            if let neighbour = siteIndex(grid: SIMD3<Int>(gx, gy, gz)) {
                                result.append(SIMD2<UInt32>(atom, UInt32(neighbour)))
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}

/// A face-centred cubic crystal of `cells`³ unit cells, four atoms each.
struct FCCLattice: Sendable, Equatable {
    var latticeConstant: Float
    var cells: Int

    static let atomsPerCell = 4
    static let basis: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, 0.5, 0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0.5, 0)]

    init(latticeConstant: Float, cells: Int) {
        self.latticeConstant = latticeConstant
        self.cells = max(cells, 1)
    }

    var count: Int { Self.atomsPerCell * cells * cells * cells }
    var boxLength: Float { latticeConstant * Float(cells) }
    /// a/√2.
    var nearestNeighbourDistance: Float { latticeConstant / Float(2).squareRoot() }

    func positions() -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        for z in 0..<cells {
            for y in 0..<cells {
                for x in 0..<cells {
                    let origin = SIMD3(Float(x), Float(y), Float(z))
                    for site in Self.basis {
                        result.append((origin + site) * latticeConstant)
                    }
                }
            }
        }
        return result
    }
}

/// Cells per axis so a cubic crystal holds about `target` atoms.
func cellsPerAxis(forAtoms target: Int, atomsPerCell: Int) -> Int {
    guard target > 0, atomsPerCell > 0 else { return 1 }
    return max(1, Int(cbrt(Double(target) / Double(atomsPerCell)).rounded()))
}
