import AtomifyEngine
import Testing
import simd
@testable import AtomifyVision

struct RoomEncounterTests {
    let patch = DistanceGrid.Triangle(SIMD3(-0.25, -0.2, -1), SIMD3(0.25, -0.2, -1), SIMD3(0, 0.3, -1))

    func snapshot(_ sequence: UInt64, distance: Float, x: Float = 0, timestep: Int64? = nil) -> SimulationSnapshot {
        .init(sequence: sequence, timestep: timestep ?? Int64(sequence), typeCount: 1,
              boxLow: [-100, -100, -100], boxHigh: [100, 100, 100],
              tags: [7], types: [1], positions: [SIMD3(x, 0, -1 + distance) / RoomScenario.metersPerUnit])
    }

    @Test func measuredApproachAndDepartureQualify() {
        var state = RoomEncounter()
        for (i, distance): (Int, Float) in [0.17, 0.145, 0.119, 0.148].enumerated() {
            state.observe(snapshot: snapshot(UInt64(i + 1), distance: distance), patch: patch, active: true, at: Double(i) * 0.11)
        }
        #expect(state.witnessTag == 7)
        #expect(state.observedTurn)
    }

    @Test func crossingThroughTheSurfaceDoesNotQualify() {
        var state = RoomEncounter()
        for (i, distance): (Int, Float) in [0.17, 0.119, -0.148].enumerated() {
            state.observe(snapshot: snapshot(UInt64(i + 1), distance: distance), patch: patch, active: true, at: Double(i) * 0.11)
        }
        #expect(!state.observedTurn)
    }

    @Test func movingPastAnEdgeWithoutNormalDepartureDoesNotQualify() {
        var state = RoomEncounter()
        state.observe(snapshot: snapshot(1, distance: 0.17), patch: patch, active: true, at: 0)
        state.observe(snapshot: snapshot(2, distance: 0.119), patch: patch, active: true, at: 0.11)
        state.observe(snapshot: snapshot(3, distance: 0.119, x: 0.3), patch: patch, active: true, at: 0.22)
        #expect(!state.observedTurn)
    }

    @Test func pauseCannotSpliceTwoSeparateMovements() {
        var state = RoomEncounter()
        state.observe(snapshot: snapshot(1, distance: 0.17), patch: patch, active: true, at: 0)
        state.observe(snapshot: snapshot(2, distance: 0.119), patch: patch, active: true, at: 0.11)
        state.observe(snapshot: snapshot(3, distance: 0.119), patch: patch, active: false, at: 0.22)
        state.observe(snapshot: snapshot(4, distance: 0.148), patch: patch, active: true, at: 0.33)
        #expect(!state.observedTurn)
    }

    @Test func duplicateAndStaleSnapshotsCannotSupplyMotion() {
        var state = RoomEncounter()
        state.observe(snapshot: snapshot(1, distance: 0.17), patch: patch, active: true, at: 0)
        state.observe(snapshot: snapshot(1, distance: 0.119), patch: patch, active: true, at: 0.11)
        state.observe(snapshot: snapshot(1, distance: 0.148), patch: patch, active: true, at: 0.22)
        #expect(!state.observedTurn)
        state.observe(snapshot: snapshot(1, distance: 0.148), patch: patch, active: true, at: 0.6)
        #expect(state.witnessTag == nil)
        #expect(!state.observedTurn)
    }

    @Test func freshSnapshotAfterGapStartsNewEvidence() {
        var state = RoomEncounter()
        state.observe(snapshot: snapshot(1, distance: 0.17), patch: patch, active: true, at: 0)
        state.observe(snapshot: snapshot(2, distance: 0.119), patch: patch, active: true, at: 0.11)
        state.observe(snapshot: snapshot(3, distance: 0.148), patch: patch, active: true, at: 0.5)
        #expect(!state.observedTurn)
    }

    @Test func frozenTimestepAndLargePositionJumpDiscardEvidence() {
        var state = RoomEncounter()
        state.observe(snapshot: snapshot(1, distance: 0.17), patch: patch, active: true, at: 0)
        state.observe(snapshot: snapshot(2, distance: 0.119, timestep: 1), patch: patch, active: true, at: 0.11)
        state.observe(snapshot: snapshot(3, distance: 0.148), patch: patch, active: true, at: 0.22)
        #expect(!state.observedTurn)
        state.reset()
        state.observe(snapshot: snapshot(1, distance: 0.17, x: -0.2), patch: patch, active: true, at: 0)
        state.observe(snapshot: snapshot(2, distance: 0.119, x: 0.2), patch: patch, active: true, at: 0.11)
        state.observe(snapshot: snapshot(3, distance: 0.148, x: 0.2), patch: patch, active: true, at: 0.22)
        #expect(!state.observedTurn)
    }

    @Test func boundedSearchRotatesAcrossAllTags() {
        var state = RoomEncounter()
        var points = [SIMD3<Float>](repeating: [100, 100, 100], count: 300)
        points[299] = SIMD3(0, 0, -0.83) / RoomScenario.metersPerUnit
        var frame = SimulationSnapshot(sequence: 1, timestep: 1, typeCount: 1,
            boxLow: [-100, -100, -100], boxHigh: [100, 100, 100],
            tags: Array(1...300).map(Int64.init), types: [Int32](repeating: 1, count: 300), positions: points)
        state.observe(snapshot: frame, patch: patch, active: true, at: 0)
        #expect(state.witnessTag == nil)
        frame.sequence = 2; frame.timestep = 2
        state.observe(snapshot: frame, patch: patch, active: true, at: 0.11)
        #expect(state.witnessTag == 300)
    }

    @Test func guideRemainsInsideRealObservedTriangleAndInFront() throws {
        let source = DistanceGrid.Triangle(SIMD3(-1, 1, -1), SIMD3(1, 1, -1), SIMD3(0, 2, -1))
        let behind = DistanceGrid.Triangle(SIMD3(-0.5, 1, 1), SIMD3(0.5, 1, 1), SIMD3(0, 2, 1))
        var pose = matrix_identity_float4x4
        pose.columns.3.y = 1.6
        let selected = try #require(RoomEncounter.selectPatch(from: [behind, source], worldFromWearer: pose))
        let center = (selected.a + selected.b + selected.c) / 3
        #expect(center.z == -1)
        for point in [selected.a, selected.b, selected.c] {
            #expect(DistanceGrid.distance(from: point, to: source) < 1e-5)
            #expect(simd_distance(point, center) <= 0.25001)
        }
        #expect(RoomEncounter.selectPatch(from: [behind], worldFromWearer: pose) == nil)
    }

    @Test func tinyObservedGeometryIsFallbackAndInvalidGeometryIsRejected() throws {
        var pose = matrix_identity_float4x4
        pose.columns.3.y = 1.6
        let small = DistanceGrid.Triangle(SIMD3(-0.02, 1.4, -1), SIMD3(0.02, 1.4, -1), SIMD3(0, 1.45, -1))
        let selected = try #require(RoomEncounter.selectPatch(from: [small], worldFromWearer: pose))
        #expect(selected == small)
        let degenerate = DistanceGrid.Triangle(.zero, .zero, .zero)
        #expect(RoomEncounter.selectPatch(from: [degenerate], worldFromWearer: pose) == nil)
        pose.columns.0.x = .nan
        #expect(RoomEncounter.selectPatch(from: [small], worldFromWearer: pose) == nil)
    }
}
