import simd
import XCTest
@testable import AtomifyRender

final class SpatialBlockingTests: XCTestCase {
    /// Deterministic pseudo-random positions in a cube of side `size`.
    static func positions(_ count: Int, size: Float = 100, seed: UInt32 = 1) -> [SIMD3<Float>] {
        var state = seed
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        return (0..<count).map { _ in SIMD3(next(), next(), next()) * size }
    }

    func testDivisions() {
        XCTAssertEqual(SpatialBlocking.divisions(count: 0, images: 1), 1)
        XCTAssertEqual(SpatialBlocking.divisions(count: 10, images: 1), 2)
        XCTAssertEqual(SpatialBlocking.divisions(count: 1_000_000, images: 1), 8)
        XCTAssertEqual(SpatialBlocking.divisions(count: 100_000_000, images: 1), 16)
        XCTAssertEqual(SpatialBlocking.divisions(count: 100_000_000, images: 27), 6)
    }

    func testSmallScenesAreOneBlock() {
        let layout = SpatialBlocking.layout(positions: Self.positions(100))
        XCTAssertNil(layout.order)
        XCTAssertEqual(layout.ranges, [0..<100])
        XCTAssertEqual(SpatialBlocking.layout(positions: []), BlockLayout(order: nil, ranges: []))
        // A single particle with images stays unsorted too.
        XCTAssertNil(SpatialBlocking.layout(positions: [.zero], images: 8).order)
    }

    func testLargeScenesAreSortedIntoCells() throws {
        let positions = Self.positions(50_000)
        let layout = SpatialBlocking.layout(positions: positions)
        let order = try XCTUnwrap(layout.order)
        XCTAssertEqual(order.count, positions.count)
        XCTAssertEqual(Set(order).count, positions.count, "order is a permutation")
        // Ranges are contiguous and cover everything.
        var next = 0
        for range in layout.ranges {
            XCTAssertEqual(range.lowerBound, next)
            XCTAssertFalse(range.isEmpty)
            next = range.upperBound
        }
        XCTAssertEqual(next, positions.count)
        let d = SpatialBlocking.divisions(count: positions.count, images: 1)
        XCTAssertLessThanOrEqual(layout.ranges.count, d * d * d)
        // Each range is compact: its bounding box is about one cell wide.
        let cell = 100 / Float(d)
        for range in layout.ranges {
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for k in range {
                let p = positions[Int(order[k])]
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
            XCTAssertLessThanOrEqual(simd_reduce_max(high - low), cell * 1.01)
        }
    }

    func testSampledOrderPutsCoarseLevelsFirst() throws {
        let positions = Self.positions(4_000, size: 10)
        let layout = SpatialBlocking.layout(positions: positions, images: 8)
        let order = try XCTUnwrap(layout.order)
        for range in layout.ranges {
            let levels = range.map { SpatialBlocking.level(of: Int(order[$0])) }
            XCTAssertEqual(levels, levels.sorted(by: >), "levels descending within a block")
        }
    }

    func testLevelDistribution() {
        var counts = [0, 0, 0]
        for i in 0..<160_000 { counts[SpatialBlocking.level(of: i)] += 1 }
        XCTAssertEqual(Double(counts[2]) / 160_000, 1.0 / 16, accuracy: 0.005)
        XCTAssertEqual(Double(counts[1]) / 160_000, 3.0 / 16, accuracy: 0.005)
        XCTAssertEqual(SpatialBlocking.level(of: 12345), SpatialBlocking.level(of: 12345))
    }

    func testScrambleIsAHash() {
        XCTAssertEqual(SpatialBlocking.scramble(0), 0)
        XCTAssertNotEqual(SpatialBlocking.scramble(1), SpatialBlocking.scramble(2))
        XCTAssertEqual(SpatialBlocking.scramble(42), SpatialBlocking.scramble(42))
    }

    func testInverse() {
        XCTAssertEqual(SpatialBlocking.inverse(of: [2, 0, 1]), [1, 2, 0])
        XCTAssertEqual(SpatialBlocking.inverse(of: []), [])
    }

    func testClampCell() {
        XCTAssertEqual(SpatialBlocking.clampCell(-3, 8), 0)
        XCTAssertEqual(SpatialBlocking.clampCell(3.7, 8), 3)
        XCTAssertEqual(SpatialBlocking.clampCell(8, 8), 7)
        XCTAssertEqual(SpatialBlocking.clampCell(1e30, 8), 7)
        XCTAssertEqual(SpatialBlocking.clampCell(.infinity, 8), 7)
        XCTAssertEqual(SpatialBlocking.clampCell(-.infinity, 8), 0)
        XCTAssertEqual(SpatialBlocking.clampCell(.nan, 8), 0)
    }

    func testNonFinitePositionsDoNotBreakTheSort() throws {
        var positions = Self.positions(30_000)
        positions[5] = SIMD3(.nan, 0, 0)
        positions[6] = SIMD3(.infinity, 0, 0)
        let layout = SpatialBlocking.layout(positions: positions)
        let order = try XCTUnwrap(layout.order)
        XCTAssertEqual(Set(order).count, positions.count)
    }

    func testAllEqualPositions() throws {
        let positions = [SIMD3<Float>](repeating: SIMD3(1, 2, 3), count: 25_000)
        let layout = SpatialBlocking.layout(positions: positions)
        XCTAssertEqual(layout.ranges, [0..<25_000])
        XCTAssertEqual(try XCTUnwrap(layout.order).count, 25_000)
    }
}

final class BlockCullingTests: XCTestCase {
    private let camera = OrbitCamera(target: .zero, distance: 10)
    private var projection: simd_float4x4 { camera.projectionMatrix(aspect: 1, near: 0.1, far: 100, reverseZ: false) }

