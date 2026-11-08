import AtomifyRender
import simd
import Testing
@testable import RenderLab

@Suite struct ZincblendeTests {
    static let siliconCarbideNearest: Float = 1.88776

    @Test(arguments: [1, 2, 3, 5])
    func atomCount(cells: Int) {
        let lattice = ZincblendeLattice(cells: cells)
        let expected = 8 * cells * cells * cells
        #expect(lattice.count == expected)
        #expect(lattice.positions().count == expected)
        #expect(lattice.sublatticeIndices().count == expected)
    }

    @Test(arguments: zip([1, 2, 3, 4], [7, 86, 333, 844]))
    func bondCount(cells: Int, expected: Int) {
        #expect(ZincblendeLattice(cells: cells).bonds().count == expected)
    }

    @Test(arguments: [1, 2, 4])
    func bondLengthsAreNearestNeighbours(cells: Int) {
        let lattice = ZincblendeLattice(cells: cells)
        let positions = lattice.positions()
        for pair in lattice.bonds() {
            let length = distance(positions, Int(pair.x), Int(pair.y))
            #expect(closeF(length, Self.siliconCarbideNearest, tolerance: 1e-4))
        }
    }

    @Test func nearestNeighbourDistance() {
        let lattice = ZincblendeLattice(cells: 1)
        #expect(lattice.latticeConstant == 4.3596)
        #expect(closeF(lattice.nearestNeighbourDistance, Self.siliconCarbideNearest, tolerance: 1e-4))
        #expect(closeF(lattice.boxLength, 4.3596))
        #expect(closeF(ZincblendeLattice(cells: 4).boxLength, 4 * 4.3596, tolerance: 1e-4))
    }

    @Test func bondsJoinTheTwoSublattices() {
        let lattice = ZincblendeLattice(cells: 2)
        let sublattice = lattice.sublatticeIndices()
        for pair in lattice.bonds() {
            #expect(sublattice[Int(pair.x)] == 1)
            #expect(sublattice[Int(pair.y)] == 0)
        }
    }

    @Test func bondsAreUniqueAndAtMostFourPerAtom() {
        let lattice = ZincblendeLattice(cells: 3)
        let bonds = lattice.bonds()
        #expect(Set(bonds).count == bonds.count)
        var degree = [Int](repeating: 0, count: lattice.count)
        for pair in bonds {
            degree[Int(pair.x)] += 1
            degree[Int(pair.y)] += 1
        }
        #expect(degree.max() == 4)
        // The atom at the centre of the crystal has all four.
        let center = lattice.index(cell: SIMD3<Int>(1, 1, 1), basis: 4)
        #expect(degree[center] == 4)
    }

    @Test func bondsMatchAllPairsSearch() {
        let lattice = ZincblendeLattice(cells: 2)
        let positions = lattice.positions()
        var expected = 0
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                let d = distance(positions, i, j)
                if closeF(d, Self.siliconCarbideNearest, tolerance: 1e-3) { expected += 1 }
            }
        }
        #expect(lattice.bonds().count == expected)
    }

    @Test func siteIndexInvertsPositions() {
        let lattice = ZincblendeLattice(cells: 2)
        let quarter = lattice.latticeConstant / 4
        for (index, p) in lattice.positions().enumerated() {
            let gx = Int((p.x / quarter).rounded())
            let gy = Int((p.y / quarter).rounded())
            let gz = Int((p.z / quarter).rounded())
            #expect(lattice.siteIndex(grid: SIMD3<Int>(gx, gy, gz)) == index)
        }
    }

    @Test func siteIndexRejectsNonSites() {
        let lattice = ZincblendeLattice(cells: 2)
        #expect(lattice.siteIndex(grid: SIMD3<Int>(1, 0, 0)) == nil)
        #expect(lattice.siteIndex(grid: SIMD3<Int>(-1, -1, -1)) == nil)
        #expect(lattice.siteIndex(grid: SIMD3<Int>(8, 0, 0)) == nil)
        #expect(lattice.siteIndex(grid: SIMD3<Int>(0, 0, 0)) == 0)
        #expect(lattice.siteIndex(grid: SIMD3<Int>(1, 1, 1)) == 4)
    }

    @Test func positionsInsideTheBox() {
        let lattice = ZincblendeLattice(cells: 3)
        let length = lattice.boxLength
        for p in lattice.positions() {
            #expect(p.x >= 0 && p.y >= 0 && p.z >= 0)
            #expect(p.x < length && p.y < length && p.z < length)
        }
    }

    @Test func halfOfTheAtomsAreOnEachSublattice() {
        let indices = ZincblendeLattice(cells: 2).sublatticeIndices()
        let second = indices.filter { $0 == 1 }.count
        #expect(second * 2 == indices.count)
        #expect(Array(indices.prefix(8)) == [0, 0, 0, 0, 1, 1, 1, 1])
    }

    @Test func atLeastOneCell() {
        #expect(ZincblendeLattice(cells: 0).cells == 1)
        #expect(ZincblendeLattice(cells: -3).count == 8)
    }
}

