import ARKit
import AtomifyEngine
import AtomifyKit
import AtomifyVision
import CompositorServices
import Metal
import OSLog
import QuartzCore
import SwiftUI

/// Textures for the lab: both eyes in one layered texture where the system
/// offers it (drawn once with vertex amplification), foveated so what you
/// look at gets full resolution, and depth so passthrough and hands blend
/// correctly with the atoms.
struct LabLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
        let foveation = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveation
        let layouts = capabilities.supportedLayouts(options: foveation ? [.foveationEnabled] : [])
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}

/// Lets the layer cross from the scene closure into the main actor.
struct LabLayer: @unchecked Sendable {
    let renderer: LayerRenderer
}

/// What the main actor hands the render thread. The render thread only
/// reads it, so it never waits for a snapshot to be built.
final class LabMailbox: @unchecked Sendable {
    struct Frame {
        var scene: SceneData?
        var generation: UInt64
        var worldFromSimulation: simd_float4x4
        var highlightColor: SIMD4<Float>
        var isVisible: Bool
    }

    private let lock = NSLock()
    private var frame = Frame(scene: nil, generation: 0, worldFromSimulation: matrix_identity_float4x4,
                              highlightColor: SIMD4(1, 1, 1, 1), isVisible: false)
    private var viewerPose: simd_float4x4?
    private var viewerPoseTime: CFTimeInterval = 0

    /// Keeps the newest scene; an older build never replaces a newer one.
    func publish(_ scene: SceneData?, generation: UInt64) {
        lock.withLock {
            guard generation > frame.generation else { return }
            frame.scene = scene
            frame.generation = generation
        }
    }

    func place(_ worldFromSimulation: simd_float4x4) { lock.withLock { frame.worldFromSimulation = worldFromSimulation } }
    func setHighlightColor(_ color: SIMD4<Float>) { lock.withLock { frame.highlightColor = color } }
    func setVisible(_ visible: Bool) { lock.withLock { frame.isVisible = visible } }
    func read() -> Frame { lock.withLock { frame } }

    /// The compositor's head pose, published by the render thread.
    func publishViewerPose(_ pose: simd_float4x4?) {
        lock.withLock {
            viewerPose = pose
            viewerPoseTime = CACurrentMediaTime()
        }
    }

    func currentViewerPose() -> simd_float4x4? {
        lock.withLock { CACurrentMediaTime() - viewerPoseTime < 0.15 ? viewerPose : nil }
    }
}

/// Builds the renderer's input for each snapshot on a background queue,
/// newest request first, so neither gestures nor the render thread wait on
/// large systems.
final class LabSceneBuilder: @unchecked Sendable {
    struct Request: Sendable {
        var snapshot: SimulationSnapshot
        var styles: AtomStyleTable
        var showsBox: Bool
        var highlight: LabHighlight?
        var generation: UInt64
    }

