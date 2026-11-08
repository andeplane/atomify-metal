import AtomifyEngine
import AtomifyVision
import RealityKit
import SwiftUI
import UIKit

/// Draws the latest simulation snapshot: one instanced batch of spheres per
/// atom type, one batch of half bonds per atom type (so bonds take the colors
/// of their atoms), the simulation box when the demo asks for it, and a
/// single marker for the atom a hand is near or holding.
@MainActor
final class MoleculeScene {
    /// What the one marked atom is doing.
    struct Highlight: Equatable {
        enum Kind: Equatable { case near, held }
        var tag: Int64
        var kind: Kind
    }

    /// Placed in the room; two hands move, turn and resize it. It is the
    /// gesture target: its collision box covers the visible content.
    let root = Entity()
    /// Follows the content's position (not its turn or size) to carry the
    /// tip under it; it turns to face the wearer.
    let tipAnchor = Entity()
    /// Holds the tip's view attachment, offset so its top edge is at the anchor.
    let tipView = Entity()
    /// Maps simulation coordinates into `root`.
    private let simulation = Entity()
    private let interactionAudio = InteractionAudio()
    /// Real geometry costs triangles per atom; beyond this only the first
    /// atoms (by tag) are drawn.
    static let maxDrawnAtoms = 40_000
    /// The gesture target is this much larger than what is drawn, so a pinch
    /// at the edge of the content still lands.
    private static let targetMargin: Float = 1.1

    private var runID: UUID?
    private var demoID: String?
    var isBoxBeingMoved = false
    /// False until the lab has put the content in front of the wearer; the
    /// content stays hidden until then.
    private(set) var isPlaced = false
    private var frame: SimulationFrame?
    private var framesAtoms = false
    private var showsBox = false
    /// Draw molecules whole across periodic faces (display only).
    private var drawsWholeMolecules = false
    private var bondRules: [BondRule] = []
    /// Drawn minus simulated position per atom in the current frame; nil
    /// when atoms are drawn where they are simulated.
    private var displayShifts: [SIMD3<Float>]?
    private var exhibitExtent: SIMD3<Float>?
    private var styles: AtomStyleTable?
    private var sphereSubdivisions = -1
    private var atomBatches: [Int: InstancedBatch] = [:]
    private var bondBatches: [Int: InstancedBatch] = [:]
    private var boxBatch: InstancedBatch?
    private let marker = Entity()
    private var markerMaterials: [MarkerKey: PhysicallyBasedMaterial] = [:]
    /// The frame as drawn: with whole molecules on, positions are display
    /// positions and bonds include those across periodic faces. Picking and
    /// marking work on it; `simulatedPoint` maps back to the engine's frame.
    private(set) var currentSnapshot: SimulationSnapshot?
    private var drawnHighlight: Highlight?

    private struct MarkerKey: Hashable {
        var type: Int
        var held: Bool
    }

    init() {
        root.name = "Simulation"
        root.position = LabComfort.fallbackPosition
        root.isEnabled = false
        root.addChild(simulation)
        simulation.addChild(interactionAudio.emitter)
        simulation.addChild(marker)
        marker.isEnabled = false
        let audio = interactionAudio
        Task { await audio.prepare() }
        tipAnchor.name = "Tip"
        tipAnchor.components.set(BillboardComponent())
        tipAnchor.addChild(tipView)
        tipAnchor.isEnabled = false
    }

    /// Where the content is, as the two-hand grip sees it.
    var placement: BoxPlacement {
        get { BoxPlacement(position: root.position, orientation: root.orientation, scale: root.scale.x) }
        set {
            root.position = newValue.position
            root.orientation = newValue.orientation
            root.scale = SIMD3(repeating: newValue.scale)
        }
    }

    /// Puts the content somewhere and shows it.
    func place(_ placement: BoxPlacement) {
        self.placement = placement
        isPlaced = true
        root.isEnabled = true
    }

