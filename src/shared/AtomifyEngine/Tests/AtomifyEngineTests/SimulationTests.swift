import Foundation
import Testing
@testable import AtomifyEngine

/// Runs the scripts in Fixtures with LAMMPS. Serialized: LAMMPS resolves
/// paths against the process working directory, so simulations take turns.
@Suite(.serialized) struct SimulationTests {
    /// A fresh copy of the Fixtures folder, so scripts may write files.
    func fixtures() throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomifyEngineTests-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: directory)
        return directory
    }

    /// Starts `script` and returns a task that ends with the outcome.
    func start(_ simulation: Simulation, _ script: String, in directory: URL,
               continueAfterScript: Bool = false) -> Task<Simulation.Outcome, Never> {
        Task {
            await withCheckedContinuation { continuation in
                simulation.start(script: directory.appendingPathComponent(script), workingDirectory: directory,
                                 continueAfterScript: continueAfterScript) { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        }
    }

    /// Polls new snapshots until one satisfies `predicate`.
    func snapshot(of simulation: Simulation, timeout: Double = 30,
                  where predicate: (SimulationSnapshot) -> Bool) async -> SimulationSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = simulation.takeNewSnapshot(), predicate(snapshot) { return snapshot }
            await pause(0.005)
        }
        return nil
    }

    func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.005)
        }
        return condition()
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    @Test func scriptRunsToTheEnd() async throws {
        let directory = try fixtures()
        let script = try String(contentsOf: directory.appendingPathComponent("lj.in"), encoding: .utf8)
        let directives = ScriptDirectives.parse(script)
        #expect(directives.warnings.isEmpty)
        #expect(directives.atomStyles[1]?.name == "Ar")
        #expect(directives.camera == CameraHint(position: SIMD3(3, 3, 12), target: SIMD3(3, 3, 3)))

        let simulation = try Simulation()
        simulation.setBondRules(directives.bondRules)
        simulation.setObservableInterval(0)
        simulation.setPublishInterval(0)
        simulation.setPerAtomQuantity("c_ke")
        let outcome = await start(simulation, "lj.in", in: directory).value
        #expect(outcome == .finished)
        #expect(simulation.hasCompletedInput)
        #expect(!simulation.isRunning)
        #expect(simulation.lastErrorMessage == nil)

        let snapshot = try #require(simulation.takeNewSnapshot())
        #expect(snapshot.timestep == 200)
        #expect(snapshot.atomCount == 256)
        #expect(snapshot.typeCount == 2)
        #expect(snapshot.units == "lj")
        #expect(snapshot.runMode == .idle)
        #expect(!snapshot.bonds.isEmpty)    // #/bond 1 1 1.2
        #expect(snapshot.temperature > 0)
        #expect(snapshot.validationIssue == nil)
        #expect(snapshot.perAtomQuantity == "c_ke")
        #expect(snapshot.perAtomError == nil)
        let kinetic = try #require(snapshot.perAtomValues)
        #expect(kinetic.count == 256)
        #expect(kinetic.allSatisfy { $0.isFinite && $0 >= 0 })

        let msd = try #require(snapshot.observable(id: "c_msd"))
        #expect(msd.style == "msd")
        #expect(msd.labels == ["c_msd[1]", "c_msd[2]", "c_msd[3]", "c_msd[4]"])
        #expect(msd.hasValues)
        #expect(snapshot.observable(id: "v_kinetic")?.scalar != nil)
        #expect(snapshot.observable(id: "c_ke")?.perAtomNames == ["c_ke"])
        // The last thermo line before the final snapshot: step 150 or 200.
        let step = try #require(snapshot.observable(id: "thermo_step")?.scalar)
        #expect(step == 150 || step == 200)
        #expect(snapshot.observable(id: "thermo_c_msd[4]") != nil)
        #expect(snapshot.observable(id: "f___atomify") == nil)

        let history = ObservableHistory()
        history.record(snapshot)
        #expect(history.ids.contains("c_msd"))

        #expect(simulation.takeNewSnapshot() == nil)    // nothing newer
        let output = simulation.takeOutput()
        #expect(output.contains("Loop time"))
        #expect(!output.contains("ERROR"))
        #expect(simulation.takeOutput().isEmpty)

        simulation.cancel()
        let terminated = await waitUntil { simulation.isTerminated }
        #expect(terminated)
    }

    @Test func brokenScriptReportsTheFailingLine() async throws {
        let directory = try fixtures()
        let simulation = try Simulation()
        let outcome = await start(simulation, "broken.in", in: directory).value
        guard case .failed(let message) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("this_is_not_a_command"))
        #expect(simulation.lastErrorMessage == message)
        #expect(simulation.lastErrorInputLine == "this_is_not_a_command 1 2 3")
        #expect(!simulation.hasCompletedInput)
        #expect(simulation.takeOutput().contains("ERROR"))
        simulation.cancel()
    }

    @Test func missingWorkingDirectoryFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        let simulation = try Simulation()
        let outcome = await start(simulation, "lj.in", in: directory).value
        guard case .failed(let message) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("could not be opened"))
        simulation.cancel()
    }

    @Test func continuedRunTakesCommandsPausesAndCancels() async throws {
        let directory = try fixtures()
        let simulation = try Simulation()
        simulation.setMaxStepsPerSecond(2000)
        simulation.setPublishInterval(0)
        let finished = start(simulation, "lj.in", in: directory, continueAfterScript: true)

        let first = await snapshot(of: simulation) { $0.timestep > 260 }
        let running = try #require(first)
        #expect(simulation.isRunning)
        #expect(simulation.hasCompletedInput)
        #expect(running.runMode == .dynamics)
        #expect(running.runSteps == Int64(Simulation.continuationSteps))
        #expect(running.runStep == running.timestep - 200)
        #expect(running.inputLine == "run \(Simulation.continuationSteps)")

        // Paused, the timestep stands still, but queued commands still run.
        simulation.setPaused(true)
        await pause(0.1)
        _ = simulation.takeNewSnapshot()
        simulation.enqueue(command: "variable answer equal 42")
        let withAnswer = await snapshot(of: simulation) { $0.observable(id: "v_answer") != nil }
        let answered = try #require(withAnswer)
        #expect(answered.observable(id: "v_answer")?.scalar == 42)
        await pause(0.2)
        let paused = simulation.takeNewSnapshot() ?? answered
        #expect(paused.timestep == answered.timestep)

        simulation.setPaused(false)
        let later = await snapshot(of: simulation) { $0.timestep > answered.timestep + 20 }
        let resumed = try #require(later)
        #expect(resumed.runSteps == Int64(Simulation.continuationSteps))

        // Commands that would end the run are refused; the run goes on.
        simulation.enqueue(command: "run 10")
        let refused = await waitUntil { simulation.takeOutput().contains("cannot be used while a run is in progress") }
        #expect(refused)

        simulation.cancel()
        let outcome = await finished.value
        #expect(outcome == .cancelled)
        let terminated = await waitUntil { simulation.isTerminated }
        #expect(terminated)
        #expect(!simulation.isRunning)
        simulation.enqueue(command: "units lj")    // no-op once released
        simulation.setPaused(false)
    }

    @Test func commandsAfterTheScript() async throws {
        let directory = try fixtures()
        let simulation = try Simulation()
        let outcome = await start(simulation, "lj.in", in: directory).value
        #expect(outcome == .finished)
        let before = try #require(simulation.takeNewSnapshot())
        #expect(before.types[0] == 2)    // atom 1 is in region half

        simulation.enqueue(command: "set atom 1 type 1")
        let retyped = await snapshot(of: simulation) { $0.types[0] == 1 }
        let changed = try #require(retyped)
        #expect(changed.timestep == 200)
        #expect(changed.runMode == .idle)

        simulation.enqueue(command: "bogus_command 1")
        let failed = await waitUntil { simulation.lastErrorInputLine == "bogus_command 1" }
        #expect(failed)
        #expect(simulation.lastErrorMessage?.contains("bogus_command") == true)

        simulation.enqueue(command: "run 20")
        let ran = await snapshot(of: simulation) { $0.timestep == 220 }
        #expect(ran != nil)
        simulation.cancel()
        let terminated = await waitUntil { simulation.isTerminated }
        #expect(terminated)
    }

    @Test func unknownPerAtomQuantityIsReported() async throws {
        let directory = try fixtures()
        let simulation = try Simulation()
        simulation.setPerAtomQuantity("c_nope")
        let outcome = await start(simulation, "lj.in", in: directory).value
        #expect(outcome == .finished)
        let snapshot = try #require(simulation.takeNewSnapshot())
        #expect(snapshot.perAtomQuantity == "c_nope")
        #expect(snapshot.perAtomValues == nil)
        #expect(snapshot.perAtomError?.contains("nope") == true)
        simulation.cancel()
    }

    @Test func startsOnlyOnce() async throws {
        let directory = try fixtures()
        let simulation = try Simulation()
        let first = start(simulation, "lj.in", in: directory)
        await pause(0.05)
        let calledAgain = Flag()
        simulation.start(script: directory.appendingPathComponent("broken.in"), workingDirectory: directory) { _ in
            calledAgain.set()
        }
        let outcome = await first.value
        #expect(outcome == .finished)
        await pause(0.1)
        #expect(!calledAgain.value)
        simulation.cancel()
    }

    @Test func interactionBeforeAndAfterTheEngineIsGone() async throws {
        let simulation = try Simulation()
        // Before any script: accepted and kept.
        simulation.grab(tag: 1, target: SIMD3(1, 2, 3), stiffness: 10)
        simulation.releaseGrab()
        simulation.setForceSpheres([ForceSphere(center: .zero, radius: 1, strength: 5)])
        simulation.setForceSpheres([])
        simulation.setFrozen(true)
        simulation.setFrozen(false)
        simulation.setTopologyBonds(false)
        simulation.setWalls(origin: .zero, spacing: 1, dimensions: SIMD3(2, 2, 2), distances: Array(repeating: 1, count: 8),
                            cutoff: 0.5, strength: 1)
        simulation.removeWalls()
        simulation.setPerAtomQuantity(nil)
        #expect(simulation.takeNewSnapshot() == nil)
        #expect(simulation.secondsSinceProgress >= 0)

        simulation.cancel()
        #expect(!simulation.isTerminated)    // never started: released when dropped
    }
}

/// A thread safe flag for callbacks.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}
