import AtomifyRender
import simd

/// Ball-and-stick appearance of the few elements the test scenes use.
/// Colors are the Jmol CPK colors (sRGB); radii are display radii in Å,
/// smaller than van der Waals radii so bonds stay visible.
struct LabElement: Sendable, Equatable {
    let symbol: String
    let name: String
    /// sRGB as 0xRRGGBB.
    let srgbHex: UInt32
    let radius: Float

    var style: ParticleStyle {
        ParticleStyle(radius: radius, color: linearColor(hex: srgbHex))
    }

    static let hydrogen = LabElement(symbol: "H", name: "hydrogen", srgbHex: 0xFFFFFF, radius: 0.28)
    static let oxygen = LabElement(symbol: "O", name: "oxygen", srgbHex: 0xFF0D0D, radius: 0.40)
    static let carbon = LabElement(symbol: "C", name: "carbon", srgbHex: 0x909090, radius: 0.46)
    static let silicon = LabElement(symbol: "Si", name: "silicon", srgbHex: 0xF0C8A0, radius: 0.62)
    static let aluminium = LabElement(symbol: "Al", name: "aluminium", srgbHex: 0xBFA6A6, radius: 1.0)
}

/// Shared look of the scenes' simulation boxes.
enum LabLines {
    /// Linear RGBA.
    static let boxColor = SIMD4<Float>(0.55, 0.58, 0.65, 1)

    static func box(size: SIMD3<Float>) -> LineData {
        LineData.box(low: .zero, high: size, color: boxColor)
    }
}
