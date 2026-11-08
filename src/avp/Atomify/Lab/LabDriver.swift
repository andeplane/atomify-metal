import ARKit
import AtomifyVision
import RealityKit
import simd

/// Runs a simulation in the lab at display rate: draws the newest snapshot,
/// places the experiment in front of the wearer, refreshes the held atom,
/// lets hands push atoms, and marks the atom a hand is near. LAMMPS runs on
/// its own thread.
@MainActor
final class LabDriver {
    private let hands = HandTracker()
    private let pushing = InteractionController()
    private let head = HeadTracker()
    private var activeID: UUID?
    /// When a placement in front of the wearer was asked for.
    private var placementRequested: ContinuousClock.Instant?
    /// How long to wait for a head pose before using the fallback position.
    private let headPoseWait: Duration = .seconds(1.5)

    /// The tracked hand's world orientation, when known.
    func handOrientation(_ chirality: HandAnchor.Chirality) -> simd_quatf? {
        hands.hands[chirality]?.orientation
    }

    /// Places the experiment in front of the wearer again, upright and at
    /// its initial size (Digital Crown recenter, or the panel's Recenter).
    func recenter() {
        placementRequested = .now
    }

    /// Returns when the task is cancelled (the run changed or the lab closed).
    func run(model: AppModel, scene: MoleculeScene, interaction: LabInteraction) async {
        guard let run = model.run else {
            _ = scene.update(run: nil, hasFinished: false, highlight: nil)
            return
        }
        let driverID = UUID()
        activeID = driverID
        interaction.reset()
        pushing.reset(nil)
        hands.stop()
        head.stop()
        var providers: [any DataProvider] = []
        if let provider = hands.prepareProvider() { providers.append(provider) }
        head.start(additionalProviders: providers)
        if !scene.isPlaced { placementRequested = .now }
        var highlight: MoleculeScene.Highlight?

        while !Task.isCancelled && activeID == driverID {
            if let snapshot = scene.update(run: run, hasFinished: model.hasFinished, highlight: highlight) {
                model.report(snapshot)
            }
            placeIfRequested(scene: scene, interaction: interaction)
            scene.updateTip(visible: model.tips.current != nil)

            let canInteract = model.canInteract && scene.isPlaced && scene.currentSnapshot != nil
            hold(run: run, scene: scene, interaction: interaction,
                 canHold: canInteract && !interaction.isGripping)
            if let tag = interaction.link.takeBegan() {
                scene.playGrabCue(tag: tag)
                model.atomPulled()
            }
            if canInteract && !interaction.isPinching && !interaction.isGripping && !scene.isBoxBeingMoved {
                pushing.update(hands: hands.hands, scene: scene, simulation: run.simulation)
            } else {
                pushing.reset(run.simulation)
            }
            highlight = nextHighlight(scene: scene, interaction: interaction, canInteract: canInteract)
            try? await Task.sleep(for: .milliseconds(11))
        }

        guard activeID == driverID else { return }
        activeID = nil
        interaction.reset()
        pushing.reset(run.simulation)
        run.simulation.releaseGrab()
        hands.stop()
        head.stop()
    }

    /// Refreshes the held atom's target in the engine every frame (the
    /// engine lets go of grabs that are not refreshed), or releases it.
    private func hold(run: AppModel.Run, scene: MoleculeScene, interaction: LabInteraction, canHold: Bool) {
        switch interaction.link.frame(canHold: canHold) {
        case .hold(let tag, let target):
            guard let snapshot = scene.currentSnapshot else { return }
            // Back from where the atom is drawn to its frame in the engine.
            let point = scene.simulatedPoint(fromWorld: target, nearAtom: tag)
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
            run.simulation.grab(tag: tag, target: SIMD3<Double>(point),
                                stiffness: InteractionTuning.forUnits(snapshot.units).grabStiffness, slot: 0)
        case .release:
            run.simulation.releaseGrab(slot: 0)
        case .none:
            break
        }
    }

    /// Puts the experiment in front of the wearer once it is framed and the
    /// head pose is known (or after a short wait without one).
    private func placeIfRequested(scene: MoleculeScene, interaction: LabInteraction) {
        guard let requested = placementRequested, scene.contentExtent != nil else { return }
        let pose = head.pose()
        guard pose != nil || !WorldTrackingProvider.isSupported || ContinuousClock.now - requested > headPoseWait else { return }
        placementRequested = nil
        interaction.reset()
        scene.isBoxBeingMoved = false
        scene.place(LabComfort.placement(head: pose))
    }

    /// The held atom; otherwise the one atom nearest a hand's pinch point
    /// within direct reach, while no pinch is down.
    private func nextHighlight(scene: MoleculeScene, interaction: LabInteraction,
                               canInteract: Bool) -> MoleculeScene.Highlight? {
        if let grab = interaction.link.grab { return .init(tag: grab.tag, kind: .held) }
        guard canInteract, !interaction.isPinching, let snapshot = scene.currentSnapshot,
              let metersPerUnit = scene.worldMetersPerSimulationUnit, metersPerUnit > 1e-8 else { return nil }
        let reach = AtomPick.directReach / metersPerUnit
        var best: (tag: Int64, distance: Float)?
        for hand in hands.hands.values {
            let point = scene.simulationPoint(fromWorld: hand.pinchPoint)
            guard let index = snapshot.atomNear(point, reach: reach, radius: { scene.drawnRadius($0, in: snapshot) })
            else { continue }
            let distance = simd_distance(point, snapshot.positions[index])
            if distance < best?.distance ?? .infinity { best = (snapshot.tags[index], distance) }
        }
        return best.map { .init(tag: $0.tag, kind: .near) }
    }
}
