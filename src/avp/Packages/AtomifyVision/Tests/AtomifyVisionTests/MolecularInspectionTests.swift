import AtomifyEngine
import AtomifyVision
import Testing
import Foundation

@Suite struct MolecularInspectionTests {
    private func snapshot(_ positions: [SIMD3<Float>], bonds: [SIMD2<UInt32>]) -> SimulationSnapshot {
        .init(typeCount: 1, periodic: [false, false, false], boxLow: [-10,-10,-10], boxHigh: [10,10,10],
              tags: (1...positions.count).map(Int64.init), types: positions.map { _ in 1 }, positions: positions, bonds: bonds)
    }
    @Test func tetrahedralAnglesAndDistance() throws {
        let a = Float(1.09 / sqrt(3.0))
        let s = snapshot([[0,0,0],[a,a,a],[a,-a,-a],[-a,a,-a],[-a,-a,a]], bonds: [[0,1],[0,2],[0,3],[0,4]])
        let m = try #require(MolecularInspection.measure(snapshot: s, tag: 1, pairedTag: 2))
        #expect(m.neighborTags == [2,3,4,5])
        #expect(abs(try #require(m.meanAngleDegrees) - 109.47122) < 0.0001)
        #expect(abs(try #require(m.pairDistance) - 1.09) < 0.0001)
    }
    @Test func planarAndDuplicateEdges() throws {
        let h = Float(sqrt(3.0) / 2)
        let s = snapshot([[0,0,0],[1,0,0],[-0.5,h,0],[-0.5,-h,0]], bonds: [[0,1],[1,0],[0,2],[0,3],[0,UInt32.max]])
        let m = try #require(MolecularInspection.measure(snapshot: s, tag: 1))
        #expect(m.neighborTags.count == 3)
        #expect(abs(try #require(m.meanAngleDegrees) - 120) < 0.0001)
    }
    @Test func periodicAndInvalidGeometry() throws {
        var s = snapshot([[0.5,0,0],[9.5,0,0]], bonds: [[0,1]])
        s.periodic = [true,false,false]; s.boxLow = [0,0,0]; s.boxHigh = [10,10,10]
        #expect(try #require(MolecularInspection.measure(snapshot: s, tag: 1, pairedTag: 2)?.pairDistance) == 1)
        #expect(MolecularInspection.measure(snapshot: s, tag: 99) == nil)
        s.positions[0].x = .nan
        #expect(MolecularInspection.measure(snapshot: s, tag: 1) == nil)
        s.positions[0].x = 0; s.tags = [2,1]
        #expect(MolecularInspection.measure(snapshot: s, tag: 1) == nil)
    }
}
