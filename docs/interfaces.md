# Library interfaces

These are the public Swift interfaces the three parts are built against.
The libraries implement at least this; they may add more.
If an implementation has to differ, change this file in the same change.

All three live in the root `Package.swift`, targeting macOS 15, iOS 18, visionOS 2 (tvOS later).

---

## AtomifyRender (`src/shared/AtomifyRender`)

Imports only Metal, MetalKit, simd, SwiftUI (for the view). No knowledge of LAMMPS.

```swift
import Metal
import simd

/// Appearance shared by many particles: a lookup table indexed per particle.
public struct ParticleStyle: Sendable, Equatable {
    public var radius: Float
    public var color: SIMD4<Float>       // linear RGBA, alpha 1 for opaque
    public init(radius: Float, color: SIMD4<Float>)
}

/// Particles to draw. Struct of arrays, all of length `count`.
/// Either `styleIndices` + `styles` (cheap: 16 B/particle on the GPU)
/// or per-particle `colors` / `radii`, which override the style when non-nil.
public struct ParticleData: Sendable {
    public var positions: [SIMD3<Float>]
    public var styleIndices: [UInt16]?   // index into styles; nil means 0
    public var styles: [ParticleStyle]   // at least one
    public var colors: [SIMD4<Float>]?   // per-particle override (e.g. color by quantity)
    public var radii: [Float]?           // per-particle override
    /// Per-particle state flags: bit 0 selected/highlighted, bit 1 hidden.
    public var flags: [UInt8]?
    public var count: Int { positions.count }
    public init(positions: [SIMD3<Float>], styleIndices: [UInt16]? = nil, styles: [ParticleStyle],
                colors: [SIMD4<Float>]? = nil, radii: [Float]? = nil, flags: [UInt8]? = nil)
}

/// Bonds as index pairs into ParticleData. Each half takes its particle's color
/// unless `colors` is given.
public struct BondData: Sendable {
    public var pairs: [SIMD2<UInt32>]
    public var radius: Float
    public var colors: [SIMD4<Float>]?   // per-bond override
    public init(pairs: [SIMD2<UInt32>], radius: Float, colors: [SIMD4<Float>]? = nil)
}

/// Thin lines (simulation box, walls, axes), drawn as screen-width lines.
public struct LineData: Sendable {
    public var segments: [(SIMD3<Float>, SIMD3<Float>)]
    public var color: SIMD4<Float>
    public var width: Float              // points
    public init(segments: [(SIMD3<Float>, SIMD3<Float>)], color: SIMD4<Float>, width: Float = 1.5)
}

public struct SceneData: Sendable {
    public var particles: ParticleData
    public var bonds: BondData?
    public var lines: [LineData]
    /// Periodic copies of the particles to draw (offsets), [.zero] for none.
    public var images: [SIMD3<Float>]
    public init(particles: ParticleData, bonds: BondData? = nil, lines: [LineData] = [],
                images: [SIMD3<Float>] = [.zero])
}

public enum RenderQuality: String, Sendable, CaseIterable {
    case fast       // impostors, simple lighting; for very large systems
    case high       // impostors + SSAO + outlines/shadows; for smaller systems
}

public struct RenderSettings: Sendable, Equatable {
    public var quality: RenderQuality = .fast
    public var background: SIMD4<Float> = SIMD4(0.08, 0.08, 0.1, 1)
    public var lightDirection: SIMD3<Float> = simd_normalize(SIMD3(0.3, 1, 0.45))  // view space
    public var radiusScale: Float = 1
    public var ambientOcclusionStrength: Float = 1
    public var outlineWidth: Float = 0
    public var highlightColor: SIMD4<Float> = SIMD4(1, 0.85, 0.2, 1)
    public init()
}

/// One eye/view to render.
public struct RenderView: Sendable {
    public var viewMatrix: simd_float4x4         // world → view, camera looks down −z
    public var projectionMatrix: simd_float4x4   // view → clip
    public var viewportSize: SIMD2<Float>        // pixels
    public init(viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, viewportSize: SIMD2<Float>)
}

/// Renders SceneData. Upload is cheap to call every frame; it reuses buffers
/// (triple buffered) and only grows them. Not thread safe: use from the render thread.
public final class ParticleRenderer {
    public init(device: any MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
                sampleCount: Int = 1, reverseZ: Bool = false, maxViews: Int = 1) throws
    public var settings: RenderSettings
    /// Model transform from scene units into world.
    public var modelMatrix: simd_float4x4
    public func update(_ scene: SceneData)
    /// Draw into an encoder whose pass the caller owns (AVP / custom hosts).
    /// High quality passes (SSAO) need `encodeFrame` instead.
    public func encode(into encoder: any MTLRenderCommandEncoder, views: [RenderView])
    /// Full frame including offscreen passes (SSAO, picking) to `target`.
    public func encodeFrame(commandBuffer: any MTLCommandBuffer, target: MTLRenderPassDescriptor,
                            view: RenderView)
    /// Index of the particle at a pixel (top-left origin), or nil. Resolved from the
    /// ID buffer of the last frame; completion is called on the main queue.
    public func pick(at pixel: SIMD2<Float>, completion: @escaping @Sendable (Int?) -> Void)
    /// Statistics for an overlay.
    public var lastFrameStats: RenderStats { get }
}

public struct RenderStats: Sendable { public var particlesDrawn: Int; public var bondsDrawn: Int; public var gpuTimeMs: Double }

/// Orbit camera for mouse/touch apps.
public struct OrbitCamera: Sendable, Equatable {
    public var target: SIMD3<Float>
    public var distance: Float
    public var yaw: Float       // radians
    public var pitch: Float     // radians, clamped
    public var fieldOfView: Float = .pi / 4
    public init(target: SIMD3<Float> = .zero, distance: Float = 10, yaw: Float = 0, pitch: Float = 0)
    public mutating func rotate(by delta: SIMD2<Float>)   // radians
    public mutating func pan(by delta: SIMD2<Float>)      // in view-plane units of distance
    public mutating func zoom(by factor: Float)
    /// Fit a bounding box in view.
    public mutating func frame(low: SIMD3<Float>, high: SIMD3<Float>)
    public var viewMatrix: simd_float4x4 { get }
    public func projectionMatrix(aspect: Float, near: Float, far: Float, reverseZ: Bool) -> simd_float4x4
    /// World-space ray through a point in normalized device coords (−1...1).
    public func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)
}

#if os(macOS) || os(iOS)
import SwiftUI
/// SwiftUI view hosting an MTKView with an OrbitCamera: drag rotates,
/// right/two-finger drag pans, scroll/pinch zooms, click/tap picks.
public struct ParticleView: View {
    public init(scene: SceneData?, camera: Binding<OrbitCamera>, settings: RenderSettings,
                onPick: ((Int?) -> Void)? = nil, onStats: ((RenderStats) -> Void)? = nil)
}
#endif

// Pure helpers (unit tested):
public enum Colormap: String, CaseIterable, Sendable { case viridis, plasma, coolwarm, jet, grayscale
    public func color(at t: Float) -> SIMD4<Float>          // t clamped to 0...1, linear RGB
}
public func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float>
```

