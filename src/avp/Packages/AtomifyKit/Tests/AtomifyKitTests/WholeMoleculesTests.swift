import Foundation
import Testing
import simd
@testable import AtomifyKit

private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
    simd_length(a - b) < tolerance
}

/// Water-like rule: oxygen (1) to hydrogen (2) closer than 1.25.
private let waterRule = [BondRule(type1: 1, type2: 2, cutoff: 1.25)]
private let box = (low: SIMD3<Double>(0, 0, 0), high: SIMD3<Double>(10, 10, 10))

private func whole(_ positions: [SIMD3<Float>], types: [Int32], periodic: [Bool] = [true, true, true],
                   bonds: [SIMD2<UInt32>] = [], rules: [BondRule] = waterRule) -> WholeMolecules {
    WholeMolecules.make(positions: positions, types: types, boxLow: box.low, boxHigh: box.high,
                        periodic: periodic, bonds: bonds, rules: rules)
}

struct WholeMoleculesTests {
    @Test func aMoleculeSplitAcrossXIsDrawnWholeAroundItsFirstAtom() {
        // O just inside the high x face; one H wrapped to the low side, one
        // H on the same side (already bonded by the engine).
        let positions: [SIMD3<Float>] = [[9.6, 5, 5], [0.3, 5, 5], [9.4, 5.9, 5]]
        let result = whole(positions, types: [1, 2, 2], bonds: [[0, 2]])
        #expect(result.crossingBonds == [[0, 1]])
        #expect(near(result.positions[0], [9.6, 5, 5]))
        #expect(near(result.positions[1], [10.3, 5, 5]))
        #expect(near(result.positions[2], [9.4, 5.9, 5]))
        #expect(near(result.shifts[1], [10, 0, 0]))
        #expect(result.shifts[0] == .zero && result.shifts[2] == .zero)
        // Every drawn bond is short.
        for bond in result.crossingBonds + [[0, 2]] {
            #expect(simd_distance(result.positions[Int(bond.x)], result.positions[Int(bond.y)]) < 1.25)
        }
        #expect(result.movesAtoms)
    }

    @Test func theLowestIndexAtomStaysInTheBox() {
        // The H has the lower index, so the O is drawn next to it instead.
        let result = whole([[0.3, 5, 5], [9.6, 5, 5]], types: [2, 1])
        #expect(near(result.positions[0], [0.3, 5, 5]))
        #expect(near(result.positions[1], [-0.4, 5, 5]))
        #expect(near(result.shifts[1], [-10, 0, 0]))
    }

    @Test func aMoleculeSplitAcrossACornerIsJoinedInBothAxes() {
        // O near the (high x, low z) edge; one H wrapped in x, one in z,
        // one in both.
        let o: SIMD3<Float> = [9.7, 5, 0.2]
        let positions: [SIMD3<Float>] = [o, [0.4, 5, 0.3], [9.6, 5, 9.5], [0.2, 5.1, 9.6]]
        let rules = waterRule + [BondRule(type1: 1, type2: 3, cutoff: 1.25)]
        let result = whole(positions, types: [1, 2, 2, 3], rules: rules)
        #expect(Set(result.crossingBonds) == Set([[0, 1], [0, 2], [0, 3]]))
        #expect(near(result.positions[1], [10.4, 5, 0.3]))
        #expect(near(result.positions[2], [9.6, 5, -0.5]))
        #expect(near(result.positions[3], [10.2, 5.1, -0.4]))
        #expect(near(result.shifts[3], [10, 0, -10]))
    }

    @Test func nonPeriodicAxesAreNeverWrapped() {
        // Same split, but x is a wall: the atoms really are 9.3 apart.
        let positions: [SIMD3<Float>] = [[9.6, 5, 5], [0.3, 5, 5]]
        let walls = whole(positions, types: [1, 2], periodic: [false, true, true])
        #expect(walls.crossingBonds.isEmpty)
        #expect(walls.positions == positions)
        #expect(!walls.movesAtoms)
        // A bond the engine reports along a non-periodic axis is left as it is.
        let bonded = whole([[4.5, 0.2, 5], [5.5, 0.4, 5]], types: [1, 2], periodic: [true, false, true],
                           bonds: [[0, 1]])
        #expect(bonded.positions == [[4.5, 0.2, 5], [5.5, 0.4, 5]])
        let nothingPeriodic = whole(positions, types: [1, 2], periodic: [false, false, false])
        #expect(nothingPeriodic.positions == positions && nothingPeriodic.crossingBonds.isEmpty)
    }

    @Test func onlyRulePairsWithinTheirCutoffJoin() {
        // Two hydrogens across a face: no 2–2 rule. An O–H pair 1.4 apart by
        // minimum image: beyond the 1.25 cutoff.
        let result = whole([[9.8, 5, 5], [0.1, 5, 5], [9.5, 2, 2], [0.9, 2, 2]], types: [2, 2, 1, 2])
        #expect(result.crossingBonds.isEmpty)
        #expect(!result.movesAtoms)
    }

