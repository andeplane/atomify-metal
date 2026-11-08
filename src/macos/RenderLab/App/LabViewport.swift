import AppKit
import AtomifyRender
import MetalKit
import os
import QuartzCore
import SwiftUI
import simd

/// RenderLab's own view around `ParticleRenderer`, so it can time each
/// step of a frame (jitter, upload, encoding), choose the MSAA sample
/// count, and drive the benchmark camera. Input matches `ParticleView`:
/// drag rotates, right-, option- or shift-drag pans, scroll or pinch zooms,
/// click picks.
struct LabViewport: NSViewRepresentable {
    let model: LabModel
    let sampleCount: Int

    func makeCoordinator() -> LabViewportCoordinator {
        LabViewportCoordinator(model: model)
    }

    func makeNSView(context: Context) -> LabMTKView {
        let view = LabMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let coordinator = context.coordinator
        coordinator.configure(view, sampleCount: sampleCount)
        view.onRotate = { [weak coordinator] in coordinator?.rotate(pointerDelta: $0) }
        view.onPan = { [weak coordinator] in coordinator?.pan(pointerDelta: $0) }
        view.onZoom = { [weak coordinator] in coordinator?.zoom(by: $0) }
        view.onClick = { [weak coordinator] in coordinator?.pick(atPoint: $0) }
        return view
    }

    func updateNSView(_ view: LabMTKView, context: Context) {
        context.coordinator.setSampleCount(sampleCount)
    }

    static func dismantleNSView(_ view: LabMTKView, coordinator: LabViewportCoordinator) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// Owns the renderer, uploads the model's scene, draws, and measures.
/// Lives on the main actor, where MTKView draws and delivers events.
@MainActor
final class LabViewportCoordinator: NSObject, MTKViewDelegate {
    private let model: LabModel
    private weak var view: MTKView?
    private var renderer: ParticleRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private static let logger = Logger(subsystem: "RenderLab", category: "Viewport")

    /// The scene in the renderer's buffers, unless they hold jittered positions.
    private var uploadedScene: SceneData?
    private var jitterBuffer: [SIMD3<Float>] = []
    private var jitterFrame: UInt64 = 0

    private var lastFrameStart: Double?
    private var lastUploadMs: Double?
    private var window: [FrameSample] = []
    private var lastReport: Double = 0

    private var benchmarkStart: Double?
    private var benchmarkStartYaw: Float = 0
    private var benchmarkSamples: [FrameSample] = []

    init(model: LabModel) {
        self.model = model
    }

