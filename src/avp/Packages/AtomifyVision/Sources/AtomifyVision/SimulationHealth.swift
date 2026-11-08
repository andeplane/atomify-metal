import Foundation

/// Conservative wall-clock health policy. No temperatures or model parameters
/// are silently modified: heating and bond breaking can be the experiment.
public struct SimulationWatchdog: Sendable {
    public var startupTimeout: TimeInterval = 60
    public var progressTimeout: TimeInterval = 20
    private var hasProgressed = false

    public init() {}

    public mutating func issue(progressAge: TimeInterval, hasSnapshot: Bool, paused: Bool) -> String? {
        if hasSnapshot { hasProgressed = true }
        guard !paused else { return nil }
        guard progressAge.isFinite, progressAge >= 0 else { return "The simulation clock is invalid." }
        let limit = hasProgressed ? progressTimeout : startupTimeout
        guard progressAge > limit else { return nil }
        return hasProgressed
            ? "The simulation stopped responding. Interaction forces have been released."
            : "The experiment did not finish preparing. Try resetting it."
    }
}
