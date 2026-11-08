import AtomifyEngine
import AtomifyVision
import Foundation
import Testing

/// The app's use of the shared engine: interactions are released as a whole,
/// and a cancelled run keeps its last frame while a fresh one can start.
@Suite(.serialized) struct SimulationLifecycleTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    @Test func releaseInteractionsLetsGoOfTheGrab() async throws {
        let simulation = try Simulation()
        simulation.setFrozen(true)
        let outcome = OutcomeBox()
        simulation.start(script: Self.fixtures.appendingPathComponent("lj.in"), workingDirectory: Self.fixtures,
                         continueAfterScript: true) { outcome.set($0) }
        defer { simulation.cancel() }
        var grabbed: SimulationSnapshot?
        for _ in 0..<500 where grabbed == nil {
            simulation.grab(tag: 1, target: SIMD3(1, 1, 1), stiffness: 10)
            simulation.setForceSpheres([ForceSphere(center: SIMD3(3, 3, 3), radius: 1, strength: 1)])
            try await Task.sleep(for: .milliseconds(10))
            if let next = simulation.takeNewSnapshot(), next.grabTag == 1 { grabbed = next }
        }
        _ = try #require(grabbed)
        simulation.releaseInteractions()
        var released = false
        for _ in 0..<500 where !released {
            try await Task.sleep(for: .milliseconds(10))
            if let next = simulation.takeNewSnapshot(), next.grabTag == nil { released = true }
        }
        #expect(released)
    }

    @Test func wallsFromADistanceGridCanBeSetAndRemoved() async throws {
        let simulation = try Simulation()
        let outcome = OutcomeBox()
        let grid = DistanceGrid.build(triangles: [.init(SIMD3(0, 0, 0), SIMD3(8, 0, 0), SIMD3(0, 8, 0))],
                                      low: SIMD3(repeating: -1), high: SIMD3(repeating: 9), spacing: 1,
                                      maxDistance: 2)
        simulation.setWalls(grid, cutoff: 0.5, strength: 1)
        simulation.start(script: Self.fixtures.appendingPathComponent("lj.in"), workingDirectory: Self.fixtures,
                         continueAfterScript: false) { outcome.set($0) }
        #expect(await outcome.wait(seconds: 30) == .finished)
        simulation.setWalls(nil, cutoff: 0, strength: 0)
        simulation.cancel()
    }

    @Test func cancelledPausedEngineKeepsItsLastValidFrameAndAllowsFreshStart() async throws {
        let old = try Simulation()
        old.setPaused(true)
        let stopped = OutcomeBox()
        old.start(script: Self.fixtures.appendingPathComponent("lj.in"), workingDirectory: Self.fixtures,
                  continueAfterScript: true) { stopped.set($0) }
        var frame: SimulationSnapshot?
        for _ in 0..<300 where frame == nil {
            try await Task.sleep(for: .milliseconds(10))
            frame = old.takeNewSnapshot()
        }
        _ = try #require(frame)
        #expect(!old.hasCompletedInput) // A setup frame is not a completed preparation.
        old.releaseInteractions()
        old.cancel()
        #expect(await stopped.wait(seconds: 10) == .cancelled)
        for _ in 0..<200 where !old.isTerminated { try await Task.sleep(for: .milliseconds(10)) }
        #expect(old.isTerminated)
        #expect(old.lastKnownGoodSnapshot?.validationIssue == nil)
        #expect(old.lastKnownGoodSnapshot?.atomCount == 256)
        let fresh = try Simulation()
        let finished = OutcomeBox()
        fresh.start(script: Self.fixtures.appendingPathComponent("lj.in"), workingDirectory: Self.fixtures,
                    continueAfterScript: false) { finished.set($0) }
        #expect(await finished.wait(seconds: 10) == .finished)
        fresh.cancel()
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Simulation.Outcome?

    func set(_ value: Simulation.Outcome) {
        lock.lock(); outcome = value; lock.unlock()
    }

    func wait(seconds: Double) async -> Simulation.Outcome? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let value = lock.withLock { outcome }
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
