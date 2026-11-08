import CLammps
import Foundation
import simd

/// A soft repulsive sphere in simulation coordinates (e.g. a hand or a
/// cursor) that pushes atoms out of it every step: `strength * (1 - r / radius)`
/// in LAMMPS force units. Overlapping spheres share one force budget.
public struct ForceSphere: Sendable, Equatable {
    public var center: SIMD3<Double>
    public var radius: Double
    public var strength: Double

    public init(center: SIMD3<Double>, radius: Double, strength: Double) {
        self.center = center; self.radius = radius; self.strength = strength
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

/// One LAMMPS instance running scripts on its own thread.
///
/// The script thread owns the engine: it runs the script, then stays to
/// execute commands queued with `enqueue(command:)` until the simulation is
/// cancelled or released, and destroys the engine when it leaves, so
/// `cancel()` and `deinit` never block the caller. Every other method is safe
/// from any thread and becomes a no-op once the engine is gone.
///
/// LAMMPS resolves file names against the process' working directory, so
/// only one simulation at a time runs a script; a second one waits until the
/// first has finished or was cancelled.
public final class Simulation: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case finished
        case cancelled
        case failed(String)
    }

    /// Steps run after the script with `continueAfterScript`.
    public static let continuationSteps = 1_000_000_000

    private let engine: Engine

    /// Creates the engine. Throws if LAMMPS could not start.
    /// With `echo`, LAMMPS output is also written to standard output.
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

