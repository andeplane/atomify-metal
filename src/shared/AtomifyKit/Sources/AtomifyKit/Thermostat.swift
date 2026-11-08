/// A Langevin heat bath on all atoms that the app switches on and off while a
/// script runs, through queued LAMMPS commands (the old app's thermostat).
///
/// It adds `fix atomify_thermostat all langevin T T damp seed zero yes`
/// next to the script's own fixes. Langevin adds forces only, so the script
/// must integrate the atoms (`fix nve` or similar). A script that already
/// thermostats its atoms (`fix nvt`, its own `langevin`) keeps doing so, and
/// the two pull toward their own targets.
public struct Thermostat: Sendable, Equatable {
    /// The LAMMPS fix id the app owns.
    public static let fixID = "atomify_thermostat"
    public static let removeCommand = "unfix \(fixID)"

    public var isEnabled: Bool
    /// Target temperature in the run's units (K, or reduced for `lj`).
    public var target: Double
    /// Damping time in timesteps (LAMMPS recommends about 100).
    public var dampingSteps: Double
    /// Random seed, a positive integer.
    public var seed: Int

    public init(isEnabled: Bool = false, target: Double = 300, dampingSteps: Double = 100, seed: Int = 48279) {
        self.isEnabled = isEnabled
        self.target = target
        self.dampingSteps = dampingSteps
        self.seed = seed
    }

    /// The command that adds the fix. The damping time is evaluated by
    /// LAMMPS from the current timestep size (`$(100.0*dt)`), so it is right
    /// in every unit style.
    public var addCommand: String {
        let target = Self.commandNumber(self.target)
        let damping = Self.commandNumber(dampingSteps)
        return "fix \(Self.fixID) all langevin \(target) \(target) $(\(damping)*dt) \(max(seed, 1)) zero yes"
    }

    /// Commands that take a run with `old` applied to `new`: add, remove,
    /// or replace the fix (Langevin's target cannot be changed in place).
    public static func commands(from old: Thermostat, to new: Thermostat) -> [String] {
        switch (old.isEnabled, new.isEnabled) {
        case (false, false): return []
        case (false, true): return [new.addCommand]
        case (true, false): return [removeCommand]
        case (true, true): return old.addCommand == new.addCommand ? [] : [removeCommand, new.addCommand]
        }
    }

    /// Whether `units` measures temperature in reduced Lennard-Jones units.
    public static func isReduced(units: String) -> Bool { units == "lj" }

    /// The temperature a new run starts the control at.
    public static func defaultTarget(units: String) -> Double { isReduced(units: units) ? 1.0 : 300 }

    /// Quick choices for the target.
    public static func presets(units: String) -> [Double] {
        isReduced(units: units) ? [0.5, 1.0, 1.5, 2.0] : [300, 500, 1000, 2000]
    }

    /// The slider's range.
    public static func targetRange(units: String) -> ClosedRange<Double> {
        isReduced(units: units) ? 0.05...5 : 1...3000
    }

    /// `target` limited to the slider's range; non-finite values give the default.
    public static func clampedTarget(_ target: Double, units: String) -> Double {
        guard target.isFinite else { return defaultTarget(units: units) }
        let range = targetRange(units: units)
        return min(max(target, range.lowerBound), range.upperBound)
    }

    /// A number as LAMMPS reads it, independent of the locale ("300.0", "1e-05").
    static func commandNumber(_ value: Double) -> String {
        value.isFinite ? "\(value)" : "0.0"
    }
}
