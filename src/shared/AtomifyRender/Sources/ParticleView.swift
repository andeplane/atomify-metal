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
///
/// With `pacing`, the view draws only as often as the pacing allows and
/// stops while nothing changes; without it, it draws continuously at up to
/// 120 frames per second. `contentScaleLimit` caps the pixels per point
/// (iOS), for very large systems. `onDoubleTap` (iOS) receives one-finger
/// double taps; a single-tap pick then waits until it is not a double tap.
public struct ParticleView: View {
    private let scene: SceneData?
    @Binding private var camera: OrbitCamera
    private let settings: RenderSettings
    private let options: ParticleViewOptions
    private let onPick: ((Int?) -> Void)?
    private let onStats: ((RenderStats) -> Void)?
    private let onDoubleTap: (() -> Void)?

    public init(scene: SceneData?, camera: Binding<OrbitCamera>, settings: RenderSettings,
                pacing: FramePacing? = nil, contentScaleLimit: Double? = nil,
                onPick: ((Int?) -> Void)? = nil, onStats: ((RenderStats) -> Void)? = nil,
                onDoubleTap: (() -> Void)? = nil) {
        self.scene = scene
        _camera = camera
        self.settings = settings
        self.options = ParticleViewOptions(pacing: pacing, contentScaleLimit: contentScaleLimit)
        self.onPick = onPick
        self.onStats = onStats
        self.onDoubleTap = onDoubleTap
    }

    public var body: some View {
        ParticleViewRepresentable(scene: scene, camera: $camera, settings: settings, options: options,
                                  onPick: onPick, onStats: onStats, onDoubleTap: onDoubleTap)
    }
}

/// The drawing options of a `ParticleView` that are not the scene.
struct ParticleViewOptions: Equatable {
    var pacing: FramePacing?
    var contentScaleLimit: Double?
}

/// Owns the renderer and turns input into camera changes. Lives on the
/// main actor, where MTKView draws and delivers events.
@MainActor
final class ParticleViewCoordinator: NSObject, MTKViewDelegate {
    var scene: SceneData?
    var camera: Binding<OrbitCamera>
    var settings: RenderSettings
    var options = ParticleViewOptions()
    var onPick: ((Int?) -> Void)?
    var onStats: ((RenderStats) -> Void)?
    var onDoubleTap: (() -> Void)?
    weak var view: MTKView?

    private static let logger = Logger(subsystem: "AtomifyRender", category: "ParticleView")
    private var renderer: ParticleRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private var uploadedScene: SceneData?
    private var lastStatsTime: Double = 0
    private var lastInteraction = -Double.infinity
    private var lastChange = -Double.infinity
    private var drawnCamera: OrbitCamera?
    private var scaleLimited = false

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
        lastChange = CACurrentMediaTime()
        commandQueue = device.makeCommandQueue()
        do {
            renderer = try ParticleRenderer(device: device, colorFormat: view.colorPixelFormat,
                                            depthFormat: view.depthStencilPixelFormat, sampleCount: view.sampleCount,
                                            reverseZ: true)
        } catch {
            Self.logger.error("AtomifyRender: \(String(describing: error), privacy: .public)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        applyContentScale()
        noteChange()
    }

    /// Takes new inputs from SwiftUI and wakes the view if any changed.
    func update(scene: SceneData?, camera: Binding<OrbitCamera>, settings: RenderSettings,
                options: ParticleViewOptions, onPick: ((Int?) -> Void)?, onStats: ((RenderStats) -> Void)?,
                onDoubleTap: (() -> Void)?) {
        let sceneChanged = !Self.same(self.scene, scene)
        let changed = sceneChanged || settings != self.settings || options != self.options
            || camera.wrappedValue != drawnCamera
        let scaleChanged = options.contentScaleLimit != self.options.contentScaleLimit
        self.scene = scene
        self.camera = camera
        self.settings = settings
        self.options = options
        self.onPick = onPick
        self.onStats = onStats
        self.onDoubleTap = onDoubleTap
        if scaleChanged { applyContentScale() }
        if changed { noteChange() }
    }

    private static func same(_ a: SceneData?, _ b: SceneData?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.sharesStorage(with: b)
        default: false
        }
    }

