import AtomifyEngine
import AtomifyVision
import Foundation

// Exercises the production AppModel against the real host engine, without
// RealityKit, ARKit or a headset.

enum ProbeFailure: Error { case failed(String) }
@main struct AppLifecycleProbe {
    @MainActor static func main() async throws {
        let initialDirectory = FileManager.default.currentDirectoryPath
        let demos = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = AppModel(directory: demos)
        let benzene = try require(model.catalog.demos.first { $0.id == "benzene" }, "Missing benzene")
        let methane = try require(model.catalog.demos.first { $0.id == "methane" }, "Missing methane")
        let ethane = try require(model.catalog.demos.first { $0.id == "ethane" }, "Missing ethane")
        var runs: [AppModel.Run] = []
        defer { model.stop(); runs.forEach { $0.simulation.cancel() } }

        // Rapid replacement: every load gets a fresh identity and folder, and
        // a late completion from a replaced run never reaches its successor.
        for i in 0..<30 {
            model.load([benzene, methane, ethane][i % 3])
            let run = try require(model.run, "Run \(i) did not load")
            guard !runs.contains(where: { $0.id == run.id || $0.folder == run.folder }) else {
                throw ProbeFailure.failed("Replacement reused an old identity or working folder")
            }
            guard model.isPreparing, !model.canInteract else {
                throw ProbeFailure.failed("A fresh run allowed interaction before its first frame")
            }
            runs.append(run)
            if i % 4 == 0 { model.isPaused = true }
            if i % 6 == 0 { model.setApplicationActive(false) }
            try await Task.sleep(for: .milliseconds(12))
            model.setApplicationActive(true)
            guard !model.hasFinished, model.errorMessage == nil else {
                throw ProbeFailure.failed("Stale completion altered replacement \(i): \(model.errorMessage ?? "finished")")
            }
        }

        model.load(benzene)
        var final = try require(model.run, "Final experiment did not load")
        runs.append(final)
        try await waitForHealthyDynamics(model, run: final)
        guard model.canInteract, !model.isPreparing, model.temperatureText?.hasSuffix(" K") == true else {
            throw ProbeFailure.failed("Healthy dynamics did not allow interaction or show a temperature")
        }

        // Pausing blocks interaction; restarting replaces the run but keeps speed.
        model.isPaused = true
        guard !model.canInteract else { throw ProbeFailure.failed("Paused run allowed interaction") }
        model.speed = .slow
        let originalID = final.id
        model.restart()
        final = try require(model.run, "Restart did not load")
        runs.append(final)
        guard final.id != originalID, final.demo.id == benzene.id, !model.isPaused, model.speed == .slow else {
            throw ProbeFailure.failed("Restart did not replace the run with a fresh, unpaused one")
        }
        model.speed = .normal
        try await waitForHealthyDynamics(model, run: final)

        // Recenter requests and the tips progress through the model.
        let requests = model.recenterRequests
        model.requestRecenter()
        guard model.recenterRequests == requests + 1, model.tips.current == .pullAtom else {
            throw ProbeFailure.failed("Recenter or initial tip state is wrong")
        }
        model.atomPulled()
        guard model.tips.current == .holdWithBothHands else { throw ProbeFailure.failed("Tip did not advance after a pull") }
        model.heldWithBothHands()
        guard model.tips.current == nil else { throw ProbeFailure.failed("Tips did not finish after a grip") }

        // Backgrounding holds the engine; foregrounding resumes it.
        model.setApplicationActive(false)
        guard !model.canInteract else { throw ProbeFailure.failed("Backgrounded run allowed interaction") }
        try await Task.sleep(for: .milliseconds(80))
        if let frame = final.simulation.takeNewSnapshot() { model.report(frame) }
        let pausedStep = try require(final.simulation.lastKnownGoodSnapshot, "No paused frame").timestep
        try await Task.sleep(for: .milliseconds(120))
        if let frame = final.simulation.takeNewSnapshot() { model.report(frame) }
        guard final.simulation.lastKnownGoodSnapshot?.timestep == pausedStep else { throw ProbeFailure.failed("Backgrounded engine kept advancing") }
        model.setApplicationActive(true)
        let resumeDeadline = ContinuousClock.now + .seconds(3)
        while (final.simulation.lastKnownGoodSnapshot?.timestep ?? 0) <= pausedStep && ContinuousClock.now < resumeDeadline {
            if let frame = final.simulation.takeNewSnapshot() { model.report(frame) }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (final.simulation.lastKnownGoodSnapshot?.timestep ?? 0) > pausedStep else { throw ProbeFailure.failed("Foreground engine did not resume") }
        guard Set(runs.map(\.id)).count == runs.count,
              Set(runs.map(\.folder)).count == runs.count,
              model.errorMessage == nil, !model.hasFinished else {
            throw ProbeFailure.failed("Run identities collided or a stale completion reached the final run")
        }

        // Stopping ends every engine and removes every working folder.
        model.stop()
        guard model.run == nil, !model.canInteract, !model.isPreparing else {
            throw ProbeFailure.failed("Stop left a run behind")
        }
        let cleanupDeadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < cleanupDeadline {
            if runs.allSatisfy({ $0.simulation.isTerminated && !FileManager.default.fileExists(atPath: $0.folder.path) }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        guard runs.allSatisfy({ $0.simulation.isTerminated && !FileManager.default.fileExists(atPath: $0.folder.path) }) else {
            throw ProbeFailure.failed("An engine or temporary folder survived stop")
        }
        guard FileManager.default.currentDirectoryPath == initialDirectory else { throw ProbeFailure.failed("Working directory was not restored") }
        print("APP_LIFECYCLE runs=\(runs.count) unique_ids=true unique_folders=true final_atoms=12 restart_fresh=true interaction_gated=true tips_progress=true background_holds=true foreground_resumes=true engines_stopped=true folders_removed=true cwd_restored=true")
    }

    @MainActor static func waitForHealthyDynamics(_ model: AppModel, run: AppModel.Run) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let frame = run.simulation.takeNewSnapshot() {
                model.report(frame)
                if frame.atomCount == 12, !frame.minimizing, frame.timestep >= 100,
                   frame.temperature > 0, frame.validationIssue == nil,
                   model.errorMessage == nil, !model.hasFinished, !model.stats.minimizing { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProbeFailure.failed("Benzene did not enter healthy dynamics")
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure.failed(message) }; return value
    }
}
