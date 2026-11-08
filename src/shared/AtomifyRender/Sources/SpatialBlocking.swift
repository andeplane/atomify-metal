import Foundation
import simd

/// A run of particles in the GPU buffer and the box around their centers.
/// Culling expands the box by `maxRadius` times the current radius scale.
struct ParticleBlock: Equatable, Sendable {
    var start: Int
    var count: Int
    var low: SIMD3<Float>
    var high: SIMD3<Float>
    /// Largest unscaled radius in the block.
    var maxRadius: Float
}

/// The order particles are uploaded in: grouped into spatial cells so each
/// view can skip cells out of view and draw the rest nearest first.
struct BlockLayout: Equatable, Sendable {
    /// Sorted position → original particle index; nil when unchanged.
    var order: [UInt32]?
    /// Sorted index ranges, one per non-empty cell.
    var ranges: [Range<Int>]
}

enum SpatialBlocking {
    /// Smaller scenes are one block (no sort), unless periodic copies need
    /// the sampled order for thinning.
    static let threshold = 20_000
    /// Particles per block to aim for.
    static let targetBlockSize = 2_048

    /// Cells per axis for `count` particles: about `targetBlockSize` per
    /// cell, between 2 and 16 (8 for 1M particles). Coarser with periodic
    /// copies, so the draw calls stay in the thousands.
    static func divisions(count: Int, images: Int) -> Int {
        guard count > 0 else { return 1 }
        let ideal = Int(cbrt(Double(count) / Double(targetBlockSize)).rounded(.up))
        let limit = images > 1 ? 6 : 16
        return min(max(ideal, 2), limit)
    }

    /// Detail level of a particle, stable across frames: 2 for about one in
    /// sixteen, 1 for about three in sixteen more, 0 for the rest. Within a
    /// sampled block, particles are ordered by level descending, so the
    /// first quarter (sixteenth) is an even sample of the whole block.
    static func level(of index: Int) -> Int {
        let h = scramble(UInt32(truncatingIfNeeded: index))
        if h & 15 == 0 { return 2 }
        if h & 3 == 0 { return 1 }
        return 0
    }

    /// A 32-bit integer hash (the murmur3 finalizer).
    static func scramble(_ value: UInt32) -> UInt32 {
        var h = value
        h ^= h >> 16; h &*= 0x85eb_ca6b
        h ^= h >> 13; h &*= 0xc2b2_ae35
        h ^= h >> 16
        return h
    }

    /// Groups `positions` into cells of a `divisions`³ grid over their
    /// bounds (a counting sort, linear in the count). With `sampled`, each
    /// cell is ordered by `level` descending. Hidden particles still take
    /// part; they are skipped when drawn.
    static func layout(positions: [SIMD3<Float>], images: Int = 1) -> BlockLayout {
        let n = positions.count
        let sampled = images > 1
        guard n > 0 else { return BlockLayout(order: nil, ranges: []) }
        guard n > threshold || (sampled && n > 1) else {
            return BlockLayout(order: nil, ranges: [0..<n])
        }
        let divisions = Self.divisions(count: n, images: images)
        return positions.withUnsafeBufferPointer { p in
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for i in 0..<n where p[i].x.isFinite && p[i].y.isFinite && p[i].z.isFinite {
                low = simd_min(low, p[i])
                high = simd_max(high, p[i])
            }
            if low.x > high.x { low = .zero; high = .zero }
            let d = divisions
            let scale = Float(d) / simd_max(high - low, SIMD3(repeating: 1e-6))
            let levels = sampled ? 3 : 1
            let keyCount = d * d * d * levels
            var keys = [UInt32](repeating: 0, count: n)
            var counts = [Int](repeating: 0, count: keyCount + 1)
            for i in 0..<n {
                let c = (p[i] - low) * scale
                // NaN and out-of-range land in an edge cell.
                let x = clampCell(c.x, d), y = clampCell(c.y, d), z = clampCell(c.z, d)
                var key = ((z * d + y) * d + x) * levels
                if sampled { key += 2 - level(of: i) }
                keys[i] = UInt32(key)
                counts[key + 1] += 1
            }
            for k in 0..<keyCount { counts[k + 1] += counts[k] }    // prefix sums: counts[k] = start of key k
            var ranges: [Range<Int>] = []
            for cell in 0..<(d * d * d) {
                let start = counts[cell * levels], end = counts[(cell + 1) * levels]
                if end > start { ranges.append(start..<end) }
            }
            var next = counts
            var order = [UInt32](repeating: 0, count: n)
            for i in 0..<n {
                let key = Int(keys[i])
                order[next[key]] = UInt32(i)
                next[key] += 1
            }
            return BlockLayout(order: order, ranges: ranges)
        }
    }

    @inline(__always)
    static func clampCell(_ v: Float, _ d: Int) -> Int {
        guard v.isFinite else { return v > 0 ? d - 1 : 0 }
        return Int(min(max(v, 0), Float(d - 1)))
    }

    /// Original index → sorted index, the inverse of `order`.
    static func inverse(of order: [UInt32]) -> [UInt32] {
        var inverse = [UInt32](repeating: 0, count: order.count)
        for (sorted, original) in order.enumerated() where Int(original) < order.count {
            inverse[Int(original)] = UInt32(sorted)
        }
        return inverse
    }
}

