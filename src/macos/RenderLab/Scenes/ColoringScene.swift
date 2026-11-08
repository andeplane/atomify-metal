import AtomifyRender
import Foundation
import simd

/// The per-particle value the colored-atoms scene maps to colors (and radii).
enum ScalarProperty: String, CaseIterable, Identifiable, Sendable {
    case height, distance, randomField, sineWave

    var id: Self { self }

    var title: String {
        switch self {
        case .height: "Height (z)"
        case .distance: "Distance from center"
        case .randomField: "Random field"
        case .sineWave: "Sine pattern"
        }
    }

    /// Unit of the value, for the legend.
    var unit: String {
        switch self {
        case .height, .distance: "Å"
        case .randomField, .sineWave: ""
        }
    }
}

enum RadiusMode: String, CaseIterable, Identifiable, Sendable {
    case styles, fromValue

    var id: Self { self }

    var title: String {
        switch self {
        case .styles: "Style radius"
        case .fromValue: "Radius from value"
        }
    }
}

struct ColoringParameters: Sendable, Equatable, Hashable {
    var property: ScalarProperty = .height
    var colormap: Colormap = .viridis
    /// Per-particle colors from the value; off draws the style color.
    var colorOverrides = true
    var radiusMode: RadiusMode = .styles
}

/// Scalar fields over particle positions. Deterministic.
enum ScalarField {
    static func values(_ property: ScalarProperty, positions: [SIMD3<Float>], bounds: SceneBounds,
                       seed: UInt64 = 7) -> [Float] {
        let center = bounds.center
        let extent = max(bounds.size.x, bounds.size.y, bounds.size.z, 1e-3)
        switch property {
        case .height:
            return positions.map(\.z)
        case .distance:
            return positions.map { simd_length($0 - center) }
        case .randomField:
            let scale = 5 / extent
            return positions.map { p in
                let q = (p - bounds.low) * scale
                return valueNoise(q, seed: seed) + 0.5 * valueNoise(q * 2.3, seed: seed &+ 1)
            }
        case .sineWave:
            let k = 2 * Float.pi * 2.5 / extent
            return positions.map { p in
                let q = (p - bounds.low) * k
                return sinf(q.x) * cosf(q.y) + 0.5 * sinf(q.z)
            }
        }
    }

    /// Smooth value noise in [0, 1]: random values at integer lattice
    /// points, blended with a smoothstep.
    static func valueNoise(_ p: SIMD3<Float>, seed: UInt64) -> Float {
        let fx = p.x.rounded(.down), fy = p.y.rounded(.down), fz = p.z.rounded(.down)
        let ix = Int64(fx), iy = Int64(fy), iz = Int64(fz)
        func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
        let tx = smooth(p.x - fx), ty = smooth(p.y - fy), tz = smooth(p.z - fz)
        func corner(_ dx: Int64, _ dy: Int64, _ dz: Int64) -> Float {
            LabHash.unitFloat(LabHash.hash(UInt64(bitPattern: ix + dx), UInt64(bitPattern: iy + dy),
                                           UInt64(bitPattern: iz + dz), seed: seed))
        }
        func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let x00 = mix(corner(0, 0, 0), corner(1, 0, 0), tx)
        let x10 = mix(corner(0, 1, 0), corner(1, 1, 0), tx)
        let x01 = mix(corner(0, 0, 1), corner(1, 0, 1), tx)
        let x11 = mix(corner(0, 1, 1), corner(1, 1, 1), tx)
        return mix(mix(x00, x10, ty), mix(x01, x11, ty), tz)
    }

    /// Smallest to largest finite value; 0...1 when there is none.
    static func range(_ values: [Float]) -> ClosedRange<Float> {
        var low = Float.infinity, high = -Float.infinity
        for v in values where v.isFinite {
            low = min(low, v)
            high = max(high, v)
        }
        return low <= high ? low...high : 0...1
    }

    /// `values` mapped linearly from `range` onto `radii` (the middle radius for an empty range).
    static func radii(_ values: [Float], range: ClosedRange<Float>, radii: ClosedRange<Float>) -> [Float] {
        let span = range.upperBound - range.lowerBound
        return values.map { v in
            let t = span > 0 ? min(max((v - range.lowerBound) / span, 0), 1) : 0.5
            return radii.lowerBound + (radii.upperBound - radii.lowerBound) * (t.isNaN ? 0 : t)
        }
    }

    static func colors(_ values: [Float], range: ClosedRange<Float>, colormap: Colormap) -> [SIMD4<Float>] {
        values.map { colormap.color(for: $0, in: range) }
    }
}

/// An aluminium-like FCC block colored by a scalar.
enum ColoringScene {
    static let lattice = FCCLattice(latticeConstant: 4.05, cells: 16)
    static let radiusRange: ClosedRange<Float> = 0.45...1.45

    static func make(_ parameters: ColoringParameters) -> GeneratedScene {
        let positions = lattice.positions()
        let bounds = SceneBounds.of(positions) ?? SceneBounds(low: .zero, high: .zero)
        let values = ScalarField.values(parameters.property, positions: positions, bounds: bounds)
        let range = ScalarField.range(values)
        var particles = ParticleData(positions: positions, styles: [LabElement.aluminium.style])
        var legend: ColorLegendInfo?
        if parameters.colorOverrides {
            particles.colors = ScalarField.colors(values, range: range, colormap: parameters.colormap)
            let unit = parameters.property.unit
            legend = ColorLegendInfo(title: parameters.property.title + (unit.isEmpty ? "" : " (\(unit))"),
                                     colormap: parameters.colormap, range: range)
        }
        if parameters.radiusMode == .fromValue {
            particles.radii = ScalarField.radii(values, range: range, radii: radiusRange)
        }
        let box = LabLines.box(size: SIMD3(repeating: lattice.boxLength))
        var notes = ["\(particles.count) atoms."]
        if !parameters.colorOverrides { notes.append("Color overrides off: every atom has the style color.") }
        if parameters.radiusMode == .fromValue {
            notes.append("Radii \(radiusRange.lowerBound)–\(radiusRange.upperBound) Å from the value.")
        }
        return GeneratedScene(scene: SceneData(particles: particles, lines: [box]),
                              styleNames: ["Al (aluminium)"], legend: legend, scalars: values,
                              scalarName: parameters.property.title, notes: notes)
    }
}
