import AtomifyRender
import Foundation
import Metal
import Observation
import QuartzCore
import simd

enum BenchmarkState: Equatable {
    case idle
    case running(seconds: Double)
    case finished(BenchmarkResult)
    case failed(String)
}

/// Everything the window shows: the chosen test scene and its parameters,
/// the generated scene, render settings, selection, and timings.
@MainActor @Observable
final class LabModel {
    // MARK: Scene choice

    var sceneKind: LabSceneKind? = .water
    var siliconCarbideCells = 4
    var performance = PerformanceParameters()
    var coloring = ColoringParameters()
    var pickingLayout: PickingLayout = .denseCluster

    /// The scene the sidebar and the controls ask for.
    var request: SceneRequest {
        switch sceneKind ?? .water {
        case .water: .water
        case .siliconCarbide: .siliconCarbide(cells: siliconCarbideCells)
        case .performance: .performance(performance)
        case .coloring: .coloring(coloring)
        case .picking: .picking(pickingLayout)
        }
    }

    // MARK: Rendering

    var settings = RenderSettings()
    var background: LabBackground = .dark
    var host: ViewportHost = .lab
    /// MSAA samples of the lab view.
    var sampleCount = 1
    /// Sample counts the Metal device supports, from 1.
    let supportedSampleCounts: [Int]
    var particleBudget: ParticleBudget = .four
    var showBonds = true
    var showBox = true
    var showInspector = true
    /// Set when the lab view could not create its renderer.
    var rendererError: String?

    /// `settings` with the chosen background.
    var renderSettings: RenderSettings {
        var result = settings
        result.background = background.color
        return result
    }

    // MARK: Animation (large crystal)

    var animate = false
    /// Largest offset per component, Å.
    var jitterAmplitude: Float = 0.05

    /// Positions are jittered every frame: only in the large crystal.
    var isAnimating: Bool { animate && generatedRequest?.kind == .performance }
    /// The model drives the animation (ParticleView has no per-frame hook).
    var isParticleViewAnimating: Bool { host == .particleView && isAnimating }

    // MARK: Generated scene

    private(set) var generated: GeneratedScene?
    private(set) var generatedRequest: SceneRequest?
    private(set) var isGenerating = false
    /// How long the latest scene took to generate.
    private(set) var generationMs: Double?
    private var generationID = 0
    /// The scene with jittered positions, for `ParticleView`.
    private(set) var jitteredScene: SceneData?
    @ObservationIgnored private var jitterFrame: UInt64 = 0
    @ObservationIgnored private var displayCache: (key: DisplayKey, scene: SceneData)?

    private struct DisplayKey: Equatable {
        var generation: Int
        var selected: Int?
        var bonds: Bool
        var box: Bool
    }

    // MARK: Selection, camera, timings

    /// Index of the picked particle in the generated scene.
    private(set) var selectedIndex: Int?
    var camera = OrbitCamera()
    /// Width over height of the view, for framing; set by the view.
    @ObservationIgnored var viewAspect: Float = 1.5
    var stats = LiveStats()
    var benchmark: BenchmarkState = .idle
    var benchmarkSeconds: Double = 10

    init() {
        let device = MTLCreateSystemDefaultDevice()
        let counts = [1, 2, 4, 8].filter { count in device?.supportsTextureSampleCount(count) ?? (count == 1) }
        supportedSampleCounts = counts.isEmpty ? [1] : counts
        sampleCount = counts.contains(4) ? 4 : (counts.last ?? 1)
    }

    // MARK: Scenes

    /// Generates the requested scene off the main thread and shows it.
    /// Called again whenever the request changes; a stale result is dropped.
    func loadCurrentRequest() async {
        let request = self.request
        if generatedRequest == request, generated != nil {
            isGenerating = false
            return
        }
        isGenerating = true
        let start = CACurrentMediaTime()
        let result = await Task.detached(priority: .userInitiated) {
            SceneFactory.make(request)
        }.value
        guard !Task.isCancelled, request == self.request else { return }
        show(result, for: request, milliseconds: (CACurrentMediaTime() - start) * 1000)
        isGenerating = false
    }

    private func show(_ result: GeneratedScene, for request: SceneRequest, milliseconds: Double) {
        let previous = generated
        let sameKind = generatedRequest?.kind == request.kind
        generated = result
        generatedRequest = request
        generationID += 1
        generationMs = milliseconds
        jitteredScene = nil
        if !sameKind || previous?.particleCount != result.particleCount {
            selectedIndex = nil
        }
        cancelBenchmark()
        if !sameKind || previous?.bounds != result.bounds {
            resetCamera()
        }
    }

