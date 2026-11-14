import simd

/// Appearance shared by many particles: a lookup table indexed per particle.
public struct ParticleStyle: Sendable, Equatable {
    public var radius: Float
    /// Linear RGBA, alpha 1 for opaque.
    public var color: SIMD4<Float>

    public init(radius: Float, color: SIMD4<Float>) {
        self.radius = radius
        self.color = color
    }

    /// A neutral gray style of radius 0.5, used when a scene has no styles.
    public static let fallback = ParticleStyle(radius: 0.5, color: SIMD4(0.6, 0.6, 0.6, 1))
}

/// Per-particle state bits in `ParticleData.flags`.
public enum ParticleFlags {
    /// Drawn in the highlight color and a little larger.
    public static let selected: UInt8 = 1 << 0
    /// Not drawn, and not pickable.
    public static let hidden: UInt8 = 1 << 1
}

/// Particles to draw. Struct of arrays, all of length `count`.
/// Either `styleIndices` + `styles` (cheap: 16 B/particle on the GPU)
/// or per-particle `colors` / `radii`, which override the style when non-nil.
///
/// Optional arrays whose length differs from `count` are ignored.
public struct ParticleData: Sendable {
    public var positions: [SIMD3<Float>]
    /// Index into `styles`; nil means 0. Out-of-range indices use style 0.
    public var styleIndices: [UInt16]?
    /// At least one; an empty table draws with `ParticleStyle.fallback`.
    public var styles: [ParticleStyle]
    /// Per-particle override (e.g. color by quantity), linear RGBA.
    public var colors: [SIMD4<Float>]?
    /// Per-particle override.
    public var radii: [Float]?
    /// Per-particle state flags: bit 0 selected/highlighted, bit 1 hidden.
    public var flags: [UInt8]?

    public var count: Int { positions.count }

    public init(positions: [SIMD3<Float>], styleIndices: [UInt16]? = nil, styles: [ParticleStyle],
                colors: [SIMD4<Float>]? = nil, radii: [Float]? = nil, flags: [UInt8]? = nil) {
        self.positions = positions
        self.styleIndices = styleIndices
        self.styles = styles
        self.colors = colors
        self.radii = radii
        self.flags = flags
    }

    /// `styleIndices` when it has one entry per particle.
    var validStyleIndices: [UInt16]? { styleIndices.flatMap { $0.count == count ? $0 : nil } }
    /// `colors` when it has one entry per particle.
    var validColors: [SIMD4<Float>]? { colors.flatMap { $0.count == count ? $0 : nil } }
    /// `radii` when it has one entry per particle.
    var validRadii: [Float]? { radii.flatMap { $0.count == count ? $0 : nil } }
    /// `flags` when it has one entry per particle.
    var validFlags: [UInt8]? { flags.flatMap { $0.count == count ? $0 : nil } }
    /// The style table the GPU gets: never empty, at most 65 536 entries.
    var effectiveStyles: [ParticleStyle] {
        styles.isEmpty ? [.fallback] : Array(styles.prefix(Int(UInt16.max) + 1))
    }
}

/// Bonds as index pairs into ParticleData. Each half takes its particle's color
/// unless `colors` is given.
public struct BondData: Sendable {
    public var pairs: [SIMD2<UInt32>]
    /// Cylinder radius in scene units.
    public var radius: Float
    /// Per-bond override, linear RGBA. Ignored unless it has one entry per pair.
    public var colors: [SIMD4<Float>]?
    /// Bonds longer than this (scene units) are not drawn, e.g. pairs that
    /// wrap around a periodic boundary. Infinite by default.
    public var maxLength: Float = .infinity

    public init(pairs: [SIMD2<UInt32>], radius: Float, colors: [SIMD4<Float>]? = nil) {
        self.pairs = pairs
        self.radius = radius
        self.colors = colors
    }

    var validColors: [SIMD4<Float>]? { colors.flatMap { $0.count == pairs.count ? $0 : nil } }
}

/// Thin lines (simulation box, walls, axes), drawn as screen-width lines.
public struct LineData: Sendable {
    public var segments: [(SIMD3<Float>, SIMD3<Float>)]
    /// Linear RGBA.
    public var color: SIMD4<Float>
    /// Width in points (multiplied by `RenderView.contentScale` for pixels).
    public var width: Float

    public init(segments: [(SIMD3<Float>, SIMD3<Float>)], color: SIMD4<Float>, width: Float = 1.5) {
        self.segments = segments
        self.color = color
        self.width = width
    }

