import Foundation
import simd

/// Atomify 2's custom color shaders as data: each atom's type color is
/// multiplied by factors that blend from `low` to `high` along one axis.
///
/// t = (c − from) / (to − from), with c the atom's coordinate on `axis`
/// relative to the box center (Atomify 2 drew the box centered on the
/// origin), and each factor is low + (high − low)·t, limited to 0...1.
/// Atomify 2 multiplied the displayed (sRGB) color, so the factors are
/// applied to linear colors raised to 2.2, which looks the same.
public struct ColorRamp: Codable, Sendable, Hashable {
    /// 0, 1 or 2 for x, y or z.
    public var axis: Int
    /// The coordinates where t is 0 and 1.
    public var from: Double
    public var to: Double
    /// Red, green and blue factors at t = 0 and t = 1.
    public var low: [Double]
    public var high: [Double]

    public init(axis: Int, from: Double, to: Double, low: [Double], high: [Double]) {
        self.axis = axis
        self.from = from
        self.to = to
        self.low = low
        self.high = high
    }

    /// The display-space factors for a coordinate relative to the box center.
    public func factors(at coordinate: Double) -> SIMD3<Double> {
        let span = to - from
        let t = span != 0 && span.isFinite ? (coordinate - from) / span : 0
        func rgb(_ values: [Double]) -> SIMD3<Double> {
            values.count >= 3 ? SIMD3(values[0], values[1], values[2]) : SIMD3(repeating: values.first ?? 1)
        }
        let blended = rgb(low) + (rgb(high) - rgb(low)) * (t.isFinite ? t : 0)
        return simd_clamp(blended, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// Per-atom colors: each atom's style color shaded by its position.
    func colors(for frame: AtomFrame, styleIndices: [UInt16], styles: [ParticleStyle]) -> [SIMD4<Float>]? {
        guard (0..<3).contains(axis), styleIndices.count == frame.count, !styles.isEmpty else { return nil }
        let center = ((frame.boxLow + frame.boxHigh) / 2)[axis]
        return (0..<frame.count).map { i in
            let index = Int(styleIndices[i])
            let base = styles[index < styles.count ? index : 0].color
            let f = factors(at: Double(frame.positions[i][axis]) - center)
            let linear = SIMD3<Float>(Float(pow(f.x, 2.2)), Float(pow(f.y, 2.2)), Float(pow(f.z, 2.2)))
            return SIMD4(base.x * linear.x, base.y * linear.y, base.z * linear.z, base.w)
        }
    }
}
