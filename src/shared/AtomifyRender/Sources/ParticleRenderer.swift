import Foundation
import Metal
import os
import simd

/// Renders SceneData. Upload is cheap to call every frame; it reuses buffers
/// (triple buffered) and only grows them. Not thread safe: use from the render thread.
///
/// Per frame: `update(_:)` (when the scene changed), then either
/// `encodeFrame(commandBuffer:target:view:)` (a whole frame, including the
/// high quality passes) or `encode(into:views:)` (draws into a pass the
/// host owns, e.g. a Vision Pro layer with two views).
public final class ParticleRenderer {
    public enum RendererError: Error, CustomStringConvertible {
        case unsupportedViewCount(Int)
        case missingFunction(String)
        case resourceCreation(String)

        public var description: String {
            switch self {
            case .unsupportedViewCount(let n): return "AtomifyRender: \(n) views are not supported on this device"
            case .missingFunction(let name): return "AtomifyRender: shader function \(name) is missing"
            case .resourceCreation(let what): return "AtomifyRender: could not create \(what)"
            }
        }
    }

    public let device: any MTLDevice
    public let colorFormat: MTLPixelFormat
    public let depthFormat: MTLPixelFormat
    public let sampleCount: Int
    /// Depth 1 near, 0 far (Vision Pro). Projections must match.
    public let reverseZ: Bool
    public let maxViews: Int

    public var settings = RenderSettings()
    /// Model transform from scene units into world.
    public var modelMatrix = matrix_identity_float4x4
    /// Particles drawn per frame, at most, when periodic copies are drawn:
    /// above it, the copies farthest from the eye are drawn with a quarter
    /// (then a sixteenth) of their particles, each larger to fill the same space.
    public var particleBudget = 4_000_000
    /// Vertex amplification mappings for two views. nil maps view i to
    /// render target array slice i and viewport i (layered rendering).
    public var viewMappings: [MTLVertexAmplificationViewMapping]?
    /// Density occlusion is recomputed every this many updates (and
    /// whenever the particle count changes).
    public var occlusionRefreshInterval = 8

    /// Statistics for an overlay.
    public var lastFrameStats: RenderStats {
        RenderStats(particlesDrawn: drawnParticles, bondsDrawn: drawnBonds, gpuTimeMs: gpuTime.value)
    }

    enum Geometry: Hashable { case sphere, bond, line }
    enum Pass: Hashable { case direct, gbuffer, pick }
    struct PipelineKey: Hashable {
        var geometry: Geometry
        var pass: Pass
    }

    private static let logger = Logger(subsystem: "AtomifyRender", category: "ParticleRenderer")
    private static let slotCount = 3

    private let library: any MTLLibrary
    private var offscreenLibraryStorage: (any MTLLibrary)?
    private var pipelines: [PipelineKey: any MTLRenderPipelineState] = [:]
    private var ambientOcclusionPipeline: (any MTLRenderPipelineState)?
    private var compositePipeline: (any MTLRenderPipelineState)?
    private var failedPipelines: Set<String> = []
    private let depthState: any MTLDepthStencilState
    private let alwaysDepthState: any MTLDepthStencilState
    /// Bound wherever an optional buffer is absent, so every binding the
    /// shaders reference is valid.
    private let placeholderBuffer: any MTLBuffer
    private var slots: [FrameSlot]
    /// Slot written by the latest `update`.
    private var currentSlot: Int?
    /// Slot and view of the latest drawn frame, for picking.
    private var lastDrawn: (slot: Int, view: RenderView)?
    private var drawnParticles = 0
    private var drawnBonds = 0
    private let gpuTime = LockedValue<Double>(0)
    private var occlusionCache = (values: [Float](), count: -1, age: 0)
    private var highQualityStorage: HighQualityTargets?
    private var pickTargets: PickTargets?
    private var pickQueue: (any MTLCommandQueue)?
    private let occlusionSamples = AmbientOcclusionKernel.samples(count: 16)

