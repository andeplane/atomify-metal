import Foundation

extension SimulationSnapshot {
    /// Checked before a snapshot reaches either renderer or the graph history.
    public var validationIssue: String? {
        guard time.isFinite, temperature.isFinite, temperature >= 0,
              kineticEnergy.isFinite, kineticEnergy >= 0,
              potentialEnergy?.isFinite ?? true,
              stepsPerSecond.isFinite, stepsPerSecond >= 0,
              grabForce.x.isFinite, grabForce.y.isFinite, grabForce.z.isFinite else {
            return "The simulation produced invalid energy or time."
        }
        for axis in 0..<3 {
            guard boxLow[axis].isFinite, boxHigh[axis].isFinite,
                  boxHigh[axis] > boxLow[axis],
                  Float(boxLow[axis]).isFinite, Float(boxHigh[axis]).isFinite,
                  Float(boxHigh[axis] - boxLow[axis]).isFinite else {
                return "The simulation box is invalid."
            }
        }
        guard types.count == atomCount, positions.count == atomCount,
              radii == nil || radii?.count == atomCount else {
            return "The simulation returned incomplete atoms."
        }
        var previous: Int64 = 0
        for i in tags.indices {
            let p = positions[i]
            guard tags[i] > previous, types[i] > 0, Int(types[i]) <= typeCount,
                  p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                return "The simulation produced an invalid atom."
            }
            previous = tags[i]
        }
        if let radii, !radii.allSatisfy({ $0.isFinite && $0 > 0 }) {
            return "The simulation produced an invalid atom size."
        }
        guard bonds.allSatisfy({ Int($0.x) < atomCount && Int($0.y) < atomCount && $0.x != $0.y }) else {
            return "The simulation returned an invalid bond."
        }
        return nil
    }
}

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