/// Picks the blocks to draw for a set of views.
enum BlockCulling {
    /// One instanced draw: the first `count` particles of `block`, shifted
    /// to periodic copy `image`. `detail` 0 draws every particle, 1 a
    /// quarter, 2 a sixteenth.
    struct Draw: Equatable {
        var block: ParticleBlock
        var image: Int
        var detail: Int
        var count: Int { max(block.count >> (2 * detail), 1) }

        /// Fewer particles are drawn larger so they cover the same area: a
        /// quarter at twice the radius blocks as much of the view as all of
        /// them. (Keeping the volume instead let thinned copies turn
        /// see-through and speckled.)
        static func radiusScale(detail: Int) -> Float { Float(1 << detail) }
    }

    /// Whether the box `low...high` (model space) is at least partly inside
    /// the frustum of `clipFromModel`: false only when all eight corners lie
    /// beyond one clip plane (left, right, bottom, top or behind the eye).
    static func intersects(low: SIMD3<Float>, high: SIMD3<Float>, clipFromModel: simd_float4x4) -> Bool {
        var left = false, right = false, bottom = false, top = false, front = false
        for corner in 0..<8 {
            let p = SIMD4(corner & 1 == 0 ? low.x : high.x,
                          corner & 2 == 0 ? low.y : high.y,
                          corner & 4 == 0 ? low.z : high.z, 1)
            let c = clipFromModel * p
            if c.x >= -c.w { left = true }
            if c.x <= c.w { right = true }
            if c.y >= -c.w { bottom = true }
            if c.y <= c.w { top = true }
            if c.w > 0 { front = true }
        }
        return left && right && bottom && top && front
    }

    /// Every block at every image offset that is inside at least one view,
    /// nearest first (by the first view). While more than `budget` particles
    /// are in view, the copies farthest from the eye drop to lower detail;
    /// the primary copy (index 0) never does.
    ///
    /// - Parameters:
    ///   - modelViews: model → view of each view (the first sets the order).
    ///   - projections: view → clip of each view.
    ///   - radiusScale: current scale applied to `maxRadius` for the bounds.
    static func draws(blocks: [ParticleBlock], images: [SIMD3<Float>], modelViews: [simd_float4x4],
                      projections: [simd_float4x4], radiusScale: Float, budget: Int = .max) -> [Draw] {
        guard let firstModelView = modelViews.first, !images.isEmpty else { return [] }
        let clipFromModel = zip(projections, modelViews).map { $0 * $1 }
        var visible: [(depth: Float, block: ParticleBlock, image: Int)] = []
        visible.reserveCapacity(blocks.count * images.count)
        var inView = [Int](repeating: 0, count: images.count)
        for (image, offset) in images.enumerated() {
            for block in blocks where block.count > 0 && block.low.x <= block.high.x {
                let pad = SIMD3<Float>(repeating: block.maxRadius * radiusScale)
                let low = block.low + offset - pad, high = block.high + offset + pad
                guard clipFromModel.contains(where: { intersects(low: low, high: high, clipFromModel: $0) })
                else { continue }
                let center = firstModelView * SIMD4((low + high) / 2, 1)
                visible.append((-center.z, block, image))
                inView[image] += block.count
            }
        }
        visible.sort { $0.depth < $1.depth }
        let detail = details(inView: inView, images: images, blocks: blocks, modelView: firstModelView,
                             budget: budget)
        return visible.map { Draw(block: $0.block, image: $0.image, detail: detail[$0.image]) }
    }

    /// Detail per copy: all full while the particles in view fit `budget`;
    /// otherwise copies drop a level, farthest from the eye first, until
    /// they fit or all but the primary are at the lowest.
    static func details(inView: [Int], images: [SIMD3<Float>], blocks: [ParticleBlock],
                        modelView: simd_float4x4, budget: Int) -> [Int] {
        var detail = [Int](repeating: 0, count: images.count)
        var total = inView.reduce(0, +)
        guard total > budget, images.count > 1, !blocks.isEmpty else { return detail }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for block in blocks where block.low.x <= block.high.x {
            low = simd_min(low, block.low)
            high = simd_max(high, block.high)
        }
        let eye4 = simd_inverse(modelView) * SIMD4(0, 0, 0, 1)
        let eye = SIMD3(eye4.x, eye4.y, eye4.z)
        // Distance from the eye to each copy's box; zero inside it.
        let distance = images.map { offset -> Float in
            simd_length(simd_max(simd_max(low + offset - eye, eye - high - offset), .zero))
        }
        let farthestFirst = images.indices.filter { $0 != 0 && inView[$0] > 0 }
            .sorted { distance[$0] > distance[$1] || (distance[$0] == distance[$1] && $0 < $1) }
        for level in 1...2 {
            for image in farthestFirst where total > budget {
                total -= (inView[image] >> (2 * detail[image])) - (inView[image] >> (2 * level))
                detail[image] = level
            }
        }
        return detail
    }

    /// Image offsets in drawing order: the zero offset first when present,
    /// duplicates removed; `[.zero]` when empty.
    static func normalizedImages(_ images: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for offset in images where offset.x.isFinite && offset.y.isFinite && offset.z.isFinite {
            if !result.contains(offset) { result.append(offset) }
        }
        if let zero = result.firstIndex(of: .zero), zero != 0 {
            result.remove(at: zero)
            result.insert(.zero, at: 0)
        }
        return result.isEmpty ? [.zero] : result
    }
}
