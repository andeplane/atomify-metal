/// An sRGB color with components in 0...1.
public struct RGBColor: Sendable, Equatable, Hashable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    /// From 0xRRGGBB.
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// Parses "#RRGGBB" or "RRGGBB" (either case); nil for anything else.
    public init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? hexString.dropFirst() : Substring(hexString)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.init(hex: value)
    }

    /// "#RRGGBB", components rounded and clamped to 0...255.
    public var hexString: String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let value = byte(red) << 16 | byte(green) << 8 | byte(blue)
        let digits = String(value, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }
}

/// How atoms of one LAMMPS type are drawn.
public struct AtomStyle: Sendable, Equatable {
    /// Element symbol, or "Type N" when no element is known.
    public var name: String
    public var color: RGBColor
    /// Drawn sphere radius in simulation length units.
    public var radius: Double

    public init(name: String, color: RGBColor, radius: Double) {
        self.name = name; self.color = color; self.radius = radius
    }
}

/// Resolves the style of every atom type: script directives first, then a
/// palette with a size that suits the unit system.
public struct AtomStyleTable: Sendable, Equatable {
    /// Style of each type 1...typeCount.
    public var styles: [Int: AtomStyle]
    /// Decides the colors of types without a style.
    public var dialect: ScriptDialect = .web

    public static let palette: [RGBColor] = [
        RGBColor(hex: 0xE8C547), RGBColor(hex: 0x4F9DDE), RGBColor(hex: 0xE5604D),
        RGBColor(hex: 0x6CC08B), RGBColor(hex: 0xB07CD8), RGBColor(hex: 0xF29A4A),
        RGBColor(hex: 0x5BC8C8), RGBColor(hex: 0xD6D6D6),
    ]

    public init(directives: ScriptDirectives, typeCount: Int, units: String) {
        var styles: [Int: AtomStyle] = [:]
        let dialect = directives.dialect
        for type in 1...max(typeCount, 1) {
            styles[type] = directives.atomStyles[type] ?? Self.fallback(type: type, units: units, dialect: dialect)
        }
        // Directives for types beyond typeCount are kept; LAMMPS may add types later.
        for (type, style) in directives.atomStyles where type > 0 && styles[type] == nil {
            styles[type] = style
        }
        self.styles = styles
        self.dialect = dialect
    }

    /// The style of a type; types without one get the palette color for
    /// their number and a radius of half a length unit.
    public func style(forType type: Int) -> AtomStyle {
        styles[type] ?? Self.fallback(type: type, units: "lj", dialect: dialect)
    }

    /// The style of a type without a directive. Atomify 2 drew type `t`
    /// as the `t`-th element of its table counting from hydrogen at 0
    /// (type 1 helium, 2 lithium, ...), repeating after calcium.
    public static func fallback(type: Int, units: String, dialect: ScriptDialect) -> AtomStyle {
        switch dialect {
        case .web:
            return fallback(type: type, units: units)
        case .atomify2:
            let cycle = 20
            let element = Element.atomify2[((type % cycle) + cycle) % cycle]
            return AtomStyle(name: "Type \(type)", color: element.color,
                             radius: element.radius * ScriptDirectives.atomify2RadiusScale)
        }
    }

    /// The palette style of a type without a directive.
    public static func fallback(type: Int, units: String) -> AtomStyle {
        let index = ((type - 1) % palette.count + palette.count) % palette.count
        return AtomStyle(name: "Type \(type)", color: palette[index], radius: defaultRadius(units: units))
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
        case "electron": 2.0
        default: 1.0
        }
    }
}