    public init(device: any MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
                sampleCount: Int = 1, reverseZ: Bool = false, maxViews: Int = 1) throws {
        guard maxViews == 1 || (maxViews == 2 && device.supportsVertexAmplificationCount(maxViews)) else {
            throw RendererError.unsupportedViewCount(maxViews)
        }
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = max(sampleCount, 1)
        self.reverseZ = reverseZ
        self.maxViews = maxViews
        library = try Self.makeLibrary(device: device, views: maxViews, reverseZ: reverseZ)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = reverseZ ? .greater : .less
        depth.isDepthWriteEnabled = true
        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth),
              let alwaysDepthState = device.makeDepthStencilState(descriptor: always),
              let placeholder = device.makeBuffer(length: 256, options: .storageModeShared) else {
            throw RendererError.resourceCreation("depth states or placeholder buffer")
        }
        placeholder.label = "AtomifyRender.placeholder"
        self.depthState = depthState
        self.alwaysDepthState = alwaysDepthState
        placeholderBuffer = placeholder
        slots = (0..<Self.slotCount).map { _ in FrameSlot(device: device) }

        // The pipelines every frame needs, so problems surface here.
        for geometry in [Geometry.sphere, .bond, .line] {
            _ = try makePipeline(geometry, .direct)
        }
    }

    // MARK: - Upload

    /// Copies a scene into the next set of buffers. Cost is linear in the
    /// particle and bond counts; buffers are reused and only grow.
    public func update(_ scene: SceneData) {
        let index = ((currentSlot ?? -1) + 1) % slots.count
        let slot = slots[index]
        slot.waitUntilAvailable()

        let particles = scene.particles
        let n = particles.count
        let styles = particles.effectiveStyles
        let images = BlockCulling.normalizedImages(scene.images)
        let layout = SpatialBlocking.layout(positions: particles.positions, images: images.count)
        let ambient = densityAmbient(for: particles, styles: styles)

        let gpuStyles = ParticlePacking.styles(styles)
        if let pointer = slot.styles.pointer(GPUStyle.self, count: gpuStyles.count) {
            gpuStyles.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }
            slot.styleCount = gpuStyles.count
        } else {
            slot.styleCount = 0
        }
        slot.styleTable = styles

        slot.blocks = []
        slot.particleCount = 0
        slot.hasRadii = false
        slot.hasColors = false
        if n > 0, slot.styleCount > 0, let pointer = slot.particles.pointer(GPUParticle.self, count: n) {
            let radii = particles.validRadii == nil ? nil : slot.radii.pointer(Float.self, count: n)
            let colors = particles.validColors == nil ? nil : slot.colors.pointer(UInt32.self, count: n)
            slot.blocks = ParticlePacking.packParticles(particles, styles: styles, layout: layout, ambient: ambient,
                                                        ambientStrength: 1, particles: pointer, radii: radii,
                                                        colors: colors)
            slot.particleCount = n
            slot.hasRadii = radii != nil
            slot.hasColors = colors != nil
        }
        slot.order = layout.order
        slot.images = images

        slot.bondCount = 0
        slot.hasBondColors = false
        if let bonds = scene.bonds, slot.particleCount > 0, !bonds.pairs.isEmpty, bonds.radius > 0,
           let pointer = slot.bonds.pointer(GPUBond.self, count: bonds.pairs.count) {
            let colors = bonds.validColors == nil ? nil : slot.bondColors.pointer(UInt32.self, count: bonds.pairs.count)
            let inverse = layout.order.map { SpatialBlocking.inverse(of: $0) }
            slot.bondCount = ParticlePacking.packBonds(bonds, particleCount: n, inverse: inverse, bonds: pointer,
                                                       colors: colors)
            slot.hasBondColors = colors != nil
            slot.bondRadius = bonds.radius
            slot.bondMaxLength = bonds.maxLength.isFinite ? bonds.maxLength : .greatestFiniteMagnitude
        }

        slot.lineCount = 0
        let segmentCount = ParticlePacking.segmentCount(scene.lines)
        if segmentCount > 0, let pointer = slot.lines.pointer(GPULineSegment.self, count: segmentCount) {
            slot.lineCount = ParticlePacking.packLines(scene.lines, into: pointer)
        }
        currentSlot = index
    }

    /// Density occlusion per original particle index, cached between updates.
    private func densityAmbient(for particles: ParticleData, styles: [ParticleStyle]) -> [Float]? {
        guard settings.densityOcclusion, settings.ambientOcclusionStrength > 0, particles.count > 64 else {
            occlusionCache = ([], -1, 0)
            return nil
        }
        if !DensityOcclusion.needsRefresh(cachedCount: occlusionCache.count, count: particles.count,
                                          age: occlusionCache.age, interval: occlusionRefreshInterval) {
            occlusionCache.age += 1
            return occlusionCache.values.isEmpty ? nil : occlusionCache.values
        }
        let spacing = DensityOcclusion.spacing(styles: styles, radii: particles.validRadii)
        let values = DensityOcclusion.ambient(positions: particles.positions, spacing: spacing)
        occlusionCache = (values, particles.count, 0)
        return values.isEmpty ? nil : values
    }

    // MARK: - Drawing

    /// Draw into an encoder whose pass the caller owns (AVP / custom hosts).
    /// High quality passes (SSAO) need `encodeFrame` instead.
    ///
    /// With two views the draws are amplified (`[[amplification_id]]`
    /// selects the view); the host sets the viewports / array slices.
    /// Pass the command buffer when you have it, so `update` never
    /// overwrites buffers the GPU is still reading even if the host runs
    /// more than two frames ahead.
    public func encode(into encoder: any MTLRenderCommandEncoder, views: [RenderView],
                       commandBuffer: (any MTLCommandBuffer)? = nil) {
        guard let index = currentSlot, let first = views.first else {
            drawnParticles = 0
            drawnBonds = 0
            return
        }
        let slot = slots[index]
        if let commandBuffer { slot.track(commandBuffer) }
        lastDrawn = (index, first)
        let drawn = encodeGeometry(encoder, views: views, pass: .direct, slot: slot)
        drawnParticles = drawn.particles
        drawnBonds = drawn.bonds
    }

    /// Full frame including offscreen passes (SSAO, picking) to `target`.
    /// Clears to `settings.background` when the target's color load action
    /// is `.clear`.
    public func encodeFrame(commandBuffer: any MTLCommandBuffer, target: MTLRenderPassDescriptor,
                            view: RenderView) {
        prepare(target)
        let gpuTime = self.gpuTime
        commandBuffer.addCompletedHandler { buffer in
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            if milliseconds > 0 { gpuTime.set(milliseconds) }
        }
        if settings.quality == .high, encodeHighQuality(commandBuffer: commandBuffer, target: target, view: view) {
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: target) else { return }
        encoder.label = "AtomifyRender.frame"
        encode(into: encoder, views: [view], commandBuffer: commandBuffer)
        encoder.endEncoding()
    }

    private func prepare(_ target: MTLRenderPassDescriptor) {
        if let color = target.colorAttachments[0], color.loadAction == .clear {
            let b = settings.background
            color.clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y), blue: Double(b.z), alpha: Double(b.w))
        }
        if let depth = target.depthAttachment, depth.loadAction == .clear {
            depth.clearDepth = reverseZ ? 0 : 1
        }
    }

    func makeViewUniforms(_ view: RenderView) -> ViewUniforms {
        let modelView = view.viewMatrix * modelMatrix
        let near = Transforms.nearPlane(of: view.projectionMatrix, reverseZ: reverseZ) ?? 1e-3
        var light = settings.lightDirection
        light = simd_length_squared(light) > 1e-12 ? simd_normalize(light) : SIMD3(0, 0, 1)
        return ViewUniforms(modelView: modelView, projection: view.projectionMatrix,
                            lightDirection: SIMD4(light, max(view.contentScale, 1e-3)),
                            params: SIMD4(Transforms.uniformScale(of: modelView), near,
                                          view.viewportSize.x, view.viewportSize.y))
    }

    private func makeFrameUniforms(_ slot: FrameSlot) -> FrameUniforms {
        FrameUniforms(highlightColor: settings.highlightColor,
                      nearFade: SIMD4(settings.nearFade.x, settings.nearFade.y,
                                      ParticlePacking.highlightRadiusScale,
                                      min(max(settings.ambientOcclusionStrength, 0), 1)),
                      bond: SIMD4(slot.bondRadius, slot.bondMaxLength, 0, 0),
                      options: SIMD4(slot.hasRadii ? 1 : 0, slot.hasColors ? 1 : 0, slot.hasBondColors ? 1 : 0,
                                     UInt32(max(slot.styleCount, 1))))
    }

    /// Encodes particles, bonds and lines of `slot`. Returns the particle
    /// and bond instances drawn (all views).
    @discardableResult
    private func encodeGeometry(_ encoder: any MTLRenderCommandEncoder, views: [RenderView], pass: Pass,
                                slot: FrameSlot) -> (particles: Int, bonds: Int) {
        let views = Array(views.prefix(pass == .direct ? maxViews : 1))
        guard !views.isEmpty, slot.styleCount > 0,
              let styles = slot.styles.buffer else { return (0, 0) }
        var viewUniforms = views.map { makeViewUniforms($0) }
        var frame = makeFrameUniforms(slot)

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        if views.count > 1 {
            var mappings = viewMappings ?? (0..<views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(views.count, viewMappings: &mappings)
        }
        let viewLength = MemoryLayout<ViewUniforms>.stride * viewUniforms.count
        encoder.setVertexBytes(&viewUniforms, length: viewLength, index: ShaderSource.BufferIndex.views)
        encoder.setFragmentBytes(&viewUniforms, length: viewLength, index: ShaderSource.BufferIndex.views)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: ShaderSource.BufferIndex.frame)
        encoder.setVertexBuffer(slot.particles.buffer ?? placeholderBuffer, offset: 0,
                                index: ShaderSource.BufferIndex.particles)
        encoder.setVertexBuffer(styles, offset: 0, index: ShaderSource.BufferIndex.styles)
        encoder.setVertexBuffer(slot.hasRadii ? slot.radii.buffer ?? placeholderBuffer : placeholderBuffer,
                                offset: 0, index: ShaderSource.BufferIndex.radii)
        encoder.setVertexBuffer(slot.hasColors ? slot.colors.buffer ?? placeholderBuffer : placeholderBuffer,
                                offset: 0, index: ShaderSource.BufferIndex.colors)

        func setDraw(offset: SIMD3<Float>, radiusFactor: Float) {
            var draw = DrawUniforms(offset: SIMD4(offset, radiusFactor))
            encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: ShaderSource.BufferIndex.draw)
        }

        var particlesDrawn = 0, bondsDrawn = 0
        let radiusScale = settings.radiusScale.isFinite ? max(settings.radiusScale, 0) : 1
        var fullDetailImages = Set<Int>()
        if slot.particleCount > 0, let spheres = pipeline(.sphere, pass) {
            let modelViews = viewUniforms.map(\.modelView)
            let projections = viewUniforms.map(\.projection)
            let draws = BlockCulling.draws(blocks: slot.blocks, images: slot.images, modelViews: modelViews,
                                           projections: projections,
                                           radiusScale: radiusScale * (slot.images.count > 1 ? 4 : 1),
                                           budget: slot.images.count > 1 ? particleBudget : .max)
            encoder.setRenderPipelineState(spheres)
            var current: (image: Int, detail: Int)?
            for draw in draws {
                if current?.image != draw.image || current?.detail != draw.detail {
                    current = (draw.image, draw.detail)
                    setDraw(offset: slot.images[draw.image],
                            radiusFactor: radiusScale * BlockCulling.Draw.radiusScale(detail: draw.detail))
                }
                if draw.detail == 0 { fullDetailImages.insert(draw.image) }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: draw.count, baseInstance: draw.block.start)
                particlesDrawn += draw.count
            }
        }

        if slot.bondCount > 0, let bondBuffer = slot.bonds.buffer, !fullDetailImages.isEmpty,
           let cylinders = pipeline(.bond, pass) {
            encoder.setRenderPipelineState(cylinders)
            encoder.setVertexBuffer(bondBuffer, offset: 0, index: ShaderSource.BufferIndex.bonds)
            encoder.setVertexBuffer(slot.hasBondColors ? slot.bondColors.buffer ?? placeholderBuffer : placeholderBuffer,
                                    offset: 0, index: ShaderSource.BufferIndex.bondColors)
            // Bonds go with every copy drawn in full; thinned copies have none.
            for image in fullDetailImages.sorted() {
                setDraw(offset: slot.images[image], radiusFactor: radiusScale)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                       vertexCount: 4, instanceCount: slot.bondCount)
                bondsDrawn += slot.bondCount
            }
        }

        if pass != .pick, slot.lineCount > 0, let lineBuffer = slot.lines.buffer, let lines = pipeline(.line, pass) {
            encoder.setRenderPipelineState(lines)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: ShaderSource.BufferIndex.lines)
            setDraw(offset: .zero, radiusFactor: radiusScale)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: slot.lineCount)
        }

        if views.count > 1 {
            encoder.setVertexAmplificationCount(1, viewMappings: nil)
        }
        return (particlesDrawn * views.count, bondsDrawn * views.count)
    }

    // MARK: - High quality

    /// Geometry into offscreen color + normal/depth, occlusion at half
    /// resolution, then a composite (blurred occlusion, outlines) into
    /// `target`. False when the passes could not be set up; the caller
    /// then draws the fast path.
    private func encodeHighQuality(commandBuffer: any MTLCommandBuffer, target: MTLRenderPassDescriptor,
                                   view: RenderView) -> Bool {
        guard let index = currentSlot else { return false }
        let slot = slots[index]
        let width = target.colorAttachments[0].texture?.width ?? Int(view.viewportSize.x)
        let height = target.colorAttachments[0].texture?.height ?? Int(view.viewportSize.y)
        guard width > 0, height > 0,
              pipeline(.sphere, .gbuffer) != nil,
              let ssao = makeAmbientOcclusionPipeline(), let composite = makeCompositePipeline(),
              let targets = highQualityTargets(width: width, height: height) else { return false }

        // 1. Geometry.
        let geometryPass = MTLRenderPassDescriptor()
        let multisampled = sampleCount > 1
        let b = settings.background
        geometryPass.colorAttachments[0].texture = multisampled ? targets.multisampleColor : targets.color
        geometryPass.colorAttachments[0].resolveTexture = multisampled ? targets.color : nil
        geometryPass.colorAttachments[0].loadAction = .clear
        geometryPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y),
                                                                    blue: Double(b.z), alpha: Double(b.w))
        geometryPass.colorAttachments[0].storeAction = multisampled ? .multisampleResolve : .store
        geometryPass.colorAttachments[1].texture = multisampled ? targets.multisampleNormalDepth : targets.normalDepth
        geometryPass.colorAttachments[1].resolveTexture = multisampled ? targets.normalDepth : nil
        geometryPass.colorAttachments[1].loadAction = .clear
        geometryPass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        geometryPass.colorAttachments[1].storeAction = multisampled ? .multisampleResolve : .store
        geometryPass.depthAttachment.texture = targets.depth
        geometryPass.depthAttachment.loadAction = .clear
        geometryPass.depthAttachment.clearDepth = reverseZ ? 0 : 1
        geometryPass.depthAttachment.storeAction = .dontCare
        guard let geometry = commandBuffer.makeRenderCommandEncoder(descriptor: geometryPass) else { return false }
        geometry.label = "AtomifyRender.geometry"
        slot.track(commandBuffer)
        lastDrawn = (index, view)
        let drawn = encodeGeometry(geometry, views: [view], pass: .gbuffer, slot: slot)
        geometry.endEncoding()
        drawnParticles = drawn.particles
        drawnBonds = drawn.bonds

        // 2. Occlusion.
        let strength = max(settings.ambientOcclusionStrength, 0)
        let scale = Transforms.uniformScale(of: view.viewMatrix * modelMatrix)
        let radius = AmbientOcclusionKernel.radius(requested: settings.ambientOcclusionRadius,
                                                   styles: slot.styleTable) * scale
        let fullSize = SIMD2<Float>(Float(width), Float(height))
        let occlusionSize = SIMD2<Float>(Float(targets.occlusion.width), Float(targets.occlusion.height))
        if strength > 0 {
            let occlusionPass = MTLRenderPassDescriptor()
            occlusionPass.colorAttachments[0].texture = targets.occlusion
            occlusionPass.colorAttachments[0].loadAction = .dontCare
            occlusionPass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: occlusionPass) {
                encoder.label = "AtomifyRender.ambientOcclusion"
                var uniforms = SSAOUniforms(projection: view.projectionMatrix,
                                            params: SIMD4(radius, 2 * strength, 0.002, Float(occlusionSamples.count)),
                                            screen: SIMD4(lowHalf: fullSize, highHalf: occlusionSize))
                encoder.setRenderPipelineState(ssao)
                encoder.setFragmentTexture(targets.normalDepth, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SSAOUniforms>.stride, index: 0)
                occlusionSamples.withUnsafeBytes {
                    encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        // 3. Composite into the target.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: target) else { return true }
        encoder.label = "AtomifyRender.composite"
        var uniforms = CompositeUniforms(params: SIMD4(max(settings.outlineWidth, 0), 0.3 * radius, 0.85,
                                                       strength > 0 ? 1 : 0),
                                         sizes: SIMD4(lowHalf: fullSize, highHalf: occlusionSize),
                                         outlineColor: SIMD4(0, 0, 0, 1))
        encoder.setRenderPipelineState(composite)
        encoder.setDepthStencilState(alwaysDepthState)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(targets.color, index: 0)
        encoder.setFragmentTexture(targets.normalDepth, index: 1)
        encoder.setFragmentTexture(targets.occlusion, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func highQualityTargets(width: Int, height: Int) -> HighQualityTargets? {
        if let targets = highQualityStorage, targets.width == width, targets.height == height {
            return targets
        }
        highQualityStorage = HighQualityTargets(device: device, width: width, height: height,
                                                colorFormat: colorFormat, sampleCount: sampleCount)
        return highQualityStorage
    }

    // MARK: - Picking

    /// Index of the particle at a pixel (top-left origin), or nil. Resolved from the
    /// ID buffer of the last frame; completion is called on the main queue.
    ///
    /// Renders particle IDs (and bonds, which hide what is behind them)
    /// for the one pixel under `pixel` with the last frame's view and
    /// buffers, on the renderer's own queue, and reads the result back.
    public func pick(at pixel: SIMD2<Float>, completion: @escaping @Sendable (Int?) -> Void) {
        guard let drawn = lastDrawn, slots[drawn.slot].particleCount > 0,
              pixel.x.isFinite, pixel.y.isFinite,
              let commandBuffer = pickCommandQueue()?.makeCommandBuffer(),
              let targets = pickTargetsIfPossible(),
              let readback = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let slot = slots[drawn.slot]
        var pickView = drawn.view
        pickView.projectionMatrix = Transforms.pickMatrix(pixel: pixel, viewport: drawn.view.viewportSize)
            * drawn.view.projectionMatrix

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.id
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = reverseZ ? 0 : 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        encoder.label = "AtomifyRender.pick"
        encodeGeometry(encoder, views: [pickView], pass: .pick, slot: slot)
        encoder.endEncoding()
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: targets.id, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 0,
                      destinationBytesPerRow: MemoryLayout<UInt32>.stride,
                      destinationBytesPerImage: MemoryLayout<UInt32>.stride)
            blit.endEncoding()
        }
        let order = slot.order
        let count = slot.particleCount
        let result = UncheckedSendable(value: readback)
        commandBuffer.addCompletedHandler { buffer in
            let raw = buffer.status == .completed ? result.value.contents().load(as: UInt32.self) : 0
            let picked = PickResolver.particleIndex(raw: raw, order: order, count: count)
            DispatchQueue.main.async { completion(picked) }
        }
        slot.track(commandBuffer)
        commandBuffer.commit()
    }

    private func pickCommandQueue() -> (any MTLCommandQueue)? {
        if pickQueue == nil {
            pickQueue = device.makeCommandQueue()
            pickQueue?.label = "AtomifyRender.pick"
        }
        return pickQueue
    }

    private func pickTargetsIfPossible() -> PickTargets? {
        if pickTargets == nil { pickTargets = PickTargets(device: device) }
        return pickTargets
    }

    // MARK: - Pipelines

    static func makeLibrary(device: any MTLDevice, views: Int, reverseZ: Bool) throws -> any MTLLibrary {
        let options = MTLCompileOptions()
        options.preprocessorMacros = [
            "MAX_VIEWS": NSNumber(value: views),
            "REVERSE_Z": NSNumber(value: reverseZ ? 1 : 0),
        ]
        return try device.makeLibrary(source: ShaderSource.metal, options: options)
    }

    /// The single-view library for offscreen passes (the main library when
    /// it is single-view already).
    private func offscreenLibrary() throws -> any MTLLibrary {
        if maxViews == 1 { return library }
        if let offscreenLibraryStorage { return offscreenLibraryStorage }
        let made = try Self.makeLibrary(device: device, views: 1, reverseZ: reverseZ)
        offscreenLibraryStorage = made
        return made
    }

    static func functionNames(_ geometry: Geometry, _ pass: Pass) -> (vertex: String, fragment: String) {
        let prefix: String
        switch geometry {
        case .sphere: prefix = "sphere"
        case .bond: prefix = "bond"
        case .line: prefix = "line"
        }
        let suffix: String
        switch pass {
        case .direct: suffix = "Fragment"
        case .gbuffer: suffix = "GBufferFragment"
        case .pick: suffix = "PickFragment"
        }
        return (prefix + "Vertex", prefix + suffix)
    }

    /// The pipeline, or nil (logged once) when it cannot be made.
    private func pipeline(_ geometry: Geometry, _ pass: Pass) -> (any MTLRenderPipelineState)? {
        do {
            return try makePipeline(geometry, pass)
        } catch {
            let key = "\(geometry)-\(pass)"
            if failedPipelines.insert(key).inserted {
                Self.logger.error("AtomifyRender: pipeline \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    private func makePipeline(_ geometry: Geometry, _ pass: Pass) throws -> any MTLRenderPipelineState {
        let key = PipelineKey(geometry: geometry, pass: pass)
        if let cached = pipelines[key] { return cached }
        let lib = pass == .direct ? library : try offscreenLibrary()
        let multisampled = pass != .pick && sampleCount > 1
        // Without multisampling, lines blend their soft edges instead.
        let blended = geometry == .line && pass == .direct && !multisampled
        let constants = MTLFunctionConstantValues()
        var alphaToCoverage = multisampled
        var blendedEdges = blended
        constants.setConstantValue(&alphaToCoverage, type: .bool, index: ShaderSource.FunctionConstant.alphaToCoverage)
        constants.setConstantValue(&blendedEdges, type: .bool, index: ShaderSource.FunctionConstant.blendedEdges)
        let names = Self.functionNames(geometry, pass)
        let vertex = try lib.makeFunction(name: names.vertex, constantValues: constants)
        let fragment = try lib.makeFunction(name: names.fragment, constantValues: constants)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "AtomifyRender.\(names.fragment)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        switch pass {
        case .direct:
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            PixelFormats.apply(depthFormat, to: descriptor)
            descriptor.rasterSampleCount = sampleCount
            if maxViews > 1 { descriptor.maxVertexAmplificationCount = maxViews }
        case .gbuffer:
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.colorAttachments[1].pixelFormat = .rgba16Float
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = sampleCount
        case .pick:
            descriptor.colorAttachments[0].pixelFormat = .r32Uint
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = 1
        }
        if multisampled {
            // Alpha carries edge coverage; covered samples are opaque.
            descriptor.isAlphaToCoverageEnabled = true
            descriptor.isAlphaToOneEnabled = true
        }
        if blended, let color = descriptor.colorAttachments[0] {
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = state
        return state
    }

    private func makeAmbientOcclusionPipeline() -> (any MTLRenderPipelineState)? {
        if let ambientOcclusionPipeline { return ambientOcclusionPipeline }
        do {
            let lib = try offscreenLibrary()
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "AtomifyRender.ambientOcclusion"
            descriptor.vertexFunction = lib.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = lib.makeFunction(name: "ambientOcclusionFragment")
            descriptor.colorAttachments[0].pixelFormat = .rg16Float
            ambientOcclusionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            if failedPipelines.insert("ambientOcclusion").inserted {
                Self.logger.error("AtomifyRender: occlusion pipeline failed: \(String(describing: error), privacy: .public)")
            }
        }
        return ambientOcclusionPipeline
    }

    private func makeCompositePipeline() -> (any MTLRenderPipelineState)? {
        if let compositePipeline { return compositePipeline }
        do {
            let lib = try offscreenLibrary()
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "AtomifyRender.composite"
            descriptor.vertexFunction = lib.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = lib.makeFunction(name: "compositeFragment")
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            PixelFormats.apply(depthFormat, to: descriptor)
            descriptor.rasterSampleCount = sampleCount
            compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            if failedPipelines.insert("composite").inserted {
                Self.logger.error("AtomifyRender: composite pipeline failed: \(String(describing: error), privacy: .public)")
            }
        }
        return compositePipeline
    }
}
