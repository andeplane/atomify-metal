import Metal
import simd
import XCTest
@testable import AtomifyRender

final class DensityOcclusionTests: XCTestCase {
    /// A simple cubic lattice, `n` per side, spacing 1.
    private func lattice(_ n: Int) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for z in 0..<n { for y in 0..<n { for x in 0..<n { points.append(SIMD3(Float(x), Float(y), Float(z))) } } }
        return points
    }

    func testSmallOrSparseSystemsGetNothing() {
        XCTAssertEqual(DensityOcclusion.ambient(positions: lattice(4), spacing: 1), [])
        XCTAssertEqual(DensityOcclusion.ambient(positions: lattice(10), spacing: 0), [])
        XCTAssertEqual(DensityOcclusion.ambient(positions: lattice(10), spacing: .nan), [])
        // A gas: points far apart relative to the spacing.
        let gas = lattice(6).map { $0 * 50 }
        XCTAssertEqual(DensityOcclusion.ambient(positions: gas, spacing: 1), [])
    }

    func testInteriorIsDarkerThanCorners() {
        let points = lattice(20)
        let ambient = DensityOcclusion.ambient(positions: points, spacing: 1)
        XCTAssertEqual(ambient.count, points.count)
        let corner = ambient[0]
        let centerIndex: Int = (10 * 20 + 10) * 20 + 10
        let center = ambient[centerIndex]
        XCTAssertGreaterThan(corner, center)
        XCTAssertEqual(corner, 1, accuracy: 1e-6)
        XCTAssertTrue(ambient.allSatisfy { $0 >= 0.45 - 1e-6 && $0 <= 1 })
    }

    func testNonFinitePositionsAreTolerated() {
        var points = lattice(10)
        points[3] = SIMD3(.nan, 0, 0)
        XCTAssertEqual(DensityOcclusion.ambient(positions: points, spacing: 1).count, points.count)
        let allNaN = [SIMD3<Float>](repeating: SIMD3(.nan, .nan, .nan), count: 100)
        XCTAssertEqual(DensityOcclusion.ambient(positions: allNaN, spacing: 1), [])
    }

    func testAmbientCurve() {
        XCTAssertEqual(DensityOcclusion.ambient(count: 0, reference: 100), 1)
        XCTAssertEqual(DensityOcclusion.ambient(count: 45, reference: 100), 1, accuracy: 1e-6)
        XCTAssertEqual(DensityOcclusion.ambient(count: 100, reference: 100), 0.45, accuracy: 1e-6)
        XCTAssertEqual(DensityOcclusion.ambient(count: 500, reference: 100), 0.45, accuracy: 1e-6)
    }

    func testPercentile() {
        var histogram = [Int](repeating: 0, count: 10)
        histogram[2] = 90
        histogram[7] = 10
        XCTAssertEqual(DensityOcclusion.percentile95(histogram: histogram, total: 100), 7)
        histogram[2] = 96
        histogram[7] = 4
        XCTAssertEqual(DensityOcclusion.percentile95(histogram: histogram, total: 100), 2)
        XCTAssertEqual(DensityOcclusion.percentile95(histogram: [0, 0], total: 5), 1)
    }

    func testGridIsCapped() {
        let grid = DensityOcclusion.grid(low: .zero, high: SIMD3(repeating: 1000), spacing: 0.01)
        XCTAssertLessThanOrEqual(grid.dims.x * grid.dims.y * grid.dims.z, DensityOcclusion.maxCells)
        XCTAssertGreaterThan(grid.cell, 0.01)
        let small = DensityOcclusion.grid(low: .zero, high: SIMD3(2, 2, 2), spacing: 1)
        XCTAssertEqual(small.cell, 1)
        XCTAssertEqual(small.dims, SIMD3(3, 3, 3))
        XCTAssertEqual(DensityOcclusion.clamp(.nan, 4), 0)
        XCTAssertEqual(DensityOcclusion.clamp(9, 4), 3)
    }

    func testRefreshAndSpacing() {
        XCTAssertTrue(DensityOcclusion.needsRefresh(cachedCount: -1, count: 10, age: 0, interval: 8))
        XCTAssertFalse(DensityOcclusion.needsRefresh(cachedCount: 10, count: 10, age: 7, interval: 8))
        XCTAssertTrue(DensityOcclusion.needsRefresh(cachedCount: 10, count: 10, age: 8, interval: 8))
        XCTAssertTrue(DensityOcclusion.needsRefresh(cachedCount: 10, count: 10, age: 0, interval: 0))
        let styles = [ParticleStyle(radius: 0.5, color: .one), ParticleStyle(radius: 1.5, color: .one)]
        XCTAssertEqual(DensityOcclusion.spacing(styles: styles, radii: nil), 3)
        XCTAssertEqual(DensityOcclusion.spacing(styles: styles, radii: [0.25, .nan]), 0.5)
        XCTAssertEqual(DensityOcclusion.spacing(styles: [], radii: nil), 1e-3)
    }
}