    /// The visible content's size in meters at scale 1, once framed.
    var contentExtent: SIMD3<Float>? {
        if let exhibitExtent { return exhibitExtent }
        guard let frame, let snapshot = currentSnapshot else { return nil }
        return simd_max(SIMD3<Float>(snapshot.boxHigh - snapshot.boxLow) * frame.metersPerUnit, SIMD3(repeating: 0.05))
    }

    /// Meters in the world per simulation length unit, including resizing.
    var worldMetersPerSimulationUnit: Float? {
        frame.map { $0.metersPerUnit * root.scale.x }
    }

    /// Mean drawn atom radius (simulation units), so hands push atoms where
    /// they are seen to touch.
    var atomContactRadius: Float {
        guard let styles, !styles.styles.isEmpty else { return 0 }
        return Float(styles.styles.values.reduce(0) { $0 + $1.radius } / Double(styles.styles.count))
    }

    /// The drawn radius of atom `index` (simulation units).
    func drawnRadius(_ index: Int, in snapshot: SimulationSnapshot) -> Float {
        if let radii = snapshot.radii, index < radii.count { return radii[index] }
        guard index < snapshot.types.count, let styles else { return 0 }
        return Float(styles.style(forType: Int(snapshot.types[index])).radius)
    }

    func simulationPoint(fromWorld point: SIMD3<Float>) -> SIMD3<Float> {
        simulation.convert(position: point, from: nil)
    }

    func worldPoint(fromSimulation point: SIMD3<Float>) -> SIMD3<Float> {
        simulation.convert(position: point, to: nil)
    }

    /// A world point near the atom `tag` as drawn, in that atom's own frame
    /// in the engine: the drawn point minus the atom's display shift, so a
    /// hydrogen drawn across a periodic face is not pulled across the box.
    func simulatedPoint(fromWorld point: SIMD3<Float>, nearAtom tag: Int64) -> SIMD3<Float> {
        let drawn = simulationPoint(fromWorld: point)
        guard let displayShifts, let index = currentSnapshot?.index(ofTag: tag), index < displayShifts.count else {
            return drawn
        }
        return drawn - displayShifts[index]
    }

    /// A soft spatial sound at the atom a hand just took hold of.
    func playGrabCue(tag: Int64) {
        guard let snapshot = currentSnapshot, let index = snapshot.index(ofTag: tag) else { return }
        interactionAudio.cue(at: snapshot.positions[index], enabled: true)
    }

    /// Keeps the tip under the content, facing the wearer.
    func updateTip(visible: Bool) {
        let show = visible && isPlaced
        if tipAnchor.isEnabled != show { tipAnchor.isEnabled = show }
        guard show, let extent = contentExtent else { return }
        tipAnchor.position = LabComfort.tipPosition(below: placement, extent: extent)
        if let bounds = tipView.components[ViewAttachmentComponent.self]?.bounds {
            tipView.position = [0, -bounds.extents.y / 2, 0]
        }
    }

    /// Draws a new snapshot if there is one, and the marker when it changed.
    /// Returns the new snapshot.
    func update(run: AppModel.Run?, hasFinished: Bool, highlight: Highlight?) -> SimulationSnapshot? {
        guard let run else {
            clear()
            return nil
        }
        if run.id != runID { reset(for: run) }

        let terminal = hasFinished ? run.simulation.lastKnownGoodSnapshot : nil
        let finalFrame = terminal.flatMap { $0.sequence != currentSnapshot?.sequence ? $0 : nil }
        let fresh = run.simulation.takeNewSnapshot() ?? finalFrame
        if let snapshot = fresh {
            let drawnCount = min(snapshot.atomCount, Self.maxDrawnAtoms)
            if styles == nil || styles?.styles.count != max(snapshot.typeCount, 1) {
                styles = AtomStyleTable(directives: run.directives, typeCount: snapshot.typeCount, units: snapshot.units)
                markerMaterials = [:]
                rebuildBatches(atomCount: drawnCount)
            } else if Meshes.sphereSubdivisions(forAtomCount: drawnCount) != sphereSubdivisions {
                rebuildBatches(atomCount: drawnCount)
            }
            let drawn = displayed(snapshot)
            if frame == nil, !framesAtoms || drawn.atomCount > 0 { frameContent(drawn) }
            draw(drawn)
            currentSnapshot = drawn
        }
        if fresh != nil || highlight != drawnHighlight {
            drawMarker(highlight)
            drawnHighlight = highlight
        }
        return fresh
    }