    /// The twelve edges of a parallelepiped spanned by `a`, `b`, `c` from
    /// `origin` (an axis-aligned box when the vectors are along the axes).
    public static func box(origin: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>,
                           color: SIMD4<Float>, width: Float = 1.5) -> LineData {
        var corners: [SIMD3<Float>] = []
        for k in 0..<8 {
            corners.append(origin + (k & 1 == 0 ? .zero : a) + (k & 2 == 0 ? .zero : b) + (k & 4 == 0 ? .zero : c))
        }
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for k in 0..<8 {
            for bit in [1, 2, 4] where k & bit == 0 {
                segments.append((corners[k], corners[k | bit]))
            }
        }
        return LineData(segments: segments, color: color, width: width)
    }

    /// `box(origin:a:b:c:)` for an axis-aligned box.
    public static func box(low: SIMD3<Float>, high: SIMD3<Float>, color: SIMD4<Float>,
                           width: Float = 1.5) -> LineData {
        let size = high - low
        return box(origin: low, a: SIMD3(size.x, 0, 0), b: SIMD3(0, size.y, 0), c: SIMD3(0, 0, size.z),
                   color: color, width: width)
    }
}

/// Flat translucent quads (walls), drawn after everything opaque, without
/// writing depth. A quad covers `origin + s * u + t * v` for s, t in 0...1.
public struct PanelData: Sendable {
    public struct Quad: Sendable, Equatable {
        public var origin: SIMD3<Float>
        public var u: SIMD3<Float>
        public var v: SIMD3<Float>

        public init(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
            self.origin = origin; self.u = u; self.v = v
        }
    }

    public var quads: [Quad]
    /// Linear RGB, and the opacity seen face on (more at grazing angles).
    public var color: SIMD4<Float>

    public init(quads: [Quad], color: SIMD4<Float>) {
        self.quads = quads
        self.color = color
    }

    /// The six faces of an axis-aligned box. A face of zero area is left
    /// out, so a flat box is one quad.
    public static func box(low: SIMD3<Float>, high: SIMD3<Float>, color: SIMD4<Float>) -> PanelData {
        let size = high - low
        var quads: [Quad] = []
        for axis in 0..<3 {
            let i = (axis + 1) % 3, j = (axis + 2) % 3
            guard size[i] > 0, size[j] > 0 else { continue }
            var u = SIMD3<Float>.zero, v = SIMD3<Float>.zero
            u[i] = size[i]
            v[j] = size[j]
            quads.append(Quad(origin: low, u: u, v: v))
            if size[axis] > 0 {
                var origin = low
                origin[axis] = high[axis]
                quads.append(Quad(origin: origin, u: u, v: v))
            }
        }
        return PanelData(quads: quads, color: color)
    }
}

public struct SceneData: Sendable {
    public var particles: ParticleData
    public var bonds: BondData?
    public var lines: [LineData]
    /// Translucent walls.
    public var panels: [PanelData]
    /// Periodic copies of the particles to draw (offsets), [.zero] for none.
    public var images: [SIMD3<Float>]

    public init(particles: ParticleData, bonds: BondData? = nil, lines: [LineData] = [],
                panels: [PanelData] = [], images: [SIMD3<Float>] = [.zero]) {
        self.particles = particles
        self.bonds = bonds
        self.lines = lines
        self.panels = panels
        self.images = images
    }

    /// An empty scene.
    public static let empty = SceneData(particles: ParticleData(positions: [], styles: []))

    /// True when every array of `self` is the same storage as in `other`
    /// (a copy that was never mutated), so re-uploading can be skipped.
    /// A false result only means "maybe different".
    public func sharesStorage(with other: SceneData) -> Bool {
        let a = particles, b = other.particles
        guard ArrayIdentity.same(a.positions, b.positions),
              ArrayIdentity.same(a.styles, b.styles),
              ArrayIdentity.same(a.styleIndices, b.styleIndices),
              ArrayIdentity.same(a.colors, b.colors),
              ArrayIdentity.same(a.radii, b.radii),
              ArrayIdentity.same(a.flags, b.flags),
              ArrayIdentity.same(images, other.images),
              lines.count == other.lines.count, panels.count == other.panels.count else { return false }
        for (l, r) in zip(panels, other.panels) {
            guard l.color == r.color, ArrayIdentity.same(l.quads, r.quads) else { return false }
        }
        for (l, r) in zip(lines, other.lines) {
            guard l.color == r.color, l.width == r.width,
                  ArrayIdentity.sameSegments(l.segments, r.segments) else { return false }
        }
        switch (bonds, other.bonds) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.radius == r.radius && l.maxLength == r.maxLength
                && ArrayIdentity.same(l.pairs, r.pairs) && ArrayIdentity.same(l.colors, r.colors)
        default:
            return false
        }
    }
}

