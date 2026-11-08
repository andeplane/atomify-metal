import AtomifyRender
import simd
import Testing
@testable import RenderLab

@Suite struct CatalogTests {
    static let requests: [SceneRequest] = [
        .water,
        .siliconCarbide(cells: 2),
        .performance(PerformanceParameters(lattice: .fcc, size: .tenThousand, bonds: false, images: .off)),
        .coloring(ColoringParameters()),
        .picking(.denseCluster),
        .picking(.layeredSlabs),
    ]

    @Test func kinds() {
        let kinds = LabSceneKind.allCases
        #expect(kinds == [.water, .siliconCarbide, .performance, .coloring, .picking])
        #expect(Set(kinds.map(\.title)).count == kinds.count)
        for kind in kinds {
            #expect(kind.id == kind)
            #expect(!kind.title.isEmpty)
            #expect(!kind.subtitle.isEmpty)
            #expect(!kind.systemImage.isEmpty)
        }
    }

    @Test func requestKinds() {
        let kinds = Self.requests.map(\.kind)
        #expect(kinds == [.water, .siliconCarbide, .performance, .coloring, .picking, .picking])
    }

    @Test func requestEquality() {
        #expect(SceneRequest.siliconCarbide(cells: 2) == .siliconCarbide(cells: 2))
        #expect(SceneRequest.siliconCarbide(cells: 2) != .siliconCarbide(cells: 3))
        var coloring = ColoringParameters()
        let before = SceneRequest.coloring(coloring)
        coloring.colormap = .jet
        #expect(before != .coloring(coloring))
        #expect(Set(Self.requests).count == Self.requests.count)
    }

    @Test(arguments: CatalogTests.requests)
    func factoryMakesNonEmptyScenes(request: SceneRequest) {
        let generated = SceneFactory.make(request)
        #expect(generated.particleCount > 0)
        #expect(generated.scene.particles.styles.count == generated.styleNames.count)
        #expect(generated.bounds.high.x > generated.bounds.low.x)
        #expect(!generated.notes.isEmpty)
    }

    @Test(arguments: CatalogTests.requests)
    func factoryIsDeterministic(request: SceneRequest) {
        let a = SceneFactory.make(request)
        let b = SceneFactory.make(request)
        #expect(a.scene.particles.positions == b.scene.particles.positions)
        #expect(a.scene.particles.styleIndices == b.scene.particles.styleIndices)
        #expect(a.scene.bonds?.pairs == b.scene.bonds?.pairs)
        #expect(a.bounds == b.bounds)
    }

    @Test func generatedSceneDefaults() {
        let particles = ParticleData(positions: [.zero], styles: [ParticleStyle.fallback])
        let generated = GeneratedScene(scene: SceneData(particles: particles), styleNames: ["A"])
        #expect(generated.particleCount == 1)
        #expect(generated.bondCount == 0)
        #expect(generated.legend == nil)
        #expect(generated.scalars == nil)
        #expect(generated.notes.isEmpty)
        #expect(generated.viewAngles == SIMD2<Float>(0.55, 0.35))
        #expect(generated.bounds == SceneBounds.enclosing(SceneData(particles: particles)))
    }
}

@Suite struct PickingSceneTests {
    @Test func denseCluster() {
        let generated = PickingScene.make(.denseCluster)
        let particles = generated.scene.particles
        #expect(particles.count == PickingScene.clusterCount)
        #expect(particles.styles.count == 4)
        #expect(generated.styleNames.count == 4)
        for p in particles.positions {
            #expect(simd_length(p) <= PickingScene.clusterRadius)
        }
        let used = Set(particles.styleIndices ?? [])
        #expect(used == [0, 1, 2, 3])
        #expect(generated.scene.bonds == nil)
    }

    @Test func layeredSlabs() {
        let generated = PickingScene.make(.layeredSlabs)
        let particles = generated.scene.particles
        let side = PickingScene.slabSide
        #expect(particles.count == 3 * side * side)
        #expect(generated.bondCount == side * (side - 1))
        #expect(generated.scene.lines.count == 1)
        let indices = particles.styleIndices ?? []
        for (index, p) in particles.positions.enumerated() {
            let layer = Float(indices[index])
            #expect(closeF(p.z, -layer * PickingScene.slabLayerGap))
        }
        // Bonds join neighbours in the front sheet.
        for pair in generated.scene.bonds?.pairs ?? [] {
            #expect(indices[Int(pair.x)] == 0 && indices[Int(pair.y)] == 0)
            let length = distance(particles.positions, Int(pair.x), Int(pair.y))
            #expect(closeF(length, PickingScene.slabSpacing))
        }
        #expect(generated.viewAngles == SIMD2<Float>(0.18, 0.12))
    }

    @Test func frontSheetIsSmallestSoBackShowsThrough() {
        let radii = PickingScene.slabStyles.map(\.radius)
        #expect(radii == radii.sorted())
        #expect(2 * radii[0] < PickingScene.slabSpacing)
    }
}

@Suite struct LabOptionsTests {
    @Test func backgrounds() {
        #expect(LabBackground.dark.color == RenderSettings().background)
        #expect(LabBackground.white.color == SIMD4<Float>(1, 1, 1, 1))
        #expect(LabBackground.black.color == SIMD4<Float>(0, 0, 0, 1))
        #expect(LabBackground.allCases.map(\.title) == ["Dark", "Black", "Gray", "White"])
    }

    @Test func hosts() {
        #expect(ViewportHost.allCases.map(\.title) == ["Lab view", "ParticleView"])
    }

    @Test func budgets() {
        let values = ParticleBudget.allCases.map(\.rawValue)
        #expect(values == values.sorted())
        // The renderer's own default.
        #expect(ParticleBudget.four.rawValue == 4_000_000)
    }
}
