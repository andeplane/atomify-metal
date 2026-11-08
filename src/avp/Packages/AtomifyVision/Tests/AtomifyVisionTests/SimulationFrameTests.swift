import AtomifyEngine
import AtomifyVision
import simd
import Testing

private func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let r = m * SIMD4(p, 1)
    return SIMD3(r.x, r.y, r.z)
}

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-4 }

@Suite struct SimulationFrameTests {
    @Test func bondRadiusFollowsTheSmallestAtom() {
        let styles = AtomStyleTable(directives: .init(atomStyles: [
            1: AtomStyle(name: "O", color: RGBColor(hex: 0xff0000), radius: 0.5),
            2: AtomStyle(name: "H", color: RGBColor(hex: 0xffffff), radius: 0.2),
        ]), typeCount: 2, units: "real")
        #expect(abs(LabBonds.radius(styles: styles) - 0.07) < 1e-6)
        #expect(abs(LabBonds.radius(styles: styles, atomScale: 2) - 0.14) < 1e-6)
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
