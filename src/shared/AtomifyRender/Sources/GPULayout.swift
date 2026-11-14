import Foundation
import simd

// Swift mirrors of the structs in `ShaderSource`. Every field is a 4-byte
// scalar, a SIMD4 or a 4×4 matrix, so Swift and MSL agree on offsets,
// alignment and stride without padding rules; `GPULayoutTests` checks the
// strides.

/// One particle (16 bytes): position in scene units and a packed word,
/// bits 0–15 style index, 16–23 `ParticleFlags`, 24–31 ambient light
/// (255 = fully lit). MSL: `struct Particle { packed_float3 position; uint styleFlags; }`.
struct GPUParticle: Equatable {
    var x: Float
    var y: Float
    var z: Float
    var styleFlags: UInt32
}

/// One style table entry (32 bytes): linear RGBA and params (x: radius).
struct GPUStyle: Equatable {
    var color: SIMD4<Float>
    var params: SIMD4<Float>
}

/// One bond (8 bytes): indices into the uploaded (sorted) particle buffer.
struct GPUBond: Equatable {
    var a: UInt32
    var b: UInt32
}

/// One line segment (48 bytes): start (xyz, w: width in points), end (xyz),
/// linear RGBA.
struct GPULineSegment: Equatable {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var color: SIMD4<Float>
}

/// One translucent quad (64 bytes): corner, edge vectors u and v, linear RGBA.
struct GPUPanel: Equatable {
    var origin: SIMD4<Float>
    var u: SIMD4<Float>
    var v: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Per view (160 bytes). An array of 1 or 2 is bound at vertex/fragment index 4.
struct ViewUniforms {
    /// Scene units → view space.
    var modelView: simd_float4x4
    /// View → clip.
    var projection: simd_float4x4
    /// xyz toward the light in view space; w: pixels per point.
    var lightDirection: SIMD4<Float>
    /// x: view-space length of one scene unit, y: near plane distance,
    /// zw: viewport size in pixels.
    var params: SIMD4<Float>
}

/// Per frame (64 bytes), index 5.
struct FrameUniforms {
    var highlightColor: SIMD4<Float>
    /// x, y: near fade distances (gone, full), z: highlight radius scale,
    /// w: ambient occlusion strength.
    var nearFade: SIMD4<Float>
    /// x: bond radius (scene units), y: max bond length (scene units),
    /// z: selection ring width as a fraction of the highlighted radius (0
    /// tints the selected particle instead).
    var bond: SIMD4<Float>
    /// x: has per-particle radii, y: has per-particle colors, z: has
    /// per-bond colors, w: style count.
    var options: SIMD4<UInt32>
}

/// Per draw call (16 bytes), index 6: xyz periodic image offset (scene
/// units), w: radius factor (radius scale times thinning factor).
struct DrawUniforms {
    var offset: SIMD4<Float>
}

/// Screen-space ambient occlusion pass (96 bytes).
struct SSAOUniforms {
    var projection: simd_float4x4
    /// x: radius (view units), y: exponent on the result, z: depth falloff
    /// (view units), w: sample count.
    var params: SIMD4<Float>
    /// xy: full-resolution size, zw: occlusion target size (pixels).
    var screen: SIMD4<Float>
}

/// Composite pass (48 bytes).
struct CompositeUniforms {
    /// x: outline width (pixels), y: outline depth threshold (view units),
    /// z: outline opacity, w: occlusion strength (0 skips the blur).
    var params: SIMD4<Float>
    /// xy: full-resolution size, zw: occlusion target size (pixels).
    var sizes: SIMD4<Float>
    var outlineColor: SIMD4<Float>
}

/// CPU-side packing into the GPU layout. Plain functions over plain
/// buffers, so they are unit tested without a GPU.
enum ParticlePacking {
    /// Selected particles are drawn this much larger.
    static let highlightRadiusScale: Float = 1.2

    static func styleFlags(style: UInt16, flags: UInt8, ambient: UInt8) -> UInt32 {
        UInt32(style) | UInt32(flags) << 16 | UInt32(ambient) << 24
    }

    static func unpack(styleFlags: UInt32) -> (style: UInt16, flags: UInt8, ambient: UInt8) {
        (UInt16(truncatingIfNeeded: styleFlags), UInt8(truncatingIfNeeded: styleFlags >> 16),
         UInt8(truncatingIfNeeded: styleFlags >> 24))
    }

    /// Ambient light 0...1 (1 fully lit) as a byte, after scaling the
    /// darkening by `strength`.
    static func ambientByte(_ ambient: Float, strength: Float) -> UInt8 {
        guard ambient.isFinite else { return 255 }
        let s = min(max(strength, 0), 1)
        let lit = 1 - s * (1 - min(max(ambient, 0), 1))
        return UInt8((lit * 255).rounded())
    }

    /// Linear RGBA as RGBA8 with sRGB-encoded color (red in the low byte),
    /// which the shader decodes; 4 bytes with good precision in the darks.
    static func packColor(_ linear: SIMD4<Float>) -> UInt32 {
        let srgb = linearToSrgb(SIMD3(linear.x, linear.y, linear.z))
        func byte(_ v: Float) -> UInt32 {
            v.isFinite ? UInt32((min(max(v, 0), 1) * 255).rounded()) : 0
        }
        return byte(srgb.x) | byte(srgb.y) << 8 | byte(srgb.z) << 16 | byte(linear.w) << 24
    }

    /// Inverse of `packColor` (to linear RGBA).
    static func unpackColor(_ packed: UInt32) -> SIMD4<Float> {
        let c = SIMD4<Float>(Float(packed & 0xFF), Float((packed >> 8) & 0xFF),
                             Float((packed >> 16) & 0xFF), Float(packed >> 24)) / 255
        return SIMD4(srgbToLinear(SIMD3(c.x, c.y, c.z)), c.w)
    }

