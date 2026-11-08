import AtomifyRender
import simd
import Testing
@testable import RenderLab

@Suite struct PickedParticleTests {
    static let red = ParticleStyle(radius: 0.5, color: SIMD4<Float>(1, 0, 0, 1))
    static let blue = ParticleStyle(radius: 1.5, color: SIMD4<Float>(0, 0, 1, 1))
    static let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 2, 3), SIMD3(4, 5, 6)]

    static func scene(_ particles: ParticleData) -> SceneData {
        SceneData(particles: particles)
    }

    @Test func styleResolution() {
        let particles = ParticleData(positions: Self.positions, styleIndices: [0, 1, 7],
                                     styles: [Self.red, Self.blue])
        let names = ["Red", "Blue"]
        let first = PickedParticle.make(index: 1, scene: Self.scene(particles), styleNames: names)
        #expect(first?.index == 1)
        #expect(first?.position == SIMD3<Float>(1, 2, 3))
        #expect(first?.styleIndex == 1)
        #expect(first?.styleName == "Blue")
        #expect(first?.color == Self.blue.color)
        #expect(first?.radius == 1.5)
        #expect(first?.colorIsOverride == false)
        #expect(first?.radiusIsOverride == false)
        #expect(first?.flags == 0)
        #expect(first?.scalar == nil)
        // Out-of-range style index: style 0, as the renderer draws it.
        let outOfRange = PickedParticle.make(index: 2, scene: Self.scene(particles), styleNames: names)
        #expect(outOfRange?.styleIndex == 0)
        #expect(outOfRange?.styleName == "Red")
    }

    @Test func missingOrMismatchedStyleIndices() {
        let none = ParticleData(positions: Self.positions, styles: [Self.red, Self.blue])
        #expect(PickedParticle.make(index: 2, scene: Self.scene(none), styleNames: [])?.styleIndex == 0)
        let short = ParticleData(positions: Self.positions, styleIndices: [1], styles: [Self.red, Self.blue])
        #expect(PickedParticle.make(index: 0, scene: Self.scene(short), styleNames: [])?.styleIndex == 0)
    }

    @Test func emptyStyleTableUsesFallback() {
        let particles = ParticleData(positions: Self.positions, styles: [])
        let picked = PickedParticle.make(index: 0, scene: Self.scene(particles), styleNames: [])
        #expect(picked?.radius == ParticleStyle.fallback.radius)
        #expect(picked?.color == ParticleStyle.fallback.color)
        #expect(picked?.styleName == "Style 0")
    }

    @Test func overrides() {
        var particles = ParticleData(positions: Self.positions, styles: [Self.red])
        particles.colors = [SIMD4<Float>(0, 1, 0, 1), SIMD4<Float>(0, 0, 0, 1), SIMD4<Float>(1, 1, 1, 1)]
        particles.radii = [0.1, 0.2, 0.3]
        particles.flags = [0, ParticleFlags.selected, 0]
        let picked = PickedParticle.make(index: 1, scene: Self.scene(particles), styleNames: ["Red"],
                                         scalars: [10, 20, 30])
        #expect(picked?.color == SIMD4<Float>(0, 0, 0, 1))
        #expect(picked?.colorIsOverride == true)
        #expect(picked?.radius == 0.2)
        #expect(picked?.radiusIsOverride == true)
        #expect(picked?.flags == ParticleFlags.selected)
        #expect(picked?.scalar == 20)
    }

    @Test func mismatchedOverridesAreIgnored() {
        var particles = ParticleData(positions: Self.positions, styles: [Self.red])
        particles.colors = [SIMD4<Float>(0, 1, 0, 1)]
        particles.radii = [9]
        particles.flags = [1]
        let picked = PickedParticle.make(index: 0, scene: Self.scene(particles), styleNames: [], scalars: [1])
        #expect(picked?.colorIsOverride == false)
        #expect(picked?.radiusIsOverride == false)
        #expect(picked?.radius == 0.5)
        #expect(picked?.flags == 0)
        #expect(picked?.scalar == nil)
    }

    @Test(arguments: [-1, 3, 1_000])
    func outOfRangeIndex(index: Int) {
        let particles = ParticleData(positions: Self.positions, styles: [Self.red])
        #expect(PickedParticle.make(index: index, scene: Self.scene(particles), styleNames: []) == nil)
    }

    @Test func srgbHex() {
        let particles = ParticleData(positions: Self.positions, styles: [Self.red])
        let picked = PickedParticle.make(index: 0, scene: Self.scene(particles), styleNames: [])
        #expect(picked?.srgbHex == "#FF0000")
        guard var other = picked else { return }
        other.color = linearColor(hex: 0x3E63DD)
        #expect(other.srgbHex == "#3E63DD")
        other.color = SIMD4<Float>(2, -1, 0, 1)
        #expect(other.srgbHex == "#FF0000")
    }

    @Test func drawnRadius() {
        let particles = ParticleData(positions: Self.positions, styles: [Self.blue])
        let picked = PickedParticle.make(index: 0, scene: Self.scene(particles), styleNames: [])
        #expect(picked?.drawnRadius(radiusScale: 2, selected: false) == 3)
        #expect(closeF(picked?.drawnRadius(radiusScale: 2, selected: true) ?? 0, 3.6))
        #expect(picked?.drawnRadius(radiusScale: -1, selected: false) == 0)
    }
}
