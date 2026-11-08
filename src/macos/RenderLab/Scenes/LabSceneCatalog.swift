import AtomifyRender
import simd

/// The test scenes in the sidebar.
enum LabSceneKind: String, CaseIterable, Identifiable, Sendable {
    case water, siliconCarbide, performance, coloring, picking

    var id: Self { self }

    var title: String {
        switch self {
        case .water: "Water molecule"
        case .siliconCarbide: "SiC crystal"
        case .performance: "Large crystal"
        case .coloring: "Colored atoms"
        case .picking: "Picking"
        }
    }

    var subtitle: String {
        switch self {
        case .water: "One static H₂O with bonds"
        case .siliconCarbide: "3C-SiC zincblende, bonds and box"
        case .performance: "10k–8M atoms, timing, benchmark"
        case .coloring: "Colormaps, per-atom colors and radii"
        case .picking: "Dense scenes for click-to-select"
        }
    }

    /// SF Symbol.
    var systemImage: String {
        switch self {
        case .water: "drop"
        case .siliconCarbide: "cube"
        case .performance: "speedometer"
        case .coloring: "paintpalette"
        case .picking: "cursorarrow.click"
        }
    }
}

/// Everything a scene generator needs: which scene, and its parameters.
/// Equal requests produce identical scenes.
enum SceneRequest: Sendable, Equatable, Hashable {
    case water
    case siliconCarbide(cells: Int)
    case performance(PerformanceParameters)
    case coloring(ColoringParameters)
    case picking(PickingLayout)

    var kind: LabSceneKind {
        switch self {
        case .water: .water
        case .siliconCarbide: .siliconCarbide
        case .performance: .performance
        case .coloring: .coloring
        case .picking: .picking
        }
    }
}

/// Legend of per-particle colors.
struct ColorLegendInfo: Sendable, Equatable {
    var title: String
    var colormap: Colormap
    var range: ClosedRange<Float>
}

/// A generated scene and what the app shows about it.
struct GeneratedScene: Sendable {
    var scene: SceneData
    /// Around everything drawn, periodic copies included.
    var bounds: SceneBounds
    /// A name for each style, by style index.
    var styleNames: [String]
    var legend: ColorLegendInfo?
    /// The per-particle value behind colors or radii, and its name.
    var scalars: [Float]?
    var scalarName: String?
    /// Remarks shown under the scene's controls.
    var notes: [String]
    /// Camera yaw and pitch (radians) for the initial and reset view.
    var viewAngles: SIMD2<Float>

    init(scene: SceneData, styleNames: [String], legend: ColorLegendInfo? = nil, scalars: [Float]? = nil,
         scalarName: String? = nil, notes: [String] = [], viewAngles: SIMD2<Float> = SIMD2(0.55, 0.35)) {
        self.scene = scene
        self.bounds = SceneBounds.enclosing(scene)
        self.styleNames = styleNames
        self.legend = legend
        self.scalars = scalars
        self.scalarName = scalarName
        self.notes = notes
        self.viewAngles = viewAngles
    }

    var particleCount: Int { scene.particles.count }
    var bondCount: Int { scene.bonds?.pairs.count ?? 0 }
}

enum SceneFactory {
    static func make(_ request: SceneRequest) -> GeneratedScene {
        switch request {
        case .water: WaterMolecule.make()
        case .siliconCarbide(let cells): SiliconCarbideScene.make(cells: cells)
        case .performance(let parameters): PerformanceScene.make(parameters)
        case .coloring(let parameters): ColoringScene.make(parameters)
        case .picking(let layout): PickingScene.make(layout)
        }
    }
}

/// What the app draws: the generated scene with the display toggles and
/// the selection applied. Arrays that do not change are shared, so the
/// renderer can tell an unchanged scene from a new one.
enum SceneComposer {
    static func compose(_ base: SceneData, selected: Int?, showBonds: Bool, showBox: Bool) -> SceneData {
        var scene = base
        if !showBonds { scene.bonds = nil }
        if !showBox { scene.lines = [] }
        let count = base.particles.count
        if let index = selected, index >= 0, index < count {
            var flags = base.particles.flags ?? []
            if flags.count != count { flags = [UInt8](repeating: 0, count: count) }
            flags[index] |= ParticleFlags.selected
            scene.particles.flags = flags
        }
        return scene
    }
}
