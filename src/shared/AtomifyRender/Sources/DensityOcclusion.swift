import Foundation
import simd

/// Ambient light per particle from how crowded its surroundings are:
/// particles deep inside dense material get about half, particles on a
/// surface or in a gas get all of it. Gives large systems depth cues in
/// fast mode, where there is no screen-space pass.
public enum DensityOcclusion {
    /// Cells of the counting grid, at most.
    static let maxCells = 4_000_000
    /// Grid cells counted on each side of a particle's cell.
    static let reach = 3

    /// Ambient light (0...1) per particle. Counts the particles in a cube
    /// seven `spacing`s wide around each one, with a summed-volume table so
    /// the cost is linear in the count, and normalizes by the 95th
    /// percentile count. `spacing` should be about one particle diameter.
    /// Empty when there are 64 particles or fewer, or the system is too
    /// sparse for anything to be enclosed (a gas).
    public static func ambient(positions: [SIMD3<Float>], spacing: Float) -> [Float] {
        guard positions.count > 64, spacing > 0, spacing.isFinite else { return [] }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for p in positions where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        guard low.x <= high.x else { return [] }
        let (cell, dims) = grid(low: low, high: high, spacing: spacing)
        let nx = dims.x, ny = dims.y, nz = dims.z
        @inline(__always) func cellIndex(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let c = (p - low) / cell
            return SIMD3(clamp(c.x, nx), clamp(c.y, ny), clamp(c.z, nz))
        }

        // Summed-volume table with a zero border: sums[x+1, y+1, z+1] counts
        // the particles in cells [0...x] × [0...y] × [0...z].
        let sx = nx + 1, sy = ny + 1, sz = nz + 1
        var sums = [Int32](repeating: 0, count: sx * sy * sz)
        @inline(__always) func at(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * sy + y) * sx + x }
        var cells = [SIMD3<Int32>](repeating: .zero, count: positions.count)
        for (i, p) in positions.enumerated() {
            let c = cellIndex(p)
            cells[i] = SIMD3(Int32(c.x), Int32(c.y), Int32(c.z))
            sums[at(c.x + 1, c.y + 1, c.z + 1)] += 1
        }
        sums.withUnsafeMutableBufferPointer { s in
            for z in 1..<sz {
                for y in 1..<sy {
                    for x in 1..<sx {
                        s[at(x, y, z)] += s[at(x - 1, y, z)] + s[at(x, y - 1, z)] + s[at(x, y, z - 1)]
                            - s[at(x - 1, y - 1, z)] - s[at(x - 1, y, z - 1)] - s[at(x, y - 1, z - 1)]
                            + s[at(x - 1, y - 1, z - 1)]
                    }
                }
            }
        }

        var counts = [Int32](repeating: 0, count: positions.count)
        var histogram = [Int](repeating: 0, count: 4096)
        for i in positions.indices {
            let c = SIMD3<Int>(Int(cells[i].x), Int(cells[i].y), Int(cells[i].z))
            let x0 = max(c.x - reach, 0), x1 = min(c.x + reach + 1, nx)
            let y0 = max(c.y - reach, 0), y1 = min(c.y + reach + 1, ny)
            let z0 = max(c.z - reach, 0), z1 = min(c.z + reach + 1, nz)
            let count = sums[at(x1, y1, z1)] - sums[at(x0, y1, z1)] - sums[at(x1, y0, z1)] - sums[at(x1, y1, z0)]
                + sums[at(x0, y0, z1)] + sums[at(x0, y1, z0)] + sums[at(x1, y0, z0)] - sums[at(x0, y0, z0)]
            counts[i] = count
            histogram[min(Int(count), histogram.count - 1)] += 1
        }

        let reference = percentile95(histogram: histogram, total: positions.count)
        guard reference >= 24 else { return [] }    // a gas: nothing is enclosed
        return counts.map { ambient(count: $0, reference: reference) }
    }

    /// Whether cached values must be recomputed: the count changed, or they
    /// have been reused `interval` times (particles move slowly between
    /// updates, and the computation is linear but not free).
    public static func needsRefresh(cachedCount: Int, count: Int, age: Int, interval: Int) -> Bool {
        cachedCount != count || age >= max(interval, 0)
    }

    /// Grid spacing for `ambient(positions:spacing:)`: one particle diameter
    /// (the largest style radius, or the largest of the first 4096
    /// per-particle radii when given), at least 0.001.
    public static func spacing(styles: [ParticleStyle], radii: [Float]?) -> Float {
        var largest = styles.map(\.radius).filter { $0.isFinite }.max() ?? 0
        if let radii {
            largest = radii.prefix(4096).filter { $0.isFinite }.max() ?? largest
        }
        return max(largest * 2, 1e-3)
    }

    /// Ambient light for a neighbor count relative to the reference count:
    /// 1 up to 45% of it, easing down to 0.45 at the reference and above.
    static func ambient(count: Int32, reference: Int) -> Float {
        let crowding = min(max((Float(count) / Float(reference) - 0.45) / 0.55, 0), 1)
        return 1 - 0.55 * crowding * crowding * (3 - 2 * crowding)
    }

    /// The smallest count that at least 95% of particles are at or below.
    static func percentile95(histogram: [Int], total: Int) -> Int {
        var seen = 0
        for (count, particles) in histogram.enumerated() {
            seen += particles
            if seen * 20 >= total * 19 { return count }
        }
        return histogram.count - 1
    }

    /// A grid of cells about `spacing` wide over `low...high`, coarsened
    /// until it has at most `maxCells` cells.
    static func grid(low: SIMD3<Float>, high: SIMD3<Float>, spacing: Float) -> (cell: Float, dims: SIMD3<Int>) {
        var cell = spacing
        while true {
            let span = (high - low) / cell
            if span.x < 4096, span.y < 4096, span.z < 4096 {
                let dims = SIMD3(Int(span.x) + 1, Int(span.y) + 1, Int(span.z) + 1)
                if dims.x * dims.y * dims.z <= maxCells { return (cell, dims) }
            }
            cell *= 1.26
        }
    }

    @inline(__always)
    static func clamp(_ v: Float, _ n: Int) -> Int {
        guard v.isFinite else { return 0 }
        return Int(min(max(v, 0), Float(n - 1)))
    }
}
