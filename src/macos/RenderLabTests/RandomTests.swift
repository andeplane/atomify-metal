import Testing
@testable import RenderLab

@Suite struct RandomTests {
    @Test func splitMixIsDeterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<100 {
            #expect(a.next() == b.next())
        }
    }

    @Test func differentSeedsDiffer() {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)
        #expect(a.next() != b.next())
    }

    @Test func unitAndUniformRanges() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<10_000 {
            let u = rng.nextUnit()
            #expect(u >= 0 && u < 1)
            let v = rng.uniform(-3, 5)
            #expect(v >= -3 && v < 5)
        }
    }

    @Test func unitFloatBounds() {
        #expect(LabHash.unitFloat(0) == 0)
        #expect(LabHash.unitFloat(UInt64.max) < 1)
        #expect(LabHash.unitFloat(UInt64.max) > 0.999)
    }

    @Test func hashMixesEveryArgument() {
        let base = LabHash.hash(1, 2, 3, seed: 4)
        #expect(base == LabHash.hash(1, 2, 3, seed: 4))
        #expect(base != LabHash.hash(2, 2, 3, seed: 4))
        #expect(base != LabHash.hash(1, 3, 3, seed: 4))
        #expect(base != LabHash.hash(1, 2, 4, seed: 4))
        #expect(base != LabHash.hash(1, 2, 3, seed: 5))
    }

    @Test func mixIsNotIdentity() {
        #expect(LabHash.mix(1) != 1)
        #expect(LabHash.mix(1) != LabHash.mix(2))
    }
}
