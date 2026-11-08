import Foundation
import simd

/// Matrix helpers in Metal's conventions: right-handed view space looking
/// down −z, clip depth 0...1 (1...0 with reverse Z), column-major matrices.
public enum Transforms {
    public static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, 1))
    }

    /// View matrix of an eye at `eye` looking at `target`.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        var right = simd_cross(forward, up)
        if simd_length_squared(right) < 1e-12 {
            // Looking along `up`: any perpendicular will do.
            right = simd_cross(forward, abs(forward.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1))
        }
        right = simd_normalize(right)
        let trueUp = simd_cross(right, forward)
        return simd_float4x4(rows: [
            SIMD4(right, -simd_dot(right, eye)),
            SIMD4(trueUp, -simd_dot(trueUp, eye)),
            SIMD4(-forward, simd_dot(forward, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// Perspective projection. `far` may be `.infinity`. With `reverseZ`,
    /// depth is 1 at `near` and 0 at `far`.
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float,
                                   reverseZ: Bool) -> simd_float4x4 {
        let ys = 1 / tanf(fovY / 2)
        let xs = ys / max(aspect, 1e-6)
        let zz: Float, zw: Float
        switch (reverseZ, far.isFinite) {
        case (false, true):
            zz = far / (near - far); zw = near * far / (near - far)
        case (false, false):
            zz = -1; zw = -near
        case (true, true):
            zz = near / (far - near); zw = near * far / (far - near)
        case (true, false):
            zz = 0; zw = near
        }
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zz, -1),
            SIMD4(0, 0, zw, 0)
        ))
    }

    /// Distance to the near plane of a perspective `projection` (where clip
    /// depth is 0, or 1 with reverse Z). nil for projections without one.
    public static func nearPlane(of projection: simd_float4x4, reverseZ: Bool) -> Float? {
        let p22 = projection.columns.2.z, p32 = projection.columns.3.z
        let denominator = reverseZ ? p22 + 1 : p22
        guard abs(denominator) > 1e-12, projection.columns.2.w != 0 else { return nil }
        let near = p32 / denominator
        return near.isFinite && near > 0 ? near : nil
    }

    /// Length of one model unit after `matrix` (the scale of its first column).
    static func uniformScale(of matrix: simd_float4x4) -> Float {
        let c = matrix.columns.0
        return simd_length(SIMD3(c.x, c.y, c.z))
    }

    /// Normalized device coordinates (−1...1, y up) of a pixel position with
    /// a top-left origin.
    public static func ndc(pixel: SIMD2<Float>, viewport: SIMD2<Float>) -> SIMD2<Float> {
        let v = simd_max(viewport, SIMD2(repeating: 1))
        return SIMD2(pixel.x / v.x * 2 - 1, 1 - pixel.y / v.y * 2)
    }

    /// A matrix that, applied after a projection, maps the one-pixel square
    /// around `pixel` (top-left origin) of a `viewport`-sized target onto the
    /// whole clip square, so a 1×1 target sees exactly that pixel.
    public static func pickMatrix(pixel: SIMD2<Float>, viewport: SIMD2<Float>) -> simd_float4x4 {
        let v = simd_max(viewport, SIMD2(repeating: 1))
        let center = ndc(pixel: pixel, viewport: v)
        return simd_float4x4(columns: (
            SIMD4(v.x, 0, 0, 0),
            SIMD4(0, v.y, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-center.x * v.x, -center.y * v.y, 0, 1)
        ))
    }
}