final class KernelAndGrowthTests: XCTestCase {
    func testSamplesLieInTheHemisphere() {
        let samples = AmbientOcclusionKernel.samples(count: 16)
        XCTAssertEqual(samples.count, 16)
        for s in samples {
            XCTAssertGreaterThan(s.z, 0)
            XCTAssertLessThanOrEqual(simd_length(SIMD3(s.x, s.y, s.z)), 1 + 1e-5)
            XCTAssertEqual(s.w, 0)
        }
        XCTAssertEqual(samples, AmbientOcclusionKernel.samples(count: 16), "deterministic")
        XCTAssertEqual(AmbientOcclusionKernel.samples(count: 0).count, 1)
        XCTAssertEqual(AmbientOcclusionKernel.samples(count: 1000).count, AmbientOcclusionKernel.maxSamples)
        // Later samples reach further on average.
        let first = samples.prefix(4).map { simd_length(SIMD3($0.x, $0.y, $0.z)) }.reduce(0, +)
        let last = samples.suffix(4).map { simd_length(SIMD3($0.x, $0.y, $0.z)) }.reduce(0, +)
        XCTAssertGreaterThan(last, first)
    }

    func testOcclusionRadius() {
        let styles = [ParticleStyle(radius: 0.5, color: .one), ParticleStyle(radius: 2, color: .one)]
        XCTAssertEqual(AmbientOcclusionKernel.radius(requested: 3, styles: styles), 3)
        XCTAssertEqual(AmbientOcclusionKernel.radius(requested: 0, styles: styles), 50)
        XCTAssertEqual(AmbientOcclusionKernel.radius(requested: .nan, styles: styles), 50)
        XCTAssertEqual(AmbientOcclusionKernel.radius(requested: 0, styles: []), 1)
        // Water's oxygen at a quarter of 1.52 Å gets about the web app's 10 Å.
        let oxygen = [ParticleStyle(radius: 0.25 * 1.52, color: .one)]
        XCTAssertEqual(AmbientOcclusionKernel.radius(requested: 0, styles: oxygen), 9.5, accuracy: 1e-4)
    }

    func testOcclusionFalloffExponentAndOutlineDepth() {
        XCTAssertEqual(AmbientOcclusionKernel.falloff(radius: 10), 2, accuracy: 1e-6)
        XCTAssertEqual(AmbientOcclusionKernel.exponent(strength: 1), 5)
        XCTAssertEqual(AmbientOcclusionKernel.exponent(strength: 0.5), 2.5)
        XCTAssertEqual(AmbientOcclusionKernel.exponent(strength: -1), 0)
        let styles = [ParticleStyle(radius: 0.5, color: .one), ParticleStyle(radius: .infinity, color: .one)]
        XCTAssertEqual(AmbientOcclusionKernel.outlineDepth(styles: styles), 0.6, accuracy: 1e-6)
        XCTAssertEqual(AmbientOcclusionKernel.outlineDepth(styles: []), 0.3)
    }