    static func styles(_ styles: [ParticleStyle]) -> [GPUStyle] {
        styles.map { GPUStyle(color: $0.color, params: SIMD4($0.radius, 0, 0, 0)) }
    }

    /// Writes `data.count` particles into `particles` in `layout` order, and
    /// per-particle radii / colors into `radii` / `colors` when given (they
    /// must be when `data` has valid overrides). Returns the blocks with
    /// their bounds; hidden particles do not count toward the bounds.
    ///
    /// - Parameter ambient: ambient light per original index (0...1), or nil.
    static func packParticles(_ data: ParticleData, styles: [ParticleStyle], layout: BlockLayout,
                              ambient: [Float]?, ambientStrength: Float,
                              particles: UnsafeMutablePointer<GPUParticle>,
                              radii: UnsafeMutablePointer<Float>?,
                              colors: UnsafeMutablePointer<UInt32>?) -> [ParticleBlock] {
        let n = data.count
        guard n > 0 else { return [] }
        let styleCount = max(styles.count, 1)
        let styleRadius = styles.isEmpty ? [ParticleStyle.fallback.radius] : styles.map(\.radius)
        let styleIndices = data.validStyleIndices
        let flags = data.validFlags
        let overrideRadii = radii == nil ? nil : data.validRadii
        let overrideColors = colors == nil ? nil : data.validColors
        let ambient = ambient.flatMap { $0.count == n ? $0 : nil }
        let ranges = layout.ranges.isEmpty ? [0..<n] : layout.ranges
        var blocks: [ParticleBlock] = []
        blocks.reserveCapacity(ranges.count)
        data.positions.withUnsafeBufferPointer { positions in
            let order = layout.order.flatMap { $0.count == n ? $0 : nil }
            for range in ranges {
                var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
                var maxRadius: Float = 0
                for k in range {
                    let i = order.map { Int($0[k]) } ?? k
                    let p = positions[i]
                    var style = styleIndices?[i] ?? 0
                    if Int(style) >= styleCount { style = 0 }
                    let f = flags?[i] ?? 0
                    let a = ambient.map { ambientByte($0[i], strength: ambientStrength) } ?? 255
                    particles[k] = GPUParticle(x: p.x, y: p.y, z: p.z,
                                               styleFlags: styleFlags(style: style, flags: f, ambient: a))
                    var radius = styleRadius[Int(style)]
                    if let overrideRadii {
                        radius = overrideRadii[i]
                        radii?[k] = radius
                    }
                    if let overrideColors {
                        colors?[k] = packColor(overrideColors[i])
                    }
                    guard f & ParticleFlags.hidden == 0, p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                    if f & ParticleFlags.selected != 0 { radius *= highlightRadiusScale }
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                    if radius.isFinite { maxRadius = max(maxRadius, radius) }
                }
                blocks.append(ParticleBlock(start: range.lowerBound, count: range.count, low: low, high: high,
                                            maxRadius: maxRadius))
            }
        }
        return blocks
    }

    /// Writes the valid bonds (both indices below `particleCount`, not the
    /// same particle) remapped through `inverse` (original → sorted index),
    /// with their colors when `colors` is given. Returns how many it wrote.
    static func packBonds(_ data: BondData, particleCount: Int, inverse: [UInt32]?,
                          bonds: UnsafeMutablePointer<GPUBond>, colors: UnsafeMutablePointer<UInt32>?) -> Int {
        let bondColors = colors == nil ? nil : data.validColors
        let inverse = inverse.flatMap { $0.count == particleCount ? $0 : nil }
        var written = 0
        for (index, pair) in data.pairs.enumerated() {
            guard Int(pair.x) < particleCount, Int(pair.y) < particleCount, pair.x != pair.y else { continue }
            let a = inverse.map { $0[Int(pair.x)] } ?? pair.x
            let b = inverse.map { $0[Int(pair.y)] } ?? pair.y
            bonds[written] = GPUBond(a: a, b: b)
            if let bondColors { colors?[written] = packColor(bondColors[index]) }
            written += 1
        }
        return written
    }

    /// Number of segments `packLines` writes.
    static func segmentCount(_ lines: [LineData]) -> Int {
        lines.reduce(0) { $0 + ($1.width > 0 ? $1.segments.count : 0) }
    }

    /// Writes every segment of every line set with a positive width.
    /// Returns how many it wrote.
    static func packLines(_ lines: [LineData], into segments: UnsafeMutablePointer<GPULineSegment>) -> Int {
        var written = 0
        for line in lines where line.width > 0 {
            for (a, b) in line.segments {
                segments[written] = GPULineSegment(start: SIMD4(a, line.width), end: SIMD4(b, 0), color: line.color)
                written += 1
            }
        }
        return written
    }

    /// Number of quads `packPanels` writes.
    static func panelCount(_ panels: [PanelData]) -> Int {
        panels.reduce(0) { $0 + ($1.color.w > 0 ? $1.quads.count : 0) }
    }

    /// Writes every quad of every visible panel set. Returns how many it wrote.
    static func packPanels(_ panels: [PanelData], into quads: UnsafeMutablePointer<GPUPanel>) -> Int {
        var written = 0
        for panel in panels where panel.color.w > 0 {
            for quad in panel.quads {
                quads[written] = GPUPanel(origin: SIMD4(quad.origin, 1), u: SIMD4(quad.u, 0), v: SIMD4(quad.v, 0),
                                          color: panel.color)
                written += 1
            }
        }
        return written
    }
}
