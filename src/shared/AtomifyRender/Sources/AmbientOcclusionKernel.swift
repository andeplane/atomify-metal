import Foundation
import simd

/// Sample points for the screen-space ambient occlusion pass.
enum AmbientOcclusionKernel {
    static let maxSamples = 32

    /// `count` points in the unit hemisphere around +z (tangent space),
    /// denser near the center so close occluders count more. Deterministic,
    /// so frames don't flicker. Stored as float4 (w unused).
    static func samples(count: Int, seed: UInt32 = 0x9E37_79B9) -> [SIMD4<Float>] {
        let count = min(max(count, 1), maxSamples)
        var state = seed
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(SpatialBlocking.scramble(state) >> 8) / Float(1 << 24)
        }
        return (0..<count).map { i in
            // A direction in the hemisphere, rejecting ones almost in the
            // tangent plane (they self-occlude on curved surfaces).
            var d = SIMD3<Float>(next() * 2 - 1, next() * 2 - 1, next() * 0.65 + 0.35)
            if simd_length_squared(d) < 1e-6 { d = SIMD3(0, 0, 1) }
            d = simd_normalize(d)
            let t = Float(i + 1) / Float(count)
            let length = 0.1 + 0.9 * t * t    // lerp(0.1, 1, t²)
            return SIMD4(d * length * (0.5 + 0.5 * next()), 0)
        }
    }

    /// Screen-space occlusion radius in scene units: `requested` when
    /// positive, otherwise four times the largest style radius (about two
    /// particle diameters).
    static func radius(requested: Float, styles: [ParticleStyle]) -> Float {
        if requested > 0, requested.isFinite { return requested }
        let largest = styles.map(\.radius).filter { $0.isFinite }.max() ?? 0
        return largest > 0 ? 4 * largest : 1
    }
}

/// How GPU buffers grow: never shrink while in use, grow by half again (or
/// to what is needed) in multiples of 256 elements, so a slowly growing
/// scene reallocates rarely.
enum BufferGrowth {
    static let minimumCapacity = 256

    static func capacity(required: Int, current: Int) -> Int {
        guard required > current else { return current }
        let grown = max(required, current + current / 2, minimumCapacity)
        return (grown + 255) / 256 * 256
    }
}
