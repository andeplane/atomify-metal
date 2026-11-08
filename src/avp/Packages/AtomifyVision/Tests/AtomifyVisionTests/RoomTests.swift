import AtomifyEngine
import AtomifyVision
import Foundation
import simd
import Testing

@Suite struct RoomTests {
    @Test func pointTriangleDistanceCoversFaceEdgeAndCorner() {
        let t = DistanceGrid.Triangle([0, 0, 0], [1, 0, 0], [0, 1, 0])
        #expect(abs(DistanceGrid.distance(from: [0.2, 0.2, 0.5], to: t) - 0.5) < 1e-6)     // above the face
        #expect(abs(DistanceGrid.distance(from: [0.5, -1, 0], to: t) - 1) < 1e-6)          // beside edge ab
        #expect(abs(DistanceGrid.distance(from: [-3, -4, 0], to: t) - 5) < 1e-6)           // past corner a
        #expect(abs(DistanceGrid.distance(from: [1, 1, 0], to: t) - sqrtf(0.5)) < 1e-6)    // beside edge bc
    }

    @Test func gridMeasuresDistanceToAFloor() {
        // Floor at y = 0 made of two triangles.
        let floor = [DistanceGrid.Triangle([-2, 0, -2], [2, 0, -2], [2, 0, 2]),
                     DistanceGrid.Triangle([-2, 0, -2], [2, 0, 2], [-2, 0, 2])]
        let grid = DistanceGrid.build(triangles: floor, low: [-1, 0, -1], high: [1, 1, 1], spacing: 0.1,
                                      maxDistance: 0.3)
        #expect(grid.dimensions == SIMD3<Int32>(21, 11, 21))
        #expect(grid.value(10, 0, 10) == 0)
        #expect(abs(grid.value(10, 2, 10) - 0.2) < 1e-5)
        #expect(grid.value(10, 9, 10) == 0.3)    // beyond maxDistance
        let scaled = grid.scaled(by: 10)
        #expect(abs(scaled.value(10, 2, 10) - 2) < 1e-4)
        #expect(scaled.spacing == 1)
    }

    @Test func roomScriptsRunOnLAMMPSAndFitTheRoom() async throws {
        for preset in RoomScenario.Preset.allCases {
            let scenario = RoomScenario(preset: preset, amount: .fewer)
            let copy = try scenario.makeWorkingCopy()
            defer { try? FileManager.default.removeItem(at: copy.folder) }
            let simulation = try Simulation()
            simulation.start(script: copy.script, workingDirectory: copy.folder, continueAfterScript: false) { _ in }
            var snapshot: SimulationSnapshot?
            for _ in 0..<500 where snapshot == nil {
                try await Task.sleep(for: .milliseconds(10))
                snapshot = simulation.takeNewSnapshot()
            }
            let first = try #require(snapshot, "\(preset) produced no snapshot")
            #expect(first.atomCount == scenario.atomCount)
            #expect(abs(Float(first.boxHigh.y) * RoomScenario.metersPerUnit - RoomScenario.roomHigh.y) < 1e-3)
            simulation.cancel()
        }
    }

    @Test func tuningDependsOnUnits() {
        #expect(InteractionTuning.forUnits("lj") != InteractionTuning.forUnits("metal"))
        #expect(InteractionTuning.forUnits("unknown") == InteractionTuning.forUnits("lj"))
    }

    @Test func nearestAtomRespectsRadius() {
        let snapshot = SimulationSnapshot(typeCount: 1, boxLow: [0, 0, 0], boxHigh: [10, 10, 10], tags: [4, 8],
                                          types: [1, 1], positions: [[1, 1, 1], [5, 5, 5]])
        #expect(snapshot.nearestAtom(to: [4.5, 5, 5], within: 1) == 1)
        #expect(snapshot.nearestAtom(to: [3, 3, 3], within: 1) == nil)
    }
}
