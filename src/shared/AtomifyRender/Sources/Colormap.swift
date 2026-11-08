import Foundation
import simd

/// Color maps for coloring particles by a scalar. Stops are in sRGB and are
/// interpolated in sRGB (as plotting libraries do), then converted to linear
/// light, which the renderer shades in.
public enum Colormap: String, CaseIterable, Sendable {
    case viridis, plasma, coolwarm, jet, grayscale

    /// Linear RGBA (alpha 1) at `t`, clamped to 0...1. NaN maps to 0.
    public func color(at t: Float) -> SIMD4<Float> {
        SIMD4(srgbToLinear(srgbColor(at: t)), 1)
    }

    /// sRGB (0...1) at `t`, clamped to 0...1. NaN maps to 0.
    public func srgbColor(at t: Float) -> SIMD3<Float> {
        let t = t.isNaN ? 0 : min(max(t, 0), 1)
        let stops = self.stops
        // Evenly spaced stops unless positions are given.
        let positions = self.positions ?? (0..<stops.count).map { Float($0) / Float(stops.count - 1) }
        var upper = 1
        while upper < positions.count - 1 && positions[upper] < t { upper += 1 }
        let lower = upper - 1
        let span = positions[upper] - positions[lower]
        let f = span > 0 ? (t - positions[lower]) / span : 0
        return simd_mix(stops[lower], stops[upper], SIMD3(repeating: min(max(f, 0), 1)))
    }

    /// `count` evenly spaced linear colors from 0 to 1, for a legend or a
    /// lookup table.
    public func table(count: Int) -> [SIMD4<Float>] {
        guard count > 1 else { return count == 1 ? [color(at: 0)] : [] }
        return (0..<count).map { color(at: Float($0) / Float(count - 1)) }
    }

    /// Linear RGBA for `value` mapped linearly from `range`; an empty range
    /// gives the middle color.
    public func color(for value: Float, in range: ClosedRange<Float>) -> SIMD4<Float> {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return color(at: 0.5) }
        return color(at: (value - range.lowerBound) / span)
    }

    private var stops: [SIMD3<Float>] {
        switch self {
        case .viridis:
            return Self.hex([0x440154, 0x482878, 0x3E4989, 0x31688E, 0x26828E,
                             0x1F9E89, 0x35B779, 0x6ECE58, 0xB5DE2B, 0xFDE725])
        case .plasma:
            return Self.hex([0x0D0887, 0x46039F, 0x7201A8, 0x9C179E, 0xBD3786,
                             0xD8576B, 0xED7953, 0xFB9F3A, 0xFDCA26, 0xF0F921])
        case .coolwarm:
            // Moreland's diverging map (matplotlib "coolwarm").
            return Self.rgb([(59, 76, 192), (98, 130, 234), (141, 176, 254), (184, 208, 249), (221, 221, 221),
                             (245, 196, 173), (244, 154, 123), (222, 96, 77), (180, 4, 38)])
        case .jet:
            // As the `colormap` npm package the web app uses.
            return Self.rgb([(0, 0, 131), (0, 60, 170), (5, 255, 255), (255, 255, 0), (250, 0, 0), (128, 0, 0)])
        case .grayscale:
            return [SIMD3(repeating: 0), SIMD3(repeating: 1)]
        }
    }

    private var positions: [Float]? {
        switch self {
        case .jet: return [0, 0.125, 0.375, 0.625, 0.875, 1]
        default: return nil
        }
    }

    private static func hex(_ values: [UInt32]) -> [SIMD3<Float>] {
        // Qualified: the member `srgbColor(at:)` would shadow the free function.
        values.map { AtomifyRender.srgbColor(hex: $0) }
    }

    private static func rgb(_ values: [(Int, Int, Int)]) -> [SIMD3<Float>] {
        values.map { SIMD3(Float($0.0), Float($0.1), Float($0.2)) / 255 }
    }
}

/// sRGB-encoded components (0...1) to linear light.
public func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
}

/// One sRGB-encoded component (0...1) to linear light.
public func srgbToLinear(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}

/// Linear light to sRGB-encoded components (0...1).
public func linearToSrgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(linearToSrgb(c.x), linearToSrgb(c.y), linearToSrgb(c.z))
}

/// One linear component to sRGB encoding (0...1).
public func linearToSrgb(_ c: Float) -> Float {
    let c = min(max(c, 0), 1)
    return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
}

/// sRGB components (0...1) from 0xRRGGBB.
public func srgbColor(hex: UInt32) -> SIMD3<Float> {
    SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
}

/// Linear RGBA from an sRGB color given as 0xRRGGBB.
public func linearColor(hex: UInt32, alpha: Float = 1) -> SIMD4<Float> {
    SIMD4(srgbToLinear(srgbColor(hex: hex)), alpha)
}

/// Linear RGBA from sRGB components (0...1).
public func linearColor(srgb: SIMD3<Float>, alpha: Float = 1) -> SIMD4<Float> {
    SIMD4(srgbToLinear(srgb), alpha)
}
