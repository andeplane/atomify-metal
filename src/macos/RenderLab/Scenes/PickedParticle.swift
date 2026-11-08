import AtomifyRender
import Foundation
import simd

/// What the inspector shows about a clicked particle, resolved the way
/// the renderer resolves it: per-particle overrides win over the style,
/// and a missing or out-of-range style index means style 0.
struct PickedParticle: Sendable, Equatable {
    var index: Int
    var position: SIMD3<Float>
    var styleIndex: Int
    var styleName: String
    /// Linear RGBA.
    var color: SIMD4<Float>
    var colorIsOverride: Bool
    /// Before `RenderSettings.radiusScale`.
    var radius: Float
    var radiusIsOverride: Bool
    var flags: UInt8
    var scalar: Float?

    /// nil when `index` is not a particle of `scene`.
    static func make(index: Int, scene: SceneData, styleNames: [String], scalars: [Float]? = nil) -> PickedParticle? {
        let particles = scene.particles
        let count = particles.count
        guard index >= 0, index < count else { return nil }
        let styles = particles.styles.isEmpty ? [ParticleStyle.fallback] : particles.styles
        var styleIndex = 0
        if let indices = particles.styleIndices, indices.count == count {
            styleIndex = Int(indices[index])
        }
        if styleIndex >= styles.count { styleIndex = 0 }
        let style = styles[styleIndex]
        let colors = particles.colors.flatMap { $0.count == count ? $0 : nil }
        let radii = particles.radii.flatMap { $0.count == count ? $0 : nil }
        let flags = particles.flags.flatMap { $0.count == count ? $0[index] : nil } ?? 0
        let name = styleIndex < styleNames.count ? styleNames[styleIndex] : "Style \(styleIndex)"
        return PickedParticle(index: index, position: particles.positions[index], styleIndex: styleIndex,
                              styleName: name, color: colors?[index] ?? style.color,
                              colorIsOverride: colors != nil, radius: radii?[index] ?? style.radius,
                              radiusIsOverride: radii != nil, flags: flags,
                              scalar: scalars.flatMap { $0.count == count ? $0[index] : nil })
    }

    /// "#RRGGBB" of the sRGB-encoded color.
    var srgbHex: String {
        let c = linearToSrgb(SIMD3(color.x, color.y, color.z))
        func byte(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.x), byte(c.y), byte(c.z))
    }

    /// Radius on screen: scaled, and 1.2× larger while selected.
    func drawnRadius(radiusScale: Float, selected: Bool) -> Float {
        radius * max(radiusScale, 0) * (selected ? 1.2 : 1)
    }
}
