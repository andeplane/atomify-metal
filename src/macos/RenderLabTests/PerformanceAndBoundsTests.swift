import AtomifyRender
import simd
import Testing
@testable import RenderLab

@Suite struct PeriodicImagesTests {
    @Test func off() {
        let offsets = PeriodicImages.off.offsets(box: SIMD3<Float>(1, 2, 3))
        #expect(offsets == [SIMD3<Float>.zero])
        #expect(PeriodicImages.off.perAxis == 1)
    }

    @Test(arguments: zip([PeriodicImages.three, .five], [27, 125]))
    func copies(images: PeriodicImages, count: Int) {
        let size = SIMD3<Float>(2, 3, 4)
        let offsets = images.offsets(box: size)
        #expect(offsets.count == count)
        #expect(offsets.first == SIMD3<Float>.zero)
        #expect(Set(offsets).count == count)
        let half = Float(images.perAxis / 2)
        for offset in offsets {
            let cells = offset / size
            #expect(cells.x == cells.x.rounded() && abs(cells.x) <= half)
            #expect(cells.y == cells.y.rounded() && abs(cells.y) <= half)
            #expect(cells.z == cells.z.rounded() && abs(cells.z) <= half)
        }
    }

    @Test func titles() {
        #expect(PeriodicImages.allCases.map(\.title) == ["None", "3×3×3", "5×5×5"])
    }
}

@Suite struct SceneBoundsTests {
    @Test func ofPoints() {
        let points: [SIMD3<Float>] = [SIMD3(1, 5, -2), SIMD3(-1, 2, 3), SIMD3(.nan, 100, 100)]
        let bounds = SceneBounds.of(points)
        #expect(bounds?.low == SIMD3<Float>(-1, 2, -2))
        #expect(bounds?.high == SIMD3<Float>(1, 5, 3))
        #expect(bounds?.center == SIMD3<Float>(0, 3.5, 0.5))
        #expect(bounds?.size == SIMD3<Float>(2, 3, 5))
    }

    @Test func ofNothing() {
        #expect(SceneBounds.of([]) == nil)
        #expect(SceneBounds.of([SIMD3<Float>(.infinity, 0, 0)]) == nil)
    }

    @Test func paddedAndUnion() {
        let a = SceneBounds(low: .zero, high: SIMD3<Float>(1, 1, 1))
        let padded = a.padded(by: 0.5)
        #expect(padded.low == SIMD3<Float>(-0.5, -0.5, -0.5))
        #expect(padded.high == SIMD3<Float>(1.5, 1.5, 1.5))
        #expect(a.padded(by: -1) == a)
        let b = SceneBounds(low: SIMD3<Float>(-2, 0, 0), high: SIMD3<Float>(0, 3, 0))
        let union = a.union(b)
        #expect(union.low == SIMD3<Float>(-2, 0, 0))
        #expect(union.high == SIMD3<Float>(1, 3, 1))
    }

    @Test func includingImages() {
        let a = SceneBounds(low: .zero, high: SIMD3<Float>(2, 2, 2))
        let images = PeriodicImages.three.offsets(box: SIMD3<Float>(2, 2, 2))
        let grown = a.including(images: images)
        #expect(grown.low == SIMD3<Float>(-2, -2, -2))
        #expect(grown.high == SIMD3<Float>(4, 4, 4))
        #expect(a.including(images: [.zero]) == a)
        #expect(a.including(images: []) == a)
    }

    @Test func enclosingPadsByLargestRadius() {
        let styles = [ParticleStyle(radius: 0.5, color: SIMD4<Float>(1, 1, 1, 1)),
                      ParticleStyle(radius: 2, color: SIMD4<Float>(1, 1, 1, 1))]
        let particles = ParticleData(positions: [.zero, SIMD3<Float>(1, 0, 0)], styles: styles)
        let bounds = SceneBounds.enclosing(SceneData(particles: particles))
        #expect(bounds.low == SIMD3<Float>(-2, -2, -2))
        #expect(bounds.high == SIMD3<Float>(3, 2, 2))
    }

    @Test func enclosingUsesRadiusOverrides() {
        var particles = ParticleData(positions: [.zero], styles: [ParticleStyle.fallback])
        particles.radii = [3]
        let bounds = SceneBounds.enclosing(SceneData(particles: particles))
        #expect(bounds.high == SIMD3<Float>(3, 3, 3))
    }