@Suite struct FCCLatticeTests {
    @Test(arguments: [1, 2, 4])
    func atomCount(cells: Int) {
        let lattice = FCCLattice(latticeConstant: 4.05, cells: cells)
        #expect(lattice.count == 4 * cells * cells * cells)
        #expect(lattice.positions().count == lattice.count)
    }

    @Test func nearestNeighbours() {
        let lattice = FCCLattice(latticeConstant: 4.05, cells: 2)
        let positions = lattice.positions()
        var smallest = Float.infinity
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                smallest = min(smallest, distance(positions, i, j))
            }
        }
        #expect(closeF(smallest, lattice.nearestNeighbourDistance, tolerance: 1e-4))
        #expect(closeF(lattice.nearestNeighbourDistance, 2.86378, tolerance: 1e-4))
        #expect(closeF(lattice.boxLength, 8.1))
    }

    @Test func atLeastOneCell() {
        #expect(FCCLattice(latticeConstant: 1, cells: 0).count == 4)
    }
}

@Suite struct CellsPerAxisTests {
    @Test(arguments: zip([10_000, 100_000, 1_000_000, 4_000_000, 8_000_000], [11, 23, 50, 79, 100]))
    func zincblende(target: Int, cells: Int) {
        #expect(cellsPerAxis(forAtoms: target, atomsPerCell: 8) == cells)
    }

    @Test func fcc() {
        #expect(cellsPerAxis(forAtoms: 4_000_000, atomsPerCell: 4) == 100)
        #expect(cellsPerAxis(forAtoms: 8_000_000, atomsPerCell: 4) == 126)
    }

    @Test func degenerate() {
        #expect(cellsPerAxis(forAtoms: 0, atomsPerCell: 8) == 1)
        #expect(cellsPerAxis(forAtoms: 3, atomsPerCell: 8) == 1)
        #expect(cellsPerAxis(forAtoms: 100, atomsPerCell: 0) == 1)
    }
}

@Suite struct SiliconCarbideSceneTests {
    @Test func defaultCrystal() {
        let generated = SiliconCarbideScene.make(cells: 4)
        let scene = generated.scene
        #expect(scene.particles.count == 512)
        #expect(scene.particles.styles.count == 2)
        #expect(scene.particles.styleIndices?.count == 512)
        #expect(generated.bondCount == 844)
        #expect(scene.bonds?.radius == SiliconCarbideScene.bondRadius)
        let maxLength = scene.bonds?.maxLength ?? 0
        #expect(maxLength > 1.88776 && maxLength < 2.5)
        #expect(scene.lines.count == 1)
        #expect(scene.lines.first?.segments.count == 12)
        #expect(generated.styleNames.count == 2)
        #expect(!generated.notes.isEmpty)
    }

    @Test func boundsHoldTheBox() {
        let generated = SiliconCarbideScene.make(cells: 2)
        let length = ZincblendeLattice(cells: 2).boxLength
        #expect(generated.bounds.low.x <= 0)
        #expect(generated.bounds.high.x >= length)
    }
}