    private func block(_ start: Int, at center: SIMD3<Float>, count: Int = 10, radius: Float = 0.5) -> ParticleBlock {
        ParticleBlock(start: start, count: count, low: center - 0.5, high: center + 0.5, maxRadius: radius)
    }

    func testIntersects() {
        let clip = projection * camera.viewMatrix
        XCTAssertTrue(BlockCulling.intersects(low: SIMD3(-1, -1, -1), high: SIMD3(1, 1, 1), clipFromModel: clip))
        // Far to the left, behind the eye, above.
        XCTAssertFalse(BlockCulling.intersects(low: SIMD3(-100, -1, -1), high: SIMD3(-90, 1, 1), clipFromModel: clip))
        XCTAssertFalse(BlockCulling.intersects(low: SIMD3(-1, -1, 20), high: SIMD3(1, 1, 30), clipFromModel: clip))
        XCTAssertFalse(BlockCulling.intersects(low: SIMD3(-1, 50, -1), high: SIMD3(1, 60, 1), clipFromModel: clip))
        // A box around the eye is in view.
        XCTAssertTrue(BlockCulling.intersects(low: SIMD3(-1, -1, 9), high: SIMD3(1, 1, 11), clipFromModel: clip))
    }

    func testDrawsAreCulledAndSortedNearestFirst() {
        let blocks = [block(0, at: SIMD3(0, 0, -5)), block(10, at: SIMD3(0, 0, 5)), block(20, at: SIMD3(0, 0, 0)),
                      block(30, at: SIMD3(-100, 0, 0))]
        let draws = BlockCulling.draws(blocks: blocks, images: [.zero], modelViews: [camera.viewMatrix],
                                       projections: [projection], radiusScale: 1)
        XCTAssertEqual(draws.map(\.block.start), [10, 20, 0])
        XCTAssertTrue(draws.allSatisfy { $0.image == 0 && $0.detail == 0 && $0.count == 10 })
    }

    func testRadiusPaddingKeepsEdgeBlocks() {
        // Just outside the right edge of the view at the target plane.
        let halfWidth = 10 * tanf(.pi / 8)
        let edge = block(0, at: SIMD3(halfWidth + 1.2, 0, 0), radius: 1)
        let small = BlockCulling.draws(blocks: [edge], images: [.zero], modelViews: [camera.viewMatrix],
                                       projections: [projection], radiusScale: 0)
        let large = BlockCulling.draws(blocks: [edge], images: [.zero], modelViews: [camera.viewMatrix],
                                       projections: [projection], radiusScale: 1)
        XCTAssertTrue(small.isEmpty)
        XCTAssertEqual(large.count, 1)
    }

