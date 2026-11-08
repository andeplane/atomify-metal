import simd

/// Distance from points on a regular grid to the nearest triangle, used to
/// let atoms bounce off the room mesh. Distances are only exact up to
/// `maxDistance`; points further away hold `maxDistance`.
public struct DistanceGrid: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var spacing: Float
    public var dimensions: SIMD3<Int32>
    /// distances[(k * ny + j) * nx + i] for grid point origin + spacing * (i, j, k).
    public var distances: [Float]
    public var maxDistance: Float

    public struct Triangle: Sendable, Equatable {
        public var a, b, c: SIMD3<Float>
        public init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) { self.a = a; self.b = b; self.c = c }
    }

    /// Builds the grid over `low...high`. Cost grows with the number of
    /// triangles times (maxDistance / spacing)^3, so run it off the main actor.
    public static func build(triangles: [Triangle], low: SIMD3<Float>, high: SIMD3<Float>, spacing: Float,
                             maxDistance: Float) -> DistanceGrid {
        let counts = simd_max(SIMD3<Int32>(((high - low) / spacing - 1e-3).rounded(.up)) &+ 1, SIMD3(repeating: 2))
        let nx = Int(counts.x), ny = Int(counts.y), nz = Int(counts.z)
        var distances = [Float](repeating: maxDistance, count: nx * ny * nz)
        let reach = maxDistance + spacing

        for triangle in triangles {
            let lowCorner = simd_min(simd_min(triangle.a, triangle.b), triangle.c) - reach
            let highCorner = simd_max(simd_max(triangle.a, triangle.b), triangle.c) + reach
            let first = simd_clamp(SIMD3<Int32>(((lowCorner - low) / spacing).rounded(.down)), .zero, counts &- 1)
            let last = simd_clamp(SIMD3<Int32>(((highCorner - low) / spacing).rounded(.up)), .zero, counts &- 1)
            guard first.x <= last.x, first.y <= last.y, first.z <= last.z else { continue }
            for k in Int(first.z)...Int(last.z) {
                for j in Int(first.y)...Int(last.y) {
                    let row = (k * ny + j) * nx
                    for i in Int(first.x)...Int(last.x) {
                        let point = low + spacing * SIMD3(Float(i), Float(j), Float(k))
                        let d = distance(from: point, to: triangle)
                        if d < distances[row + i] { distances[row + i] = d }
                    }
                }
            }
        }
        return DistanceGrid(origin: low, spacing: spacing, dimensions: counts, distances: distances,
                            maxDistance: maxDistance)
    }

    /// Value at grid point (i, j, k).
    public func value(_ i: Int, _ j: Int, _ k: Int) -> Float {
        distances[(k * Int(dimensions.y) + j) * Int(dimensions.x) + i]
    }

    /// The same grid in other length units: positions and distances multiplied by `factor`.
    public func scaled(by factor: Float) -> DistanceGrid {
        DistanceGrid(origin: origin * factor, spacing: spacing * factor, dimensions: dimensions,
                     distances: distances.map { $0 * factor }, maxDistance: maxDistance * factor)
    }

    /// Closest distance from a point to a triangle (Ericson, Real-Time
    /// Collision Detection, 5.1.5).
    public static func distance(from p: SIMD3<Float>, to t: Triangle) -> Float {
        let a = t.a, b = t.b, c = t.c
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_distance(p, a) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_distance(p, b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_distance(p, a + v * ab)
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_distance(p, c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_distance(p, a + w * ac)
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_distance(p, b + w * (c - b))
        }
        let denominator = va + vb + vc
        guard denominator != 0 else { return simd_distance(p, a) }
        let v = vb / denominator, w = vc / denominator
        return simd_distance(p, a + ab * v + ac * w)
    }
}
