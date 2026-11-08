/// Names of the units of a LAMMPS unit style, for labels
/// (https://docs.lammps.org/units.html), as the web app shows them.
public struct UnitSystem: Sendable, Equatable {
    public var style: String
    public var time: String
    public var length: String
    public var energy: String
    public var temperature: String
    public var pressure: String
    public var velocity: String

    public init(style: String, time: String, length: String, energy: String, temperature: String,
                pressure: String, velocity: String) {
        self.style = style; self.time = time; self.length = length; self.energy = energy
        self.temperature = temperature; self.pressure = pressure; self.velocity = velocity
    }

    /// The unit system of a LAMMPS unit style ("lj", "real", "metal", ...), or nil.
    public static func named(_ style: String) -> UnitSystem? { all.first { $0.style == style } }

    public static let all: [UnitSystem] = [
        UnitSystem(style: "lj", time: "τ", length: "σ", energy: "ε", temperature: "reduced LJ",
                   pressure: "ε/σ³", velocity: "σ/τ"),
        UnitSystem(style: "real", time: "fs", length: "Å", energy: "kcal/mol", temperature: "K",
                   pressure: "atm", velocity: "Å/fs"),
        UnitSystem(style: "metal", time: "ps", length: "Å", energy: "eV", temperature: "K",
                   pressure: "bar", velocity: "Å/ps"),
        UnitSystem(style: "si", time: "s", length: "m", energy: "J", temperature: "K",
                   pressure: "Pa", velocity: "m/s"),
        UnitSystem(style: "cgs", time: "s", length: "cm", energy: "erg", temperature: "K",
                   pressure: "dyn/cm²", velocity: "cm/s"),
        UnitSystem(style: "electron", time: "fs", length: "Bohr", energy: "Hartree", temperature: "K",
                   pressure: "Pa", velocity: "Bohr/atomic time unit"),
        UnitSystem(style: "micro", time: "µs", length: "µm", energy: "pg·µm²/µs²", temperature: "K",
                   pressure: "pg/(µm·µs²)", velocity: "µm/µs"),
        UnitSystem(style: "nano", time: "ns", length: "nm", energy: "ag·nm²/ns²", temperature: "K",
                   pressure: "ag/(nm·ns²)", velocity: "nm/ns"),
    ]
}
