import AtomifyKit
import Foundation
import Observation

/// App state shared by the experience carousel, the controls panel and the
/// immersive lab. Kept free of RealityKit and ARKit so it can be exercised
/// on a Mac (scripts/check-app-lifecycle.sh).
@MainActor @Observable
final class AppModel {
    static let windowID = "main"
    static let controlsWindowID = "lab-controls"
    static let labSpaceID = "lab"

    typealias Speed = SimulationSpeed

    /// The simulation currently loaded into the lab.
    struct Run {
        let demo: Demo
        let simulation: LammpsSimulation
        let directives: ScriptDirectives
        let folder: URL
        /// Changes for every load, so the lab can reset its scene.
        let id = UUID()

        var title: String { demo.title }
    }

    struct Stats: Equatable {
        var atoms = 0
        var timestep: Int64 = 0
        var temperature = 0.0
        var units = ""
        var minimizing = false
    }

    let catalog: DemoCatalog
    let demosDirectory: URL?
    private(set) var catalogError: String?

    private(set) var run: Run?
    private(set) var stats = Stats()
    private(set) var errorMessage: String?
    private(set) var recoveryMessage: String?
    private(set) var hasFinished = false
    private(set) var isStopping = false
    /// True until the first frame arrives and while the engine minimizes
    /// (relaxes) the starting structure, when there is nothing to touch yet.
    var isPreparing: Bool { run != nil && errorMessage == nil && (!hasFirstFrame || stats.minimizing) }
    private(set) var hasFirstFrame = false
    /// The in-context tips; they progress once per app session.
    private(set) var tips = LabTips()
    /// Bumped by the panel's Recenter button; the lab places the experiment
    /// in front of the wearer again.
    private(set) var recenterRequests = 0

    /// Labs currently shown.
    var openLabs = 0
    var activeLabPresentation: UUID?
    var labIsOpen: Bool { openLabs > 0 }
    @ObservationIgnored var restoreLibrary: (() -> Void)?

    /// Keeps the last valid frame available for diagnostics; it is not an
    /// engine checkpoint and is never used to resume corrupted dynamics.
    private(set) var lastValidSnapshot: SimulationSnapshot?
    private(set) var isApplicationSuspended = false

    var isPaused = false { didSet {
        run?.simulation.releaseInteractions()
        run?.simulation.setPaused(isApplicationSuspended || isPaused)
        resumedAt = .now
    } }
    var speed = Speed.normal { didSet {
        if let run { run.simulation.setMaxStepsPerSecond(speed.stepsPerSecond(for: run.demo)) }
    } }

    @ObservationIgnored private var lastReport = ContinuousClock.now
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var resumedAt = ContinuousClock.now

    init(directory: URL? = Bundle.main.url(forResource: "Demos", withExtension: nil)) {
        demosDirectory = directory
        do {
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            catalog = try DemoCatalog.load(from: directory)
        } catch {
            catalog = DemoCatalog(demos: [])
            catalogError = "The bundled experiences could not be read: \(error.localizedDescription)"
        }
    }

    /// The experiences shown in the carousel.
    var boxDemos: [Demo] { catalog.releaseDemos }

    /// Whether hands may act on the atoms right now.
    var canInteract: Bool {
        run != nil && !isPaused && !isApplicationSuspended && errorMessage == nil && !hasFinished &&
            !isStopping && !isPreparing
    }

    /// "300 K", or "T = 0.85 (reduced)" in model units.
    var temperatureText: String? { Readout.temperature(stats.temperature, units: stats.units) }

    func requestRecenter() { recenterRequests += 1 }
    func atomPulled() { if !tips.hasPulledAtom { tips.atomPulled() } }
    func heldWithBothHands() { if !tips.hasHeldWithBothHands { tips.heldWithBothHands() } }

    // MARK: Running

    func setApplicationActive(_ active: Bool) {
        isApplicationSuspended = !active
        run?.simulation.releaseInteractions()
        run?.simulation.setPaused(!active || isPaused)
        resumedAt = .now
    }

    func load(_ demo: Demo) {
        guard let demosDirectory else { return }
        start(demo) { try DemoCatalog.makeWorkingCopy(of: demo, from: demosDirectory) }
    }

    func restart() {
        guard !isStopping, let demo = run?.demo else { return }
        load(demo)
    }