    func testBufferGrowth() {
        XCTAssertEqual(BufferGrowth.capacity(required: 0, current: 0), 0)
        XCTAssertEqual(BufferGrowth.capacity(required: 1, current: 0), 256)
        XCTAssertEqual(BufferGrowth.capacity(required: 100, current: 512), 512, "never shrinks")
        XCTAssertEqual(BufferGrowth.capacity(required: 513, current: 512), 768, "grows by half")
        XCTAssertEqual(BufferGrowth.capacity(required: 5_000, current: 512), 5_120, "or to what is needed")
        XCTAssertEqual(BufferGrowth.capacity(required: 1_000_001, current: 0) % 256, 0)
        // A slowly growing scene reallocates rarely.
        var capacity = 0, reallocations = 0
        for required in stride(from: 1, through: 1_000_000, by: 1_000) {
            let next = BufferGrowth.capacity(required: required, current: capacity)
            if next != capacity { reallocations += 1 }
            capacity = next
        }
        XCTAssertLessThan(reallocations, 30)
    }
}

final class SceneTypesTests: XCTestCase {
    func testEffectiveStyles() {
        XCTAssertEqual(ParticleData(positions: [], styles: []).effectiveStyles, [.fallback])
        let many = [ParticleStyle](repeating: .fallback, count: 70_000)
        XCTAssertEqual(ParticleData(positions: [], styles: many).effectiveStyles.count, 65_536)
    }

    func testCountAndValidation() {
        let data = ParticleData(positions: [.zero, .one], styleIndices: [0, 1], styles: [.fallback],
                                colors: [.one, .one], radii: [1, 2], flags: [0, 1])
        XCTAssertEqual(data.count, 2)
        XCTAssertNotNil(data.validStyleIndices)
        XCTAssertNotNil(data.validColors)
        XCTAssertNotNil(data.validRadii)
        XCTAssertNotNil(data.validFlags)
    }

    func testSharesStorage() {
        let positions: [SIMD3<Float>] = [.zero, .one]
        let scene = SceneData(particles: ParticleData(positions: positions, styles: [.fallback]),
                              bonds: BondData(pairs: [SIMD2(0, 1)], radius: 0.1),
                              lines: [LineData.box(low: .zero, high: .one, color: .one)],
                              panels: [PanelData.box(low: .zero, high: .one, color: SIMD4(1, 1, 1, 0.1))])
        let copy = scene
        XCTAssertTrue(scene.sharesStorage(with: copy))
        var moved = scene
        moved.particles.positions[0] = SIMD3(5, 5, 5)
        XCTAssertFalse(scene.sharesStorage(with: moved))
        var rebonded = scene
        rebonded.bonds = nil
        XCTAssertFalse(scene.sharesStorage(with: rebonded))
        var thicker = scene
        thicker.bonds?.radius = 0.2
        XCTAssertFalse(scene.sharesStorage(with: thicker))
        var recolored = scene
        recolored.lines[0].color = .zero
        XCTAssertFalse(scene.sharesStorage(with: recolored))
        var relined = scene
        relined.lines = []
        XCTAssertFalse(scene.sharesStorage(with: relined))
        var repaneled = scene
        repaneled.panels = []
        XCTAssertFalse(scene.sharesStorage(with: repaneled))
        var tinted = scene
        tinted.panels[0].color = .one
        XCTAssertFalse(scene.sharesStorage(with: tinted))
        // Equal contents in different storage count as different.
        let rebuilt = SceneData(particles: ParticleData(positions: positions.map { $0 }, styles: [.fallback]))
        XCTAssertTrue(SceneData.empty.sharesStorage(with: SceneData.empty))
        XCTAssertFalse(scene.sharesStorage(with: rebuilt))
    }

    func testArrayIdentity() {
        let a = [1, 2, 3]
        let b = a
        var c = a
        c[0] = 9
        XCTAssertTrue(ArrayIdentity.same(a, b))
        XCTAssertFalse(ArrayIdentity.same(a, c))
        XCTAssertTrue(ArrayIdentity.same([Int](), []))
        XCTAssertTrue(ArrayIdentity.same(nil as [Int]?, nil))
        XCTAssertFalse(ArrayIdentity.same(a as [Int]?, nil))
        XCTAssertFalse(ArrayIdentity.same([1], [1, 2]))
    }