/// Cheap identity checks on Swift arrays (same buffer and length).
enum ArrayIdentity {
    static func same<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        let pa = a.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        let pb = b.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        return pa == pb
    }

    static func same<T>(_ a: [T]?, _ b: [T]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return same(x, y)
        default: return false
        }
    }

    static func sameSegments(_ a: [(SIMD3<Float>, SIMD3<Float>)], _ b: [(SIMD3<Float>, SIMD3<Float>)]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        let pa = a.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        let pb = b.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        return pa == pb
    }
}

public enum RenderQuality: String, Sendable, CaseIterable {
    /// Impostors, simple lighting; for very large systems.
    case fast
    /// Impostors + SSAO + outlines; for smaller systems.
    case high
}

public struct RenderSettings: Sendable, Equatable {
    public var quality: RenderQuality = .fast
    /// Linear RGBA clear color.
    public var background: SIMD4<Float> = RenderSettings.defaultBackground
    /// Toward the light, in view space.
    public var lightDirection: SIMD3<Float> = simd_normalize(SIMD3(0.3, 1, 0.45))
    /// Multiplies every particle radius.
    public var radiusScale: Float = 1
    /// 0 turns ambient occlusion off; 1 is the default look. Scales both the
    /// per-particle density occlusion and (in `.high`) the screen-space pass.
    public var ambientOcclusionStrength: Float = 1
    /// Screen-space occlusion radius in scene units; 0 picks four times the
    /// largest style radius.
    public var ambientOcclusionRadius: Float = 0
    /// Outline width in pixels in `.high` quality; 0 for none.
    public var outlineWidth: Float = 0
    /// Linear RGBA for selected particles.
    public var highlightColor: SIMD4<Float> = SIMD4(1, 0.85, 0.2, 1)
    /// Draw a selected particle in its own color inside a ring of
    /// `highlightColor` (the enlarged part of its sphere), rather than
    /// tinting the whole particle, so a swatch of its color matches it.
    public var selectionRing: Bool = false
    /// Darken particles in crowded regions, computed on the CPU from
    /// particle density (cheap on the GPU, refreshed every few updates).
    public var densityOcclusion: Bool = true
    /// View-space distances (gone, full size): geometry closer to the eye
    /// than `y` shrinks away and is gone by `x`. Zero disables. Vision Pro
    /// uses (0.15, 0.30) meters so nothing sits too close to focus on.
    public var nearFade: SIMD2<Float> = .zero

    public init() {}

    /// Near-black `#121214` (sRGB), Atomify 2's canvas, as linear RGBA.
    public static let defaultBackground = SIMD4<Float>(0.006049, 0.006049, 0.006995, 1)
}

/// One eye/view to render.
public struct RenderView: Sendable {
    /// World → view, camera looks down −z.
    public var viewMatrix: simd_float4x4
    /// View → clip (Metal clip space, depth 0...1, or 1...0 with reverse Z).
    public var projectionMatrix: simd_float4x4
    /// Pixels.
    public var viewportSize: SIMD2<Float>
    /// Pixels per point, for line widths.
    public var contentScale: Float = 1

    public init(viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, viewportSize: SIMD2<Float>) {
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.viewportSize = viewportSize
    }

    public init(viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, viewportSize: SIMD2<Float>,
                contentScale: Float) {
        self.init(viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, viewportSize: viewportSize)
        self.contentScale = contentScale
    }
}

/// Statistics for an overlay.
public struct RenderStats: Sendable, Equatable {
    /// Particle instances drawn in the last frame (all views, all periodic copies).
    public var particlesDrawn: Int
    public var bondsDrawn: Int
    /// GPU time of the last completed `encodeFrame` command buffer.
    public var gpuTimeMs: Double
    /// Frames the view drew per second since its previous report, or 0 when
    /// the reporter does not count frames.
    public var framesPerSecond: Double

    public init(particlesDrawn: Int = 0, bondsDrawn: Int = 0, gpuTimeMs: Double = 0, framesPerSecond: Double = 0) {
        self.particlesDrawn = particlesDrawn
        self.bondsDrawn = bondsDrawn
        self.gpuTimeMs = gpuTimeMs
        self.framesPerSecond = framesPerSecond
    }
}
