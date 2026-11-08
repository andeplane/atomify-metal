import AtomifyEngine
import AtomifyVision
import simd
import Testing

private func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let r = m * SIMD4(p, 1)
    return SIMD3(r.x, r.y, r.z)
}

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-4 }

@Suite struct InstanceBuilderTests {
    @Test func cylinderSpansSegment() throws {
        for (start, end) in [(SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 2, 0)), ([1, 2, 3], [-4, 0.5, 7]),
                             ([0, 0, 0], [3, 0, 0]), ([0, 0, 0], [0, -1, 0])] {
            let m = try #require(InstanceBuilder.cylinderTransform(from: start, to: end, radius: 0.1))
            // The unit cylinder runs from y = -0.5 to y = 0.5.
            #expect(close(apply(m, [0, -0.5, 0]), start))
            #expect(close(apply(m, [0, 0.5, 0]), end))
            // Its rim stays at the requested radius, perpendicular to the axis.
            let rim = apply(m, [1, 0, 0]) - (start + end) / 2
            #expect(abs(simd_length(rim) - 0.1) < 1e-5)
            #expect(abs(simd_dot(rim, simd_normalize(end - start))) < 1e-5)
            #expect(simd_determinant(m) > 0)
        }
        #expect(InstanceBuilder.cylinderTransform(from: [1, 1, 1], to: [1, 1, 1], radius: 1) == nil)
    }

    @Test func boxHasTwelveEdges() {
        let edges = InstanceBuilder.boxEdges(low: [0, 0, 0], high: [1, 2, 3], radius: 0.01)
        #expect(edges.count == 12)
    }

    @Test func groupsAtomsAndHalfBondsByType() {
        let snapshot = SimulationSnapshot(typeCount: 2, boxLow: [0, 0, 0], boxHigh: [10, 10, 10],
                                          tags: [1, 2, 3], types: [1, 2, 2],
                                          positions: [[1, 1, 1], [2, 1, 1], [5, 5, 5]], bonds: [[0, 1]])
        let styles = AtomStyleTable(directives: .init(), typeCount: 2, units: "lj")
        let batches = InstanceBuilder.build(snapshot: snapshot, styles: styles, atomScale: 2,
                                            bondRadius: 0.1, includeBonds: true)
        #expect(batches.atoms[1]?.count == 1)
        #expect(batches.atoms[2]?.count == 2)
        #expect(batches.atoms[1]?.first?.columns.0.x == 1.0)    // 0.5 * atomScale 2
        #expect(batches.halfBonds[1]?.count == 1)
        #expect(batches.halfBonds[2]?.count == 1)
        let noBonds = InstanceBuilder.build(snapshot: snapshot, styles: styles, atomScale: 1, bondRadius: 0.1,
                                            includeBonds: false)
        #expect(noBonds.halfBonds.isEmpty)
    }

    @Test func perAtomRadiiOverrideTypeRadius() {
        let snapshot = SimulationSnapshot(typeCount: 1, boxLow: [0, 0, 0], boxHigh: [1, 1, 1], tags: [1, 2],
                                          types: [1, 1], positions: [[0, 0, 0], [1, 1, 1]], radii: [0.25, 0.75])
        let batches = InstanceBuilder.build(snapshot: snapshot, styles: .init(directives: .init(), typeCount: 1, units: "lj"),
                                            atomScale: 1, bondRadius: 0, includeBonds: true)
        #expect(batches.atoms[1]?.map { $0.columns.0.x } == [0.25, 0.75])
    }

    @Test func focusPreservesEveryAtomAndOnlyEmphasizesLocalBonds() {
        let s = SimulationSnapshot(typeCount: 1, boxLow: [0,0,0], boxHigh: [10,10,10],
                                   tags: [1,2,3], types: [1,1,1], positions: [[1,1,1],[2,1,1],[3,1,1]], bonds: [[0,1],[1,2]])
        let batches = InstanceBuilder.build(snapshot: s, styles: .init(directives: .init(), typeCount: 1, units: "lj"),
                                            atomScale: 1, bondRadius: 0.1, includeBonds: true, focusedTags: [1,2])
        #expect(batches.atoms[1]?.count == 2)
        #expect(batches.contextAtoms[1]?.count == 1)
        #expect(batches.halfBonds[1]?.count == 2)
        #expect(batches.contextHalfBonds[1]?.count == 2)
        #expect(batches.contextAtoms[1]?.first?.columns.3.x == 3)
    }

    @Test func frameFitsLongestSideAndRoundTrips() {
        let frame = SimulationFrame(boxLow: [0, 0, 0], boxHigh: [20, 10, 10], size: 0.5)
        #expect(abs(frame.metersPerUnit - 0.025) < 1e-6)
        let m = frame.localFromSimulation
        #expect(close(apply(m, [10, 5, 5]), [0, 0, 0]))
        #expect(close(apply(m, [20, 5, 5]), [0.25, 0, 0]))
        #expect(close(frame.simulationPoint(fromLocal: [0.25, 0, 0]), [20, 5, 5]))
    }

    @Test func snapshotFindsAtomsByTag() {
        let snapshot = SimulationSnapshot(typeCount: 1, boxLow: [0, 0, 0], boxHigh: [1, 1, 1], tags: [2, 5, 9],
                                          types: [1, 1, 1], positions: [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        #expect(snapshot.index(ofTag: 5) == 1)
        #expect(snapshot.index(ofTag: 9) == 2)
        #expect(snapshot.index(ofTag: 3) == nil)
    }
}
