import AtomifyEngine
import AtomifyVision
import Foundation
import simd
import Testing

/// Opt-in real engine runs with the app's generated room scripts and a
/// synthetic scanned room. This does not stand in for physical room capture.
@Suite(.serialized) struct RoomSoakTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ATOMIFY_ROOM_SOAK"] == "1"),
          .timeLimit(.minutes(10)))
    func allPresetsRemainFiniteWithRoomWallsAndHandContact() async throws {
        let low = SIMD3<Float>(-2.8, 0, -2.8), high = SIMD3<Float>(2.8, 2.8, 2.8)
        var triangles: [DistanceGrid.Triangle] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            triangles += [.init(a, b, c), .init(a, c, d)]
        }
        quad([low.x,low.y,low.z], [high.x,low.y,low.z], [high.x,low.y,high.z], [low.x,low.y,high.z])
        quad([low.x,high.y,low.z], [high.x,high.y,low.z], [high.x,high.y,high.z], [low.x,high.y,high.z])
        quad([low.x,low.y,low.z], [low.x,high.y,low.z], [low.x,high.y,high.z], [low.x,low.y,high.z])
        quad([high.x,low.y,low.z], [high.x,high.y,low.z], [high.x,high.y,high.z], [high.x,low.y,high.z])
        quad([low.x,low.y,low.z], [high.x,low.y,low.z], [high.x,high.y,low.z], [low.x,high.y,low.z])
        quad([low.x,low.y,high.z], [high.x,low.y,high.z], [high.x,high.y,high.z], [low.x,high.y,high.z])
        let grid = DistanceGrid.build(triangles: triangles, low: RoomScenario.roomLow, high: RoomScenario.roomHigh,
                                      spacing: 0.06, maxDistance: 0.14).scaled(by: 1 / RoomScenario.metersPerUnit)
        for preset in RoomScenario.Preset.allCases {
            let scenario = RoomScenario(preset: preset, amount: .more)
            let copy = try scenario.makeWorkingCopy()
            defer { try? FileManager.default.removeItem(at: copy.folder) }
            let simulation = try Simulation()
            defer { simulation.cancel() }
            simulation.setPublishInterval(0.02)
            simulation.setWalls(grid, cutoff: RoomScenario.wallCutoff, strength: RoomScenario.wallStrength)
            let completion = RoomSoakCompletion()
            simulation.start(script: copy.script, workingDirectory: copy.folder, continueAfterScript: true) { completion.set($0) }
            var last: SimulationSnapshot?
            var samples = 0, contactSamples = 0
            let deadline = ContinuousClock.now + .seconds(150)
            while ContinuousClock.now < deadline, completion.value == nil {
                if let s = simulation.takeNewSnapshot() {
                    #expect(s.validationIssue == nil)
                    #expect(s.atomCount == scenario.atomCount)
                    let contained = s.positions.allSatisfy { point in
                        let meters = point * RoomScenario.metersPerUnit
                        return (0..<3).allSatisfy { meters[$0] >= low[$0] - 0.06 && meters[$0] <= high[$0] + 0.06 }
                    }
                    #expect(contained, "An atom escaped the fully represented synthetic room")
                    last = s; samples += 1
                    // Six overlapping moving hand colliders share the LJ force
                    // budget, with intentional tracking gaps every ten samples.
                    if samples % 10 < 7 {
                        let x = 8 * sin(Double(samples) * 0.1)
                        simulation.setForceSpheres((0..<6).map { i in
                            .init(center: [x, 32.5 + Double(i) * 0.1, -30], radius: 4,
                                  strength: InteractionTuning.forUnits("lj").pushStrength)
                        })
                        contactSamples += 1
                    } else { simulation.setForceSpheres([]) }
                    if s.timestep >= 30_000 { break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            simulation.releaseInteractions()
            simulation.cancel()
            for _ in 0..<500 where completion.value == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(completion.value == .cancelled)
            let s = try #require(last)
            #expect(s.timestep >= 30_000)
            #expect(contactSamples > 0)
            print("ROOM_SOAK preset=\(preset.rawValue) atoms=\(s.atomCount) step=\(s.timestep) samples=\(samples) contact_samples=\(contactSamples) temperature=\(s.temperature) finite=\(s.validationIssue == nil)")
        }
    }
}

private final class RoomSoakCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Simulation.Outcome?
    var value: Simulation.Outcome? { lock.withLock { outcome } }
    func set(_ value: Simulation.Outcome) { lock.withLock { outcome = value } }
}