    /// The scene to draw: the generated one with the display toggles and the selection.
    var displayScene: SceneData {
        guard let generated else { return .empty }
        let key = DisplayKey(generation: generationID, selected: selectedIndex, bonds: showBonds, box: showBox)
        if let cache = displayCache, cache.key == key { return cache.scene }
        let scene = SceneComposer.compose(generated.scene, selected: selectedIndex, showBonds: showBonds,
                                          showBox: showBox)
        displayCache = (key, scene)
        return scene
    }

    /// What `ParticleView` draws: the display scene, jittered while animating.
    var particleViewScene: SceneData {
        isParticleViewAnimating ? (jitteredScene ?? displayScene) : displayScene
    }

    /// Jitters the display scene for `ParticleView` at about 60 Hz while
    /// `isParticleViewAnimating`.
    func runParticleViewAnimation() async {
        while isParticleViewAnimating, !Task.isCancelled {
            let base = displayScene
            jitterFrame &+= 1
            var positions: [SIMD3<Float>] = []
            ThermalJitter.apply(base: base.particles.positions, amplitude: jitterAmplitude, frame: jitterFrame,
                                into: &positions)
            var moved = base
            moved.particles.positions = positions
            jitteredScene = moved
            try? await Task.sleep(for: .milliseconds(16))
        }
        jitteredScene = nil
    }

    /// After switching between the lab view and `ParticleView`.
    func hostChanged() {
        stats = LiveStats()
        cancelBenchmark()
    }

    // MARK: Selection

    func select(_ index: Int?) {
        guard let index, index >= 0, index < (generated?.particleCount ?? 0) else {
            selectedIndex = nil
            return
        }
        selectedIndex = index
    }

    var picked: PickedParticle? {
        guard let index = selectedIndex, let generated else { return nil }
        return PickedParticle.make(index: index, scene: displayScene, styleNames: generated.styleNames,
                                   scalars: generated.scalars)
    }

    // MARK: Camera

    /// Frames the whole scene from its preferred direction.
    func resetCamera() {
        let bounds = generated?.bounds ?? SceneBounds(low: SIMD3(repeating: -1), high: SIMD3(repeating: 1))
        let angles = generated?.viewAngles ?? SIMD2(0.55, 0.35)
        var camera = OrbitCamera(yaw: angles.x, pitch: angles.y)
        camera.frame(low: bounds.low, high: bounds.high, aspect: viewAspect)
        self.camera = camera
    }

    // MARK: Statistics and benchmark

    /// `ParticleView` reports GPU time and counts only.
    func recordParticleViewStats(_ renderStats: RenderStats) {
        guard host == .particleView else { return }
        stats = LiveStats(gpuMs: renderStats.gpuTimeMs > 0 ? renderStats.gpuTimeMs : nil,
                          particlesDrawn: renderStats.particlesDrawn, bondsDrawn: renderStats.bondsDrawn)
    }

    var isBenchmarkRunning: Bool {
        switch benchmark {
        case .running: return true
        default: return false
        }
    }

    var canBenchmark: Bool { host == .lab && generated != nil && !isGenerating }

    func startBenchmark() {
        guard canBenchmark else { return }
        benchmark = .running(seconds: max(benchmarkSeconds, 1))
    }

    func cancelBenchmark() {
        if isBenchmarkRunning { benchmark = .idle }
    }

    func toggleBenchmark() {
        isBenchmarkRunning ? cancelBenchmark() : startBenchmark()
    }

    func dismissBenchmarkResult() {
        if !isBenchmarkRunning { benchmark = .idle }
    }

    /// The configuration a benchmark measured, for its report.
    var benchmarkLabel: String {
        var parts = [sceneKind?.title ?? "Scene"]
        if let generated {
            parts.append("\(generated.particleCount.formatted()) particles")
            if showBonds, generated.bondCount > 0 { parts.append("\(generated.bondCount.formatted()) bonds") }
            if generated.scene.images.count > 1 { parts.append("\(generated.scene.images.count) copies") }
        }
        parts.append(settings.quality.rawValue)
        parts.append(sampleCount > 1 ? "MSAA \(sampleCount)×" : "no MSAA")
        if isAnimating { parts.append("animated") }
        return parts.joined(separator: ", ")
    }
}

/// Runs `work` on the main actor: now when already on the main thread,
/// otherwise soon. The renderer's callbacks are documented to arrive on the
/// main queue, but this does not rely on it.
func performOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        Task { @MainActor in work() }
    }
}
