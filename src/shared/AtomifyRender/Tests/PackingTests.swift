import simd
import XCTest
@testable import AtomifyRender

final class PackingTests: XCTestCase {
    private let red = SIMD4<Float>(1, 0, 0, 1)
    private let blue = SIMD4<Float>(0, 0, 1, 1)

    func testStyleFlagsRoundTrip() {
        let packed = ParticlePacking.styleFlags(style: 0xBEEF, flags: 0x03, ambient: 0x80)
        XCTAssertEqual(packed, 0x8003_BEEF)
        let unpacked = ParticlePacking.unpack(styleFlags: packed)
        XCTAssertEqual(unpacked.style, 0xBEEF)
        XCTAssertEqual(unpacked.flags, 0x03)
        XCTAssertEqual(unpacked.ambient, 0x80)
    }

    func testAmbientByte() {
        XCTAssertEqual(ParticlePacking.ambientByte(1, strength: 1), 255)
        XCTAssertEqual(ParticlePacking.ambientByte(0, strength: 1), 0)
        XCTAssertEqual(ParticlePacking.ambientByte(0.5, strength: 1), 128)
        XCTAssertEqual(ParticlePacking.ambientByte(0, strength: 0), 255)
        XCTAssertEqual(ParticlePacking.ambientByte(0, strength: 0.5), 128)
        XCTAssertEqual(ParticlePacking.ambientByte(2, strength: 3), 255)
        XCTAssertEqual(ParticlePacking.ambientByte(-1, strength: 1), 0)
        XCTAssertEqual(ParticlePacking.ambientByte(.nan, strength: 1), 255)
    }

    func testColorPackingRoundTrip() {
        for color in [SIMD4<Float>(0, 0, 0, 1), SIMD4(1, 1, 1, 0), SIMD4(0.214, 0.5, 0.01, 0.5),
                      SIMD4(0.001, 0.9, 0.3, 1)] {
            let back = ParticlePacking.unpackColor(ParticlePacking.packColor(color))
            // Within one sRGB step.
            let a = linearToSrgb(SIMD3(color.x, color.y, color.z))
            let b = linearToSrgb(SIMD3(back.x, back.y, back.z))
            XCTAssertLessThan(simd_reduce_max(simd_abs(a - b)), 1.0 / 255 + 1e-4)
            XCTAssertEqual(back.w, color.w, accuracy: 1.0 / 255)
        }
        XCTAssertEqual(ParticlePacking.packColor(SIMD4(1, 0, 0, 1)), 0xFF00_00FF)
        XCTAssertEqual(ParticlePacking.packColor(SIMD4(.nan, 2, -1, 1)), 0xFF00_FF00)
    }

    func testStyles() {
        let styles = ParticlePacking.styles([ParticleStyle(radius: 0.7, color: red)])
        XCTAssertEqual(styles, [GPUStyle(color: red, params: SIMD4(0.7, 0, 0, 0))])
    }

    private func pack(_ data: ParticleData, layout: BlockLayout? = nil, ambient: [Float]? = nil,
                      radii: Bool = false, colors: Bool = false)
        -> (particles: [GPUParticle], radii: [Float], colors: [UInt32], blocks: [ParticleBlock]) {
        let n = data.count
        // At least one element, so the buffers have a base address.
        var particles = [GPUParticle](repeating: GPUParticle(x: 0, y: 0, z: 0, styleFlags: 0), count: max(n, 1))
        var radiiOut = [Float](repeating: -1, count: max(n, 1))
        var colorsOut = [UInt32](repeating: 0, count: max(n, 1))
        let layout = layout ?? BlockLayout(order: nil, ranges: n > 0 ? [0..<n] : [])
        var blocks: [ParticleBlock] = []
        particles.withUnsafeMutableBufferPointer { p in
            radiiOut.withUnsafeMutableBufferPointer { r in
                colorsOut.withUnsafeMutableBufferPointer { c in
                    blocks = ParticlePacking.packParticles(
                        data, styles: data.effectiveStyles, layout: layout, ambient: ambient, ambientStrength: 1,
                        particles: p.baseAddress!, radii: radii ? r.baseAddress : nil,
                        colors: colors ? c.baseAddress : nil)
                }
            }
        }
        return (Array(particles.prefix(n)), Array(radiiOut.prefix(n)), Array(colorsOut.prefix(n)), blocks)
    }

