import simd

// Small comparison helpers with explicit types, so test expressions stay
// simple for the type checker.

func closeF(_ a: Float, _ b: Float, tolerance: Float = 1e-5) -> Bool {
    abs(a - b) <= tolerance
}

func closeD(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

func closeV3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-5) -> Bool {
    simd_length(a - b) <= tolerance
}

func closeV4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float = 1e-5) -> Bool {
    simd_length(a - b) <= tolerance
}

/// Distance between two particles of a position array.
func distance(_ positions: [SIMD3<Float>], _ i: Int, _ j: Int) -> Float {
    simd_length(positions[i] - positions[j])
}
