import Metal
import simd
import XCTest
@testable import AtomifyRender

/// End-to-end checks on a real GPU: the shaders compile, a sphere lands
/// where the camera says, picking finds it, and every path runs without
/// validation errors. Skipped where there is no Metal device.
final class RendererGPUTests: XCTestCase {
    private let size = 64
    private let background = SIMD4<Float>(0, 0, 0, 1)

    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        return device
    }

    private func renderView(distance: Float = 5, reverseZ: Bool = false) -> RenderView {
        let camera = OrbitCamera(distance: distance)
        return RenderView(viewMatrix: camera.viewMatrix,
                          projectionMatrix: camera.projectionMatrix(aspect: 1, near: 0.1, far: 100, reverseZ: reverseZ),
                          viewportSize: SIMD2(Float(size), Float(size)))
    }

    private func scene(colors: [SIMD4<Float>]? = nil) -> SceneData {
        let red = ParticleStyle(radius: 1, color: SIMD4(1, 0, 0, 1))
        let blue = ParticleStyle(radius: 0.5, color: SIMD4(0, 0, 1, 1))
        let particles = ParticleData(positions: [SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(0, 0, -50)],
                                     styleIndices: [0, 1, 1], styles: [red, blue], colors: colors)
        return SceneData(particles: particles,
                         bonds: BondData(pairs: [SIMD2(0, 1)], radius: 0.2),
                         lines: [LineData.box(low: SIMD3(repeating: -2), high: SIMD3(repeating: 2),
                                              color: SIMD4(1, 1, 1, 1))])
    }

    /// Renders one frame and returns RGBA8 pixels (row-major, top row first).
    private func render(_ renderer: ParticleRenderer, view: RenderView) throws -> [UInt8] {
        let device = renderer.device
        let sampleCount = renderer.sampleCount
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size,
                                                                       height: size, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        let color = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size,
                                                                       height: size, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        if sampleCount > 1 {
            depthDescriptor.textureType = .type2DMultisample
            depthDescriptor.sampleCount = sampleCount
        }
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))

        let pass = MTLRenderPassDescriptor()
        if sampleCount > 1 {
            let msaaDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size,
                                                                          height: size, mipmapped: false)
            msaaDescriptor.textureType = .type2DMultisample
            msaaDescriptor.sampleCount = sampleCount
            msaaDescriptor.usage = .renderTarget
            msaaDescriptor.storageMode = .private
            pass.colorAttachments[0].texture = try XCTUnwrap(device.makeTexture(descriptor: msaaDescriptor))
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.encodeFrame(commandBuffer: commandBuffer, target: pass, view: view)
        let readback = try XCTUnwrap(device.makeBuffer(length: size * size * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size, height: size, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        let bytes = readback.contents().bindMemory(to: UInt8.self, capacity: size * size * 4)
        return Array(UnsafeBufferPointer(start: bytes, count: size * size * 4))
    }

    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> SIMD4<UInt8> {
        let i = (y * size + x) * 4
        return SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    private func makeRenderer(_ device: any MTLDevice, sampleCount: Int = 1, reverseZ: Bool = false,
                              quality: RenderQuality = .fast) throws -> ParticleRenderer {
        let renderer = try ParticleRenderer(device: device, colorFormat: .rgba8Unorm, depthFormat: .depth32Float,
                                            sampleCount: sampleCount, reverseZ: reverseZ)
        renderer.settings.background = background
        renderer.settings.quality = quality
        return renderer
    }

    func testFastFrameDrawsTheSphereAtTheCenter() throws {
        let renderer = try makeRenderer(try device())
        renderer.update(scene())
        let pixels = try render(renderer, view: renderView())
        let center = pixel(pixels, size / 2, size / 2)
        XCTAssertGreaterThan(center.x, 60, "red sphere in the middle: \(center)")
        XCTAssertLessThan(center.z, center.x)
        XCTAssertEqual(pixel(pixels, 1, size / 2), SIMD4(0, 0, 0, 255), "background at the left edge")
        let stats = renderer.lastFrameStats
        XCTAssertEqual(stats.particlesDrawn, 3)
        XCTAssertEqual(stats.bondsDrawn, 1)
    }

    /// A wall in front of the sphere tints it; one behind it is hidden
    /// where the sphere is and shows over the background.
    private func checkPanels(_ renderer: ParticleRenderer, view: RenderView) throws {
        let wall = SIMD4<Float>(0, 1, 0, 0.5)
        var base = scene()
        base.lines = []
        var front = base
        front.panels = [PanelData.box(low: SIMD3(-3, -3, 2), high: SIMD3(3, 3, 2), color: wall)]
        renderer.update(front)
        let tinted = try render(renderer, view: view)
        var behind = base
        behind.panels = [PanelData.box(low: SIMD3(-3, -3, -2), high: SIMD3(3, 3, -2), color: wall)]
        renderer.update(behind)
        let hidden = try render(renderer, view: view)
        renderer.update(base)
        let plain = try render(renderer, view: view)

        let center = (tinted: pixel(tinted, size / 2, size / 2), hidden: pixel(hidden, size / 2, size / 2),
                      plain: pixel(plain, size / 2, size / 2))
        XCTAssertGreaterThan(Int(center.tinted.y), Int(center.plain.y) + 40, "wall in front: \(center)")
        XCTAssertEqual(center.hidden, center.plain, "wall behind the sphere")
        // Off the sphere, inside the wall: green over the background either way.
        XCTAssertGreaterThan(pixel(hidden, 4, 4).y, 40)
        XCTAssertEqual(pixel(plain, 4, 4).y, 0)
    }

    func testPanelsFast() throws {
        try checkPanels(try makeRenderer(try device()), view: renderView())
    }

    func testPanelsMultisampleAndHighQuality() throws {
        let device = try device()
        guard device.supportsTextureSampleCount(4) else { throw XCTSkip("No 4x MSAA") }
        try checkPanels(try makeRenderer(device, sampleCount: 4), view: renderView())
        try checkPanels(try makeRenderer(device, sampleCount: 4, quality: .high), view: renderView())
        try checkPanels(try makeRenderer(device, quality: .high), view: renderView())
    }

    func testReverseZMultisampleAndOverrides() throws {
        let device = try device()
        guard device.supportsTextureSampleCount(4) else { throw XCTSkip("No 4x MSAA") }
        let renderer = try makeRenderer(device, sampleCount: 4, reverseZ: true)
        let green = SIMD4<Float>(0, 1, 0, 1)
        renderer.update(scene(colors: [green, green, green]))
        let pixels = try render(renderer, view: renderView(reverseZ: true))
        let center = pixel(pixels, size / 2, size / 2)
        XCTAssertGreaterThan(center.y, center.x, "per-particle color wins: \(center)")
    }

    func testHighQualityFrame() throws {
        let renderer = try makeRenderer(try device(), quality: .high)
        renderer.settings.outlineWidth = 1.5
        renderer.update(scene())
        let pixels = try render(renderer, view: renderView())
        let center = pixel(pixels, size / 2, size / 2)
        XCTAssertGreaterThan(center.x, 40, "composited sphere: \(center)")
        XCTAssertEqual(pixel(pixels, 1, size / 2), SIMD4(0, 0, 0, 255))
        XCTAssertEqual(renderer.lastFrameStats.particlesDrawn, 3)
    }

    func testHighQualityMultisampleFrame() throws {
        let device = try device()
        guard device.supportsTextureSampleCount(4) else { throw XCTSkip("No 4x MSAA") }
        let renderer = try makeRenderer(device, sampleCount: 4, reverseZ: true, quality: .high)
        renderer.update(scene())
        let pixels = try render(renderer, view: renderView(reverseZ: true))
        XCTAssertGreaterThan(pixel(pixels, size / 2, size / 2).x, 40)
    }

    /// Picks and waits (running the main run loop, where completion is
    /// delivered) for the answer.
    private func pick(_ renderer: ParticleRenderer, at pixel: SIMD2<Float>) -> Int?? {
        let result = LockedValue<Int??>(nil)
        renderer.pick(at: pixel) { index in result.set(.some(index)) }
        let deadline = Date().addingTimeInterval(5)
        while result.value == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return result.value
    }

    func testPickFindsTheParticleUnderThePixel() throws {
        let renderer = try makeRenderer(try device())
        renderer.update(scene())
        _ = try render(renderer, view: renderView())
        let hit = pick(renderer, at: SIMD2(Float(size) / 2, Float(size) / 2))
        XCTAssertEqual(hit, .some(0), "the sphere in the middle")
        let miss = pick(renderer, at: SIMD2(1, Float(size) - 1))
        XCTAssertEqual(miss, .some(nil), "background at the left edge")
    }

    func testPickBeforeAnyFrameIsNil() throws {
        let renderer = try makeRenderer(try device())
        XCTAssertEqual(pick(renderer, at: .zero), .some(nil))
    }

    func testLargeSceneWithImagesAndFlags() throws {
        let renderer = try makeRenderer(try device())
        let positions = SpatialBlockingTests.positions(60_000, size: 4).map { $0 - 2 }
        var flags = [UInt8](repeating: 0, count: positions.count)
        flags[0] = ParticleFlags.selected
        flags[1] = ParticleFlags.hidden
        let particles = ParticleData(positions: positions, styles: [ParticleStyle(radius: 0.05, color: .one)],
                                     radii: [Float](repeating: 0.05, count: positions.count), flags: flags)
        let pairs = (0..<1_000).map { SIMD2<UInt32>(UInt32($0), UInt32($0 + 1)) }
        var bonds = BondData(pairs: pairs, radius: 0.01, colors: [SIMD4<Float>](repeating: .one, count: pairs.count))
        bonds.maxLength = 1
        let images: [SIMD3<Float>] = [.zero, SIMD3(4, 0, 0), SIMD3(-4, 0, 0)]
        renderer.particleBudget = 100_000
        renderer.update(SceneData(particles: particles, bonds: bonds, images: images))
        _ = try render(renderer, view: renderView(distance: 12))
        let stats = renderer.lastFrameStats
        XCTAssertGreaterThan(stats.particlesDrawn, 60_000)
        XCTAssertLessThanOrEqual(stats.particlesDrawn, 180_000)
        // Updating again reuses (and here keeps) the buffers in the next slot.
        renderer.update(SceneData(particles: particles))
        _ = try render(renderer, view: renderView(distance: 12))
        XCTAssertEqual(renderer.lastFrameStats.bondsDrawn, 0)
    }

    func testEmptySceneAndNoUpdate() throws {
        let renderer = try makeRenderer(try device())
        _ = try render(renderer, view: renderView())
        XCTAssertEqual(renderer.lastFrameStats.particlesDrawn, 0)
        renderer.update(.empty)
        let pixels = try render(renderer, view: renderView())
        XCTAssertEqual(pixel(pixels, size / 2, size / 2), SIMD4(0, 0, 0, 255))
    }

    func testTwoViewsWhenSupported() throws {
        let device = try device()
        guard device.supportsVertexAmplificationCount(2) else {
            XCTAssertThrowsError(try ParticleRenderer(device: device, colorFormat: .rgba8Unorm,
                                                      depthFormat: .depth32Float, maxViews: 2))
            return
        }
        let renderer = try ParticleRenderer(device: device, colorFormat: .rgba8Unorm, depthFormat: .depth32Float,
                                            maxViews: 2)
        renderer.update(scene())
        // Two array slices, one per view.
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size,
                                                                       height: size, mipmapped: false)
        colorDescriptor.textureType = .type2DArray
        colorDescriptor.arrayLength = 2
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size,
                                                                       height: size, mipmapped: false)
        depthDescriptor.textureType = .type2DArray
        depthDescriptor.arrayLength = 2
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.renderTargetArrayLength = 2
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(size), height: Double(size), znear: 0, zfar: 1)
        encoder.setViewports([viewport, viewport])
        var left = renderView(), right = renderView()
        left.viewMatrix = Transforms.translation(SIMD3(0.03, 0, 0)) * left.viewMatrix
        right.viewMatrix = Transforms.translation(SIMD3(-0.03, 0, 0)) * right.viewMatrix
        renderer.encode(into: encoder, views: [left, right], commandBuffer: commandBuffer)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        XCTAssertEqual(renderer.lastFrameStats.particlesDrawn, 6)
    }
}
