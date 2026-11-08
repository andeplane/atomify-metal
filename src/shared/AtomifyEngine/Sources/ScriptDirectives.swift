import Foundation

/// Draw a bond between atoms of these types when they are closer than
/// `cutoff` (simulation length units).
public struct BondRule: Sendable, Equatable, Hashable {
    public var type1: Int
    public var type2: Int
    public var cutoff: Double

    public init(type1: Int, type2: Int, cutoff: Double) {
        self.type1 = type1; self.type2 = type2; self.cutoff = cutoff
    }

    /// Whether this rule is for the same pair of types as `other`, in either order.
    public func samePair(as other: BondRule) -> Bool {
        (type1 == other.type1 && type2 == other.type2) || (type1 == other.type2 && type2 == other.type1)
    }
}

/// The initial view a script or an example asks for.
public struct CameraHint: Sendable, Equatable {
    /// Eye position. In simulation coordinates, or relative to the box
    /// center with `relativeToBoxCenter`.
    public var position: SIMD3<Double>?
    /// The point looked at; the box center when nil.
    public var target: SIMD3<Double>?
    /// Which way is up on screen; +y when nil. Only its part across the
    /// view direction counts.
    public var up: SIMD3<Double>?
    /// Vertical field of view in degrees; the viewer's default when nil.
    public var fieldOfView: Double?
    /// `position` and `target` are offsets from the box center, as the
    /// Atomify 2 apps drew systems centered on the origin.
    public var relativeToBoxCenter: Bool

    public init(position: SIMD3<Double>? = nil, target: SIMD3<Double>? = nil, up: SIMD3<Double>? = nil,
                fieldOfView: Double? = nil, relativeToBoxCenter: Bool = false) {
        self.position = position; self.target = target; self.up = up
        self.fieldOfView = fieldOfView; self.relativeToBoxCenter = relativeToBoxCenter
    }
}

/// Which Atomify's reading of the `#/atom` directives a script was written
/// for. They differ in element colors, radii and the colors of types
/// without a directive.
public enum ScriptDialect: String, Sendable, Codable, Equatable {
    /// The Atomify web app (and this app's default).
    case web
    /// Atomify 2, the Qt app for desktop and iOS (2016-2017).
    case atomify2
}

/// The Atomify comment commands in a LAMMPS input script, as the web app
/// reads them:
///
///     #/atom 1 oxygen              element color and radius for type 1 (name or symbol)
///     #/atom 2 1.5 #ff0000         custom radius and color for type 2
///     #/bond 1 2 2.0               bonds between types 1 and 2 closer than 2.0
///     #/camera position 10 10 30   initial camera position
///     #/camera target 5 5 5        point the camera looks at
///
/// They are LAMMPS comments, so scripts stay valid for plain LAMMPS. Radii
/// are scaled by `elementRadiusScale` like the web app does when drawing.
/// Later lines win. Unknown `#/` commands are ignored; malformed known ones
/// produce a warning.
public struct ScriptDirectives: Sendable, Equatable {
    public var atomStyles: [Int: AtomStyle]
    public var bondRules: [BondRule]
    public var camera: CameraHint?
    public var warnings: [String]
    /// How `#/atom` was read, and how types without one are drawn.
    public var dialect: ScriptDialect

    public init(atomStyles: [Int: AtomStyle] = [:], bondRules: [BondRule] = [], camera: CameraHint? = nil,
                warnings: [String] = [], dialect: ScriptDialect = .web) {
        self.atomStyles = atomStyles; self.bondRules = bondRules; self.camera = camera; self.warnings = warnings
        self.dialect = dialect
    }

    /// The web app draws atoms at 0.33 times the radius given in `#/atom`
    /// (van der Waals radius for elements).
    public static let elementRadiusScale = 0.33
    /// Atomify 2 on iOS drew them at 0.25 times that radius.
    public static let atomify2RadiusScale = 0.25

    /// The radius factor of a dialect.
    public static func radiusScale(_ dialect: ScriptDialect) -> Double {
        switch dialect {
        case .web: elementRadiusScale
        case .atomify2: atomify2RadiusScale
        }
    }

    public static func parse(_ script: String, dialect: ScriptDialect = .web) -> ScriptDirectives {
        var result = ScriptDirectives(dialect: dialect)
        for rawLine in script.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#/") else { continue }
            let words = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
            guard let command = words.first else { continue }
            let arguments = Array(words.dropFirst())
            switch command {
            case "atom": result.parseAtom(arguments, line: line)
            case "bond": result.parseBond(arguments, line: line)
            case "camera": result.parseCamera(arguments, line: line)
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
        let scale = Self.radiusScale(dialect)
        if args.count == 2, let element = Element.named(args[1], dialect: dialect) {
            atomStyles[type] = AtomStyle(name: element.symbol, color: element.color, radius: element.radius * scale)
        } else if args.count == 2 {
            warnings.append("Ignored '\(line)': atom type '\(args[1])' does not exist.")
        } else if args.count == 3, let radius = Double(args[1]), radius > 0, radius.isFinite,
                  args[2].hasPrefix("#"), let color = RGBColor(hexString: args[2]) {
            atomStyles[type] = AtomStyle(name: "Type \(type)", color: color, radius: radius * scale)
        } else {
            warnings.append("Ignored '\(line)': expected an element name, or a radius and #RRGGBB color.")
        }
    }

    private mutating func parseBond(_ args: [String], line: String) {
        guard args.count == 3, let a = Int(args[0]), let b = Int(args[1]), let cutoff = Double(args[2]),
              a > 0, b > 0, cutoff > 0, cutoff.isFinite else {
            warnings.append("Ignored '\(line)': expected two atom types and a distance.")
            return
        }
        let rule = BondRule(type1: a, type2: b, cutoff: cutoff)
        if let existing = bondRules.firstIndex(where: { $0.samePair(as: rule) }) {
            bondRules[existing] = rule
        } else {
            bondRules.append(rule)
        }
    }

    private mutating func parseCamera(_ args: [String], line: String) {
        guard args.count == 4, args[0] == "position" || args[0] == "target",
              let x = Double(args[1]), let y = Double(args[2]), let z = Double(args[3]),
              x.isFinite, y.isFinite, z.isFinite else {
            warnings.append("Ignored '\(line)': expected 'camera position x y z' or 'camera target x y z'.")
            return
        }
        var hint = camera ?? CameraHint()
        if args[0] == "position" {
            hint.position = SIMD3(x, y, z)
        } else {
            hint.target = SIMD3(x, y, z)
        }
        camera = hint
    }
}
