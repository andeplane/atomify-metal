#if os(macOS) || os(iOS)
import MetalKit
import os
import QuartzCore
import SwiftUI
import simd
#if os(iOS)
import UIKit
#endif

/// SwiftUI view hosting an MTKView with an OrbitCamera: drag rotates,
/// right/two-finger drag pans, scroll/pinch zooms, click/tap picks.
/// Option- or shift-drag also pans on macOS.
public struct ParticleView: View {
    private let scene: SceneData?
    @Binding private var camera: OrbitCamera
    private let settings: RenderSettings
    private let onPick: ((Int?) -> Void)?
    private let onStats: ((RenderStats) -> Void)?

    public init(scene: SceneData?, camera: Binding<OrbitCamera>, settings: RenderSettings,
                onPick: ((Int?) -> Void)? = nil, onStats: ((RenderStats) -> Void)? = nil) {
        self.scene = scene
        _camera = camera
        self.settings = settings
        self.onPick = onPick
        self.onStats = onStats
    }

    public var body: some View {
        ParticleViewRepresentable(scene: scene, camera: $camera, settings: settings, onPick: onPick,
                                  onStats: onStats)
    }
}

/// Owns the renderer and turns input into camera changes. Lives on the
/// main actor, where MTKView draws and delivers events.
@MainActor
final class ParticleViewCoordinator: NSObject, @preconcurrency MTKViewDelegate {
    var scene: SceneData?
    var camera: Binding<OrbitCamera>
    var settings: RenderSettings
    var onPick: ((Int?) -> Void)?
    var onStats: ((RenderStats) -> Void)?
    weak var view: MTKView?

    private static let logger = Logger(subsystem: "AtomifyRender", category: "ParticleView")
    private var renderer: ParticleRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private var uploadedScene: SceneData?
    private var lastStatsTime: Double = 0

    init(camera: Binding<OrbitCamera>, settings: RenderSettings) {
        self.camera = camera
        self.settings = settings
    }

    func configure(_ view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            Self.logger.error("AtomifyRender: no Metal device")
            return
        }
        self.view = view
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        let b = settings.background
        view.clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y), blue: Double(b.z), alpha: Double(b.w))
        view.delegate = self
        commandQueue = device.makeCommandQueue()
        do {
            renderer = try ParticleRenderer(device: device, colorFormat: view.colorPixelFormat,
                                            depthFormat: view.depthStencilPixelFormat, sampleCount: view.sampleCount,
                                            reverseZ: true)
        } catch {
            Self.logger.error("AtomifyRender: \(String(describing: error), privacy: .public)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, let commandQueue, let target = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        renderer.settings = settings
        if let scene {
            let unchanged = uploadedScene.map { scene.sharesStorage(with: $0) } ?? false
            if !unchanged {
                renderer.update(scene)
                uploadedScene = scene
            }
        } else if uploadedScene != nil {
            renderer.update(.empty)
            uploadedScene = nil
        }
        let renderView = ParticleViewMath.renderView(camera: camera.wrappedValue, drawableSize: drawableSize(view),
                                                     boundsSize: boundsSize(view))
        renderer.encodeFrame(commandBuffer: commandBuffer, target: target, view: renderView)
        commandBuffer.present(drawable)
        commandBuffer.commit()

        let now = CACurrentMediaTime()
        if let onStats, ParticleViewMath.shouldReport(now: now, last: lastStatsTime) {
            lastStatsTime = now
            onStats(renderer.lastFrameStats)
        }
    }

    // MARK: Input (pointer deltas in points, x right, y down)

    func rotate(pointerDelta: SIMD2<Float>) {
        var camera = self.camera.wrappedValue
        camera.rotate(by: camera.rotationDelta(forPointerMove: pointerDelta, viewHeight: boundsSize(view).y))
        self.camera.wrappedValue = camera
    }

    func pan(pointerDelta: SIMD2<Float>) {
        var camera = self.camera.wrappedValue
        camera.pan(by: camera.panDelta(forPointerMove: pointerDelta, viewHeight: boundsSize(view).y))
        self.camera.wrappedValue = camera
    }

    func zoom(by factor: Float) {
        var camera = self.camera.wrappedValue
        camera.zoom(by: factor)
        self.camera.wrappedValue = camera
    }

    /// Picks at a point in view coordinates (top-left origin).
    func pick(atPoint point: SIMD2<Float>) {
        guard let renderer, onPick != nil else { return }
        let pixel = ParticleViewMath.pixel(fromPoint: point, boundsSize: boundsSize(view),
                                           drawableSize: drawableSize(view))
        renderer.pick(at: pixel) { [weak self] index in
            MainActor.assumeIsolated {
                self?.onPick?(index)
            }
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

#if os(macOS)
/// MTKView that forwards mouse and trackpad input.
final class InteractiveMTKView: MTKView {
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

struct ParticleViewRepresentable: NSViewRepresentable {
    let scene: SceneData?
    @Binding var camera: OrbitCamera
    let settings: RenderSettings
    let onPick: ((Int?) -> Void)?
    let onStats: ((RenderStats) -> Void)?

    func makeCoordinator() -> ParticleViewCoordinator {
        ParticleViewCoordinator(camera: $camera, settings: settings)
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let coordinator = context.coordinator
        apply(to: coordinator)
        coordinator.configure(view)
        view.onRotate = { [weak coordinator] in coordinator?.rotate(pointerDelta: $0) }
        view.onPan = { [weak coordinator] in coordinator?.pan(pointerDelta: $0) }
        view.onZoom = { [weak coordinator] in coordinator?.zoom(by: $0) }
        view.onClick = { [weak coordinator] in coordinator?.pick(atPoint: $0) }
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: ParticleViewCoordinator) {
        coordinator.scene = scene
        coordinator.camera = $camera
        coordinator.settings = settings
        coordinator.onPick = onPick
        coordinator.onStats = onStats
    }
}
#endif

#if os(iOS)
extension ParticleViewCoordinator: UIGestureRecognizerDelegate {
    @objc func handleRotate(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        rotate(pointerDelta: SIMD2(Float(t.x), Float(t.y)))
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        pan(pointerDelta: SIMD2(Float(t.x), Float(t.y)))
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        zoom(by: Float(gesture.scale))
        gesture.scale = 1
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: gesture.view)
        pick(atPoint: SIMD2(Float(p.x), Float(p.y)))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

struct ParticleViewRepresentable: UIViewRepresentable {
    let scene: SceneData?
    @Binding var camera: OrbitCamera
    let settings: RenderSettings
    let onPick: ((Int?) -> Void)?
    let onStats: ((RenderStats) -> Void)?

    func makeCoordinator() -> ParticleViewCoordinator {
        ParticleViewCoordinator(camera: $camera, settings: settings)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let coordinator = context.coordinator
        apply(to: coordinator)
        coordinator.configure(view)

        let rotate = UIPanGestureRecognizer(target: coordinator, action: #selector(ParticleViewCoordinator.handleRotate(_:)))
        rotate.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(ParticleViewCoordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(ParticleViewCoordinator.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(ParticleViewCoordinator.handleTap(_:)))
        for gesture in [rotate, pan, pinch, tap] as [UIGestureRecognizer] {
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: ParticleViewCoordinator) {
        coordinator.scene = scene
        coordinator.camera = $camera
        coordinator.settings = settings
        coordinator.onPick = onPick
        coordinator.onStats = onStats
    }
}
#endif
#endif