    @Test func enclosingIncludesLinesAndImages() {
        let particles = ParticleData(positions: [.zero], styles: [ParticleStyle.fallback])
        let line = LineData.box(low: .zero, high: SIMD3<Float>(10, 10, 10), color: SIMD4<Float>(1, 1, 1, 1))
        let scene = SceneData(particles: particles, lines: [line], images: [.zero, SIMD3<Float>(10, 0, 0)])
        let bounds = SceneBounds.enclosing(scene)
        #expect(bounds.low == SIMD3<Float>(-0.5, -0.5, -0.5))
        #expect(bounds.high == SIMD3<Float>(20, 10, 10))
    }

    @Test func enclosingEmptyScene() {
        let bounds = SceneBounds.enclosing(.empty)
        #expect(bounds.low == SIMD3<Float>(-0.5, -0.5, -0.5))
        #expect(bounds.high == SIMD3<Float>(0.5, 0.5, 0.5))
    }
}

@Suite struct PerformanceSceneTests {
    @Test func sizes() {
        #expect(PerformanceSize.allCases.map(\.rawValue) == [10_000, 100_000, 1_000_000, 4_000_000, 8_000_000])
        #expect(PerformanceSize.allCases.map(\.title) == ["10k", "100k", "1M", "4M", "8M"])
    }

    @Test func parameterCounts() {
        var parameters = PerformanceParameters()
        parameters.size = .oneMillion
        #expect(parameters.cells == 50)
        #expect(parameters.particleCount == 1_000_000)
        parameters.size = .eightMillion
        #expect(parameters.particleCount == 8_000_000)
        parameters.lattice = .fcc
        parameters.size = .fourMillion
        #expect(parameters.cells == 100)
        #expect(parameters.particleCount == 4_000_000)
    }

    @Test func lattices() {
        #expect(PerformanceLattice.siliconCarbide.hasBonds)
        #expect(!PerformanceLattice.fcc.hasBonds)
        #expect(PerformanceLattice.siliconCarbide.atomsPerCell == 8)
        #expect(PerformanceLattice.fcc.atomsPerCell == 4)
    }

    @Test func smallSiliconCarbideWithBonds() {
        let generated = PerformanceScene.make(PerformanceParameters())
        // 100k target: 23³ cells.
        #expect(generated.particleCount == 97_336)
        #expect(generated.scene.particles.styleIndices?.count == 97_336)
        #expect(generated.bondCount > 0)
        #expect(generated.scene.images.count == 1)
        #expect(generated.scene.lines.count == 1)
    }

    @Test func tenThousandBondCount() {
        var parameters = PerformanceParameters()
        parameters.size = .tenThousand
        let generated = PerformanceScene.make(parameters)
        #expect(generated.particleCount == 10_648)
        #expect(generated.bondCount == 19_877)
    }

    @Test func bondsOff() {
        var parameters = PerformanceParameters()
        parameters.size = .tenThousand
        parameters.bonds = false
        let generated = PerformanceScene.make(parameters)
        #expect(generated.scene.bonds == nil)
        #expect(generated.bondCount == 0)
    }

    @Test func fccHasNoBonds() {
        var parameters = PerformanceParameters()
        parameters.lattice = .fcc
        parameters.size = .tenThousand
        let generated = PerformanceScene.make(parameters)
        #expect(generated.particleCount == 10_976)
        #expect(generated.scene.bonds == nil)
        #expect(generated.scene.particles.styles.count == 1)
        #expect(generated.notes.contains("The FCC crystal has no bonds."))
    }

    @Test func periodicImages() {
        var parameters = PerformanceParameters()
        parameters.size = .tenThousand
        parameters.images = .three
        let generated = PerformanceScene.make(parameters)
        let length = ZincblendeLattice(cells: 11).boxLength
        #expect(generated.scene.images.count == 27)
        #expect(generated.scene.images.first == SIMD3<Float>.zero)
        #expect(generated.bounds.low.x <= -length)
        #expect(generated.bounds.high.x >= 2 * length - 0.01)
        #expect(generated.notes.contains("Bonds are not periodic, so copies show seams."))
    }
}
