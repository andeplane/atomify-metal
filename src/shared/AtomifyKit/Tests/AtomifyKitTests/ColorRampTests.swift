import AtomifyRender
import Foundation
import Testing
import simd
@testable import AtomifyKit

@Suite struct ColorRampTests {
    /// Atomify 2's granular patterns shader: 0.2 + 0.8·(z + 7.5) / 5, clamped.
    let height = ColorRamp(axis: 2, from: -7.5, to: -2.5, low: [0.2, 0.2, 0.2], high: [1, 1, 1])

    @Test func factorsBlendAndClamp() {
        #expect(simd_length(height.factors(at: -5) - SIMD3(repeating: 0.6)) < 1e-12)
        #expect(height.factors(at: -7.5) == SIMD3(repeating: 0.2))
        #expect(height.factors(at: -10) == SIMD3(repeating: 0))     // 0.2 − 0.4, clamped
        #expect(height.factors(at: 0) == SIMD3(repeating: 1))       // 1.4, clamped
        let gray = ColorRamp(axis: 0, from: 1, to: 1, low: [0.5], high: [1])
        #expect(gray.factors(at: 3) == SIMD3(repeating: 0.5))       // no span: all low
    }

    @Test func typeColorsAreShadedByPositionFromTheBoxCenter() throws {
        // sampleFrame's box center is (1.5, 1.5, 1.5); atom y offsets are −1.5, −1.5, −0.5, −1.5.
        let ramp = ColorRamp(axis: 1, from: -1.5, to: -0.5, low: [0, 0.5, 1], high: [1, 0.5, 0])
        let scene = SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type,
                                       selectedTag: nil, showBox: false, bondRadius: 0, colorRamp: ramp)
        let colors = try #require(scene.particles.colors)
        #expect(colors.count == 4)
        #expect(isClose(colors[0], SIMD4(0, 0, 0, 1)))      // red at the blue end
        #expect(isClose(colors[1], SIMD4(0, 0, 1, 1)))      // blue at the blue end
        #expect(isClose(colors[2], SIMD4(1, 0, 0, 1)))      // red at the red end
        let half = ColorRamp(axis: 1, from: -1.5, to: -0.5, low: [0.5, 0.5, 0.5], high: [0.5, 0.5, 0.5])
        let dimmed = try #require(SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type,
                                                     selectedTag: nil, showBox: false, bondRadius: 0,
                                                     colorRamp: half).particles.colors)
        // Display-space 0.5 is linear 0.5^2.2.
        #expect(isClose(dimmed[0].x, Float(pow(0.5, 2.2))))
    }

    @Test func perAtomColoringIgnoresTheRamp() throws {
        let frame = sampleFrame(quantity: "vx", values: [0, 1, 2, 3])
        let scene = SceneBuilder.scene(from: frame, typeStyles: sampleStyles,
                                       colorMode: .perAtom(quantity: "vx", colormap: .viridis, range: 0...3),
                                       selectedTag: nil, showBox: false, bondRadius: 0, colorRamp: height)
        let plain = SceneBuilder.scene(from: frame, typeStyles: sampleStyles,
                                       colorMode: .perAtom(quantity: "vx", colormap: .viridis, range: 0...3),
                                       selectedTag: nil, showBox: false, bondRadius: 0)
        #expect(scene.particles.colors == plain.particles.colors)
        let invalid = ColorRamp(axis: 3, from: 0, to: 1, low: [1], high: [1])
        #expect(SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                   showBox: false, bondRadius: 0, colorRamp: invalid).particles.colors == nil)
    }

    @Test func decodesFromTheCatalog() throws {
        let json = #"{"colorRamp": {"axis": 1, "from": -8, "to": 8, "low": [0, 0.3, 1], "high": [1, 0.3, 0]}}"#
        let options = try JSONDecoder().decode(ExampleOptions.self, from: Data(json.utf8))
        #expect(options.colorRamp == ColorRamp(axis: 1, from: -8, to: 8, low: [0, 0.3, 1], high: [1, 0.3, 0]))
    }
}
