import Foundation

/// Number formatting for the run's units.
enum Format {
    /// "312 K" for real units, "T 1.20" for reduced Lennard-Jones units.
    static func temperature(_ value: Double, units: String) -> String {
        guard value.isFinite else { return "–" }
        if units == "lj" {
            return "T " + value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
        }
        return value.formatted(.number.precision(.fractionLength(0))) + " K"
    }

    /// Two decimals for everyday magnitudes, scientific notation for SI
    /// lengths and other very small or large values.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let magnitude = abs(value)
        if magnitude == 0 || (magnitude >= 0.01 && magnitude < 100_000) {
            return value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
        }
        return value.formatted(.number.notation(.scientific).precision(.significantDigits(3)))
    }

    /// The length unit of a LAMMPS unit system, for labels like "x (Å)".
    static func lengthUnit(_ units: String) -> String? {
        switch units {
        case "lj": "σ"
        case "real", "metal": "Å"
        case "si": "m"
        case "cgs": "cm"
        case "electron": "a₀"
        case "micro": "µm"
        case "nano": "nm"
        default: nil
        }
    }

    /// "x (Å)", or "x" when the unit is unknown.
    static func axis(_ name: String, units: String) -> String {
        lengthUnit(units).map { "\(name) (\($0))" } ?? name
    }

    /// "1.52 Å", or the bare number.
    static func length(_ value: Double, units: String) -> String {
        let number = number(value)
        return lengthUnit(units).map { "\(number) \($0)" } ?? number
    }

    /// Whole numbers with grouping: "1,860".
    static func count(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    /// One decimal: "0.4".
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
