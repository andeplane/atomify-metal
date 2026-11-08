import simd

/// The bonds of one particle block: those whose first particle is in it.
struct BondRange: Equatable, Sendable {
    var start: Int
    var count: Int
    /// Longest drawn bond in the range (scene units): how far its bonds can
    /// reach beyond the block.
    var reach: Float
}

/// Groups bonds by particle block so views can skip bonds out of view, the
/// same way particles are skipped (`BlockCulling`).
enum BondBlocking {
    /// Reorders `bonds` (and `colors`) in place so the bonds of each block
    /// are contiguous, in block order, and returns one range per block. A
    /// bond belongs to the block of its first particle (sorted index).
    /// `length` gives a bond's scene length; bonds longer than `maxLength`
    /// are never drawn and do not count toward `reach`.
    static func group(bonds: UnsafeMutablePointer<GPUBond>, colors: UnsafeMutablePointer<UInt32>?, count: Int,
                      blocks: [ParticleBlock], particleCount: Int, maxLength: Float,
                      length: (GPUBond) -> Float) -> [BondRange] {
        guard count > 0, !blocks.isEmpty else { return [] }
        var blockOf = [Int32](repeating: -1, count: particleCount)
        for (index, block) in blocks.enumerated() {
            for particle in block.start..<min(block.start + block.count, particleCount) {
                blockOf[particle] = Int32(index)
            }
        }
        // Bonds whose first particle is in no block go last, in a range of their own.
        let spare = blocks.count
        var counts = [Int](repeating: 0, count: blocks.count + 1)
        var reach = [Float](repeating: 0, count: blocks.count + 1)
        var owner = [Int32](repeating: 0, count: count)
        for i in 0..<count {
            let a = Int(bonds[i].a)
            let block = a < particleCount && blockOf[a] >= 0 ? Int(blockOf[a]) : spare
            owner[i] = Int32(block)
            counts[block] += 1
            let l = length(bonds[i])
            if l <= maxLength, l.isFinite { reach[block] = max(reach[block], l) }
        }
        var starts = [Int](repeating: 0, count: blocks.count + 1)
        for block in 1..<starts.count { starts[block] = starts[block - 1] + counts[block - 1] }
        let sortedBonds = Array(UnsafeBufferPointer(start: bonds, count: count))
        let sortedColors = colors.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
        var next = starts
        for i in 0..<count {
            let block = Int(owner[i])
            bonds[next[block]] = sortedBonds[i]
            if let colors, let sortedColors { colors[next[block]] = sortedColors[i] }
            next[block] += 1
        }
        var ranges = (0..<blocks.count).map { BondRange(start: starts[$0], count: counts[$0], reach: reach[$0]) }
        if counts[spare] > 0 {
            // Never culled: an infinite reach.
            ranges.append(BondRange(start: starts[spare], count: counts[spare], reach: .infinity))
        }
        return ranges
    }

    /// The bond ranges to draw for each copy in `images`: those whose block,
    /// grown by the reach of its bonds, the largest sphere and `bondRadius`,
    /// is inside at least one view. Adjacent ranges are merged.
    static func draws(ranges: [BondRange], blocks: [ParticleBlock], images: [Int], offsets: [SIMD3<Float>],
                      clipFromModels: [simd_float4x4], radiusScale: Float,
                      bondRadius: Float) -> [(image: Int, range: Range<Int>)] {
        var result: [(image: Int, range: Range<Int>)] = []
        for image in images where image < offsets.count {
            let offset = offsets[image]
            var current: Range<Int>?
            for (index, range) in ranges.enumerated() where range.count > 0 {
                var visible = true
                if index < blocks.count, range.reach.isFinite {
                    let block = blocks[index]
                    let pad = SIMD3<Float>(repeating: block.maxRadius * radiusScale + range.reach + bondRadius)
                    let low = block.low + offset - pad, high = block.high + offset + pad
                    visible = block.low.x <= block.high.x && clipFromModels.contains {
                        BlockCulling.intersects(low: low, high: high, clipFromModel: $0)
                    }
                }
                guard visible else { continue }
                let span = range.start..<(range.start + range.count)
                if let open = current, open.upperBound == span.lowerBound {
                    current = open.lowerBound..<span.upperBound
                } else {
                    if let open = current { result.append((image, open)) }
                    current = span
                }
            }
            if let open = current { result.append((image, open)) }
        }
        return result
    }
}