    /// Runs a script file on a new thread. Relative paths in the script
    /// resolve against `workingDirectory`, which must be writable for
    /// scripts that write output. With `continueAfterScript`, keeps
    /// integrating ("run" for `continuationSteps`) afterwards. `onFinish` is
    /// called on the script thread when the script (and continuation) ends;
    /// queued commands are still executed after that, until `cancel()`.
    /// Can be called once per instance.
    public func start(script: URL, workingDirectory: URL, continueAfterScript: Bool = false,
                      onFinish: @escaping @Sendable (Outcome) -> Void) {
        // Only the script thread uses the handle until it releases the engine.
        guard let claimed = engine.claimForRun() else { return }
        nonisolated(unsafe) let handle = claimed
        let engine = engine
        let steps = Self.continuationSteps
        let thread = Thread {
            let status = Engine.inDirectory(workingDirectory) { () -> atomify_status in
                var result = atomify_sim_run_file(handle, script.path)
                if result == ATOMIFY_OK { engine.markInputCompleted() }
                if result == ATOMIFY_OK && continueAfterScript {
                    result = atomify_sim_command(handle, "run \(steps)")
                }
                // A script without a final run (or a fast one that ended
                // between publications) still shows its last state.
                if result != ATOMIFY_CANCELLED { _ = atomify_sim_publish(handle) }
                return result
            }
            let outcome: Outcome
            if status == nil {
                outcome = .failed("The working directory \(workingDirectory.path) could not be opened.")
            } else if status == ATOMIFY_OK {
                outcome = engine.healthIssue.map { .failed($0) } ?? .finished
            } else if status == ATOMIFY_CANCELLED {
                outcome = .cancelled
            } else {
                let message = String(cString: atomify_sim_last_error(handle))
                engine.recordError(message: message, line: String(cString: atomify_sim_last_error_line(handle)))
                outcome = .failed(message)
            }
            engine.markScriptEnded()
            onFinish(outcome)

            // Serve queued commands until cancelled.
            while atomify_sim_is_cancelled(handle) == 0 {
                guard atomify_sim_wait_for_commands(handle, 0.5) == 1 else { continue }
                _ = Engine.inDirectory(workingDirectory) { () -> Void in
                    if atomify_sim_execute_queued(handle) == ATOMIFY_ERROR {
                        engine.recordError(message: String(cString: atomify_sim_last_error(handle)),
                                           line: String(cString: atomify_sim_last_error_line(handle)))
                    }
                    _ = atomify_sim_publish(handle)
                }
            }
            engine.release()
        }
        thread.name = "LAMMPS"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Queues a single LAMMPS command (or several, one per line). During a
    /// run it is executed between two timesteps (also while paused) and the
    /// run continues; after the script it is executed by the idle script
    /// thread. Commands that would start or leave a run (run, minimize,
    /// clear, include, jump, ...) are rejected during runs. Errors appear in
    /// `takeOutput()`.
    public func enqueue(command: String) {
        withHandle { atomify_sim_enqueue_command($0, command) }
    }

    public func setPaused(_ paused: Bool) { withHandle { atomify_sim_set_paused($0, paused ? 1 : 0) } }

    /// Stops the run at its next timestep; the engine is then released.
    public func cancel() { engine.cancel() }

    /// True from `start` until the script (and continuation) has ended.
    public var isRunning: Bool { engine.isRunning }
    /// True once the engine has been released (after `cancel()`).
    public var isTerminated: Bool { engine.isTerminated }
    /// True only after the input file completed successfully.
    public var hasCompletedInput: Bool { engine.hasCompletedInput }
    /// Why the run was stopped because a snapshot was invalid, or nil.
    public var healthIssue: String? { engine.healthIssue }
    /// Message of the last LAMMPS error: the one that failed the script, or
    /// of a command queued after it (errors of commands queued during a run
    /// only appear in `takeOutput()`). Nil if there was none.
    public var lastErrorMessage: String? { engine.lastError?.message }
    /// The input line that error came from, e.g. "pair_coeff 1 1 1.0", or
    /// the run command when the error ended a run. Nil if unknown.
    public var lastErrorInputLine: String? { engine.lastError?.line }
    /// The newest valid snapshot taken so far.
    public var lastKnownGoodSnapshot: SimulationSnapshot? { engine.lastKnownGoodSnapshot }
    /// Wall clock seconds since LAMMPS last completed a step.
    public var secondsSinceProgress: Double {
        engine.withHandle { atomify_sim_seconds_since_progress($0) } ?? 0
    }

    /// Limits the integration rate; nil runs as fast as possible.
    public func setMaxStepsPerSecond(_ steps: Double?) {
        withHandle { atomify_sim_set_max_steps_per_second($0, steps ?? 0) }
    }

    /// Wall clock seconds between published snapshots (default 1/90).
    public func setPublishInterval(_ seconds: Double) {
        withHandle { atomify_sim_set_publish_interval($0, seconds) }
    }

    /// Wall clock seconds between observable samples (default 0.05). Each
    /// sample makes LAMMPS compute energy and virial on one step; 0 samples
    /// every step.
    public func setObservableInterval(_ seconds: Double) {
        withHandle { atomify_sim_set_observable_interval($0, seconds) }
    }

    /// Per-atom quantity to publish with each snapshot, for coloring:
    /// "vx", "vy", "vz", "fx", "fy", "fz", "speed", "q", "mass", "type",
    /// "c_ID", "c_ID[2]", "f_ID", "f_ID[2]", "v_name" (atom-style), or nil.
    /// Problems (an unknown compute, a missing column) are reported in
    /// `SimulationSnapshot.perAtomError`.
    public func setPerAtomQuantity(_ name: String?) {
        withHandle { handle in
            if let name {
                name.withCString { atomify_sim_set_per_atom_quantity(handle, $0) }
            } else {
                atomify_sim_set_per_atom_quantity(handle, nil)
            }
        }
    }

    // MARK: Bonds

    /// Draw bonds from the LAMMPS topology (molecular atom styles). On by default.
    public func setTopologyBonds(_ enabled: Bool) {
        withHandle { atomify_sim_set_topology_bonds($0, enabled ? 1 : 0) }
    }

    /// Replaces the distance bond rules (e.g. from `#/bond`).
    public func setBondRules(_ rules: [BondRule]) {
        withHandle { handle in
            atomify_sim_clear_bond_cutoffs(handle)
            for rule in rules {
                atomify_sim_set_bond_cutoff(handle, Int32(clamping: rule.type1), Int32(clamping: rule.type2),
                                            rule.cutoff)
            }
        }
    }

    // MARK: Interaction

    /// Pulls the atom with LAMMPS ID `tag` towards `target` (simulation
    /// units) with a damped spring. Two grabs can be held at once, one per
    /// `slot` (0 or 1). Grabs and force spheres not refreshed for 0.35 s are
    /// released, so call this every frame while dragging.
    public func grab(tag: Int64, target: SIMD3<Double>, stiffness: Double, slot: Int = 0) {
        var point = [target.x, target.y, target.z]
        withHandle { atomify_sim_set_grab_slot($0, Int32(clamping: slot), tag, &point, stiffness) }
    }

    /// Lets go of the grab in `slot`, or of both when nil.
    public func releaseGrab(slot: Int? = nil) {
        for slot in slot.map({ [$0] }) ?? [0, 1] {
            withHandle { atomify_sim_set_grab_slot($0, Int32(clamping: slot), 0, nil, 0) }
        }
    }

    /// Replaces the force spheres; an empty array removes them.
    public func setForceSpheres(_ spheres: [ForceSphere]) {
        let raw = spheres.map {
            atomify_force_sphere(center: ($0.center.x, $0.center.y, $0.center.z), radius: $0.radius,
                                 strength: $0.strength)
        }
        withHandle { handle in
            raw.withUnsafeBufferPointer {
                atomify_sim_set_force_spheres(handle, $0.baseAddress, Int32(clamping: $0.count))
            }
        }
    }

    /// Holds every atom in place while forces keep being evaluated; a
    /// grabbed atom jumps to its target and the snapshot reports the force on it.
    public func setFrozen(_ frozen: Bool) { withHandle { atomify_sim_set_frozen($0, frozen ? 1 : 0) } }

    /// Walls from a distance field: `distances[(k * ny + j) * nx + i]` is the
    /// distance from `origin + spacing * (i, j, k)` to the nearest surface.
    /// Atoms closer than `cutoff` are pushed away with `strength * (1 - d / cutoff)`.
    public func setWalls(origin: SIMD3<Double>, spacing: Double, dimensions: SIMD3<Int32>, distances: [Float],
                         cutoff: Double, strength: Double) {
        let count = Int(dimensions.x) * Int(dimensions.y) * Int(dimensions.z)
        guard dimensions.x > 1, dimensions.y > 1, dimensions.z > 1, distances.count >= count else {
            removeWalls()
            return
        }
        var origin = [origin.x, origin.y, origin.z]
        var dims = [dimensions.x, dimensions.y, dimensions.z]
        withHandle { handle in
            distances.withUnsafeBufferPointer {
                atomify_sim_set_wall_grid(handle, &origin, spacing, &dims, $0.baseAddress, cutoff, strength)
            }
        }
    }

    public func removeWalls() {
        withHandle { atomify_sim_set_wall_grid($0, nil, 0, nil, nil, 0, 0) }
    }

    // MARK: Output

    /// The newest snapshot if it is newer than the last one returned.
    public func takeNewSnapshot() -> SimulationSnapshot? { engine.takeNewSnapshot() }

    /// Text LAMMPS printed since the last call (thermo output, warnings, errors).
    public func takeOutput() -> String { engine.takeOutput() }

    @discardableResult
    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? { engine.withHandle(body) }
}

/// Owns the C handle. Shared between the simulation object and its script
/// thread, which keeps it alive until it releases it.
private final class Engine: @unchecked Sendable {
    static let directoryLock = NSLock()
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var claimed = false
    private var running = false
    private var lastSequence: UInt64 = 0
    private var issue: String?
    private var knownGood: SimulationSnapshot?
    private var finalSnapshot: SimulationSnapshot?
    private var inputCompleted = false
    private var leftoverOutput = ""
    private var error: (message: String, line: String?)?