---

## AtomifyEngine (`src/shared/AtomifyEngine`)

Depends on CLammps. No Metal.

```swift
/// One LAMMPS instance running scripts on its own thread.
public final class Simulation: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable { case finished, cancelled, failed(String) }
    public init(echo: Bool = false) throws

    /// Runs a script file. Relative paths resolve against `workingDirectory`.
    /// With `continueAfterScript`, keeps integrating ("run" forever) afterwards.
    public func start(script: URL, workingDirectory: URL, continueAfterScript: Bool = false,
                      onFinish: @escaping @Sendable (Outcome) -> Void)
    /// Queues a single LAMMPS command, executed between timesteps on the sim thread.
    public func enqueue(command: String)

    public func setPaused(_ paused: Bool)
    public func cancel()
    public var isRunning: Bool { get }
    public func setMaxStepsPerSecond(_ steps: Double?)
    public func setPublishInterval(_ seconds: Double)

    // Bonds
    public func setTopologyBonds(_ enabled: Bool)
    public func setBondRules(_ rules: [BondRule])

    // Interaction (from vision-atomify)
    public func grab(tag: Int64, target: SIMD3<Double>, stiffness: Double, slot: Int = 0)
    public func releaseGrab(slot: Int? = nil)
    public func setForceSpheres(_ spheres: [ForceSphere])
    public func setFrozen(_ frozen: Bool)

    /// Per-atom quantity to publish with each snapshot, for coloring:
    /// "vx", "vy", "vz", "fx", "q", "mass", "c_ID", "c_ID[2]", "v_name", "f_ID", or nil.
    public func setPerAtomQuantity(_ name: String?)

    /// Newest snapshot if newer than the last returned one.
    public func takeNewSnapshot() -> SimulationSnapshot?
    /// Text LAMMPS printed since the last call (thermo output, warnings).
    public func takeOutput() -> String
}

public struct ForceSphere: Sendable, Equatable { center: SIMD3<Double>; radius: Double; strength: Double }
public struct BondRule: Sendable, Hashable { type1: Int; type2: Int; cutoff: Double }

public struct SimulationSnapshot: Sendable {
    public var sequence: UInt64
    public var timestep: Int64
    public var time: Double
    public var units: String
    public var typeCount: Int
    public var dimension: Int
    public var periodic: [Bool]
    public var minimizing: Bool
    public var boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>
    /// Triclinic tilt (xy, xz, yz); zero for orthogonal boxes.
    public var tilt: SIMD3<Double>
    public var temperature: Double
    public var kineticEnergy: Double
    public var potentialEnergy: Double?
    public var stepsPerSecond: Double
    public var tags: [Int64]                 // sorted
    public var types: [Int32]                // 1-based
    public var positions: [SIMD3<Float>]
    public var radii: [Float]?
    public var bonds: [SIMD2<UInt32>]        // indices into the arrays above
    /// Values of the quantity chosen with setPerAtomQuantity, per atom, or nil.
    public var perAtomValues: [Float]?
    public var perAtomQuantity: String?
    /// Global scalars and vectors of computes, fixes, variables and thermo keywords.
    public var observables: [Observable]
    public var atomCount: Int { get }
    public func index(ofTag tag: Int64) -> Int?
    public func atomHit(rayOrigin: SIMD3<Float>, direction: SIMD3<Float>, radius: (Int) -> Float,
                        tolerance: Float) -> Int?
}

public struct Observable: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case thermo, compute, fix, variable }
    public var id: String                 // "c_temp", "f_ave", "v_msd", "thermo_temp"
    public var kind: Kind
    public var name: String               // LAMMPS ID / variable name
    public var style: String?             // compute/fix style, e.g. "msd"
    public var values: [Double]           // 1 for a scalar, N for a global vector
    public var labels: [String]           // component labels, same length as values
    /// Names of per-atom quantities this provides, e.g. ["c_ke"] or ["c_stress[1]", ...].
    public var perAtomNames: [String]
}

/// Records observables over time for plotting. Not thread safe.
public final class ObservableHistory {
    public init(capacity: Int = 10_000)
    public func record(_ snapshot: SimulationSnapshot)
    public func series(id: String, component: Int = 0) -> [SIMD2<Double>]   // (time, value)
    public var ids: [String] { get }
    public func reset()
}

/// `#/atom`, `#/bond`, `#/camera` comment directives.
public struct ScriptDirectives: Sendable, Equatable {
    public var atomStyles: [Int: AtomStyle]
    public var bondRules: [BondRule]
    public var camera: CameraHint?
    public var warnings: [String]
    public static func parse(_ script: String) -> ScriptDirectives
}
public struct CameraHint: Sendable, Equatable { public var position: SIMD3<Double>?; public var target: SIMD3<Double>? }
public struct AtomStyle: Sendable, Equatable { public var name: String; public var color: RGBColor; public var radius: Double }
public struct RGBColor: Sendable, Equatable, Hashable { public var red, green, blue: Double  /* sRGB 0...1 */
    public init(hex: UInt32); public init?(hexString: String) }
