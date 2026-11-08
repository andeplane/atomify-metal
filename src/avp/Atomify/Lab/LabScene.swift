import AtomifyEngine
import AtomifyVision
import Foundation
import simd

/// The lab's content on the main actor: which snapshot is shown, how it is
/// framed and where it sits in the room. It hands the render thread a scene
/// per snapshot (built in the background) and the placement, and answers
/// the questions hands ask: where an atom is, and which atom is where.
@MainActor
final class LabScene {
    let mailbox = LabMailbox()
    private lazy var builder = LabSceneBuilder(mailbox: mailbox)

    private var runID: UUID?
    private var demoID: String?
    var isBoxBeingMoved = false
    /// False until the lab has put the content in front of the wearer; the
    /// content stays hidden until then.
    private(set) var isPlaced = false {
        didSet { mailbox.setVisible(isPlaced) }
    }
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
    private var generation: UInt64 = 0
    /// The frame as drawn: with whole molecules on, positions are display
    /// positions and bonds include those across periodic faces. Picking and
    /// marking work on it; `simulatedPoint` maps back to the engine's frame.
    private(set) var currentSnapshot: SimulationSnapshot?
    private var drawnHighlight: LabHighlight?

    /// Where the content is, as the two-hand grip sees it.
    var placement = BoxPlacement(position: LabComfort.fallbackPosition) {
        didSet { publishPlacement() }
    }

    /// Puts the content somewhere and shows it.
    func place(_ placement: BoxPlacement) {
        self.placement = placement
        isPlaced = true
    }

    /// The visible content's size in meters at scale 1, once framed.
    var contentExtent: SIMD3<Float>? {
        if let exhibitExtent { return exhibitExtent }
        guard let frame, let snapshot = currentSnapshot else { return nil }
        return simd_max(SIMD3<Float>(snapshot.boxHigh - snapshot.boxLow) * frame.metersPerUnit, SIMD3(repeating: 0.05))
    }

    /// Meters in the world per simulation length unit, including resizing.
    var worldMetersPerSimulationUnit: Float? {
        frame.map { $0.metersPerUnit * placement.scale }
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
        guard let frame else { return point }
        return LabContent.simulationPoint(fromWorld: point, placement: placement, frame: frame)
    }

    func worldPoint(fromSimulation point: SIMD3<Float>) -> SIMD3<Float> {
        guard let frame else { return point }
        return LabContent.worldPoint(fromSimulation: point, placement: placement, frame: frame)
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

    /// Where atom `tag` is drawn in the world, if it is in the frame.
    func worldPosition(ofAtom tag: Int64) -> SIMD3<Float>? {
        guard let snapshot = currentSnapshot, let index = snapshot.index(ofTag: tag) else { return nil }
        return worldPoint(fromSimulation: snapshot.positions[index])
    }

    /// Hands a new snapshot (and the marked atom, when it changed) to the
    /// renderer. Returns the new snapshot.
    func update(run: AppModel.Run?, hasFinished: Bool, highlight: LabHighlight?) -> SimulationSnapshot? {
        guard let run else {
            clear()
            return nil
        }
        if run.id != runID { reset(for: run) }

        let terminal = hasFinished ? run.simulation.lastKnownGoodSnapshot : nil
        let finalFrame = terminal.flatMap { $0.sequence != currentSnapshot?.sequence ? $0 : nil }
        let fresh = run.simulation.takeNewSnapshot() ?? finalFrame
        if let snapshot = fresh {
            if styles == nil || styles?.styles.count != max(snapshot.typeCount, 1) {
                styles = AtomStyleTable(directives: run.directives, typeCount: snapshot.typeCount, units: snapshot.units)
            }
            let drawn = displayed(snapshot)
            if frame == nil, !framesAtoms || drawn.atomCount > 0 { frameContent(drawn) }
            currentSnapshot = drawn
        }
        if let snapshot = currentSnapshot, let styles, fresh != nil || highlight != drawnHighlight {
            if let highlight {
                mailbox.setHighlightColor(LabContent.highlightColor(highlight, in: snapshot, styles: styles))
            }
            generation &+= 1
            builder.submit(.init(snapshot: snapshot, styles: styles, showsBox: showsBox, highlight: highlight,
                                 generation: generation))
            drawnHighlight = highlight
        }
        return fresh
    }

    // MARK: - Private

    private func publishPlacement() {
        guard let frame else { return }
        mailbox.place(LabContent.worldFromSimulation(placement: placement, frame: frame))
    }

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
        if !keepsPlacement { isPlaced = false }
    }

    private func clear() {
        isBoxBeingMoved = false
        drawnHighlight = nil
        frame = nil
        exhibitExtent = nil
        styles = nil
        currentSnapshot = nil
        displayShifts = nil
        runID = nil
        generation &+= 1
        mailbox.publish(nil, generation: generation)
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
        if framesAtoms, let styles,
           let exhibit = ExhibitFraming(snapshot: snapshot, styles: styles, size: LabComfort.initialSize) {
            frame = exhibit.frame
            exhibitExtent = exhibit.extent
        } else {
            frame = SimulationFrame(boxLow: snapshot.boxLow, boxHigh: snapshot.boxHigh, size: LabComfort.initialSize)
        }
        publishPlacement()
    }
}
