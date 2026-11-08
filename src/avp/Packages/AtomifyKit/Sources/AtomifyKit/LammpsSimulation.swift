import CLammps
import Foundation
import simd

/// One LAMMPS instance running a script on its own thread.
///
/// The script thread owns the engine: it creates it, runs the script and
/// destroys it when the run ends or is cancelled, so `cancel()` and `deinit`
/// never block the caller. Every other method is safe from any thread and
/// becomes a no-op once the engine is gone.
public final class LammpsSimulation: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case finished
        case cancelled
        case failed(String)
    }

    public struct ForceSphere: Sendable, Equatable {
        public var center: SIMD3<Double>
        public var radius: Double
        public var strength: Double
        public init(center: SIMD3<Double>, radius: Double, strength: Double) {
            self.center = center; self.radius = radius; self.strength = strength
        }
    }

    private let engine: Engine

    /// Creates the engine. Throws if LAMMPS could not start.
    public init(echo: Bool = false) throws {
        guard let handle = atomify_sim_create(echo ? 1 : 0) else {
            throw SimulationError.engineUnavailable
        }
        let message = String(cString: atomify_sim_last_error(handle))
        if !message.isEmpty {
            atomify_sim_destroy(handle)
            throw SimulationError.lammps(message)
        }
        engine = Engine(handle)
    }

    /// Dropping the simulation cancels a running script; the script thread
    /// then releases the engine.
    deinit {
        engine.cancel()
        engine.releaseIfIdle()
    }

    // MARK: Running

    /// Runs `script` on a new thread, then keeps integrating if
    /// `continueAfterScript` is set (demos run until they are closed).
    /// The working directory is changed to `directory` first so relative
    /// file names in the script resolve; it must be writable for scripts that
    /// write output. Can be called once per instance. continuationSteps bounds
    /// the post-input observation to 1...1,000,000,000 integration steps.
    public func start(script: URL, directory: URL, continueAfterScript: Bool,
                      continuationSteps: Int = 1_000_000_000,
                      onFinish: @escaping @Sendable (Outcome) -> Void) {
        // Only the script thread uses the handle until it releases the engine.
        guard let claimed = engine.claimForRun() else { return }
        nonisolated(unsafe) let handle = claimed
        let engine = engine
        let observationSteps = min(1_000_000_000, max(1, continuationSteps))
        let thread = Thread {
            // LAMMPS resolves file names against a process-wide directory.
            // Never let a replacement run change it beneath a cancelling run.
            Engine.directoryLock.lock()
            defer { Engine.directoryLock.unlock() }
            let previousDirectory = FileManager.default.currentDirectoryPath
            defer { FileManager.default.changeCurrentDirectoryPath(previousDirectory) }
            guard FileManager.default.changeCurrentDirectoryPath(directory.path) else {
                engine.release()
                onFinish(.failed("The experiment folder could not be opened."))
                return
            }
            var status = atomify_sim_run_file(handle, script.path)
            if status == ATOMIFY_OK { engine.markInputCompleted() }
            if status == ATOMIFY_OK && continueAfterScript {
                status = atomify_sim_command(handle, "run \(observationSteps)")
            }
            // A fast finite run can end between throttled publications. A zero-
            // step setup publishes its exact endpoint without advancing time.
            if status == ATOMIFY_OK {
                status = atomify_sim_command(handle, "run 0")
            }
            _ = engine.takeNewSnapshot()
            let outcome: Outcome
            switch status {
            case ATOMIFY_OK:
                outcome = engine.healthIssue.map { .failed($0) } ?? .finished
            case ATOMIFY_CANCELLED: outcome = .cancelled
            default: outcome = .failed(String(cString: atomify_sim_last_error(handle)))
            }
            // Retain the endpoint after the native engine is destroyed.
            engine.release()
            onFinish(outcome)
        }
        thread.name = "LAMMPS"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        thread.start()
    }

    public func setPaused(_ paused: Bool) { withHandle { atomify_sim_set_paused($0, paused ? 1 : 0) } }

    /// Stops the run at its next timestep; the engine is then released.
    public func cancel() { engine.cancel() }

    public var isTerminated: Bool { engine.isTerminated }
    /// True only after the input file completed successfully, not when its first frame appeared.
    public var hasCompletedInput: Bool { engine.hasCompletedInput }
    public var healthIssue: String? { engine.healthIssue }
    public var lastKnownGoodSnapshot: SimulationSnapshot? { engine.lastKnownGoodSnapshot }
    public var secondsSinceProgress: Double { engine.withHandle { atomify_sim_seconds_since_progress($0) } ?? 0 }

    public func releaseInteractions() {
        releaseGrab()
        setForceSpheres([])
    }

    /// Limits the integration rate; nil runs as fast as possible.
    public func setMaxStepsPerSecond(_ steps: Double?) {
        withHandle { atomify_sim_set_max_steps_per_second($0, steps ?? 0) }
    }

    public func setPublishInterval(_ seconds: Double) {
        withHandle { atomify_sim_set_publish_interval($0, seconds) }
    }

    // MARK: Bonds and forces

    public func setTopologyBonds(_ enabled: Bool) {
        withHandle { atomify_sim_set_topology_bonds($0, enabled ? 1 : 0) }
    }

    public func setBondRules(_ rules: [BondRule]) {
        withHandle { handle in
            atomify_sim_clear_bond_cutoffs(handle)
            for rule in rules {
                atomify_sim_set_bond_cutoff(handle, Int32(rule.type1), Int32(rule.type2), rule.cutoff)
            }
        }
    }

    public func setForceSpheres(_ spheres: [ForceSphere]) {
        let raw = spheres.map {
            atomify_force_sphere(center: ($0.center.x, $0.center.y, $0.center.z), radius: $0.radius,
                                 strength: $0.strength)
        }
        withHandle { handle in raw.withUnsafeBufferPointer { atomify_sim_set_force_spheres(handle, $0.baseAddress, Int32($0.count)) } }
    }

    /// Pulls the atom with LAMMPS ID `tag` towards `target` (simulation
    /// units). Two grabs can be held at once, one per `slot` (0 or 1).
    public func grab(tag: Int64, target: SIMD3<Double>, stiffness: Double, slot: Int = 0) {
        var point = [target.x, target.y, target.z]
        withHandle { atomify_sim_set_grab_slot($0, Int32(slot), tag, &point, stiffness) }
    }

    /// Lets go of the grab in `slot`, or of both when nil.
    public func releaseGrab(slot: Int? = nil) {
        for slot in slot.map({ [$0] }) ?? [0, 1] {
            withHandle { atomify_sim_set_grab_slot($0, Int32(slot), 0, nil, 0) }
        }
    }

    /// Holds every atom in place while forces keep being evaluated; a
    /// grabbed atom jumps to its target and the snapshot reports the force on it.
    public func setFrozen(_ frozen: Bool) { withHandle { atomify_sim_set_frozen($0, frozen ? 1 : 0) } }

    /// Walls from a distance field (simulation units), e.g. the room mesh.
    /// Atoms closer than `cutoff` to a surface are pushed away. nil removes them.
    public func setWalls(_ grid: DistanceGrid?, cutoff: Double, strength: Double) {
        withHandle { handle in
            guard let grid else {
                atomify_sim_set_wall_grid(handle, nil, 0, nil, nil, 0, 0)
                return
            }
            var origin = [Double(grid.origin.x), Double(grid.origin.y), Double(grid.origin.z)]
            var dims = [Int32(grid.dimensions.x), Int32(grid.dimensions.y), Int32(grid.dimensions.z)]
            grid.distances.withUnsafeBufferPointer { distances in
                atomify_sim_set_wall_grid(handle, &origin, Double(grid.spacing), &dims, distances.baseAddress,
                                          cutoff, strength)
            }
        }
    }

    // MARK: Output

    /// The newest snapshot if it is newer than the last one returned.
    public func takeNewSnapshot() -> SimulationSnapshot? { engine.takeNewSnapshot() }

    @discardableResult
    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? { engine.withHandle(body) }
}

