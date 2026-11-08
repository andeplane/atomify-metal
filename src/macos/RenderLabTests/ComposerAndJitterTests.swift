import AtomifyRender
import simd
import Testing
@testable import RenderLab

@Suite struct SceneComposerTests {
    static func base(flags: [UInt8]? = nil) -> SceneData {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        let particles = ParticleData(positions: positions, styles: [ParticleStyle.fallback], flags: flags)
        let bonds = BondData(pairs: [SIMD2<UInt32>(0, 1)], radius: 0.1)
        let box = LineData.box(low: .zero, high: SIMD3<Float>(2, 1, 1), color: SIMD4<Float>(1, 1, 1, 1))
        return SceneData(particles: particles, bonds: bonds, lines: [box])
    }

    @Test func unchangedSharesStorage() {
        let base = Self.base()
        let composed = SceneComposer.compose(base, selected: nil, showBonds: true, showBox: true)
        #expect(composed.sharesStorage(with: base))
        #expect(composed.particles.flags == nil)
    }

    @Test func hideBondsAndBox() {
        let base = Self.base()
        let noBonds = SceneComposer.compose(base, selected: nil, showBonds: false, showBox: true)
        #expect(noBonds.bonds == nil)
        #expect(noBonds.lines.count == 1)
        let noBox = SceneComposer.compose(base, selected: nil, showBonds: true, showBox: false)
        #expect(noBox.bonds != nil)
        #expect(noBox.lines.isEmpty)
    }

    @Test func selectionSetsOneFlag() {
        let composed = SceneComposer.compose(Self.base(), selected: 1, showBonds: true, showBox: true)
        #expect(composed.particles.flags == [0, ParticleFlags.selected, 0])
        #expect(composed.particles.positions == Self.base().particles.positions)
    }

    @Test func selectionKeepsOtherFlags() {
        let hidden = ParticleFlags.hidden
        let base = Self.base(flags: [hidden, hidden, 0])
        let composed = SceneComposer.compose(base, selected: 0, showBonds: true, showBox: true)
        let both = hidden | ParticleFlags.selected
        #expect(composed.particles.flags == [both, hidden, 0])
        // The base scene is not modified.
        #expect(base.particles.flags == [hidden, hidden, 0])
    }

    @Test func selectionReplacesMismatchedFlags() {
        let base = Self.base(flags: [1])
        let composed = SceneComposer.compose(base, selected: 2, showBonds: true, showBox: true)
        #expect(composed.particles.flags == [0, 0, ParticleFlags.selected])
    }

    @Test(arguments: [-1, 3, 100])
    func outOfRangeSelectionIsIgnored(index: Int) {
        let base = Self.base()
        let composed = SceneComposer.compose(base, selected: index, showBonds: true, showBox: true)
        #expect(composed.particles.flags == nil)
    }
}

@Suite struct ThermalJitterTests {
    static func lattice(_ count: Int) -> [SIMD3<Float>] {
        (0..<count).map { i in SIMD3<Float>(Float(i % 97), Float(i / 97), 0) }
    }

    @Test func sameFrameSameOutput() {
        let base = Self.lattice(5_000)
        var a: [SIMD3<Float>] = []
        var b: [SIMD3<Float>] = []
        ThermalJitter.apply(base: base, amplitude: 0.1, frame: 7, into: &a)
        ThermalJitter.apply(base: base, amplitude: 0.1, frame: 7, into: &b)
        #expect(a == b)
        #expect(a.count == base.count)
        #expect(ThermalJitter.key(frame: 7) != ThermalJitter.key(frame: 8))
    }

    @Test func framesDiffer() {
        let base = Self.lattice(1_000)
        var a: [SIMD3<Float>] = []
        var b: [SIMD3<Float>] = []
        ThermalJitter.apply(base: base, amplitude: 0.1, frame: 1, into: &a)
        ThermalJitter.apply(base: base, amplitude: 0.1, frame: 2, into: &b)
        #expect(a != b)
        #expect(a != base)
    }

    @Test func boundedByAmplitudeAndCentred() {
        let base = Self.lattice(20_000)
        var out: [SIMD3<Float>] = []
        let amplitude: Float = 0.25
        ThermalJitter.apply(base: base, amplitude: amplitude, frame: 3, into: &out)
        var sum = SIMD3<Float>.zero
        for i in 0..<base.count {
            let d = out[i] - base[i]
            let limit = amplitude + 1e-4
            #expect(abs(d.x) <= limit && abs(d.y) <= limit && abs(d.z) <= limit)
            sum += d
        }
        let mean = sum / Float(base.count)
        #expect(simd_length(mean) < 0.01)
    }

    @Test func zeroAmplitudeIsTheBase() {
        let base = Self.lattice(100)
        var out: [SIMD3<Float>] = []
        ThermalJitter.apply(base: base, amplitude: 0, frame: 9, into: &out)
        #expect(out == base)
    }

    @Test func parallelChunksMatchSerial() {
        let count = ThermalJitter.chunkSize * 3 + 17
        let base = Self.lattice(count)
        var out = [SIMD3<Float>](repeating: SIMD3<Float>(9, 9, 9), count: 5)
        ThermalJitter.apply(base: base, amplitude: 0.5, frame: 11, into: &out)
        #expect(out.count == count)
        let key = ThermalJitter.key(frame: 11)
        for i in stride(from: 0, to: count, by: 101) {
            let offset = ThermalJitter.offset(index: UInt64(i), key: key)
            let expected = base[i] + 0.5 * offset
            #expect(closeV3(out[i], expected, tolerance: 1e-6))
        }
        let last = count - 1
        let lastOffset = ThermalJitter.offset(index: UInt64(last), key: key)
        let lastExpected = base[last] + 0.5 * lastOffset
        #expect(closeV3(out[last], lastExpected, tolerance: 1e-6))
    }

    @Test func emptyInputEmptiesOutput() {
        var out: [SIMD3<Float>] = [SIMD3<Float>(1, 2, 3)]
        ThermalJitter.apply(base: [], amplitude: 1, frame: 0, into: &out)
        #expect(out.isEmpty)
    }

    @Test func offsetRange() {
        for i in 0..<10_000 {
            let o = ThermalJitter.offset(index: UInt64(i), key: 12_345)
            #expect(o.x >= -1 && o.x < 1)
            #expect(o.y >= -1 && o.y < 1)
            #expect(o.z >= -1 && o.z < 1)
        }
    }
}