    func configure(_ view: MTKView, sampleCount: Int) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            report(error: "No Metal device.")
            return
        }
        self.view = view
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = sampleCount
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = self
        commandQueue = device.makeCommandQueue()
        makeRenderer()
    }

    /// A new sample count needs a new renderer (its pipelines are built for one).
    func setSampleCount(_ count: Int) {
        guard let view, count != view.sampleCount else { return }
        view.sampleCount = count
        makeRenderer()
    }

    private func makeRenderer() {
        guard let view, let device = view.device else { return }
        do {
            renderer = try ParticleRenderer(device: device, colorFormat: view.colorPixelFormat,
                                            depthFormat: view.depthStencilPixelFormat,
                                            sampleCount: view.sampleCount, reverseZ: true)
            report(error: nil)
        } catch {
            renderer = nil
            report(error: String(describing: error))
        }
        uploadedScene = nil
        lastFrameStart = nil
    }

    /// Published later: this can run during a SwiftUI view update.
    private func report(error: String?) {
        if let error { Self.logger.error("RenderLab: \(error, privacy: .public)") }
        let model = self.model
        Task { @MainActor in
            if model.rendererError != error { model.rendererError = error }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 { model.viewAspect = Float(size.width / size.height) }
    }

    func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        let interval = lastFrameStart.map { (frameStart - $0) * 1000 }
        lastFrameStart = frameStart
        guard let renderer, let commandQueue else { return }
        renderer.settings = model.renderSettings
        renderer.particleBudget = model.particleBudget.rawValue
        advanceBenchmark(now: frameStart)

        // The drawable first, so waiting for one is not counted as CPU work.
        guard let target = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let workStart = CACurrentMediaTime()

        var jitterMs: Double?
        var uploadMs: Double?
        let scene = model.displayScene
        if model.isAnimating, scene.particles.count > 0 {
            jitterFrame &+= 1
            ThermalJitter.apply(base: scene.particles.positions, amplitude: model.jitterAmplitude,
                                frame: jitterFrame, into: &jitterBuffer)
            jitterMs = (CACurrentMediaTime() - workStart) * 1000
            uploadMs = uploadJittered(scene, renderer: renderer)
            uploadedScene = nil
        } else {
            let unchanged = uploadedScene.map { scene.sharesStorage(with: $0) } ?? false
            if !unchanged {
                uploadMs = Self.timed { renderer.update(scene) }
                uploadedScene = scene
                if !jitterBuffer.isEmpty { jitterBuffer = [] }
            }
        }
        if let uploadMs { lastUploadMs = uploadMs }

        let renderView = ParticleViewMath.renderView(camera: model.camera, drawableSize: drawableSize(view),
                                                     boundsSize: boundsSize(view))
        renderer.encodeFrame(commandBuffer: commandBuffer, target: target, view: renderView)
        commandBuffer.present(drawable)
        commandBuffer.commit()

        let end = CACurrentMediaTime()
        let renderStats = renderer.lastFrameStats
        let sample = FrameSample(intervalMs: interval, cpuMs: (end - workStart) * 1000, jitterMs: jitterMs,
                                 uploadMs: uploadMs, gpuMs: renderStats.gpuTimeMs)
        record(sample, renderStats: renderStats, frameStart: frameStart, now: end)
    }

    /// Uploads `scene` with the jittered positions. The copy that shares
    /// `jitterBuffer` is gone when this returns, so next frame's jitter
    /// writes the buffer in place instead of copying it.
    private func uploadJittered(_ scene: SceneData, renderer: ParticleRenderer) -> Double {
        var moved = scene
        moved.particles.positions = jitterBuffer
        return Self.timed { renderer.update(moved) }
    }

    private static func timed(_ work: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        work()
        return (CACurrentMediaTime() - start) * 1000
    }

    private func record(_ sample: FrameSample, renderStats: RenderStats, frameStart: Double, now: Double) {
        window.append(sample)
        if let start = benchmarkStart, frameStart > start {
            benchmarkSamples.append(sample)
        }
        if ParticleViewMath.shouldReport(now: now, last: lastReport) {
            model.stats = FrameStatistics.live(window, seconds: now - lastReport, lastUploadMs: lastUploadMs,
                                               gpuMs: renderStats.gpuTimeMs,
                                               particlesDrawn: renderStats.particlesDrawn,
                                               bondsDrawn: renderStats.bondsDrawn)
            window.removeAll(keepingCapacity: true)
            lastReport = now
        }
    }

    // MARK: Benchmark

    /// Turns the camera once around the target over the benchmark's
    /// duration, then reports the frames recorded on the way.
    private func advanceBenchmark(now: Double) {
        guard case .running(let seconds) = model.benchmark else {
            benchmarkStart = nil
            benchmarkSamples = []
            return
        }
        guard let start = benchmarkStart else {
            benchmarkStart = now
            benchmarkStartYaw = model.camera.yaw
            benchmarkSamples = []
            return
        }
        let elapsed = now - start
        var camera = model.camera
        camera.yaw = BenchmarkOrbit.yaw(start: benchmarkStartYaw, elapsed: elapsed, duration: seconds)
        model.camera = camera
        guard elapsed >= seconds else { return }
        let drawn = renderer?.lastFrameStats ?? RenderStats()
        if let result = BenchmarkResult.make(samples: benchmarkSamples, seconds: elapsed,
                                             particlesDrawn: drawn.particlesDrawn, bondsDrawn: drawn.bondsDrawn,
                                             label: model.benchmarkLabel) {
            model.benchmark = .finished(result)
        } else {
            model.benchmark = .failed("No frames were recorded.")
        }
        benchmarkStart = nil
        benchmarkSamples = []
    }

    // MARK: Input (pointer deltas in points, x right, y down)

    func rotate(pointerDelta: SIMD2<Float>) {
        var camera = model.camera
        camera.rotate(by: camera.rotationDelta(forPointerMove: pointerDelta, viewHeight: boundsSize(view).y))
        model.camera = camera
    }

    func pan(pointerDelta: SIMD2<Float>) {
        var camera = model.camera
        camera.pan(by: camera.panDelta(forPointerMove: pointerDelta, viewHeight: boundsSize(view).y))
        model.camera = camera
    }

    func zoom(by factor: Float) {
        var camera = model.camera
        camera.zoom(by: factor)
        model.camera = camera
    }

    /// Picks at a point in view coordinates (top-left origin).
    func pick(atPoint point: SIMD2<Float>) {
        guard let renderer, let view else { return }
        let pixel = ParticleViewMath.pixel(fromPoint: point, boundsSize: boundsSize(view),
                                           drawableSize: drawableSize(view))
        let model = self.model
        renderer.pick(at: pixel) { index in
            performOnMain { model.select(index) }
        }
    }

    private func boundsSize(_ view: MTKView?) -> SIMD2<Float> {
        guard let view else { return SIMD2(1, 1) }
        return SIMD2(Float(view.bounds.width), Float(view.bounds.height))
    }

    private func drawableSize(_ view: MTKView) -> SIMD2<Float> {
        SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
    }
}

/// MTKView that forwards mouse and trackpad input (as `ParticleView`'s
/// own view does; that one is internal to the library).
final class LabMTKView: MTKView {
    var onRotate: (@MainActor (SIMD2<Float>) -> Void)?
    var onPan: (@MainActor (SIMD2<Float>) -> Void)?
    var onZoom: (@MainActor (Float) -> Void)?
    var onClick: (@MainActor (SIMD2<Float>) -> Void)?
    private var dragDistance: Float = 0

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = SIMD2(Float(event.deltaX), Float(event.deltaY))
        dragDistance += abs(delta.x) + abs(delta.y)
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            onPan?(delta)
        } else {
            onRotate?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if ParticleViewMath.isClick(dragDistance: dragDistance) {
            onClick?(topLeftPoint(event))
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        onPan?(SIMD2(Float(event.deltaX), Float(event.deltaY)))
    }

    override func otherMouseDragged(with event: NSEvent) {
        onPan?(SIMD2(Float(event.deltaX), Float(event.deltaY)))
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(ParticleViewMath.zoomFactor(scrollDelta: Float(event.scrollingDeltaY),
                                            precise: event.hasPreciseScrollingDeltas))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(max(1 + Float(event.magnification), 0.01))
    }

    private func topLeftPoint(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? p.y : bounds.height - p.y
        return SIMD2(Float(p.x), Float(y))
    }
}