    /// Ends the current run.
    func stop() {
        guard let run else { return }
        healthTask?.cancel()
        healthTask = nil
        run.simulation.releaseInteractions()
        run.simulation.cancel()
        self.run = nil
        stats = Stats()
        hasFirstFrame = false
        // The completion callback removes the folder only after LAMMPS has
        // stopped reading it (including relative potential/data files).
    }

    private func start(_ demo: Demo, prepare: () throws -> (folder: URL, script: URL)) {
        stop()
        var preparedFolder: URL?
        do {
            let copy = try prepare()
            preparedFolder = copy.folder
            let script = try String(contentsOf: copy.script, encoding: .utf8)
            let directives = ScriptDirectives.parse(script)
            let simulation = try LammpsSimulation()
            simulation.setBondRules(directives.bondRules)
            simulation.setMaxStepsPerSecond(speed.stepsPerSecond(for: demo))
            simulation.setPublishInterval(1.0 / 90.0)
            let run = Run(demo: demo, simulation: simulation, directives: directives, folder: copy.folder)
            self.run = run
            isPaused = false
            hasFinished = false
            errorMessage = nil
            recoveryMessage = nil
            isStopping = false
            hasFirstFrame = false
            lastValidSnapshot = nil
            stats = Stats()
            let id = run.id
            simulation.start(script: copy.script, directory: copy.folder, continueAfterScript: true,
                             continuationSteps: 1_000_000_000) { [weak self] outcome in
                try? FileManager.default.removeItem(at: copy.folder)
                Task { @MainActor [weak self] in self?.finished(id, outcome) }
            }
            monitor(run)
        } catch {
            if let preparedFolder { try? FileManager.default.removeItem(at: preparedFolder) }
            errorMessage = error.localizedDescription
        }
    }

    private func finished(_ id: UUID, _ outcome: LammpsSimulation.Outcome) {
        guard run?.id == id else { return }
        healthTask?.cancel()
        isStopping = false
        run?.simulation.releaseInteractions()
        lastValidSnapshot = run?.simulation.lastKnownGoodSnapshot ?? lastValidSnapshot
        hasFinished = true
        switch outcome {
        case .finished:
            recoveryMessage = "The experiment has ended. Restart to run it again."
        case .cancelled:
            if let issue = run?.simulation.healthIssue { errorMessage = issue }
            if errorMessage != nil {
                recoveryMessage = "The engine stopped. Restart begins again from the original experiment."
            }
        case .failed(let message):
            errorMessage = message
            recoveryMessage = "The experiment stopped safely. Restart begins again from the original experiment."
        }
        if let snapshot = lastValidSnapshot { report(snapshot) }
    }

    private func monitor(_ run: Run) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            var watchdog = SimulationWatchdog()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.run?.id == run.id, !self.hasFinished else { return }
                let recentlyResumed = ContinuousClock.now - self.resumedAt < .seconds(2)
                let issue = run.simulation.healthIssue ?? watchdog.issue(
                    progressAge: run.simulation.secondsSinceProgress,
                    hasSnapshot: run.simulation.lastKnownGoodSnapshot != nil,
                    paused: self.isApplicationSuspended || self.isPaused || recentlyResumed)
                if let issue {
                    self.lastValidSnapshot = run.simulation.lastKnownGoodSnapshot
                    self.errorMessage = issue
                    self.recoveryMessage = "Stopping the engine. Restart will be available when it has stopped."
                    self.isStopping = true
                    run.simulation.releaseInteractions()
                    run.simulation.cancel()
                    return
                }
            }
        }
    }

    /// Called by the lab with each new snapshot; keeps the panel's numbers
    /// fresh (at most five times a second) without re-rendering every frame.
    func report(_ snapshot: SimulationSnapshot) {
        lastValidSnapshot = snapshot
        let next = Stats(atoms: snapshot.atomCount, timestep: snapshot.timestep, temperature: snapshot.temperature,
                         units: snapshot.units, minimizing: snapshot.minimizing)
        let now = ContinuousClock.now
        if !hasFirstFrame { hasFirstFrame = true }
        guard hasFinished || now - lastReport > .milliseconds(200) || next.atoms != stats.atoms ||
              next.minimizing != stats.minimizing else { return }
        lastReport = now
        if stats != next { stats = next }
    }
}
