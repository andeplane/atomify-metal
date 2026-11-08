import Foundation

/// How atoms of one LAMMPS type are drawn.
public struct AtomStyle: Sendable, Equatable {
    public var name: String
    public var color: RGBColor
    /// Drawn sphere radius in simulation length units.
    public var radius: Double

    public init(name: String, color: RGBColor, radius: Double) {
        self.name = name; self.color = color; self.radius = radius
    }
}

/// Draw a bond between atoms of these types when they are closer than
/// `cutoff` (simulation length units).
public struct BondRule: Sendable, Equatable, Hashable {
    public var type1: Int
    public var type2: Int
    public var cutoff: Double

    public init(type1: Int, type2: Int, cutoff: Double) {
        self.type1 = type1; self.type2 = type2; self.cutoff = cutoff
    }
}

/// The Atomify comment commands in a LAMMPS input script:
///
///     #/atom 1 oxygen          element colors and radius for type 1
///     #/atom 2 1.5 #ff0000     custom radius and color for type 2
///     #/bond 1 2 2.0           bonds between types 1 and 2 closer than 2.0
///
/// They are LAMMPS comments, so scripts stay valid for plain LAMMPS.
/// Camera commands from the web app are ignored here.
public struct ScriptDirectives: Sendable, Equatable {
    public var atomStyles: [Int: AtomStyle] = [:]
    public var bondRules: [BondRule] = []
    public var warnings: [String] = []

    public init(atomStyles: [Int: AtomStyle] = [:], bondRules: [BondRule] = []) {
        self.atomStyles = atomStyles; self.bondRules = bondRules
    }

    /// Element van der Waals radii are scaled by this for a ball and stick look.
    public static let elementRadiusScale = 0.3

    public static func parse(_ script: String) -> ScriptDirectives {
        var result = ScriptDirectives()
        for rawLine in script.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#/") else { continue }
            let words = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
            guard let command = words.first else { continue }
            switch command {
            case "atom": result.parseAtom(Array(words.dropFirst()), line: line)
            case "bond": result.parseBond(Array(words.dropFirst()), line: line)
            default: continue
            }
        }
        return result
    }

    private mutating func parseAtom(_ args: [String], line: String) {
        guard let type = args.first.flatMap({ Int($0) }), type > 0 else {
            warnings.append("Ignored '\(line)': expected an atom type number.")
            return
        }
        if args.count == 2, let element = Element.named(args[1]) {
            atomStyles[type] = AtomStyle(name: element.symbol, color: element.color,
                                         radius: element.radius * Self.elementRadiusScale)
        } else if args.count == 3, let radius = Double(args[1]), radius > 0,
                  let color = RGBColor(hexString: args[2]) {
            atomStyles[type] = AtomStyle(name: "Type \(type)", color: color, radius: radius * Self.elementRadiusScale)
        } else {
            warnings.append("Ignored '\(line)': expected an element name, or a radius and #RRGGBB color.")
        }
    }

    private mutating func parseBond(_ args: [String], line: String) {
        guard args.count == 3, let a = Int(args[0]), let b = Int(args[1]), let cutoff = Double(args[2]),
              a > 0, b > 0, cutoff > 0 else {
            warnings.append("Ignored '\(line)': expected two atom types and a distance.")
            return
        }
        bondRules.append(BondRule(type1: a, type2: b, cutoff: cutoff))
    }
}

/// Resolves the style of every atom type: script directives first, then a
/// palette with a size that suits the unit system.
public struct AtomStyleTable: Sendable, Equatable {
    public var styles: [Int: AtomStyle]

    public static let palette: [RGBColor] = [
        RGBColor(hex: 0xE8C547), RGBColor(hex: 0x4F9DDE), RGBColor(hex: 0xE5604D),
        RGBColor(hex: 0x6CC08B), RGBColor(hex: 0xB07CD8), RGBColor(hex: 0xF29A4A),
        RGBColor(hex: 0x5BC8C8), RGBColor(hex: 0xD6D6D6),
    ]

    public init(directives: ScriptDirectives, typeCount: Int, units: String) {
        let fallbackRadius = Self.defaultRadius(units: units)
        var styles: [Int: AtomStyle] = [:]
        for type in 1...max(typeCount, 1) {
            styles[type] = directives.atomStyles[type] ?? AtomStyle(
                name: "Type \(type)", color: Self.palette[(type - 1) % Self.palette.count], radius: fallbackRadius)
        }
        self.styles = styles
    }

    public func style(forType type: Int) -> AtomStyle {
        styles[type] ?? AtomStyle(name: "Type \(type)", color: Self.palette[0], radius: 0.5)
    }

    /// Half the typical nearest neighbor distance: sigma in LJ units, about
    /// two ångström otherwise.
    public static func defaultRadius(units: String) -> Double {
        switch units {
        case "lj": 0.5
        case "si": 1.0e-10
        case "cgs": 1.0e-8
        case "nano": 0.1
        case "micro": 1.0e-4
        default: 1.0
        }
    }
}
