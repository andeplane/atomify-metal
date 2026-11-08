import AtomifyEngine
import AtomifyRender
import simd

/// How atoms are colored.
public enum ColorMode: Hashable, Sendable {
    /// By LAMMPS atom type, from `#/atom` directives or the default palette.
    case type
    /// By a per-atom quantity ("vx", "c_ke", "c_stress[1]", ...) through a
    /// colormap. A nil range uses the values' own min and max.
    case perAtom(quantity: String, colormap: Colormap, range: ClosedRange<Float>?)

    /// The per-atom quantity the engine has to publish, or nil.
    public var quantity: String? {
        if case .perAtom(let quantity, _, _) = self { return quantity }
        return nil
    }
}

/// Per-atom quantities that can color atoms.
public enum PerAtomQuantities {
    /// Always available from the engine.
    public static let builtIn = ["vx", "vy", "vz"]

    /// The per-atom names the snapshot's computes, fixes and variables
    /// provide, in order and without repeats, followed by `builtIn`.
    public static func available(from observables: [AtomifyEngine.Observable]) -> [String] {
        available(perAtomNames: observables.map(\.perAtomNames))
    }

    public static func available(perAtomNames: [[String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in Array(perAtomNames.joined()) + builtIn where !name.isEmpty && seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }
}

/// The min and max of the finite values, or nil when there are none.
/// A single value v gives v...v.
public func finiteRange(of values: [Float]) -> ClosedRange<Float>? {
    var low = Float.infinity, high = -Float.infinity
    for value in values where value.isFinite {
        low = min(low, value)
        high = max(high, value)
    }
    return low <= high ? low...high : nil
}

/// Remembers the smallest and largest value seen over a run, as the web app
/// does for its color legend, so colors do not flicker as the range of one
/// frame moves. `reset()` starts over (for a new quantity or run).
public struct ColorRangeTracker: Sendable, Equatable {
    public private(set) var range: ClosedRange<Float>?

    public init() {}

    public mutating func include(_ values: [Float]) {
        guard let frame = finiteRange(of: values) else { return }
        if let range {
            self.range = min(range.lowerBound, frame.lowerBound)...max(range.upperBound, frame.upperBound)
        } else {
            range = frame
        }
    }

    public mutating func reset() { range = nil }
}

/// A colormap sampled into a table, so coloring a million atoms is a lookup
/// per atom rather than an interpolation.
public struct ColorLookup: Sendable {
    public let colors: [SIMD4<Float>]
    public let range: ClosedRange<Float>

    public init(colormap: Colormap, range: ClosedRange<Float>, resolution: Int = 256) {
        let n = max(resolution, 2)
        colors = (0..<n).map { colormap.color(at: Float($0) / Float(n - 1)) }
        self.range = range
    }

    /// Position of a value in the range, 0...1; the middle for an empty range
    /// and non-finite values.
    public func fraction(of value: Float) -> Float {
        let width = range.upperBound - range.lowerBound
        guard value.isFinite, width > 0, width.isFinite else { return 0.5 }
        return min(max((value - range.lowerBound) / width, 0), 1)
    }

    public func color(for value: Float) -> SIMD4<Float> {
        let index = Int((fraction(of: value) * Float(colors.count - 1)).rounded())
        return colors[min(max(index, 0), colors.count - 1)]
    }

    public func colors(for values: [Float]) -> [SIMD4<Float>] {
        values.map(color(for:))
    }
}

extension RGBColor {
    /// Linear RGBA (alpha 1), which the renderer shades in.
    public var linear: SIMD4<Float> {
        SIMD4(srgbToLinear(SIMD3(Float(red), Float(green), Float(blue))), 1)
    }
}