    // MARK: Pacing

    /// Something to draw changed: the scene, camera, settings or size.
    func noteChange() {
        lastChange = CACurrentMediaTime()
        updatePacing()
    }

    /// The user touched the view.
    func noteInteraction() {
        lastInteraction = CACurrentMediaTime()
        updatePacing()
    }

    /// Starts, slows or stops the draw loop as `options.pacing` says.
    func updatePacing() {
        guard let view else { return }
        guard let pacing = options.pacing else {
            if view.preferredFramesPerSecond != 120 { view.preferredFramesPerSecond = 120 }
            if view.isPaused { view.isPaused = false }
            return
        }
        let now = CACurrentMediaTime()
        let rate = pacing.framesPerSecond(sinceInteraction: now - lastInteraction, sinceChange: now - lastChange,
                                          constrained: Self.isConstrained)
        if rate == 0 {
            if !view.isPaused { view.isPaused = true }
        } else {
            if view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }
            if view.isPaused { view.isPaused = false }
        }
    }

    /// Low Power Mode or thermal pressure.
    static var isConstrained: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    /// Caps the drawable's pixels per point (iOS); macOS follows the window.
    /// Waits until the view is in a window, where the display scale is known,
    /// and leaves the scale alone when no limit was ever set.
    func applyContentScale() {
        #if os(iOS)
        guard let view, let window = view.window else { return }
        guard options.contentScaleLimit != nil || scaleLimited else { return }
        let native = window.traitCollection.displayScale > 0 ? window.traitCollection.displayScale : view.contentScaleFactor
        let scale = options.contentScaleLimit.map { min(native, CGFloat(max($0, 1))) } ?? native
        scaleLimited = options.contentScaleLimit != nil
        if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
        #endif
    }

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
        drawnCamera = camera.wrappedValue
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
        if options.pacing != nil { updatePacing() }
    }

    // MARK: Input (pointer deltas in points, x right, y down)

    func rotate(pointerDelta: SIMD2<Float>) {
        noteInteraction()
        var camera = self.camera.wrappedValue
        camera.rotate(by: camera.rotationDelta(forPointerMove: pointerDelta, viewHeight: boundsSize(view).y))
        self.camera.wrappedValue = camera
    }

    func pan(pointerDelta: SIMD2<Float>) {
        noteInteraction()
        var camera = self.camera.wrappedValue
        let size = boundsSize(view)
        camera.pan(by: camera.panDelta(forPointerMove: pointerDelta, viewHeight: size.y, viewWidth: size.x))
        self.camera.wrappedValue = camera
    }

    func zoom(by factor: Float) {
        noteInteraction()
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

    private func drawableSize(_ view: MTKView?) -> SIMD2<Float> {
        guard let view else { return SIMD2(1, 1) }
        return SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
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
    let options: ParticleViewOptions
    let onPick: ((Int?) -> Void)?
    let onStats: ((RenderStats) -> Void)?
    let onDoubleTap: (() -> Void)?

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
        coordinator.update(scene: scene, camera: $camera, settings: settings, options: options, onPick: onPick,
                           onStats: onStats, onDoubleTap: onDoubleTap)
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

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        noteInteraction()
        onDoubleTap?()
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
    let options: ParticleViewOptions
    let onPick: ((Int?) -> Void)?
    let onStats: ((RenderStats) -> Void)?
    let onDoubleTap: (() -> Void)?

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
        var gestures: [UIGestureRecognizer] = [rotate, pan, pinch, tap]
        if onDoubleTap != nil {
            let doubleTap = UITapGestureRecognizer(target: coordinator,
                                                   action: #selector(ParticleViewCoordinator.handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)
            gestures.append(doubleTap)
        }
        for gesture in gestures {
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: ParticleViewCoordinator) {
        coordinator.update(scene: scene, camera: $camera, settings: settings, options: options, onPick: onPick,
                           onStats: onStats, onDoubleTap: onDoubleTap)
    }
}
#endif
#endif
