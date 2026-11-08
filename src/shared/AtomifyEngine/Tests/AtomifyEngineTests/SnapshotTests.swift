import Testing
@testable import AtomifyEngine

@Suite struct SnapshotTests {
    /// Three atoms on the z axis at z = 0, 2 and 5.
    func line() -> SimulationSnapshot {
        SimulationSnapshot(typeCount: 2, boxLow: SIMD3(-1, -1, -1), boxHigh: SIMD3(1, 1, 6),
                           tags: [2, 5, 9], types: [1, 2, 1],
                           positions: [SIMD3(0, 0, 0), SIMD3(0, 0, 2), SIMD3(0, 0, 5)],
                           bonds: [SIMD2(0, 1)])
    }

    @Test func indexOfTag() {
        let snapshot = line()
        #expect(snapshot.atomCount == 3)
        #expect(snapshot.index(ofTag: 2) == 0)
        #expect(snapshot.index(ofTag: 9) == 2)
        #expect(snapshot.index(ofTag: 4) == nil)
        #expect(snapshot.index(ofTag: 10) == nil)
        #expect(snapshot.validationIssue == nil)
    }

    @Test func observableById() {
        var snapshot = line()
        snapshot.observables = [EngineObservable(kind: .compute, name: "msd", values: [1, 2, 3, 4], timestep: 0),
                                EngineObservable(kind: .thermo, name: "temp", values: [1], timestep: 0)]
        #expect(snapshot.observable(id: "thermo_temp")?.scalar == 1)
        #expect(snapshot.observable(id: "c_msd")?.values.count == 4)
        #expect(snapshot.observable(id: "c_temp") == nil)
    }

    @Test func nearestAtom() {
        let snapshot = line()
        #expect(snapshot.nearestAtom(to: SIMD3(0, 0, 1.8), within: 0.5) == 1)
        #expect(snapshot.nearestAtom(to: SIMD3(0, 0, 3.5), within: 1) == nil)
        #expect(snapshot.nearestAtom(to: SIMD3(0, 0, 3.6), within: 2) == 2)
    }

    @Test func rayHitsTheFirstAtomAlongIt() {
        let snapshot = line()
        let radius: (Int) -> Float = { _ in 0.5 }
        // From above, looking down the z axis: the atom at z = 5 is first.
        #expect(snapshot.atomHit(rayOrigin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, -3), radius: radius,
                                 tolerance: 0) == 2)
        // From below.
        #expect(snapshot.atomHit(rayOrigin: SIMD3(0, 0, -10), direction: SIMD3(0, 0, 1), radius: radius,
                                 tolerance: 0) == 0)
        // Looking away, and passing beside the atoms.
        #expect(snapshot.atomHit(rayOrigin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, 1), radius: radius,
                                 tolerance: 0) == nil)
        #expect(snapshot.atomHit(rayOrigin: SIMD3(1, 0, 10), direction: SIMD3(0, 0, -1), radius: radius,
                                 tolerance: 0) == nil)
        // The tolerance widens the target.
        #expect(snapshot.atomHit(rayOrigin: SIMD3(1, 0, 10), direction: SIMD3(0, 0, -1), radius: radius,
                                 tolerance: 0.6) == 2)
        // An origin inside an atom hits it.
        #expect(snapshot.atomHit(rayOrigin: SIMD3(0, 0, 2.1), direction: SIMD3(0, 0, -1), radius: radius,
                                 tolerance: 0) == 1)
        #expect(snapshot.atomHit(rayOrigin: SIMD3(0, 0, 10), direction: .zero, radius: radius, tolerance: 0) == nil)
    }

    @Test func orthogonalBox() {
        let snapshot = line()
        #expect(!snapshot.isTriclinic)
        #expect(snapshot.boxVectors.a == SIMD3(2, 0, 0))
        #expect(snapshot.boxVectors.b == SIMD3(0, 2, 0))
        #expect(snapshot.boxVectors.c == SIMD3(0, 0, 7))
        #expect(snapshot.bounds.low == SIMD3(-1, -1, -1))
        #expect(snapshot.bounds.high == SIMD3(1, 1, 6))
    }

    @Test func triclinicBox() {
        var snapshot = line()
        snapshot.boxLow = .zero
        snapshot.boxHigh = SIMD3(10, 10, 10)
        snapshot.tilt = SIMD3(2, -3, 1)    // xy, xz, yz
        #expect(snapshot.isTriclinic)
        #expect(snapshot.boxVectors.a == SIMD3(10, 0, 0))
        #expect(snapshot.boxVectors.b == SIMD3(2, 10, 0))
        #expect(snapshot.boxVectors.c == SIMD3(-3, 1, 10))
        // x spans min(0, xy, xz, xy + xz) ... max(...) beyond lo/hi.
        #expect(snapshot.bounds.low == SIMD3(-3, 0, 0))
        #expect(snapshot.bounds.high == SIMD3(12, 11, 10))
    }

    @Test func validation() {
        var snapshot = line()
        snapshot.positions[1].x = .nan
        #expect(snapshot.validationIssue != nil)

        snapshot = line()
        snapshot.types[2] = 3    // more than typeCount
        #expect(snapshot.validationIssue != nil)

        snapshot = line()
        snapshot.tags = [2, 9, 5]    // not sorted
        #expect(snapshot.validationIssue != nil)

        snapshot = line()
        snapshot.bonds = [SIMD2(0, 3)]
        #expect(snapshot.validationIssue != nil)

        snapshot = line()
        snapshot.radii = [0.5, -1, 0.5]
        #expect(snapshot.validationIssue != nil)
        snapshot.radii = [0.5, 0, 0.5]
        #expect(snapshot.validationIssue == nil)

        snapshot = line()
        snapshot.perAtomValues = [1, 2]
        #expect(snapshot.validationIssue != nil)
        snapshot.perAtomValues = [1, .nan, 2]    // NaN marks unknown values
        #expect(snapshot.validationIssue == nil)

        snapshot = line()
        snapshot.boxHigh.z = -2
        #expect(snapshot.validationIssue != nil)

        snapshot = line()
        snapshot.temperature = .infinity
        #expect(snapshot.validationIssue != nil)
    }

    @Test func runStatus() {
        var snapshot = line()
        #expect(snapshot.runMode == .idle)
        #expect(snapshot.runProgress == nil)
        snapshot.runMode = .dynamics
        snapshot.runStep = 250
        snapshot.runSteps = 1000
        #expect(snapshot.runProgress == 0.25)
        snapshot.runSteps = 0
        #expect(snapshot.runProgress == nil)
    }

    @Test func wallPlanes() {
        let zhi = WallPlane(face: 5, position: 6.5)
        #expect(zhi.axis == 2)
        #expect(zhi.isUpper)
        let xlo = WallPlane(face: 0, position: -1)
        #expect(xlo.axis == 0)
        #expect(!xlo.isUpper)
    }
}