    func testPackParticlesWithStyles() {
        let data = ParticleData(positions: [SIMD3(0, 0, 0), SIMD3(1, 2, 3), SIMD3(-1, 0, 0)],
                                styleIndices: [1, 0, 7],
                                styles: [ParticleStyle(radius: 0.5, color: red), ParticleStyle(radius: 1, color: blue)])
        let out = pack(data)
        XCTAssertEqual(out.particles[1], GPUParticle(x: 1, y: 2, z: 3,
                                                     styleFlags: ParticlePacking.styleFlags(style: 0, flags: 0, ambient: 255)))
        XCTAssertEqual(ParticlePacking.unpack(styleFlags: out.particles[0].styleFlags).style, 1)
        // Out-of-range style falls back to 0.
        XCTAssertEqual(ParticlePacking.unpack(styleFlags: out.particles[2].styleFlags).style, 0)
        XCTAssertEqual(out.blocks, [ParticleBlock(start: 0, count: 3, low: SIMD3(-1, 0, 0), high: SIMD3(1, 2, 3),
                                                  maxRadius: 1)])
        XCTAssertEqual(out.radii, [-1, -1, -1], "radii untouched without overrides")
    }

    func testPackParticlesFlagsAndBounds() {
        let data = ParticleData(positions: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(1, 1, 1)],
                                styles: [ParticleStyle(radius: 1, color: red)],
                                flags: [ParticleFlags.selected, ParticleFlags.hidden, 0])
        let out = pack(data)
        XCTAssertEqual(ParticlePacking.unpack(styleFlags: out.particles[0].styleFlags).flags, ParticleFlags.selected)
        XCTAssertEqual(ParticlePacking.unpack(styleFlags: out.particles[1].styleFlags).flags, ParticleFlags.hidden)
        // The hidden particle is left out of the bounds; the selected one is larger.
        XCTAssertEqual(out.blocks[0].high, SIMD3(1, 1, 1))
        XCTAssertEqual(out.blocks[0].maxRadius, ParticlePacking.highlightRadiusScale, accuracy: 1e-6)
    }

    func testPackParticlesOverridesFollowOrder() {
        let data = ParticleData(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)],
                                styles: [ParticleStyle(radius: 1, color: red)],
                                colors: [red, blue, SIMD4(0, 1, 0, 1)], radii: [0.1, 0.2, 0.3])
        let layout = BlockLayout(order: [2, 0, 1], ranges: [0..<1, 1..<3])
        let out = pack(data, layout: layout, ambient: [1, 0.5, 0], radii: true, colors: true)
        XCTAssertEqual(out.particles.map(\.x), [2, 0, 1])
        XCTAssertEqual(out.radii, [0.3, 0.1, 0.2])
        XCTAssertEqual(out.colors, [ParticlePacking.packColor(SIMD4(0, 1, 0, 1)), ParticlePacking.packColor(red),
                                    ParticlePacking.packColor(blue)])
        XCTAssertEqual(out.particles.map { ParticlePacking.unpack(styleFlags: $0.styleFlags).ambient }, [0, 255, 128])
        XCTAssertEqual(out.blocks.count, 2)
        XCTAssertEqual(out.blocks[0], ParticleBlock(start: 0, count: 1, low: SIMD3(2, 0, 0), high: SIMD3(2, 0, 0),
                                                    maxRadius: 0.3))
        XCTAssertEqual(out.blocks[1].start, 1)
        XCTAssertEqual(out.blocks[1].count, 2)
        XCTAssertEqual(out.blocks[1].maxRadius, 0.2, accuracy: 1e-6)
    }

    func testPackParticlesIgnoresMismatchedArrays() {
        let data = ParticleData(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)], styleIndices: [1],
                                styles: [ParticleStyle(radius: 1, color: red), ParticleStyle(radius: 2, color: blue)],
                                colors: [red], radii: [5], flags: [ParticleFlags.hidden])
        XCTAssertNil(data.validStyleIndices)
        XCTAssertNil(data.validColors)
        XCTAssertNil(data.validRadii)
        XCTAssertNil(data.validFlags)
        let out = pack(data, ambient: [0], radii: true, colors: true)
        XCTAssertEqual(out.radii, [-1, -1])
        XCTAssertEqual(out.colors, [0, 0])
        XCTAssertEqual(out.blocks[0].maxRadius, 1)
        XCTAssertEqual(ParticlePacking.unpack(styleFlags: out.particles[0].styleFlags).ambient, 255)
    }

    func testPackParticlesEmptyAndNonFinite() {
        XCTAssertEqual(pack(ParticleData(positions: [], styles: [])).blocks, [])
        let data = ParticleData(positions: [SIMD3(.nan, 0, 0), SIMD3(1, 1, 1)], styles: [])
        let out = pack(data)
        XCTAssertEqual(out.blocks[0].low, SIMD3(1, 1, 1))
        XCTAssertEqual(out.blocks[0].maxRadius, ParticleStyle.fallback.radius)
    }

    func testPackBondsRemapsAndDropsInvalid() {
        var bonds = BondData(pairs: [SIMD2(0, 1), SIMD2(1, 5), SIMD2(2, 2), SIMD2(2, 0)], radius: 0.1,
                             colors: [red, blue, red, blue])
        var out = [GPUBond](repeating: GPUBond(a: 9, b: 9), count: 4)
        var colors = [UInt32](repeating: 0, count: 4)
        let inverse: [UInt32] = [1, 2, 0]    // original -> sorted
        let written = out.withUnsafeMutableBufferPointer { b in
            colors.withUnsafeMutableBufferPointer { c in
                ParticlePacking.packBonds(bonds, particleCount: 3, inverse: inverse, bonds: b.baseAddress!,
                                          colors: c.baseAddress)
            }
        }
        XCTAssertEqual(written, 2)
        XCTAssertEqual(Array(out.prefix(2)), [GPUBond(a: 1, b: 2), GPUBond(a: 0, b: 1)])
        XCTAssertEqual(Array(colors.prefix(2)), [ParticlePacking.packColor(red), ParticlePacking.packColor(blue)])

        bonds.colors = nil
        let plain = out.withUnsafeMutableBufferPointer {
            ParticlePacking.packBonds(bonds, particleCount: 3, inverse: nil, bonds: $0.baseAddress!, colors: nil)
        }
        XCTAssertEqual(plain, 2)
        XCTAssertEqual(Array(out.prefix(2)), [GPUBond(a: 0, b: 1), GPUBond(a: 2, b: 0)])
        XCTAssertNil(BondData(pairs: [SIMD2(0, 1)], radius: 1, colors: []).validColors)
        XCTAssertEqual(BondData(pairs: [], radius: 1).maxLength, .infinity)
    }

    func testPackLines() {
        let box = LineData.box(low: .zero, high: SIMD3(1, 2, 3), color: red, width: 2)
        let hidden = LineData(segments: [(.zero, SIMD3(1, 0, 0))], color: blue, width: 0)
        let lines = [box, hidden]
        XCTAssertEqual(ParticlePacking.segmentCount(lines), 12)
        var out = [GPULineSegment](repeating: GPULineSegment(start: .zero, end: .zero, color: .zero), count: 12)
        let written = out.withUnsafeMutableBufferPointer { ParticlePacking.packLines(lines, into: $0.baseAddress!) }
        XCTAssertEqual(written, 12)
        XCTAssertEqual(out[0].start.w, 2)
        XCTAssertEqual(out[0].color, red)
        XCTAssertTrue(out.allSatisfy { $0.end.w == 0 })
    }
}