public struct Element: Sendable, Equatable { symbol, name, radius (Å vdW), color; static func named(_:) -> Element?; static let all }
public struct AtomStyleTable: Sendable, Equatable {
    public init(directives: ScriptDirectives, typeCount: Int, units: String)
    public func style(forType type: Int) -> AtomStyle
}
```

---

## AtomifyKit (`src/shared/AtomifyKit`)

Depends on AtomifyEngine and AtomifyRender. Shared by all apps.

```swift
/// Example simulations in the web app's examples.json format.
public struct Example: Codable, Identifiable, Hashable { id, title, description, imageUrl?, inputScript, keywords?, files: [ExampleFile] }
public struct ExampleCatalog { static func load(from directory: URL) throws -> ExampleCatalog; examples; func workingCopy(of:) throws -> (folder: URL, script: URL) }

public enum ColorMode: Hashable { case type, perAtom(quantity: String, colormap: Colormap, range: ClosedRange<Float>?) }

/// Builds render scene data from a snapshot (pure, unit tested).
public enum SceneBuilder {
    public static func scene(from snapshot: SimulationSnapshot, styles: AtomStyleTable, colorMode: ColorMode,
                             selectedTag: Int64?, showBox: Bool, bondRadius: Float) -> SceneData
}

/// Owns a Simulation, polls snapshots on a display tick, keeps history, exposes state to SwiftUI.
@MainActor @Observable public final class SimulationSession { ... }
```