    func testBoxLines() {
        let box = LineData.box(low: SIMD3(-1, -1, -1), high: SIMD3(1, 2, 3), color: .one, width: 3)
        XCTAssertEqual(box.segments.count, 12)
        XCTAssertEqual(box.width, 3)
        let lengths = box.segments.map { simd_length($0.1 - $0.0) }.sorted()
        XCTAssertEqual(lengths, [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4])
        let tilted = LineData.box(origin: .zero, a: SIMD3(1, 0, 0), b: SIMD3(1, 1, 0), c: SIMD3(0, 0, 1), color: .one)
        XCTAssertEqual(tilted.width, 1.5)
        XCTAssertTrue(tilted.segments.contains { $0.0 == SIMD3(1, 0, 0) && $0.1 == SIMD3(2, 1, 0) })
    }

    func testSettingsAndViewDefaults() {
        let settings = RenderSettings()
        XCTAssertEqual(settings.quality, .fast)
        XCTAssertEqual(simd_length(settings.lightDirection), 1, accuracy: 1e-5)
        XCTAssertEqual(settings.radiusScale, 1)
        XCTAssertEqual(settings.nearFade, .zero)
        XCTAssertEqual(RenderQuality.allCases, [.fast, .high])
        XCTAssertEqual(RenderQuality(rawValue: "high"), .high)
        let view = RenderView(viewMatrix: matrix_identity_float4x4, projectionMatrix: matrix_identity_float4x4,
                              viewportSize: SIMD2(10, 20))
        XCTAssertEqual(view.contentScale, 1)
        let scaled = RenderView(viewMatrix: matrix_identity_float4x4, projectionMatrix: matrix_identity_float4x4,
                                viewportSize: SIMD2(10, 20), contentScale: 2)
        XCTAssertEqual(scaled.contentScale, 2)
        XCTAssertEqual(RenderStats(), RenderStats(particlesDrawn: 0, bondsDrawn: 0, gpuTimeMs: 0))
        XCTAssertEqual(SceneData(particles: ParticleData(positions: [], styles: [])).images, [.zero])
    }
}

final class ShaderSourceTests: XCTestCase {
    func testSourceDeclaresEveryFunction() {
        let source = ShaderSource.metal
        for geometry in [ParticleRenderer.Geometry.sphere, .bond, .line, .panel] {
            for pass in [ParticleRenderer.Pass.direct, .gbuffer, .pick] where !(geometry == .line && pass == .pick) {
                let names = ParticleRenderer.functionNames(geometry, pass)
                XCTAssertTrue(source.contains(" \(names.vertex)("), names.vertex)
                XCTAssertTrue(source.contains(" \(names.fragment)("), names.fragment)
            }
        }
        for name in ["fullscreenVertex", "ambientOcclusionFragment", "compositeFragment"] {
            XCTAssertTrue(source.contains(" \(name)("), name)
        }
        XCTAssertEqual(ParticleRenderer.functionNames(.bond, .gbuffer).fragment, "bondGBufferFragment")
        XCTAssertEqual(ParticleRenderer.functionNames(.sphere, .pick).fragment, "spherePickFragment")
        XCTAssertEqual(ParticleRenderer.functionNames(.line, .direct).vertex, "lineVertex")
        XCTAssertEqual(ParticleRenderer.functionNames(.panel, .gbuffer).fragment, "panelFragment")
    }