    // MARK: - Private

    private func reset(for run: AppModel.Run) {
        // Restarting the same experience keeps it where the wearer put it.
        let keepsPlacement = isPlaced && run.demo.id == demoID
        clear()
        runID = run.id
        demoID = run.demo.id
        framesAtoms = run.demo.frame == "atoms"
        showsBox = run.demo.showsBox == true
        drawsWholeMolecules = run.demo.wholeMolecules == true
        bondRules = run.directives.bondRules
        root.components.remove(CollisionComponent.self)
        root.components.remove(InputTargetComponent.self)
        if !keepsPlacement {
            isPlaced = false
            root.isEnabled = false
        }
    }

    private func clear() {
        isBoxBeingMoved = false
        for batch in atomBatches.values { batch.entity.removeFromParent() }
        for batch in bondBatches.values { batch.entity.removeFromParent() }
        boxBatch?.entity.removeFromParent()
        atomBatches = [:]
        bondBatches = [:]
        boxBatch = nil
        marker.isEnabled = false
        markerMaterials = [:]
        drawnHighlight = nil
        frame = nil
        exhibitExtent = nil
        styles = nil
        currentSnapshot = nil
        displayShifts = nil
        sphereSubdivisions = -1
        runID = nil
        tipAnchor.isEnabled = false
    }

    /// The snapshot as drawn: molecules made whole across periodic faces
    /// when the experience asks for it, otherwise unchanged.
    private func displayed(_ snapshot: SimulationSnapshot) -> SimulationSnapshot {
        guard let whole = WholeMolecules.make(snapshot: snapshot, rules: bondRules, enabled: drawsWholeMolecules),
              whole.movesAtoms || !whole.crossingBonds.isEmpty else {
            displayShifts = nil
            return snapshot
        }
        var drawn = snapshot
        drawn.positions = whole.positions
        drawn.bonds = snapshot.bonds + whole.crossingBonds
        displayShifts = whole.shifts
        return drawn
    }

    /// Molecule-like exhibits ("atoms" framing) are centred and sized from
    /// their actual atoms, so an empty vacuum box cannot make them tiny.
    /// Everything else fits the simulation box. Computed once per run.
    private func frameContent(_ snapshot: SimulationSnapshot) {
        let frame: SimulationFrame
        if framesAtoms, let styles,
           let exhibit = ExhibitFraming(snapshot: snapshot, styles: styles, size: LabComfort.initialSize) {
            frame = exhibit.frame
            exhibitExtent = exhibit.extent
        } else {
            frame = SimulationFrame(boxLow: snapshot.boxLow, boxHigh: snapshot.boxHigh, size: LabComfort.initialSize)
        }
        self.frame = frame
        simulation.transform = Transform(matrix: frame.localFromSimulation)
        currentSnapshot = snapshot
        guard let extent = contentExtent else { return }
        root.components.set(CollisionComponent(shapes: [.generateBox(size: extent * Self.targetMargin)]))
        root.components.set(InputTargetComponent(allowedInputTypes: .all))
    }

