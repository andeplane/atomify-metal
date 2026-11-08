import simd
import XCTest
@testable import AtomifyRender

final class BondBlockingTests: XCTestCase {
    private let blocks = [
        ParticleBlock(start: 0, count: 2, low: SIMD3(0, 0, 0), high: SIMD3(1, 1, 1), maxRadius: 0.5),
        ParticleBlock(start: 2, count: 2, low: SIMD3(10, 0, 0), high: SIMD3(11, 1, 1), maxRadius: 0.5),
    ]

    private func group(_ input: [GPUBond], colors input2: [UInt32]?, particleCount: Int = 4,
                       maxLength: Float = .greatestFiniteMagnitude,
                       length: (GPUBond) -> Float = { _ in 1 }) -> ([GPUBond], [UInt32]?, [BondRange]) {
        var bonds = input
        var colors = input2
        let ranges = bonds.withUnsafeMutableBufferPointer { b in
            if colors != nil {
                return colors!.withUnsafeMutableBufferPointer { c in
                    BondBlocking.group(bonds: b.baseAddress!, colors: c.baseAddress, count: b.count, blocks: blocks,
                                       particleCount: particleCount, maxLength: maxLength, length: length)
                }
            }
            return BondBlocking.group(bonds: b.baseAddress!, colors: nil, count: b.count, blocks: blocks,
                                      particleCount: particleCount, maxLength: maxLength, length: length)
        }
        return (bonds, colors, ranges)
    }

    func testGroupsBondsByTheBlockOfTheirFirstParticle() {
        let input = [GPUBond(a: 3, b: 2), GPUBond(a: 0, b: 1), GPUBond(a: 2, b: 1), GPUBond(a: 1, b: 0)]
        let (bonds, colors, ranges) = group(input, colors: [30, 1, 21, 10]) { bond in
            bond.a == 2 && bond.b == 1 ? 9 : 1    // a long bond across blocks
        }
        XCTAssertEqual(bonds, [GPUBond(a: 0, b: 1), GPUBond(a: 1, b: 0), GPUBond(a: 3, b: 2), GPUBond(a: 2, b: 1)])
        XCTAssertEqual(colors, [1, 10, 30, 21], "colors move with their bonds")
        XCTAssertEqual(ranges, [BondRange(start: 0, count: 2, reach: 1), BondRange(start: 2, count: 2, reach: 9)])
    }

    func testBondsTooLongToDrawDoNotCountTowardReach() {
        let (_, _, ranges) = group([GPUBond(a: 0, b: 1), GPUBond(a: 1, b: 2)], colors: nil, maxLength: 5) { bond in
            bond.a == 1 ? 50 : 2
        }
        XCTAssertEqual(ranges, [BondRange(start: 0, count: 2, reach: 2), BondRange(start: 2, count: 0, reach: 0)])
    }

    func testBondsOutsideEveryBlockAreNeverCulled() {
        let (bonds, _, ranges) = group([GPUBond(a: 5, b: 0), GPUBond(a: 0, b: 1)], colors: nil, particleCount: 6)
        XCTAssertEqual(bonds, [GPUBond(a: 0, b: 1), GPUBond(a: 5, b: 0)])
        XCTAssertEqual(ranges.last, BondRange(start: 1, count: 1, reach: .infinity))
    }

    func testNothingToGroup() {
        var bonds = [GPUBond(a: 0, b: 1)]
        let empty = bonds.withUnsafeMutableBufferPointer {
            BondBlocking.group(bonds: $0.baseAddress!, colors: nil, count: 1, blocks: [], particleCount: 2,
                               maxLength: 1) { _ in 1 }
        }
        XCTAssertEqual(empty, [])
    }

    /// A camera at x = 0.5 looking down −z sees the first block, not the second (at x = 10).
    private var clip: simd_float4x4 {
        let camera = OrbitCamera(target: SIMD3(0.5, 0.5, 0.5), distance: 4)
        return camera.projectionMatrix(aspect: 1, near: 0.1, far: 100, reverseZ: true) * camera.viewMatrix
    }

    func testDrawsOnlyRangesInView() {
        let ranges = [BondRange(start: 0, count: 2, reach: 1), BondRange(start: 2, count: 3, reach: 1)]
        let draws = BondBlocking.draws(ranges: ranges, blocks: blocks, images: [0], offsets: [.zero],
                                       clipFromModels: [clip], radiusScale: 1, bondRadius: 0.1)
        XCTAssertEqual(draws.map(\.image), [0])
        XCTAssertEqual(draws.map(\.range), [0..<2])
    }

    func testALongReachKeepsAFarBlocksBondsAndAdjacentRangesMerge() {
        let ranges = [BondRange(start: 0, count: 2, reach: 1), BondRange(start: 2, count: 3, reach: 9.5)]
        let draws = BondBlocking.draws(ranges: ranges, blocks: blocks, images: [0], offsets: [.zero],
                                       clipFromModels: [clip], radiusScale: 1, bondRadius: 0.1)
        XCTAssertEqual(draws.map(\.range), [0..<5])
    }

    func testCopiesAreCulledAtTheirOffsetAndUnculledRangesAlwaysDraw() {
        let ranges = [BondRange(start: 0, count: 2, reach: 1), BondRange(start: 2, count: 3, reach: 1),
                      BondRange(start: 5, count: 1, reach: .infinity)]
        // Copy 1 moves the second block onto the first.
        let draws = BondBlocking.draws(ranges: ranges, blocks: blocks, images: [0, 1, 7],
                                       offsets: [.zero, SIMD3(-10, 0, 0)], clipFromModels: [clip], radiusScale: 1,
                                       bondRadius: 0.1)
        XCTAssertEqual(draws.map(\.image), [0, 0, 1])
        XCTAssertEqual(draws.map(\.range), [0..<2, 5..<6, 2..<6])
    }
}
