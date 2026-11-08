import Foundation
import simd

/// Simulations that fill the wearer's room: a Lennard-Jones gas whose
/// length unit is a few centimeters, bounded by the room mesh.
public struct RoomScenario: Sendable, Hashable, Identifiable {
    public enum Preset: String, Sendable, CaseIterable, Identifiable {
        case gas, twoGases, droplets
        public var id: Self { self }
    }

    public enum Amount: String, Sendable, CaseIterable, Identifiable {
        case fewer, normal, more
        public var id: Self { self }
        public var title: String { rawValue.capitalized }
        var factor: Double {
            switch self {
            case .fewer: 0.4
            case .normal: 1
            case .more: 2.5
            }
        }
    }

    public var preset: Preset
    public var amount: Amount = .normal

    public init(preset: Preset, amount: Amount = .normal) { self.preset = preset; self.amount = amount }

    public var id: String { "room-\(preset.rawValue)" }

    /// Meters per simulation length unit (sigma).
    public static let metersPerUnit: Float = 0.04
    /// Region simulated around the wearer's starting point, in meters
    /// (the immersive space's origin is on the floor under the wearer).
    public static let roomLow = SIMD3<Float>(-4, -0.1, -4)
    public static let roomHigh = SIMD3<Float>(4, 3.2, 4)
    /// Atoms start in a ball in front of the wearer, then spread out.
    public static let spawnCenter = SIMD3<Float>(0, 1.3, -1.2)
    public static let spawnRadius: Float = 0.6

    /// Walls start pushing this far from the room mesh, in simulation units.
    public static let wallCutoff = 3.0
    public static let wallStrength = 60.0

    public var title: String {
        switch preset {
        case .gas: "Gas in your room"
        case .twoGases: "Two gases"
        case .droplets: "Droplets"
        }
    }

    public var summary: String {
        switch preset {
        case .gas: "Atoms float through your room and bounce off walls, floor and furniture. Push them with your hands."
        case .twoGases: "Light and heavy atoms mixing. The heavy ones move slower."
        case .droplets: "A cold, sticky gas. Atoms clump into droplets over time. Push a cluster apart and watch what happens."
        }
    }

    var baseCount: Int {
        switch preset {
        case .gas: 1200
        case .twoGases: 1600
        case .droplets: 1500
        }
    }

    public var atomCount: Int { Int(Double(baseCount) * amount.factor) }

    var temperature: Double { preset == .droplets ? 0.45 : 1.0 }

    /// The `#/atom` lines give colors; everything else is plain LAMMPS.
    public func script(seed: Int = 4928) -> String {
        let s = Self.metersPerUnit
        let low = Self.roomLow / s, high = Self.roomHigh / s
        let center = Self.spawnCenter / s, radius = Self.spawnRadius / s
        func f(_ value: Float) -> String { String(format: "%.3f", value) }
        let count = atomCount
        var lines = [
            "# Room scenario: \(title)",
            "#/atom 1 1.2 #6EC6FF",
            "#/atom 2 1.2 #FF8A65",
            "units lj",
            "atom_style atomic",
            "boundary f f f",
            "region room block \(f(low.x)) \(f(high.x)) \(f(low.y)) \(f(high.y)) \(f(low.z)) \(f(high.z))",
            "region spawn sphere \(f(center.x)) \(f(center.y)) \(f(center.z)) \(f(radius))",
            "create_box 2 room",
        ]
        switch preset {
        case .gas, .droplets:
            lines.append("create_atoms 1 random \(count) \(seed) spawn overlap 0.9 maxtry 200")
        case .twoGases:
            lines.append("create_atoms 1 random \(count / 2) \(seed) spawn overlap 0.9 maxtry 200")
            lines.append("create_atoms 2 random \(count - count / 2) \(seed + 1) spawn overlap 0.9 maxtry 200")
        }
        lines += [
            "mass 1 1.0",
            "mass 2 \(preset == .twoGases ? "4.0" : "1.0")",
            "pair_style lj/cut 2.5",
            "pair_coeff * * 1.0 1.0 2.5",
            "neighbor 0.5 bin",
            "neigh_modify every 1 delay 0 check yes",
            "velocity all create \(temperature) \(seed + 2) mom yes rot yes",
            "fix move all nve",
            "fix heat all langevin \(temperature) \(temperature) 5.0 \(seed + 3)",
            "fix room all wall/reflect xlo EDGE xhi EDGE ylo EDGE yhi EDGE zlo EDGE zhi EDGE",
            "thermo_modify lost error",
            "timestep 0.005",
            "run 1000000000",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the script to a fresh folder and returns it and the script.
    public func makeWorkingCopy(into scratch: URL = FileManager.default.temporaryDirectory) throws
        -> (folder: URL, script: URL) {
        let folder = scratch.appendingPathComponent("atomify-room-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("room.in")
        try script(seed: Int.random(in: 1000...99999)).write(to: url, atomically: true, encoding: .utf8)
        return (folder, url)
    }
}

/// How strongly hands act on atoms, per LAMMPS unit system, so a push feels
/// similar in every simulation.
public struct InteractionTuning: Sendable, Equatable {
    /// Peak force of a fingertip or palm sphere, in force units.
    public var pushStrength: Double
    /// Spring constant pulling a grabbed atom, in force per length units.
    public var grabStiffness: Double

    public static func forUnits(_ units: String) -> InteractionTuning {
        switch units {
        case "metal": InteractionTuning(pushStrength: 1, grabStiffness: 20)         // eV/Å, eV/Å²
        case "real": InteractionTuning(pushStrength: 23.06, grabStiffness: 100)        // kcal/mol/Å
        case "electron": InteractionTuning(pushStrength: 0.1, grabStiffness: 0.2)
        default: InteractionTuning(pushStrength: 10, grabStiffness: 50)             // lj
        }
    }
}
