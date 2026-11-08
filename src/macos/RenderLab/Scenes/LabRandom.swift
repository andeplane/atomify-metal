import Foundation

/// Integer hashing for deterministic noise: the same input gives the same
/// output on every run and every machine.
enum LabHash {
    /// The SplitMix64 finalizer: a bijective scramble of 64 bits.
    static func mix(_ x: UInt64) -> UInt64 {
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A hash of up to four integers.
    static func hash(_ a: UInt64, _ b: UInt64 = 0, _ c: UInt64 = 0, seed: UInt64 = 0) -> UInt64 {
        mix(mix(mix(seed ^ 0x9E37_79B9_7F4A_7C15 ^ a) ^ b) ^ c)
    }

    /// The top 24 bits as a Float in [0, 1).
    static func unitFloat(_ x: UInt64) -> Float {
        Float(x >> 40) * (1.0 / 16_777_216.0)
    }
}

/// SplitMix64: small, fast, and deterministic for a given seed, so the
/// generated scenes are identical on every run.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return LabHash.mix(state)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Float {
        LabHash.unitFloat(next())
    }

    /// Uniform in [low, high).
    mutating func uniform(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * nextUnit()
    }
}