    private func rebuildBatches(atomCount: Int) {
        for batch in atomBatches.values { batch.entity.removeFromParent() }
        for batch in bondBatches.values { batch.entity.removeFromParent() }
        atomBatches = [:]
        bondBatches = [:]
        guard let styles else { return }
        sphereSubdivisions = Meshes.sphereSubdivisions(forAtomCount: atomCount)
        guard let sphere = try? Meshes.sphere(subdivisions: sphereSubdivisions),
              let tube = try? Meshes.tube() else { return }
        for (type, style) in styles.styles {
            let atoms = InstancedBatch(mesh: sphere, material: Self.material(style.color))
            let bonds = InstancedBatch(mesh: tube, material: Self.material(style.color))
            simulation.addChild(atoms.entity)
            simulation.addChild(bonds.entity)
            atomBatches[type] = atoms
            bondBatches[type] = bonds
        }
        if boxBatch == nil {
            var edge = UnlitMaterial(color: .white)
            edge.blending = .transparent(opacity: 0.35)
            let box = InstancedBatch(mesh: tube, material: edge)
            simulation.addChild(box.entity)
            boxBatch = box
        }
        if marker.components[ModelComponent.self] == nil, let smooth = try? Meshes.sphere(subdivisions: 3) {
            marker.components.set(ModelComponent(mesh: smooth, materials: [SimpleMaterial()]))
        }
    }

    private func draw(_ snapshot: SimulationSnapshot) {
        guard let styles, let frame else { return }
        var drawn = snapshot
        if drawn.atomCount > Self.maxDrawnAtoms {
            drawn.tags = Array(drawn.tags.prefix(Self.maxDrawnAtoms))
            drawn.types = Array(drawn.types.prefix(Self.maxDrawnAtoms))
            drawn.positions = Array(drawn.positions.prefix(Self.maxDrawnAtoms))
            drawn.radii = drawn.radii.map { Array($0.prefix(Self.maxDrawnAtoms)) }
            drawn.bonds = drawn.bonds.filter { Int($0.x) < Self.maxDrawnAtoms && Int($0.y) < Self.maxDrawnAtoms }
        }
        let bondRadius = InstanceBuilder.bondRadius(styles: styles, atomScale: 1)
        let batches = InstanceBuilder.build(snapshot: drawn, styles: styles, atomScale: 1,
                                            bondRadius: bondRadius, includeBonds: true)
        for (type, batch) in atomBatches { batch.update(batches.atoms[type] ?? []) }
        for (type, batch) in bondBatches { batch.update(batches.halfBonds[type] ?? []) }

        if showsBox {
            // About one millimeter thick at the initial size, whatever the units.
            let radius = 0.001 / frame.metersPerUnit
            boxBatch?.update(InstanceBuilder.boxEdges(low: SIMD3<Float>(snapshot.boxLow),
                                                      high: SIMD3<Float>(snapshot.boxHigh), radius: radius))
        } else {
            boxBatch?.update([])
        }
    }

    /// The one marked atom, in its own colour: barely larger and a little
    /// brighter when a hand is near it, clearly glowing while held. Never a
    /// translucent shell.
    private func drawMarker(_ highlight: Highlight?) {
        guard let highlight, let snapshot = currentSnapshot, let styles,
              let index = snapshot.index(ofTag: highlight.tag) else {
            marker.isEnabled = false
            return
        }
        let held = highlight.kind == .held
        let type = Int(snapshot.types[index])
        let key = MarkerKey(type: type, held: held)
        let material = markerMaterials[key] ?? Self.markerMaterial(styles.style(forType: type).color, held: held)
        markerMaterials[key] = material
        marker.components[ModelComponent.self]?.materials = [material]
        let radius = drawnRadius(index, in: snapshot) * (held ? 1.08 : 1.04)
        marker.transform = Transform(matrix: InstanceBuilder.sphereTransform(center: snapshot.positions[index], radius: radius))
        marker.isEnabled = true
    }

    private static func material(_ color: RGBColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1))
        material.roughness = 0.35
        material.metallic = 0.0
        return material
    }

    private static func markerMaterial(_ color: RGBColor, held: Bool) -> PhysicallyBasedMaterial {
        let lift = held ? 0.3 : 0.15
        func brighten(_ value: Double) -> Double { value + (1 - value) * lift }
        let base = UIColor(red: brighten(color.red), green: brighten(color.green), blue: brighten(color.blue), alpha: 1)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: base)
        material.roughness = 0.3
        material.metallic = 0.0
        material.emissiveColor = .init(color: UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1))
        material.emissiveIntensity = held ? 1.6 : 0.4
        return material
    }
}