    func testBufferIndicesMatchTheSource() {
        let source = ShaderSource.metal
        let expectations: [(String, Int)] = [
            ("const device Particle *particles", ShaderSource.BufferIndex.particles),
            ("const device Style *styles", ShaderSource.BufferIndex.styles),
            ("const device float *radii", ShaderSource.BufferIndex.radii),
            ("const device uint *colors", ShaderSource.BufferIndex.colors),
            ("constant ViewUniforms *views", ShaderSource.BufferIndex.views),
            ("constant FrameUniforms &frame", ShaderSource.BufferIndex.frame),
            ("constant DrawUniforms &draw", ShaderSource.BufferIndex.draw),
            ("const device Bond *bonds", ShaderSource.BufferIndex.bonds),
            ("const device uint *bondColors", ShaderSource.BufferIndex.bondColors),
            ("const device LineSegment *segments", ShaderSource.BufferIndex.lines),
            ("const device Panel *panels", ShaderSource.BufferIndex.panels),
        ]
        for (declaration, index) in expectations {
            XCTAssertTrue(source.contains("\(declaration) [[buffer(\(index))]]"), declaration)
        }
        XCTAssertTrue(source.contains("[[function_constant(\(ShaderSource.FunctionConstant.alphaToCoverage))]]"))
        XCTAssertTrue(source.contains("[[function_constant(\(ShaderSource.FunctionConstant.blendedEdges))]]"))
        XCTAssertTrue(source.contains("static float insideDepth(float sphereRadius, float bondRadius)"))
        XCTAssertFalse(source.contains("\\("), "no unexpanded interpolation")
    }
}

final class PickAndFormatTests: XCTestCase {
    func testPickResolver() {
        XCTAssertNil(PickResolver.particleIndex(raw: 0, order: nil, count: 10))
        XCTAssertEqual(PickResolver.particleIndex(raw: 1, order: nil, count: 10), 0)
        XCTAssertEqual(PickResolver.particleIndex(raw: 3, order: [7, 8, 9], count: 3), 9)
        XCTAssertNil(PickResolver.particleIndex(raw: 11, order: nil, count: 10))
        XCTAssertNil(PickResolver.particleIndex(raw: 3, order: [7, 8], count: 3))
    }

    func testPixelFormats() {
        XCTAssertTrue(PixelFormats.hasDepth(.depth32Float))
        XCTAssertTrue(PixelFormats.hasDepth(.depth32Float_stencil8))
        XCTAssertFalse(PixelFormats.hasDepth(.stencil8))
        XCTAssertFalse(PixelFormats.hasDepth(.invalid))
        XCTAssertTrue(PixelFormats.hasStencil(.depth32Float_stencil8))
        XCTAssertFalse(PixelFormats.hasStencil(.depth32Float))
        let descriptor = MTLRenderPipelineDescriptor()
        PixelFormats.apply(.depth32Float_stencil8, to: descriptor)
        XCTAssertEqual(descriptor.depthAttachmentPixelFormat, .depth32Float_stencil8)
        XCTAssertEqual(descriptor.stencilAttachmentPixelFormat, .depth32Float_stencil8)
        PixelFormats.apply(.invalid, to: descriptor)
        XCTAssertEqual(descriptor.depthAttachmentPixelFormat, .invalid)
        XCTAssertEqual(descriptor.stencilAttachmentPixelFormat, .invalid)
    }

    func testLockedValue() {
        let value = LockedValue(1.5)
        value.set(2.5)
        XCTAssertEqual(value.value, 2.5)
        XCTAssertEqual(UncheckedSendable(value: 3).value, 3)
    }
}

final class ParticleViewMathTests: XCTestCase {
    func testPixelConversion() {
        XCTAssertEqual(ParticleViewMath.pixel(fromPoint: SIMD2(10, 20), boundsSize: SIMD2(100, 50),
                                              drawableSize: SIMD2(200, 100)), SIMD2(20, 40))
        XCTAssertEqual(ParticleViewMath.pixel(fromPoint: SIMD2(10, 20), boundsSize: .zero,
                                              drawableSize: SIMD2(200, 100)), SIMD2(10, 20))
        XCTAssertEqual(ParticleViewMath.contentScale(boundsSize: SIMD2(100, 50), drawableSize: SIMD2(200, 100)), 2)
        XCTAssertEqual(ParticleViewMath.contentScale(boundsSize: .zero, drawableSize: SIMD2(200, 100)), 1)
    }

