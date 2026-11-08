/// Element colors and van der Waals radii (Å), the same table the Atomify
/// web app uses for `#/atom <type> <element>`.
public struct Element: Sendable, Equatable {
    public let symbol: String
    public let name: String
    public let radius: Double
    public let color: RGBColor

    /// Looks up an element by full name ("oxygen") or symbol ("O"), ignoring case.
    public static func named(_ name: String) -> Element? {
        let key = name.lowercased()
        return all.first { $0.name == key || $0.symbol.lowercased() == key }
    }

    public static let all: [Element] = [
        Element(symbol: "H", name: "hydrogen", radius: 1.2, color: RGBColor(hex: 0xCCCCCC)),
        Element(symbol: "He", name: "helium", radius: 1.4, color: RGBColor(hex: 0xD9FFFF)),
        Element(symbol: "Li", name: "lithium", radius: 1.82, color: RGBColor(hex: 0xCC80FF)),
        Element(symbol: "Be", name: "beryllium", radius: 1.53, color: RGBColor(hex: 0xC2FF00)),
        Element(symbol: "B", name: "boron", radius: 1.92, color: RGBColor(hex: 0xFFB5B5)),
        Element(symbol: "C", name: "carbon", radius: 1.7, color: RGBColor(hex: 0x808080)),
        Element(symbol: "N", name: "nitrogen", radius: 1.55, color: RGBColor(hex: 0x3050F8)),
        Element(symbol: "O", name: "oxygen", radius: 1.52, color: RGBColor(hex: 0xAA0000)),
        Element(symbol: "F", name: "fluorine", radius: 1.35, color: RGBColor(hex: 0x90E050)),
        Element(symbol: "Ne", name: "neon", radius: 1.54, color: RGBColor(hex: 0x3050F8)),
        Element(symbol: "Na", name: "sodium", radius: 2.27, color: RGBColor(hex: 0xAB5CF2)),
        Element(symbol: "Mg", name: "magnesium", radius: 1.73, color: RGBColor(hex: 0x8AFF00)),
        Element(symbol: "Al", name: "aluminium", radius: 1.84, color: RGBColor(hex: 0xBFA6A6)),
        Element(symbol: "Si", name: "silicon", radius: 2.27, color: RGBColor(hex: 0xF0C8A0)),
        Element(symbol: "P", name: "phosphorus", radius: 1.8, color: RGBColor(hex: 0xFF8000)),
        Element(symbol: "S", name: "sulfur", radius: 1.8, color: RGBColor(hex: 0xFFFF30)),
        Element(symbol: "Cl", name: "chlorine", radius: 1.75, color: RGBColor(hex: 0x1FF01F)),
        Element(symbol: "Ar", name: "argon", radius: 1.88, color: RGBColor(hex: 0x80D1E3)),
        Element(symbol: "K", name: "potassium", radius: 2.75, color: RGBColor(hex: 0x8F40D4)),
        Element(symbol: "Ca", name: "calcium", radius: 2.31, color: RGBColor(hex: 0x3DFF00)),
        Element(symbol: "Sc", name: "scandium", radius: 2.11, color: RGBColor(hex: 0xE6E6E6)),
        Element(symbol: "Ti", name: "titanium", radius: 2.0, color: RGBColor(hex: 0xBFC2C7)),
        Element(symbol: "V", name: "vanadium", radius: 2.0, color: RGBColor(hex: 0xA6A6AB)),
        Element(symbol: "Cr", name: "chromium", radius: 2.0, color: RGBColor(hex: 0x8A99C7)),
        Element(symbol: "Mn", name: "manganese", radius: 2.0, color: RGBColor(hex: 0x9C7AC7)),
        Element(symbol: "Fe", name: "iron", radius: 2.0, color: RGBColor(hex: 0xE06633)),
        Element(symbol: "Co", name: "cobalt", radius: 2.0, color: RGBColor(hex: 0xF090A0)),
        Element(symbol: "Ni", name: "nickel", radius: 1.63, color: RGBColor(hex: 0x50D050)),
        Element(symbol: "Cu", name: "copper", radius: 1.4, color: RGBColor(hex: 0xC88033)),
        Element(symbol: "Zn", name: "zinc", radius: 1.39, color: RGBColor(hex: 0x7D80B0)),
        Element(symbol: "Ga", name: "gallium", radius: 1.87, color: RGBColor(hex: 0xC28F8F)),
        Element(symbol: "Ge", name: "germanium", radius: 2.11, color: RGBColor(hex: 0x668F8F)),
        Element(symbol: "As", name: "arsenic", radius: 1.85, color: RGBColor(hex: 0xBD80E3)),
        Element(symbol: "Se", name: "selenium", radius: 1.9, color: RGBColor(hex: 0xFFA100)),
        Element(symbol: "Br", name: "bromine", radius: 1.85, color: RGBColor(hex: 0xA62929)),
        Element(symbol: "Kr", name: "krypton", radius: 2.02, color: RGBColor(hex: 0x5CB8D1)),
        Element(symbol: "Rb", name: "rubidium", radius: 3.03, color: RGBColor(hex: 0x702EB0)),
        Element(symbol: "Sr", name: "strontium", radius: 2.49, color: RGBColor(hex: 0x00FF00)),
        Element(symbol: "Y", name: "yttrium", radius: 2.0, color: RGBColor(hex: 0x94FFFF)),
        Element(symbol: "Zr", name: "zirconium", radius: 2.0, color: RGBColor(hex: 0x94E0E0)),
        Element(symbol: "Nb", name: "niobium", radius: 2.0, color: RGBColor(hex: 0x73C2C9)),
        Element(symbol: "Mo", name: "molybdenum", radius: 2.0, color: RGBColor(hex: 0x54B5B5)),
        Element(symbol: "Tc", name: "technetium", radius: 2.0, color: RGBColor(hex: 0x3B9E9E)),
        Element(symbol: "Ru", name: "ruthenium", radius: 2.0, color: RGBColor(hex: 0x248F8F)),
        Element(symbol: "Rh", name: "rhodium", radius: 2.0, color: RGBColor(hex: 0x0A7D8C)),
        Element(symbol: "Pd", name: "palladium", radius: 1.63, color: RGBColor(hex: 0x006985)),
        Element(symbol: "Ag", name: "silver", radius: 1.72, color: RGBColor(hex: 0xC0C0C0)),
        Element(symbol: "Cd", name: "cadmium", radius: 1.58, color: RGBColor(hex: 0xFFD98F)),
        Element(symbol: "In", name: "indium", radius: 1.93, color: RGBColor(hex: 0xA67573)),
        Element(symbol: "Sn", name: "tin", radius: 2.17, color: RGBColor(hex: 0x668080)),
        Element(symbol: "Sb", name: "antimony", radius: 2.06, color: RGBColor(hex: 0x9E63B5)),
        Element(symbol: "Te", name: "tellurium", radius: 2.06, color: RGBColor(hex: 0xD47A00)),
        Element(symbol: "I", name: "iodine", radius: 1.98, color: RGBColor(hex: 0x940094)),
        Element(symbol: "Xe", name: "xenon", radius: 2.16, color: RGBColor(hex: 0x429EB0)),
        Element(symbol: "Cs", name: "caesium", radius: 3.43, color: RGBColor(hex: 0x57178F)),
        Element(symbol: "Ba", name: "barium", radius: 2.68, color: RGBColor(hex: 0x00C900)),
        Element(symbol: "La", name: "lanthanum", radius: 2.0, color: RGBColor(hex: 0x70D4FF)),
        Element(symbol: "Ce", name: "cerium", radius: 2.0, color: RGBColor(hex: 0xFFFFC7)),
        Element(symbol: "Pr", name: "praseodymium", radius: 2.0, color: RGBColor(hex: 0xD9FFC7)),
        Element(symbol: "Nd", name: "neodymium", radius: 2.0, color: RGBColor(hex: 0xC7FFC7)),
        Element(symbol: "Pm", name: "promethium", radius: 2.0, color: RGBColor(hex: 0xA3FFC7)),
        Element(symbol: "Sm", name: "samarium", radius: 2.0, color: RGBColor(hex: 0x8FFFC7)),
        Element(symbol: "Eu", name: "europium", radius: 2.0, color: RGBColor(hex: 0x61FFC7)),
        Element(symbol: "Gd", name: "gadolinium", radius: 2.0, color: RGBColor(hex: 0x45FFC7)),
        Element(symbol: "Tb", name: "terbium", radius: 2.0, color: RGBColor(hex: 0x30FFC7)),
        Element(symbol: "Dy", name: "dysprosium", radius: 2.0, color: RGBColor(hex: 0x1FFFC7)),
        Element(symbol: "Ho", name: "holmium", radius: 2.0, color: RGBColor(hex: 0x00FF9C)),
        Element(symbol: "Er", name: "erbium", radius: 2.0, color: RGBColor(hex: 0x00E675)),
        Element(symbol: "Tm", name: "thulium", radius: 2.0, color: RGBColor(hex: 0x00D452)),
        Element(symbol: "Yb", name: "ytterbium", radius: 2.0, color: RGBColor(hex: 0x00BF38)),
        Element(symbol: "Lu", name: "lutetium", radius: 2.0, color: RGBColor(hex: 0x00AB24)),
        Element(symbol: "Hf", name: "hafnium", radius: 2.0, color: RGBColor(hex: 0x4DC2FF)),
        Element(symbol: "Ta", name: "tantalum", radius: 2.0, color: RGBColor(hex: 0x4DA6FF)),
        Element(symbol: "W", name: "tungsten", radius: 2.0, color: RGBColor(hex: 0x2194D6)),
    ]
}

public struct RGBColor: Sendable, Equatable, Hashable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
    /// Parses "#RRGGBB" or "RRGGBB".
    public init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