    init(_ handle: OpaquePointer) { self.handle = handle }

    var isTerminated: Bool { lock.withLock { handle == nil } }
    var isRunning: Bool { lock.withLock { running } }
    var healthIssue: String? { lock.withLock { issue } }
    var lastKnownGoodSnapshot: SimulationSnapshot? { lock.withLock { knownGood } }
    var hasCompletedInput: Bool { lock.withLock { inputCompleted } }
    func markInputCompleted() { lock.withLock { inputCompleted = true } }
    func markScriptEnded() { lock.withLock { running = false } }
    var lastError: (message: String, line: String?)? { lock.withLock { error } }
    func recordError(message: String, line: String) {
        lock.withLock { error = (message, line.isEmpty ? nil : line) }
    }

    /// Runs `body` with the process working directory set to `directory`,
    /// one simulation at a time. Nil if the directory cannot be entered.
    static func inDirectory<T>(_ directory: URL, _ body: () -> T) -> T? {
        directoryLock.lock()
        defer { directoryLock.unlock() }
        let manager = FileManager.default
        let previous = manager.currentDirectoryPath
        guard manager.changeCurrentDirectoryPath(directory.path) else { return nil }
        defer { manager.changeCurrentDirectoryPath(previous) }
        return body()
    }

    func claimForRun() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !claimed else { return nil }
        claimed = true
        running = true
        return handle
    }

    func cancel() { withHandle { atomify_sim_cancel($0) } }

    /// Called by the script thread when it leaves. Keeps what the app has
    /// not taken yet (the last snapshot and output) after the engine is gone.
    func release() {
        lock.lock()
        let handle = handle
        if let handle {
            leftoverOutput += Self.readOutput(handle)
            if let snapshot = readSnapshot(handle) { finalSnapshot = snapshot }
        }
        self.handle = nil
        running = false
        lock.unlock()
        if let handle { atomify_sim_destroy(handle) }
    }

    /// Releases an engine that never ran a script.
    func releaseIfIdle() {
        lock.lock()
        let idle = !claimed
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
        guard let handle else {
            defer { finalSnapshot = nil }
            return finalSnapshot
        }
        return readSnapshot(handle)
    }

    func takeOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        var text = leftoverOutput
        leftoverOutput = ""
        if let handle { text += Self.readOutput(handle) }
        return text
    }

    /// The engine's snapshot if newer than the last one read. Call with `lock` held.
    private func readSnapshot(_ handle: OpaquePointer) -> SimulationSnapshot? {
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

    private static func readOutput(_ handle: OpaquePointer) -> String {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = chunk.withUnsafeMutableBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) {
                    atomify_sim_read_output(handle, $0.baseAddress, $0.count)
                }
            }
            if count == 0 { break }
            bytes.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