    func testRenderView() {
        let camera = OrbitCamera(distance: 20)
        let view = ParticleViewMath.renderView(camera: camera, drawableSize: SIMD2(400, 200), boundsSize: SIMD2(200, 100))
        XCTAssertEqual(view.viewportSize, SIMD2(400, 200))
        XCTAssertEqual(view.contentScale, 2)
        XCTAssertEqual(view.viewMatrix, camera.viewMatrix)
        // Reverse Z: the target is between 0 and 1, nearer than far.
        let clip = view.projectionMatrix * view.viewMatrix * SIMD4(0, 0, 0, 1)
        XCTAssertGreaterThan(clip.z / clip.w, 0)
        XCTAssertLessThan(clip.z / clip.w, 1)
        XCTAssertEqual(Transforms.nearPlane(of: view.projectionMatrix, reverseZ: true) ?? 0, 0.02, accuracy: 1e-5)
        let square = ParticleViewMath.renderView(camera: camera, drawableSize: .zero, boundsSize: .zero)
        XCTAssertEqual(square.projectionMatrix.columns.0.x, square.projectionMatrix.columns.1.y)
    }

    func testInputHelpers() {
        XCTAssertGreaterThan(ParticleViewMath.zoomFactor(scrollDelta: 10, precise: true), 1)
        XCTAssertLessThan(ParticleViewMath.zoomFactor(scrollDelta: -1, precise: false), 1)
        XCTAssertEqual(ParticleViewMath.zoomFactor(scrollDelta: .nan, precise: true), 1)
        // One fast flick can't jump more than 1.5x.
        XCTAssertEqual(ParticleViewMath.zoomFactor(scrollDelta: 1e4, precise: true), 1.5, accuracy: 1e-4)
        XCTAssertEqual(ParticleViewMath.zoomFactor(scrollDelta: -1e4, precise: false), 1 / 1.5, accuracy: 1e-4)
        XCTAssertTrue(ParticleViewMath.isClick(dragDistance: 1))
        XCTAssertFalse(ParticleViewMath.isClick(dragDistance: 10))
        XCTAssertTrue(ParticleViewMath.shouldReport(now: 1, last: 0.5))
        XCTAssertFalse(ParticleViewMath.shouldReport(now: 1, last: 0.9))
        XCTAssertTrue(ParticleViewMath.shouldReport(now: 0, last: 5))
    }

    func testClickActions() {
        func action(_ count: Int, drag: Float = 0, doubles: Bool = true, interval: Double = 0.4)
            -> ParticleViewMath.ClickAction {
            ParticleViewMath.clickAction(clickCount: count, dragDistance: drag, handlesDoubleClick: doubles,
                                         doubleClickInterval: interval)
        }
        // Without a double-click action, a click picks at once.
        XCTAssertEqual(action(1, doubles: false), .pick(delay: 0))
        XCTAssertEqual(action(2, doubles: false), .none)
        // With one, the first click waits; the second reframes instead.
        XCTAssertEqual(action(1), .pick(delay: 0.4))
        XCTAssertEqual(action(2), .doubleClick)
        XCTAssertEqual(action(3), .none)
        XCTAssertEqual(action(0), .pick(delay: 0.4))
        XCTAssertEqual(action(1, interval: -1), .pick(delay: 0))
        // A drag is never a click.
        XCTAssertEqual(action(1, drag: 10), .none)
        XCTAssertEqual(action(2, drag: 10), .none)
    }

    func testFrameRateFromCountedFrames() {
        XCTAssertEqual(ParticleViewMath.frameRate(frames: 15, elapsed: 0.25), 60, accuracy: 1e-9)
        XCTAssertEqual(ParticleViewMath.frameRate(frames: 0, elapsed: 0.25), 0)
        XCTAssertEqual(ParticleViewMath.frameRate(frames: 3, elapsed: 0), 0)
        XCTAssertEqual(ParticleViewMath.frameRate(frames: 3, elapsed: .infinity), 0)
        XCTAssertEqual(RenderStats(framesPerSecond: 60).framesPerSecond, 60)
    }
}
