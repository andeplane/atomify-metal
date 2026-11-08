import Testing
@testable import AtomifyKit

@Suite struct QualityPolicyTests {
    @Test func automaticFollowsSystemSize() {
        let policy = QualityPolicy()
        #expect(policy.quality(atomCount: 0) == .high)
        #expect(policy.quality(atomCount: 49_999) == .high)
        #expect(policy.quality(atomCount: 50_000) == .fast)
        #expect(policy.quality(atomCount: 1_000_000) == .fast)
    }

    @Test func automaticIsFastWhenConstrained() {
        #expect(QualityPolicy().quality(atomCount: 3, constrained: true) == .fast)
    }

    @Test func explicitModesIgnoreSize() {
        #expect(QualityPolicy(mode: .high).quality(atomCount: 1_000_000, constrained: true) == .high)
        #expect(QualityPolicy(mode: .fast).quality(atomCount: 3) == .fast)
    }

    @Test func veryLargeSystemsGetFewerPixels() {
        let policy = QualityPolicy()
        #expect(policy.contentScaleLimit(atomCount: 299_999) == nil)
        #expect(policy.contentScaleLimit(atomCount: 300_000) == 2)
        #expect(QualityPolicy(mode: .high).contentScaleLimit(atomCount: 400_000) == 2)
    }

    @Test func modesHaveTitles() {
        #expect(QualityPolicy.Mode.allCases.map(\.title) == ["Automatic", "Fast", "High"])
        #expect(QualityPolicy.Mode(rawValue: "high") == .high)
    }
}
