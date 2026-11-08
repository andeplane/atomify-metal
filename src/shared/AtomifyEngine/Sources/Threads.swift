import CLammps
import Foundation

/// How many OpenMP threads LAMMPS may run on.
///
/// A simulation gets a maximum; its first run then picks how many of those
/// the system gains from (small systems with cheap potentials run on one,
/// see `Simulation.threads`). LAMMPS splits each step evenly between its
/// threads and waits for the slowest one, so threads on efficiency cores
/// hold back those on performance cores. The default maximum is therefore
/// the number of performance cores, capped, and the serial engine where
/// that is unknown.
public enum SimulationThreads {
    /// Most threads this build can use: the processor count, or 1 when
    /// LAMMPS was built without OpenMP.
    public static var available: Int { Int(atomify_max_threads()) }

    /// Threads new simulations use unless told otherwise.
    public static let `default` = recommended(performanceCores: sysctlInteger("hw.perflevel0.physicalcpu"),
                                              available: available)

    /// Upper limit on the default; beyond it even 100,000 atoms gain little.
    public static let defaultLimit = 8

    /// The default for a device with `performanceCores` performance cores
    /// (nil when unknown) and a build that can use `available` threads.
    public static func recommended(performanceCores: Int?, available: Int, limit: Int = defaultLimit) -> Int {
        guard let performanceCores, performanceCores > 0 else { return 1 }
        return max(1, min(performanceCores, available, limit))
    }

    static func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
