import simd

/// The geometry the bond vertex shader builds, in Swift so it can be tested.
/// `ShaderSource.bonds` implements the same steps; keep the two in step.
///
/// A bond is drawn as a cylinder between two spheres. Only the part between
/// the two sphere surfaces can be seen, so the cylinder is trimmed to it, and
/// the proxy that the fragment shader ray-casts is one rectangle (4 vertices,
/// 2 triangles) rather than a box (14 vertices, 12 triangles). The rectangle
/// lies in a plane of constant view depth in front of the whole cylinder and
/// covers its projection, so every pixel is shaded once and the depth each
/// fragment writes is never nearer than the rectangle's own (the conservative
/// depth the shader declares).
///
/// Everything is in view space: eye at the origin, looking down −z.
public enum BondProxy {
    /// How far along the axis the visible cylinder starts and ends, measured
    /// from the first sphere's center: where the cylinder's surface leaves
    /// each sphere. nil when the spheres overlap so much that none of it shows.
    public static func visibleSpan(length: Float, radiusA: Float, radiusB: Float,
                                   bondRadius: Float) -> ClosedRange<Float>? {
        guard length > 0, bondRadius > 0 else { return nil }
        let start = insideDepth(sphereRadius: radiusA, bondRadius: bondRadius)
        let end = length - insideDepth(sphereRadius: radiusB, bondRadius: bondRadius)
        return end > start ? start...end : nil
    }

    /// How far into a sphere the cylinder runs before its surface leaves it.
    static func insideDepth(sphereRadius: Float, bondRadius: Float) -> Float {
        sphereRadius > bondRadius ? (sphereRadius * sphereRadius - bondRadius * bondRadius).squareRoot() : 0
    }

    /// Cuts the segment so every point is at least `minimumDepth` in front of
    /// the eye (−z ≥ minimumDepth). nil when nothing is left.
    public static func clipToDepth(start: SIMD3<Float>, end: SIMD3<Float>,
                                   minimumDepth: Float) -> (start: SIMD3<Float>, end: SIMD3<Float>)? {
        let depthStart = -start.z, depthEnd = -end.z
        if depthStart < minimumDepth && depthEnd < minimumDepth { return nil }
        if depthStart >= minimumDepth && depthEnd >= minimumDepth { return (start, end) }
        let t = (minimumDepth - depthStart) / (depthEnd - depthStart)
        let cut = start + (end - start) * t
        return depthStart < minimumDepth ? (cut, end) : (start, cut)
    }

    public struct Quad: Equatable, Sendable {
        /// View depth of the rectangle's plane (positive, in front of the eye).
        public var depth: Float
        /// In-plane unit directions: along the projected axis, and across it.
        public var along: SIMD3<Float>
        public var across: SIMD3<Float>
        /// Extent along `along` and `across`, measured from the view axis.
        public var alongRange: ClosedRange<Float>
        public var acrossRange: ClosedRange<Float>

        /// Corner `index` (0...3, bit 0 along, bit 1 across), as the strip draws them.
        public func corner(_ index: Int) -> SIMD3<Float> {
            let a = index & 1 != 0 ? alongRange.upperBound : alongRange.lowerBound
            let b = index & 2 != 0 ? acrossRange.upperBound : acrossRange.lowerBound
            return SIMD3(0, 0, -depth) + along * a + across * b
        }
    }

    /// The rectangle covering a cylinder of `radius` from `start` to `end`.
    /// Both ends must be at least `radius` in front of the eye beyond any
    /// positive depth (see `clipToDepth`). nil for a degenerate segment.
    public static func quad(start: SIMD3<Float>, end: SIMD3<Float>, radius: Float) -> Quad? {
        let axisVector = end - start
        let axisLength = simd_length(axisVector)
        guard axisLength > 1e-6, radius > 0 else { return nil }
        let axis = axisVector / axisLength
        let (side, other) = perpendiculars(to: axis)
        // The box around the cylinder: its 8 corners.
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for end in [start, end] {
            for s in [-radius, radius] {
                for o in [-radius, radius] {
                    corners.append(end + side * s + other * o)
                }
            }
        }
        let depth = corners.map { -$0.z }.min()!
        guard depth > 0 else { return nil }
        // Project each corner from the eye onto the plane z = −depth.
        let projected = corners.map { $0 * (depth / -$0.z) }
        let along = inPlaneDirection(start * (depth / -start.z), end * (depth / -end.z))
        let across = SIMD3<Float>(-along.y, along.x, 0)
        let alongs = projected.map { simd_dot($0, along) }
        let acrosses = projected.map { simd_dot($0, across) }
        return Quad(depth: depth, along: along, across: across,
                    alongRange: alongs.min()!...alongs.max()!, acrossRange: acrosses.min()!...acrosses.max()!)
    }

    /// Two unit vectors perpendicular to `axis` and to each other.
    static func perpendiculars(to axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let helper: SIMD3<Float> = abs(axis.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let side = simd_normalize(simd_cross(helper, axis))
        return (side, simd_cross(axis, side))
    }

    /// The direction from `a` to `b` within the z plane, or x when they coincide
    /// (a bond seen end-on).
    static func inPlaneDirection(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        let d = SIMD2(b.x - a.x, b.y - a.y)
        let length = simd_length(d)
        return length > 1e-9 ? SIMD3(d.x / length, d.y / length, 0) : SIMD3(1, 0, 0)
    }
}