    @Test func aNetworkIsDrawnAsSimulatedWhenTheFlagIsOff() {
        // A periodic chain through the box: every atom bonds to the next
        // and the last to the first through the face.
        let positions: [SIMD3<Float>] = (0..<10).map { [Float($0) + 0.5, 5, 5] }
        let rules = [BondRule(type1: 1, type2: 1, cutoff: 1.1)]
        let snapshot = SimulationSnapshot(typeCount: 1, boxLow: box.low, boxHigh: box.high,
                                          tags: Array(1...10), types: Array(repeating: 1, count: 10),
                                          positions: positions,
                                          bonds: (0..<9).map { SIMD2(UInt32($0), UInt32($0 + 1)) })
        #expect(WholeMolecules.make(snapshot: snapshot, rules: rules, enabled: false) == nil)
        // When on, the infinite chain is unrolled once from its first atom
        // and the closing bond is found, but the first atom stays put.
        let on = WholeMolecules.make(snapshot: snapshot, rules: rules, enabled: true)
        #expect(on?.crossingBonds == [[0, 9]])
        #expect(on?.positions[0] == positions[0])
    }

    @Test func manySmallMoleculesScaleLinearly() {
        // 1000 three-atom molecules in a 31-unit box, a third of them
        // split across a face.
        var positions: [SIMD3<Float>] = []
        var types: [Int32] = []
        var bonds: [SIMD2<UInt32>] = []
        var split = 0
        for m in 0..<1000 {
            let base = SIMD3<Float>(Float(m % 10) * 3.1 + 0.05, Float((m / 10) % 10) * 3.1 + 1.5,
                                    Float(m / 100) * 3.1 + 1.5)
            let o = positions.count
            positions.append(base)
            positions.append(base + [-0.8, 0.6, 0])   // may fall below x = 0
            positions.append(base + [0.8, 0.6, 0])
            types += [1, 2, 2]
            bonds.append(SIMD2(UInt32(o), UInt32(o + 2)))
            if positions[o + 1].x < 0 {
                positions[o + 1].x += 31
                split += 1
            } else {
                bonds.append(SIMD2(UInt32(o), UInt32(o + 1)))
            }
        }
        let start = ContinuousClock.now
        let result = WholeMolecules.make(positions: positions, types: types, boxLow: .zero,
                                         boxHigh: [31, 31, 31], periodic: [true, true, true],
                                         bonds: bonds, rules: waterRule)
        let elapsed = ContinuousClock.now - start
        #expect(result.crossingBonds.count == split)
        #expect(split == 100)
        for bond in bonds + result.crossingBonds {
            #expect(simd_distance(result.positions[Int(bond.x)], result.positions[Int(bond.y)]) < 1.25)
        }
        #expect(elapsed < .milliseconds(50))
    }
}

/// The water experience on the real engine: every hydrogen is drawn bonded
/// to an oxygen next to it, whichever faces the molecules straddle.
@Suite(.serialized) struct WholeWaterTests {
    @Test func everyWaterMoleculeIsDrawnWhole() async throws {
        let demo = Demo(id: "water", title: "Water", summary: "", category: "", folder: "water",
                        inputScript: "water.in")
        let folder = DemoCatalogTests.demosDirectory.appendingPathComponent(demo.folder)
        try #require(FileManager.default.fileExists(atPath: folder.appendingPathComponent(demo.inputScript).path))
        let copy = try DemoCatalog.makeWorkingCopy(of: demo, from: DemoCatalogTests.demosDirectory)
        defer { try? FileManager.default.removeItem(at: copy.folder) }
        let directives = ScriptDirectives.parse(try String(contentsOf: copy.script, encoding: .utf8))
        let simulation = try LammpsSimulation()
        simulation.setBondRules(directives.bondRules)
        simulation.start(script: copy.script, directory: copy.folder, continueAfterScript: true) { _ in }
        defer { simulation.cancel() }
        var snapshot: SimulationSnapshot?
        let deadline = ContinuousClock.now + .seconds(60)
        while snapshot == nil, ContinuousClock.now < deadline {
            if let next = simulation.takeNewSnapshot(), next.atomCount > 0 { snapshot = next }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frame = try #require(snapshot, "Water produced no atoms")
        let result = try #require(WholeMolecules.make(snapshot: frame, rules: directives.bondRules, enabled: true))
        #expect(!result.crossingBonds.isEmpty, "343 molecules in a periodic box: some straddle a face")
        var bondedHydrogens = Set<Int>()
        for bond in frame.bonds + result.crossingBonds {
            let a = Int(bond.x), b = Int(bond.y)
            #expect(simd_distance(result.positions[a], result.positions[b]) < 1.25)
            if frame.types[a] == 2 { bondedHydrogens.insert(a) }
            if frame.types[b] == 2 { bondedHydrogens.insert(b) }
        }
        let hydrogens = frame.types.indices.filter { frame.types[$0] == 2 }
        #expect(hydrogens.count == 686)
        #expect(bondedHydrogens.count == hydrogens.count)
        // Shifts are whole box lengths.
        let length = SIMD3<Float>(frame.boxHigh - frame.boxLow)
        for shift in result.shifts {
            let cells = shift / length
            #expect(near(cells, cells.rounded(.toNearestOrEven), 1e-3))
        }
    }
}