    private let queue = DispatchQueue(label: "Atomify lab scene builder", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Request?
    private var busy = false
    private let mailbox: LabMailbox

    init(mailbox: LabMailbox) { self.mailbox = mailbox }

    func submit(_ request: Request) {
        let start = lock.withLock { () -> Bool in
            pending = request
            if busy { return false }
            busy = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while let request = lock.withLock({ () -> Request? in
            let next = pending
            pending = nil
            if next == nil { busy = false }
            return next
        }) {
            let scene = LabContent.scene(snapshot: request.snapshot, styles: request.styles,
                                         showsBox: request.showsBox, highlight: request.highlight)
            mailbox.publish(scene, generation: request.generation)
        }
    }
}

/// Draws frames for the layer on its own thread until the space closes,
/// with AtomifyRender's particle renderer: both eyes in one amplified pass
/// on a layered texture (or one pass per eye), reverse Z, 4x multisampling
/// while the GPU keeps up.
final class LabRenderLoop: @unchecked Sendable {
    private let layer: LayerRenderer
    private let mailbox: LabMailbox
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let queue: (any MTLCommandQueue)?
    private let layered: Bool
    private let multisampledRenderer: ParticleRenderer?
    private let singleSampleRenderer: ParticleRenderer?
    private let multisampleCount: Int
    private var multisample: (color: any MTLTexture, depth: any MTLTexture)?
    /// Turned off for good when frames run over budget: dropped frames are
    /// far worse in a headset than slightly softer edges.
    private var usesMultisampling: Bool
    private var overBudget = 0
    private var uploaded: [ObjectIdentifier: UInt64] = [:]
    private let meter = FrameMeter()
    /// GPU time per stereo frame that leaves headroom at 90 Hz.
    private static let budget = 9.5

    private let log = Logger(subsystem: "com.kvakkefly.Atomify", category: "LabRenderLoop")

    private var sampleCount: Int { usesMultisampling ? multisampleCount : 1 }
    private var renderer: ParticleRenderer? { usesMultisampling ? multisampledRenderer : singleSampleRenderer }

    init(layer: LayerRenderer, mailbox: LabMailbox) {
        self.layer = layer
        self.mailbox = mailbox
        let device = layer.device
        queue = device.makeCommandQueue()
        let configuration = layer.configuration
        let wantsLayered = configuration.layout == .layered
        let views = wantsLayered && device.supportsVertexAmplificationCount(2) ? 2 : 1
        layered = views == 2
        multisampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        func make(_ samples: Int) -> ParticleRenderer? {
            guard let renderer = try? ParticleRenderer(device: device, colorFormat: configuration.colorFormat,
                                                       depthFormat: configuration.depthFormat, sampleCount: samples,
                                                       reverseZ: true, maxViews: views) else { return nil }
            renderer.settings = Self.settings
            return renderer
        }
        multisampledRenderer = multisampleCount > 1 ? make(multisampleCount) : nil
        singleSampleRenderer = make(1)
        usesMultisampling = multisampledRenderer != nil
        log.info("Lab renderer: layered=\(self.layered) views=\(views) msaa=\(self.multisampleCount) renderer=\(self.singleSampleRenderer != nil) foveation=\(configuration.isFoveationEnabled)")
    }

    /// Fast quality (one pass, no offscreen targets) with density occlusion
    /// for depth, and nothing closer than 15 cm to the eyes.
    static var settings: RenderSettings {
        var settings = RenderSettings()
        settings.quality = .fast
        settings.background = SIMD4(0, 0, 0, 0)
        settings.densityOcclusion = true
        settings.nearFade = SIMD2(0.15, 0.30)
        return settings
    }

    func run() {
        let session = session, worldTracking = worldTracking
        Task { try? await session.run([worldTracking]) }
        while true {
            switch layer.state {
            case .paused:
                mailbox.publishViewerPose(nil)
                layer.waitUntilRunning()
            case .running:
                autoreleasepool { renderFrame() }
            case .invalidated:
                mailbox.publishViewerPose(nil)
                session.stop()
                return
            @unknown default:
                session.stop()
                return
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate()
        let content = mailbox.read()
        if let renderer, uploaded[ObjectIdentifier(renderer)] != content.generation {
            renderer.update(content.scene ?? .empty)
            uploaded[ObjectIdentifier(renderer)] = content.generation
        }
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let queue, let commandBuffer = queue.makeCommandBuffer() else { return }
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        // Leaving immersion can cancel a frame while waiting for input time;
        // an empty drawable list invalidates the frame, and even
        // endSubmission() then traps. Discard it without touching it again.
        guard !drawables.isEmpty else { return }
        defer { frame.endSubmission() }
        let meter = meter
        commandBuffer.addCompletedHandler { buffer in
            meter.recordGPU(start: buffer.gpuStartTime, end: buffer.gpuEndTime)
        }
        let drawn = content.isVisible ? content.scene?.particles.count ?? 0 : 0
        for drawable in drawables {
            let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime))
            if let report = meter.recordFrame(presentation: time, atoms: drawn) { adapt(to: report) }
            let anchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
            let tracked = anchor.flatMap { $0.isTracked ? $0 : nil }
            drawable.deviceAnchor = tracked
            mailbox.publishViewerPose(tracked?.originFromAnchorTransform)
            // Without a tracked head the frame is cleared: drawing from the
            // origin would put the camera on the floor.
            let views = tracked.map { renderViews(drawable, originFromDevice: $0.originFromAnchorTransform) } ?? []
            let draw = content.isVisible && content.scene != nil && !views.isEmpty
            renderer?.modelMatrix = content.worldFromSimulation
            renderer?.settings.highlightColor = content.highlightColor
            if layered {
                encode(drawable, slice: nil, views: draw ? views : [], commandBuffer: commandBuffer)
            } else {
                for index in drawable.views.indices where index < drawable.colorTextures.count {
                    encode(drawable, slice: index, views: draw && index < views.count ? [views[index]] : [],
                           commandBuffer: commandBuffer)
                }
            }
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        commandBuffer.commit()
    }

    /// One view per eye: world → eye and the compositor's reverse-Z projection.
    private func renderViews(_ drawable: LayerRenderer.Drawable, originFromDevice: simd_float4x4) -> [RenderView] {
        drawable.views.indices.map { index in
            let view = drawable.views[index]
            let viewport = view.textureMap.viewport
            var renderView = RenderView(viewMatrix: (originFromDevice * view.transform).inverse,
                                        projectionMatrix: drawable.computeProjection(convention: .rightUpBack,
                                                                                     viewIndex: index),
                                        viewportSize: SIMD2(Float(viewport.width), Float(viewport.height)))
            // Line widths are in points; the displays are dense.
            renderView.contentScale = 2
            return renderView
        }
    }

    /// One render pass: both eyes into the layered texture (`slice` nil),
    /// or the eye `slice` into its own texture. Empty `views` only clears.
    private func encode(_ drawable: LayerRenderer.Drawable, slice: Int?, views: [RenderView],
                        commandBuffer: any MTLCommandBuffer) {
        let index = slice ?? 0
        let color = drawable.colorTextures[index], depth = drawable.depthTextures[index]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        if layered { pass.renderTargetArrayLength = drawable.views.count }
        let targets = multisampleTargets(matching: color, depth: depth)
        if let targets {
            pass.colorAttachments[0].texture = targets.color
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = targets.depth
            pass.depthAttachment.resolveTexture = depth
            pass.depthAttachment.storeAction = .multisampleResolve
            // Reverse Z: the nearest sample has the largest depth.
            pass.depthAttachment.depthResolveFilter = .max
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.storeAction = .store
        }
        if layer.configuration.isFoveationEnabled, index < drawable.rasterizationRateMaps.count {
            pass.rasterizationRateMap = drawable.rasterizationRateMaps[index]
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Atomify lab"
        if layered {
            encoder.setViewports(drawable.views.map(\.textureMap.viewport))
        } else {
            encoder.setViewport(drawable.views[index].textureMap.viewport)
        }
        // The pipelines expect multisample targets when sampleCount > 1.
        if !views.isEmpty, let renderer, targets != nil || sampleCount == 1 {
            renderer.encode(into: encoder, views: views, commandBuffer: commandBuffer)
        }
        encoder.endEncoding()
    }

    /// Falls back to single-sample rendering after two seconds over budget.
    private func adapt(to report: FrameMeter.Report) {
        guard usesMultisampling, report.atoms > 0 else { return }
        overBudget = report.fits(budget: Self.budget) ? 0 : overBudget + 1
        if overBudget >= 2 {
            usesMultisampling = false
            multisample = nil
        }
    }

    /// Transient (memoryless) multisample color and depth matching the
    /// drawable's textures, recreated when their size changes.
    private func multisampleTargets(matching color: any MTLTexture, depth: any MTLTexture)
        -> (color: any MTLTexture, depth: any MTLTexture)? {
        guard sampleCount > 1 else { return nil }
        if let multisample, multisample.color.width == color.width, multisample.color.height == color.height,
           multisample.color.arrayLength == color.arrayLength {
            return multisample
        }
        func texture(_ format: MTLPixelFormat) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = color.textureType == .type2DArray ? .type2DMultisampleArray : .type2DMultisample
            descriptor.arrayLength = color.textureType == .type2DArray ? color.arrayLength : 1
            descriptor.pixelFormat = format
            descriptor.width = color.width
            descriptor.height = color.height
            descriptor.sampleCount = sampleCount
            descriptor.usage = .renderTarget
            // Memoryless on the headset; the Simulator needs real storage.
            descriptor.storageMode = .memoryless
            if let texture = layer.device.makeTexture(descriptor: descriptor) { return texture }
            descriptor.storageMode = .private
            return layer.device.makeTexture(descriptor: descriptor)
        }
        guard let colorTarget = texture(color.pixelFormat), let depthTarget = texture(depth.pixelFormat) else {
            // No multisample targets at all: draw single-sampled from now on.
            usesMultisampling = false
            return nil
        }
        multisample = (colorTarget, depthTarget)
        return multisample
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
