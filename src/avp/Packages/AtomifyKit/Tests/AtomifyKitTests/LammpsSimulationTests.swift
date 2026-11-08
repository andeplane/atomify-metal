import AtomifyKit
import Foundation
import Testing

/// Runs the real engine (the macOS slice of CLammps.xcframework).
@Suite(.serialized) struct LammpsSimulationTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    @Test func runsScriptAndPublishesTagSortedSnapshots() async throws {
        let simulation = try LammpsSimulation()
        simulation.setBondRules(ScriptDirectives.parse("#/bond 1 1 1.2").bondRules)
        let outcome = OutcomeBox()
        simulation.start(script: Self.fixtures.appendingPathComponent("lj.in"), directory: Self.fixtures,
                         continueAfterScript: false) { outcome.set($0) }
        let finished = await outcome.wait(seconds: 30)
        #expect(finished == .finished)
        #expect(simulation.hasCompletedInput)
        #expect(simulation.takeNewSnapshot() == nil)
        #expect(simulation.lastKnownGoodSnapshot?.timestep == 100)
    }

    @Test func finiteObservationEndsExactlyAndKeepsItsStudyFrame() async throws {
        let simulation = try LammpsSimulation()
        let outcome = OutcomeBox()
        simulation.start(script: Self.fixtures.appendingPathComponent("lj.in"), directory: Self.fixtures,
                         continueAfterScript: true, continuationSteps: 25) { outcome.set($0) }
        #expect(await outcome.wait(seconds: 10) == .finished)
        #expect(simulation.isTerminated)
        #expect(simulation.hasCompletedInput)
        let final = try #require(simulation.lastKnownGoodSnapshot)
        #expect(final.timestep == 125)
        #expect(final.atomCount == 256)
        #expect(final.validationIssue == nil)
    }

    @Test func streamsSnapshotsAndCancels() async throws {
        let simulation = try LammpsSimulation()
        simulation.setBondRules([BondRule(type1: 1, type2: 1, cutoff: 1.2)])
        let outcome = OutcomeBox()
        simulation.start(script: Self.fixtures.appendingPathComponent("lj.in"), directory: Self.fixtures,
                         continueAfterScript: true) { outcome.set($0) }

        var snapshot: SimulationSnapshot?
        for _ in 0..<300 where snapshot == nil {
            try await Task.sleep(for: .milliseconds(10))
            if let next = simulation.takeNewSnapshot(), next.timestep > 0 { snapshot = next }
        }
        let first = try #require(snapshot)
        #expect(first.units == "lj")
        #expect(first.atomCount == 256)
        #expect(first.tags == (1...256).map(Int64.init))
        #expect(!first.bonds.isEmpty)

        simulation.cancel()
        #expect(await outcome.wait(seconds: 10) == .cancelled)
    }

    @Test func reportsScriptErrors() async throws {
        let simulation = try LammpsSimulation()
        let outcome = OutcomeBox()
        simulation.start(script: Self.fixtures.appendingPathComponent("missing.in"), directory: Self.fixtures,
                         continueAfterScript: true) { outcome.set($0) }
        guard case .failed(let message) = await outcome.wait(seconds: 10) else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("missing.in"))
        #expect(!simulation.hasCompletedInput)
    }

    @Test func cancelledPausedEngineKeepsItsLastValidFrameAndAllowsFreshStart() async throws {
        let old = try LammpsSimulation()
        old.setPaused(true)
        let stopped = OutcomeBox()
        old.start(script: Self.fixtures.appendingPathComponent("lj.in"), directory: Self.fixtures,
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
        #expect(old.isTerminated)
        #expect(old.lastKnownGoodSnapshot?.validationIssue == nil)
        #expect(old.lastKnownGoodSnapshot?.atomCount == 256)
        let fresh = try LammpsSimulation()
        let finished = OutcomeBox()
        fresh.start(script: Self.fixtures.appendingPathComponent("lj.in"), directory: Self.fixtures,
                    continueAfterScript: false) { finished.set($0) }
        #expect(await finished.wait(seconds: 10) == .finished)
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: LammpsSimulation.Outcome?

    func set(_ value: LammpsSimulation.Outcome) {
        lock.lock(); outcome = value; lock.unlock()
    }

    func wait(seconds: Double) async -> LammpsSimulation.Outcome? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let value = lock.withLock { outcome }
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