    func testEmptyAndInvertedBlocksAreSkipped() {
        let empty = ParticleBlock(start: 0, count: 0, low: .zero, high: .zero, maxRadius: 1)
        let allHidden = ParticleBlock(start: 0, count: 5, low: SIMD3(repeating: .greatestFiniteMagnitude),
                                      high: SIMD3(repeating: -.greatestFiniteMagnitude), maxRadius: 0)
        XCTAssertTrue(BlockCulling.draws(blocks: [empty, allHidden], images: [.zero], modelViews: [camera.viewMatrix],
                                         projections: [projection], radiusScale: 1).isEmpty)
        XCTAssertTrue(BlockCulling.draws(blocks: [block(0, at: .zero)], images: [.zero], modelViews: [],
                                         projections: [], radiusScale: 1).isEmpty)
    }

    func testTwoViewsUseTheUnion() {
        var left = camera
        left.yaw = .pi / 2    // looks along -x from +x
        let onlyInLeft = block(0, at: SIMD3(-8, 0, 0))
        let firstOnly = BlockCulling.draws(blocks: [onlyInLeft], images: [.zero],
                                           modelViews: [camera.viewMatrix], projections: [projection], radiusScale: 1)
        XCTAssertTrue(firstOnly.isEmpty)
        let both = BlockCulling.draws(blocks: [onlyInLeft], images: [.zero],
                                      modelViews: [camera.viewMatrix, left.viewMatrix],
                                      projections: [projection, projection], radiusScale: 1)
        XCTAssertEqual(both.count, 1)
    }

    func testImagesAndBudget() {
        let blocks = [ParticleBlock(start: 0, count: 1_000, low: SIMD3(-1, -1, -1), high: SIMD3(1, 1, 1), maxRadius: 0.1)]
        let images: [SIMD3<Float>] = [.zero, SIMD3(0, 0, -2), SIMD3(0, 0, -4)]
        let unlimited = BlockCulling.draws(blocks: blocks, images: images, modelViews: [camera.viewMatrix],
                                           projections: [projection], radiusScale: 1)
        XCTAssertEqual(unlimited.map(\.image), [0, 1, 2])
        XCTAssertTrue(unlimited.allSatisfy { $0.detail == 0 })

        // 3000 in view, budget 2400: the farthest copy (2) drops to a quarter.
        let limited = BlockCulling.draws(blocks: blocks, images: images, modelViews: [camera.viewMatrix],
                                         projections: [projection], radiusScale: 1, budget: 2_400)
        XCTAssertEqual(limited.first { $0.image == 2 }?.detail, 1)
        XCTAssertEqual(limited.first { $0.image == 1 }?.detail, 0)
        XCTAssertEqual(limited.first { $0.image == 2 }?.count, 250)

        // Tiny budget: every copy but the primary at the lowest level.
        let tiny = BlockCulling.draws(blocks: blocks, images: images, modelViews: [camera.viewMatrix],
                                      projections: [projection], radiusScale: 1, budget: 1)
        XCTAssertEqual(tiny.map(\.detail), [0, 2, 2])
        XCTAssertEqual(tiny.map(\.count), [1_000, 62, 62])
    }

    func testDetailsWithoutCopies() {
        let blocks = [block(0, at: .zero, count: 100)]
        XCTAssertEqual(BlockCulling.details(inView: [100], images: [.zero], blocks: blocks,
                                            modelView: camera.viewMatrix, budget: 1), [0])
        XCTAssertEqual(BlockCulling.details(inView: [100, 100], images: [.zero, SIMD3(5, 0, 0)], blocks: [],
                                            modelView: camera.viewMatrix, budget: 1), [0, 0])
    }

    func testDrawCountAndRadiusScale() {
        let b = block(0, at: .zero, count: 3)
        XCTAssertEqual(BlockCulling.Draw(block: b, image: 0, detail: 2).count, 1)
        XCTAssertEqual(BlockCulling.Draw.radiusScale(detail: 0), 1)
        XCTAssertEqual(BlockCulling.Draw.radiusScale(detail: 2), 4)
    }

    func testNormalizedImages() {
        XCTAssertEqual(BlockCulling.normalizedImages([]), [.zero])
        XCTAssertEqual(BlockCulling.normalizedImages([SIMD3(1, 0, 0), .zero, SIMD3(1, 0, 0)]), [.zero, SIMD3(1, 0, 0)])
        XCTAssertEqual(BlockCulling.normalizedImages([SIMD3(1, 0, 0)]), [SIMD3(1, 0, 0)])
        XCTAssertEqual(BlockCulling.normalizedImages([SIMD3(.nan, 0, 0)]), [.zero])
    }
}
