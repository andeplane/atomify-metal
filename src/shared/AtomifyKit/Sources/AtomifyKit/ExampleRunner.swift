import AtomifyEngine
import Foundation

/// How far `ExampleRunner` takes each example.
public struct ExampleRunLimits: Sendable, Equatable {
    /// Stop this many steps after the first run (or minimization) started.
    public var steps: Int64
    /// Wall clock seconds before the example is cancelled as timed out.
    public var timeout: Double

    public init(steps: Int64 = 100, timeout: Double = 120) {
        self.steps = steps
        self.timeout = timeout
    }
}

/// How one example run ended.
public struct ExampleRunResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        /// The input completed, or the step limit was reached.
        case ok
        /// LAMMPS reported an error (or the files could not be prepared).
        case failed
        /// Neither the input nor the step limit was reached in time.
        case timeout
        /// Marked `"atomifyMetal": {"skip": ...}` in examples.json.
        case skipped
    }

    public var id: String
    public var status: Status
    /// True when the whole input script ran.
    public var completedInput: Bool
    public var atoms: Int
    /// Steps since the first run or minimization started.
    public var steps: Int64
    public var seconds: Double
    /// The error (first line of the LAMMPS message), timeout note or skip reason.
    public var message: String?
    /// The input line the error came from.
    public var inputLine: String?

    public init(id: String, status: Status, completedInput: Bool = false, atoms: Int = 0, steps: Int64 = 0,
                seconds: Double = 0, message: String? = nil, inputLine: String? = nil) {
        self.id = id
        self.status = status
        self.completedInput = completedInput
        self.atoms = atoms
        self.steps = steps
        self.seconds = seconds
        self.message = message
        self.inputLine = inputLine
    }

    /// Failed or timed out.
    public var isProblem: Bool { status == .failed || status == .timeout }

    /// Results as a plain text table: id, status, how it ended ("input" when
    /// the script completed, "steps" at the step limit), atoms, steps,
    /// seconds and the error with its input line.
    public static func table(_ results: [ExampleRunResult]) -> String {
        let headers = ["id", "status", "ended", "atoms", "steps", "seconds", "error"]
        let rows = results.map { result -> [String] in
            var message = result.message ?? ""
            if let line = result.inputLine { message += "  [line: \(line)]" }
            let ended = result.status != .ok ? "" : result.completedInput ? "input" : "steps"
            return [result.id, result.status.rawValue, ended, String(result.atoms), String(result.steps),
                    String(format: "%.1f", result.seconds), message]
        }
        let last = headers.count - 1
        let widths = (0..<last).map { column in ([headers] + rows).map { $0[column].count }.max() ?? 0 }
        func format(_ row: [String], header: Bool = false) -> String {
            let cells = row.enumerated().map { column, value -> String in
                guard column < last else { return value }
                let padding = String(repeating: " ", count: widths[column] - value.count)
                return (3...5).contains(column) && !header ? padding + value : value + padding
            }
            var line = cells.joined(separator: "  ")
            while line.last == " " { line.removeLast() }
            return line
        }
        let summary = [Status.ok, .failed, .timeout, .skipped].map { status in
            "\(results.filter { $0.status == status }.count) \(status.rawValue)"
        }.joined(separator: ", ")
        return ([format(headers, header: true)] + rows.map { format($0) } + ["", summary]).joined(separator: "\n")
    }
}

/// Checks that an example runs: executes its script in a working copy until
/// the input completes or `limits.steps` steps after the first run started,
/// whichever comes first, cancelling it after `limits.timeout` seconds.
///
/// Simulations take turns on the process working directory, so run examples
/// one after another (a waiting example's clock is already running).
public enum ExampleRunner {
    /// The examples bundled with the macOS app, found from a source file of
    /// this repository (pass `#filePath`): src/macos/AtomifyMac/Examples.
    public static func bundledExamplesDirectory(fromSourceFile path: String) -> URL? {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("src/macos/AtomifyMac/Examples")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("examples.json").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    public static func run(_ example: Example, from catalog: ExampleCatalog,
                           limits: ExampleRunLimits = ExampleRunLimits(),
                           scratch: URL = FileManager.default.temporaryDirectory) async -> ExampleRunResult {
        if let reason = example.skipReason {
            return ExampleRunResult(id: example.id, status: .skipped, message: reason)
        }
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = clock.now - start
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        }

        let copy: (folder: URL, script: URL)
        let simulation: Simulation
        do {
            copy = try catalog.workingCopy(of: example, into: scratch)
            simulation = try Simulation()
        } catch {
            return ExampleRunResult(id: example.id, status: .failed, seconds: elapsed(),
                                    message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: copy.folder) }

        let ending = OutcomeBox()
        simulation.setPublishInterval(0.02)
        simulation.start(script: copy.script, workingDirectory: copy.folder) { ending.set($0) }

        var atoms = 0
        var steps: Int64 = 0
        var runStart: Int64?
        var stopped: ExampleRunResult.Status?
        var stoppedAt = 0.0
        func observe(_ snapshot: SimulationSnapshot) {
            atoms = snapshot.atomCount
            if runStart == nil, snapshot.runMode != .idle { runStart = snapshot.timestep - snapshot.runStep }
            if let runStart { steps = snapshot.timestep - runStart }
        }
        while ending.outcome == nil {
            if let snapshot = simulation.takeNewSnapshot() { observe(snapshot) }
            if stopped == nil {
                if runStart != nil && steps >= limits.steps {
                    stopped = .ok
                } else if elapsed() > limits.timeout {
                    stopped = .timeout
                }
                if stopped != nil {
                    stoppedAt = elapsed()
                    simulation.cancel()
                }
            } else if elapsed() - stoppedAt > 30 {
                // Cancelling takes effect at the next timestep; a command that
                // runs for long without one (a huge read_data) is left behind.
                return ExampleRunResult(id: example.id, status: .timeout, atoms: atoms, steps: steps,
                                        seconds: elapsed(), message: "Did not stop after cancelling.")
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if let snapshot = simulation.takeNewSnapshot() ?? simulation.lastKnownGoodSnapshot {
            observe(snapshot)
            // A run that ended between two polls was never seen: count from step 0.
            if runStart == nil { steps = snapshot.timestep }
        }
        let outcome = ending.outcome ?? .cancelled
        let errorLine = simulation.lastErrorInputLine
        simulation.cancel()    // releases the engine, which stays to serve commands

        switch outcome {
        case .finished:
            return ExampleRunResult(id: example.id, status: .ok, completedInput: true, atoms: atoms, steps: steps,
                                    seconds: elapsed())
        case .cancelled:
            let status = stopped ?? .timeout
            return ExampleRunResult(id: example.id, status: status, atoms: atoms, steps: steps, seconds: elapsed(),
                                    message: status == .timeout ? "No \(limits.steps) steps within \(limits.timeout) s."
                                                                : nil)
        case .failed(let message):
            return ExampleRunResult(id: example.id, status: .failed, atoms: atoms, steps: steps, seconds: elapsed(),
                                    message: summary(message), inputLine: errorLine)
        }
    }

    /// The first line of a LAMMPS error, without its "ERROR: " prefix.
    static func summary(_ message: String) -> String {
        var line = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? message
        if line.hasPrefix("ERROR: ") { line.removeFirst(7) }
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// The outcome reported on the script thread.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Simulation.Outcome?

    var outcome: Simulation.Outcome? { lock.withLock { value } }
    func set(_ outcome: Simulation.Outcome) { lock.withLock { value = outcome } }
}