/// Owns the C handle. Shared between the simulation object and its script
/// thread, which keeps it alive until the run has ended.
private final class Engine: @unchecked Sendable {
    static let directoryLock = NSLock()
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var running = false
    private var lastSequence: UInt64 = 0
    private var issue: String?
    private var knownGood: SimulationSnapshot?
    private var inputCompleted = false

    var isTerminated: Bool { lock.withLock { handle == nil } }
    var healthIssue: String? { lock.withLock { issue } }
    var lastKnownGoodSnapshot: SimulationSnapshot? { lock.withLock { knownGood } }
    var hasCompletedInput: Bool { lock.withLock { inputCompleted } }
    func markInputCompleted() { lock.withLock { inputCompleted = true } }

    init(_ handle: OpaquePointer) { self.handle = handle }

    func claimForRun() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !running else { return nil }
        running = true
        return handle
    }

    func cancel() { withHandle { atomify_sim_cancel($0) } }

    /// Called by the script thread once the run has returned.
    func release() {
        lock.lock()
        let handle = handle
        self.handle = nil
        lock.unlock()
        if let handle { atomify_sim_destroy(handle) }
    }

    /// Releases an engine that never ran a script.
    func releaseIfIdle() {
        lock.lock()
        let idle = !running
        lock.unlock()
        if idle { release() }
    }

    @discardableResult
    func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        return body(handle)
    }

    func takeNewSnapshot() -> SimulationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var raw = atomify_snapshot()
        guard atomify_sim_snapshot_lock(handle, &raw) == 1 else { return nil }
        defer { atomify_sim_snapshot_unlock(handle) }
        guard raw.sequence > lastSequence else { return nil }
        lastSequence = raw.sequence
        let snapshot = SimulationSnapshot(raw)
        if let invalid = snapshot.validationIssue {
            issue = invalid
            atomify_sim_cancel(handle)
            return nil
        }
        knownGood = snapshot
        return snapshot
    }
}

public enum SimulationError: Error, Equatable, LocalizedError {
    case engineUnavailable
    case lammps(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable: "LAMMPS could not be started."
        case .lammps(let message): message
        }
    }
}
